//! A smoke test against the real API, kept out of `zig build test` so the suite
//! stays offline and costs no quota. Without INTERNETDATA_API_KEY the lookups
//! run without a key and the catalog is skipped.
//!
//!     ./scripts/zig.sh build live
//!     INTERNETDATA_API_KEY=... ./scripts/zig.sh build live
//!
//! It asserts what a stub cannot say honestly: that a member a plan leaves out
//! is ABSENT rather than false, that a real key reaches a real catalog, and
//! that the metadata document for a licensed database carries a size per format
//! that a caller could budget a transfer against. Nothing here downloads
//! anything.

const std = @import("std");
const internetdata = @import("internetdata");

const Io = std.Io;

test "live lookup" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const key = std.testing.environ.getPosix("INTERNETDATA_API_KEY") orelse "";
    var client = try internetdata.Client.init(gpa, threaded.io(), .{ .api_key = key });
    defer client.deinit();

    const result = try client.lookup("146.70.116.130");
    defer result.deinit();
    std.debug.print("146.70.116.130: {s}, {s}, is_vpn={?} city={?s} trial_expired={?}\n", .{
        result.value.location.country,
        result.value.asn.name,
        result.value.is_vpn,
        result.value.location.city,
        result.value.trial_expired,
    });
    try std.testing.expectEqualStrings("146.70.116.130", result.value.ip);
    try std.testing.expect(!result.value.is_bogon);
    try std.testing.expect(result.value.asn.asn > 0);
    if (key.len == 0) {
        // The one assertion a stub cannot make honestly: an answer without a key
        // leaves the paid members out, so they are ABSENT rather than false.
        try std.testing.expectEqual(@as(?bool, null), result.value.is_vpn);
        try std.testing.expectEqual(@as(?[]const u8, null), result.value.location.city);
        try std.testing.expectEqual(@as(?bool, null), result.value.trial_expired);
    }

    const network = try client.lookupAsn(9009);
    defer network.deinit();
    std.debug.print("AS9009: {s} ({s}), num_ips={?d}\n", .{ network.value.name, network.value.registry, network.value.num_ips });
    try std.testing.expectEqual(9009, network.value.asn);
    if (key.len == 0) {
        try std.testing.expectEqual(@as(?i64, null), network.value.num_ips);
    }

    const domain = try client.lookupDomain("example.com");
    defer domain.deinit();
    std.debug.print("example.com: registered={} has_mx={}\n", .{ domain.value.is_registered, domain.value.has_mx });
    try std.testing.expectEqualStrings("example.com", domain.value.domain);
    if (key.len == 0) {
        try std.testing.expect(domain.value.dns == null);
    }

    const private = try client.lookup("192.168.1.1");
    defer private.deinit();
    std.debug.print("192.168.1.1: is_bogon={} (answered locally)\n", .{private.value.is_bogon});
    try std.testing.expect(private.value.is_bogon);
    try std.testing.expectEqual(0, private.raw.len);
}

test "live catalog" {
    const gpa = std.testing.allocator;
    const key = std.testing.environ.getPosix("INTERNETDATA_API_KEY") orelse "";
    if (key.len == 0) {
        std.debug.print("SKIP: INTERNETDATA_API_KEY is not set\n", .{});
        return error.SkipZigTest;
    }

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var client = try internetdata.Client.init(gpa, threaded.io(), .{ .api_key = key });
    defer client.deinit();

    const catalog = try client.database().list(.{});
    defer catalog.deinit();
    try std.testing.expect(catalog.value.len > 0);

    var licensed: ?[]const u8 = null;
    for (catalog.value) |family| {
        std.debug.print("{s} ({s}): {d} version(s)\n", .{
            family.base,
            family.standing,
            family.versions.len,
        });
        try std.testing.expect(family.versions.len > 0);
        if (std.mem.eql(u8, family.standing, "licensed") and licensed == null) {
            licensed = family.versions[family.versions.len - 1].id;
        }
    }

    const id = licensed orelse {
        std.debug.print("this key licenses nothing, so there is no metadata to read\n", .{});
        return;
    };
    const info = try client.database().metadata(id, .{});
    defer info.deinit();
    std.debug.print("{s}: {d} rows, updated {s}, csvgz {?d} bytes\n", .{
        info.value.id,
        info.value.entries,
        info.value.updated,
        info.value.size.map.get("csvgz"),
    });
    try std.testing.expectEqualStrings(id, info.value.id);
    try std.testing.expect(info.value.size.map.count() > 0);
}

// Keyless: registering stores nothing until a person approves the client, so
// it is safe against the real server, which answers a self-registered ID.
test "live register" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var client = try internetdata.Client.init(gpa, threaded.io(), .{});
    defer client.deinit();

    const registration = try client.oauth().register(&.{"http://127.0.0.1:8765/callback"}, .{
        .client_name = "InternetData SDK check",
    });
    defer registration.deinit();
    std.debug.print("registered {s}..., issued at {d}, shown as {s}\n", .{
        registration.value.client_id[0..12],
        registration.value.client_id_issued_at,
        registration.value.client_name,
    });
    try std.testing.expect(std.mem.startsWith(u8, registration.value.client_id, "dcr_"));
    try std.testing.expectEqualStrings("none", registration.value.token_endpoint_auth_method);
    try std.testing.expectError(error.OauthRejected, client.oauth().register(&.{"myapp://cb"}, .{}));
}
