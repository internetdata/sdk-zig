//! The published library looking up addresses, an AS and a domain, keyless on
//! staging and production, and on the suite's key on staging.
//!
//! Nothing here pins a field COUNT. What holds whatever the plan: the members
//! the spec requires are always there; a member a plan leaves out is ABSENT
//! rather than false or zero, inside a shared object too; and a field the
//! key's answer serves that the keyless one does not is null in the keyless
//! result. The suite's key is on the free plan, whose first 100 lookups of a UTC
//! day answer every field and the rest Unlimited's, so which half a run sees is
//! read off `trial_expired` rather than assumed.

const std = @import("std");
const internetdata = @import("internetdata");

const staging = @import("staging.zig");

const Rung = staging.Rung;

/// Both hosts the keyless checks run against.
const origins = [_][]const u8{ staging.upstream, staging.production };

test "a keyless lookup answers every plan's members and leaves the paid ones out" {
    const gpa = std.testing.allocator;
    for (origins) |origin| {
        const rung = try Rung.on(gpa, origin, "", .{});
        defer rung.deinit();

        const result = try rung.client.lookup(staging.probe);
        defer result.deinit();
        std.debug.print("testing against {s}\n", .{origin});

        try std.testing.expect(!rung.proxy.carriedKey());
        try std.testing.expectEqualStrings(staging.probe, result.value.ip);
        try std.testing.expect(!result.value.is_bogon);
        try std.testing.expect(result.value.asn.asn > 0);
        try std.testing.expect(result.value.location.country.len == 2);
        try expectKeylessLookup(result.value);
        try expectServedAsDecoded(gpa, result.raw, result.value);
    }
}

test "a keyless AS and domain lookup leave the paid members out" {
    const gpa = std.testing.allocator;
    for (origins) |origin| {
        const rung = try Rung.on(gpa, origin, "", .{});
        defer rung.deinit();

        const network = try rung.client.lookupAsn(9009);
        defer network.deinit();
        try std.testing.expectEqual(9009, network.value.asn);
        try std.testing.expect(network.value.name.len > 0);
        const paid = .{ "type", "num_ips", "num_prefixes4", "num_prefixes6", "rpki_valid", "rpki_invalid" } ++
            .{ "rpki_not_found", "whois", "prefixes", "trial_expired" };
        inline for (paid) |name| {
            try expectAbsent("AS " ++ name, @field(network.value, name));
        }
        try expectServedAsDecoded(gpa, network.raw, network.value);

        const domain = try rung.client.lookupDomain("example.com");
        defer domain.deinit();
        try std.testing.expectEqualStrings("example.com", domain.value.domain);
        inline for (.{ "is_disposable", "dns", "ip_ranges", "disposable", "trial_expired" }) |name| {
            try expectAbsent("domain " ++ name, @field(domain.value, name));
        }
        try expectServedAsDecoded(gpa, domain.raw, domain.value);

        const calls = rung.proxy.seen();
        try std.testing.expectEqual(2, calls.len);
        try std.testing.expectEqualStrings("/asn/9009", calls[0].path);
        try std.testing.expectEqualStrings("/domain/example.com", calls[1].path);
    }
}

test "myIp answers keyless, and myEntitlement needs a key" {
    const gpa = std.testing.allocator;
    const rung = try Rung.on(gpa, staging.upstream, "", .{});
    defer rung.deinit();

    const mine = try rung.client.myIp();
    defer mine.deinit();
    try std.testing.expect(mine.value.ip.len > 0);
    try expectKeylessLookup(mine.value);

    var diagnostics: internetdata.Diagnostics = .{};
    try std.testing.expectError(error.Unauthorized, rung.client.myEntitlementWith(.{ .diagnostics = &diagnostics }));
    try std.testing.expectEqual(@as(?u16, 401), diagnostics.status);
    try std.testing.expectEqual(2, rung.proxy.seen().len);
}

test "a bogon is answered without touching the network" {
    const gpa = std.testing.allocator;
    const rung = try Rung.on(gpa, staging.upstream, "", .{});
    defer rung.deinit();

    const result = try rung.client.lookup("10.0.0.1");
    defer result.deinit();

    try std.testing.expect(result.value.is_bogon);
    try std.testing.expect(internetdata.isBogon("10.0.0.1"));
    try std.testing.expect(rung.client.isBogon("10.0.0.1"));
    try std.testing.expectEqual(0, rung.proxy.seen().len);

    // Computed rather than served, so it carries every member whatever the
    // plan, but for `trial_expired`, which marks a free-plan key's served
    // answers and so is always null here.
    inline for (comptime std.meta.fieldNames(internetdata.Answer)) |name| {
        const marker = comptime std.mem.eql(u8, name, "trial_expired");
        const value = @field(result.value, name);
        if (comptime @typeInfo(@FieldType(internetdata.Answer, name)) == .optional) {
            if (!marker and value == null) {
                std.debug.print("{s} must be present on a bogon\n", .{name});
                return error.TestExpectedEqual;
            }
            if (marker and value != null) {
                std.debug.print("{s} must be null on a bogon\n", .{name});
                return error.TestExpectedEqual;
            }
        }
    }
}

test "a batch without a key is refused once, and its bogon still answered" {
    const gpa = std.testing.allocator;
    const rung = try Rung.on(gpa, staging.upstream, "", .{ .cache = null });
    defer rung.deinit();

    // Two addresses on the wire: a keyless batch of one is answered as its lookup.
    var batch = try rung.client.lookupBatch(&.{ staging.probe, "8.8.8.8", "10.0.0.1" }, .{});
    defer batch.deinit();

    switch (batch.get("10.0.0.1").?) {
        .ok => |answer| try std.testing.expect(answer.value.is_bogon),
        .failed => return error.TestExpectedEqual,
    }
    switch (batch.get(staging.probe).?) {
        .ok => return error.TestExpectedError,
        .failed => |failure| {
            try std.testing.expectEqual(error.Unauthorized, failure.err);
            try std.testing.expectEqual(@as(?u16, 401), failure.diagnostics.status);
        },
    }
    // One request, never retried.
    try std.testing.expectEqual(1, rung.proxy.seen().len);
    try std.testing.expectEqualStrings("/batch", rung.proxy.seen()[0].path);
    try std.testing.expectEqual(std.http.Method.POST, rung.proxy.seen()[0].method);
}

test "the key reaches the wire, and its answer says which half of the trial it is" {
    try staging.require();
    const gpa = std.testing.allocator;
    const rung = try Rung.on(gpa, staging.upstream, staging.key(), .{});
    defer rung.deinit();

    const result = try rung.client.lookup(staging.probe);
    defer result.deinit();
    try std.testing.expect(rung.proxy.carriedKey());

    const expired = result.value.trial_expired orelse {
        std.debug.print("a free-plan key's answer carries no trial_expired\n", .{});
        return error.TestExpectedEqual;
    };
    // The organization's first 100 lookups of the UTC day are answered in full,
    // and the rest as Unlimited's: which half a run sees depends on the day.
    try std.testing.expectEqual(!expired, result.value.is_vpn != null);
    try std.testing.expectEqual(!expired, result.value.location.city != null);
    try expectServedAsDecoded(gpa, result.raw, result.value);
}

test "a field the key's answer serves is absent from the keyless one, never false" {
    try staging.require();
    const gpa = std.testing.allocator;
    const keyed = try Rung.on(gpa, staging.upstream, staging.key(), .{});
    defer keyed.deinit();
    const keyless = try Rung.on(gpa, staging.upstream, "", .{});
    defer keyless.deinit();

    const wide = try keyed.client.lookup(staging.probe);
    defer wide.deinit();
    try std.testing.expect(keyed.proxy.carriedKey());
    const narrow = try keyless.client.lookup(staging.probe);
    defer narrow.deinit();

    const wide_served = try std.json.parseFromSlice(std.json.Value, gpa, wide.raw, .{});
    defer wide_served.deinit();
    const narrow_served = try std.json.parseFromSlice(std.json.Value, gpa, narrow.raw, .{});
    defer narrow_served.deinit();
    for (wide_served.value.object.keys()) |field| {
        if (narrow_served.value.object.contains(field)) {
            continue;
        }
        const held = modelled(narrow.value, field);
        if (held.known and held.present) {
            std.debug.print("{s} is not in the keyless plan, so the result must not read as a value\n", .{field});
            return error.TestExpectedEqual;
        }
    }
}

test "the key's myEntitlement reports its plan" {
    try staging.require();
    const gpa = std.testing.allocator;
    const rung = try Rung.start(gpa);
    defer rung.deinit();

    const entitlement = try rung.client.myEntitlement();
    defer entitlement.deinit();
    try rung.assertKeyReachedTheWire();
    try staging.expectOneOf("tier", entitlement.value.plan.tier, &.{ "free", "starter", "scale", "max" });
    try std.testing.expect(entitlement.value.usage.requests >= 0);
}

test "a free-plan key's batch of two is refused as a bad request, once" {
    try staging.require();
    const gpa = std.testing.allocator;
    const rung = try Rung.on(gpa, staging.upstream, staging.key(), .{ .cache = null });
    defer rung.deinit();

    var batch = try rung.client.lookupBatch(&.{ staging.probe, "8.8.8.8" }, .{});
    defer batch.deinit();
    try rung.assertKeyReachedTheWire();

    for ([_][]const u8{ staging.probe, "8.8.8.8" }) |ip| {
        switch (batch.get(ip).?) {
            .ok => return error.TestExpectedError,
            .failed => |failure| {
                try std.testing.expectEqual(error.BadRequest, failure.err);
                try std.testing.expectEqual(@as(?u16, 402), failure.diagnostics.status);
            },
        }
    }
    // One request, never retried, carrying both addresses.
    try std.testing.expectEqual(1, rung.proxy.seen().len);
    try std.testing.expectEqualStrings("/batch", rung.proxy.seen()[0].path);
    try std.testing.expectEqual(2, rung.proxy.seen()[0].ips.len);
}

test "a free-plan key's batch of one is answered" {
    try staging.require();
    const gpa = std.testing.allocator;
    const rung = try Rung.on(gpa, staging.upstream, staging.key(), .{ .cache = null });
    defer rung.deinit();

    var batch = try rung.client.lookupBatch(&.{staging.probe}, .{});
    defer batch.deinit();
    try rung.assertKeyReachedTheWire();

    switch (batch.get(staging.probe).?) {
        .ok => |answer| try std.testing.expect(answer.value.trial_expired != null),
        .failed => return error.TestExpectedEqual,
    }
}

/// What Unlimited leaves out of an address's answer, the paid members inside
/// its shared objects included.
fn expectKeylessLookup(answer: internetdata.Answer) !void {
    inline for (.{
        "is_vpn",        "is_resproxy", "is_dcproxy", "is_mobproxy",  "is_pubproxy", "is_hosting", "is_cdn",  "vpn",
        "resproxy",      "dcproxy",     "mobproxy",   "pubproxy",     "hosting",     "cdn",        "carrier", "satellite",
        "ssh",           "smtp",        "web",        "dns_resolver", "bittorrent",  "whois",      "rwhois",  "hosted_domains",
        "trial_expired",
    }) |name| {
        try expectAbsent(name, @field(answer, name));
    }
    const paid_location = .{ "region", "region_code", "city", "postal_code", "latitude", "longitude" } ++
        .{ "accuracy_radius", "geoname_id", "dma_code", "last_changed" };
    inline for (paid_location) |name| {
        try expectAbsent("location." ++ name, @field(answer.location, name));
    }
    try expectAbsent("asn.country", answer.asn.country);
    try expectAbsent("asn.rpki_status", answer.asn.rpki_status);
    try expectAbsent("company.type", answer.company.type);
    try expectAbsent("company.country", answer.company.country);
    inline for (.{ "name", "phone", "address", "country", "network", "validated", "unvalidated_since" }) |name| {
        try expectAbsent("abuse." ++ name, @field(answer.abuse, name));
    }
}

fn expectAbsent(comptime name: []const u8, value: anytype) !void {
    if (value != null) {
        std.debug.print("{s} must be ABSENT without a key\n", .{name});
        return error.TestExpectedEqual;
    }
}

/// Every top-level member the wire carried reached the result, which is what
/// makes a served `false` survive, and none the wire left out reads as a value.
/// A member the client does not model at all is the API moving ahead of the
/// pinned spec, not a drop.
fn expectServedAsDecoded(gpa: std.mem.Allocator, raw: []const u8, value: anytype) !void {
    const served = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer served.deinit();
    inline for (comptime std.meta.fieldNames(@TypeOf(value))) |name| {
        const held = @field(value, name);
        const present = if (comptime @typeInfo(@TypeOf(held)) == .optional) held != null else true;
        if (present != served.value.object.contains(name)) {
            std.debug.print("{s} was {s} on the wire and {s} in the result\n", .{
                name,
                if (served.value.object.contains(name)) "present" else "absent",
                if (present) "present" else "absent",
            });
            return error.TestExpectedEqual;
        }
    }
}

/// Whether the client holds a value for the WIRE name `field`, and whether that
/// name is one the client models at all.
fn modelled(answer: internetdata.Answer, field: []const u8) struct { known: bool, present: bool } {
    inline for (comptime std.meta.fieldNames(internetdata.Answer)) |name| {
        if (std.mem.eql(u8, name, field)) {
            const value = @field(answer, name);
            return .{
                .known = true,
                .present = if (comptime @typeInfo(@FieldType(internetdata.Answer, name)) == .optional) value != null else true,
            };
        }
    }
    return .{ .known = false, .present = false };
}
