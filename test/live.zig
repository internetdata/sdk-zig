//! A smoke test against the real API, kept out of `zig build test` so the suite
//! stays offline and needs no credential.
//!
//!     INTERNETDATA_API_KEY=... ./scripts/zig.sh build live
//!
//! It asserts the two things a stub cannot say honestly: that a real key reaches
//! a real catalog, and that the metadata document for a licensed database
//! carries a size per format that a caller could budget a transfer against.
//! Nothing here downloads anything.

const std = @import("std");
const internetdata = @import("internetdata");

const Io = std.Io;

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
