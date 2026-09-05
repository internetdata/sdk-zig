//! The library as PUBLISHED, against the real staging API.
//!
//! The transfer is budgeted before it starts. Metadata publishes a size per
//! format, and that size is checked against the ceiling below FIRST, so a
//! mistaken database id can never quietly pull one of the gigabyte databases
//! through CI.
//!
//! Nothing here names a database this organization is not licensed for. The
//! unlicensed id a refusal is asserted against is picked out of the listing at
//! run time, so the suite cannot rot when a licence changes and cannot publish a
//! customer relationship the API deliberately hides.

const std = @import("std");
const internetdata = @import("internetdata");

const staging = @import("staging.zig");

/// The organization licenses the two bogon databases and nothing else. At 264
/// bytes and 760 bytes they are the only ones small enough to move in CI, and
/// this one is published in both formats.
const dataset_id = "bogon_ip_v1";
const format: internetdata.Format = .csvgz;

/// 8 MiB against a 760-byte database. Four orders of magnitude of headroom, so
/// tripping it means the suite is pointed somewhere unintended, which is exactly
/// when a transfer must not go ahead.
const ceiling = 8 << 20;

const standings = [_][]const u8{ "licensed", "expired", "unlicensed" };
const redistributions = [_][]const u8{ "evaluation", "internal", "redistribute" };

test "the catalogue answers the schema the client was written from" {
    const gpa = std.testing.allocator;
    try staging.require();
    const rung = try staging.Rung.start(gpa);
    defer rung.deinit();

    const catalog = try rung.client.list(.{});
    defer catalog.deinit();
    try rung.assertKeyReachedTheWire();
    try std.testing.expect(catalog.value.len > 0);

    for (catalog.value) |family| {
        try std.testing.expect(family.base.len > 0);
        try std.testing.expect(family.name.len > 0);
        try std.testing.expect(family.summary.len > 0);
        try staging.expectOneOf("standing", family.standing, &standings);
        if (family.redistribution) |right| {
            try staging.expectOneOf("redistribution", right, &redistributions);
        }
        // The point of the family shape: a licence covers the family, and these
        // are the ids the download, checksum and metadata calls take.
        try std.testing.expect(family.versions.len > 0);
        for (family.versions) |version| {
            try std.testing.expect(version.id.len > 0);
            try std.testing.expect(version.formats.len > 0);
        }
        if (!std.mem.eql(u8, family.standing, "unlicensed")) {
            std.debug.print("{s}: {s}\n", .{ family.base, family.standing });
        }
    }
}

// The listing is the server's answer about this key, and the client must hand it
// back unchanged. Adding an entry would advertise a database this key may not
// see; dropping one would hide a licence it holds. Compared against the bytes
// the proxy recorded, so the check does not go through the same model it tests.
test "the listing is returned exactly as served" {
    const gpa = std.testing.allocator;
    try staging.require();
    const rung = try staging.Rung.start(gpa);
    defer rung.deinit();

    const catalog = try rung.client.list(.{});
    defer catalog.deinit();
    try rung.assertKeyReachedTheWire();

    const served = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        rung.proxy.body("/api/v2/database/list").?,
        .{},
    );
    defer served.deinit();

    const items = served.value.object.get("databases").?.array.items;
    try std.testing.expectEqual(items.len, catalog.value.len);
    for (items, catalog.value) |raw, family| {
        try std.testing.expectEqualStrings(raw.object.get("base").?.string, family.base);
        try std.testing.expectEqualStrings(raw.object.get("standing").?.string, family.standing);
        // Null on the wire has to stay null here: a licence term the client
        // invents reads as a grant nobody signed.
        try std.testing.expectEqual(
            raw.object.get("redistribution").? == .null,
            family.redistribution == null,
        );
    }
}

// A licence refusal is the API saying no, not a wobble: retrying it spends quota
// to be told the same thing again.
test "a database the organization does not license is refused once" {
    const gpa = std.testing.allocator;
    try staging.require();
    const rung = try staging.Rung.start(gpa);
    defer rung.deinit();

    const catalog = try rung.client.list(.{});
    defer catalog.deinit();
    try rung.assertKeyReachedTheWire();

    const unlicensed = firstUnlicensed(catalog.value) orelse {
        std.debug.print("this key licenses the whole catalogue, so nothing can be refused\n", .{});
        return error.TestExpectedEqual;
    };
    const before = rung.proxy.seen().len;

    var diagnostics: internetdata.Diagnostics = .{};
    const failure = rung.client.downloadUrl(unlicensed, format, .{
        .retries = 3,
        .diagnostics = &diagnostics,
    });
    if (failure) |url| {
        gpa.free(url);
        std.debug.print("{s} was served, so it is licensed to this organization now\n", .{unlicensed});
        return error.TestExpectedEqual;
    } else |err| {
        try std.testing.expectEqual(error.Forbidden, err);
        try std.testing.expect(!internetdata.isRetryable(err));
    }
    try std.testing.expectEqual(@as(?u16, 403), diagnostics.status);
    // The API says WHICH refusal this is (`{"rc":"NOT_LICENSED"}`). An empty
    // message means the envelope went unread.
    try std.testing.expect(diagnostics.message().len > 0);
    std.debug.print("{s}: {s}\n", .{ unlicensed, diagnostics.message() });
    // Three retries were offered and none were taken: a 4xx is not transient.
    try std.testing.expectEqual(1, rung.proxy.seen().len - before);
}

test "a real database moves intact, in memory and on disk" {
    const gpa = std.testing.allocator;
    try staging.require();
    const rung = try staging.Rung.start(gpa);
    defer rung.deinit();

    const info = try rung.client.metadata(dataset_id, .{});
    defer info.deinit();
    try rung.assertKeyReachedTheWire();
    try std.testing.expectEqualStrings(dataset_id, info.value.id);
    try std.testing.expect(info.value.entries > 0);

    const size = info.value.size.map.get(@tagName(format)) orelse {
        std.debug.print("{s} publishes no {t} size to check a transfer against\n", .{ dataset_id, format });
        return error.TestExpectedEqual;
    };
    if (size <= 0 or size > ceiling) {
        std.debug.print("{s} is {d} bytes, past the {d} ceiling, so it is not transferred\n", .{
            dataset_id, size, ceiling,
        });
        return error.TestExpectedEqual;
    }

    var scratch = staging.Scratch.start();
    defer scratch.deinit();
    const path = scratch.path(dataset_id ++ ".csv.gz");
    const written = try rung.client.download(dataset_id, format, path, .{});
    std.debug.print("{s}.{t}: {d} bytes, metadata says {d}\n", .{ dataset_id, format, written, size });

    try std.testing.expect(written > 0);
    // Nothing partial may outlive a transfer that finished.
    try std.testing.expect(!scratch.exists(dataset_id ++ ".csv.gz.part"));

    const on_disk = try gpa.alloc(u8, ceiling);
    defer gpa.free(on_disk);
    const bytes = try scratch.read(dataset_id ++ ".csv.gz", on_disk);
    try std.testing.expectEqual(written, bytes.len);
    try std.testing.expect(bytes.len > 1 and bytes[0] == 0x1f and bytes[1] == 0x8b);

    // Read AFTER the transfer, so a rebuild between the two calls shows up as a
    // digest mismatch rather than passing against the digest of nothing.
    const digests = try rung.client.checksums(dataset_id, format, .{});
    defer digests.deinit();
    try std.testing.expectEqual(64, digests.value.sha256.len);
    try std.testing.expectEqualStrings(digests.value.sha256, &digest(bytes));

    // The in-memory variant has to be the same file, not merely a similar one.
    const in_memory = try rung.client.downloadBytes(dataset_id, format, .{});
    defer gpa.free(in_memory);
    try std.testing.expectEqualSlices(u8, bytes, in_memory);
}

// Refusals are listed too, so the entry a licence refusal just produced is what
// answers "it stopped working". This runs last of the download tests only in the
// sense that it does not depend on them: the history may legitimately be empty.
test "the download history answers the documented shape" {
    const gpa = std.testing.allocator;
    try staging.require();
    const rung = try staging.Rung.start(gpa);
    defer rung.deinit();

    const history = try rung.client.downloads(20, .{});
    defer history.deinit();
    try rung.assertKeyReachedTheWire();

    const outcomes = [_][]const u8{ "ok", "unauthorized", "denied", "expired", "unknown", "unavailable" };
    for (history.value) |attempt| {
        try std.testing.expect(attempt.dataset_id.len > 0);
        try std.testing.expect(attempt.created.len > 0);
        try staging.expectOneOf("outcome", attempt.outcome, &outcomes);
    }
    std.debug.print("{d} recent download attempt(s)\n", .{history.value.len});
}

/// A real catalogue id this organization holds no licence for, taken from the
/// listing rather than hardcoded so the suite cannot name one it should not and
/// cannot rot when a licence changes.
fn firstUnlicensed(catalog: []const internetdata.DatabaseFamily) ?[]const u8 {
    for (catalog) |family| {
        if (std.mem.eql(u8, family.standing, "unlicensed") and family.versions.len > 0) {
            return family.versions[family.versions.len - 1].id;
        }
    }
    return null;
}

fn digest(bytes: []const u8) [64]u8 {
    var sum: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sum, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&sum}) catch unreachable;
    return hex;
}
