//! Asserts the shared conformance corpus that every InternetData SDK asserts.
//!
//! The corpus is generated into testdata/ and is identical across languages, so
//! a behavior that drifts here fails here rather than surfacing as two client
//! libraries quietly disagreeing about the same address or the same refusal.

const std = @import("std");
const internetdata = @import("internetdata");

const support = @import("support.zig");
const corpus = support.corpus;

const Harness = support.Harness;
const Route = support.Route;

const metadata_path = "/api/v2/database/metadata";
const download_path = "/api/v2/database/download";

test "isBogon matches the canonical ranges" {
    const data = try corpus.load(std.testing.allocator);
    defer data.deinit();

    for (data.value.isBogon) |case| {
        std.testing.expectEqual(case.expect, internetdata.isBogon(case.ip)) catch |err| {
            std.debug.print("isBogon({s}) should be {} ({s})\n", .{ case.ip, case.expect, case.why });
            return err;
        };
    }
}

// A server listening on :: sees every IPv4 visitor as ::ffff:a.b.c.d. Read whole
// that is inside ::ffff:0:0/96, so an SDK that did not unmap answered each one
// locally as a bogon.
test "an IPv4-mapped address is the IPv4 address it carries" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    for (data.value.ipv4Mapped) |case| {
        errdefer std.debug.print("{s} carries {s} ({s})\n", .{ case.ip, case.carries, case.why });
        try std.testing.expectEqual(case.expect, internetdata.isBogon(case.ip));

        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try harness.stub.routeLookup(case.carries);
        var client = try harness.client(.{ .retries = 0 });
        defer client.deinit();

        const result = try client.lookup(case.ip);
        defer result.deinit();
        try std.testing.expectEqualStrings(case.carries, result.value.ip);
        try std.testing.expectEqual(case.expect, result.value.is_bogon);
        if (case.expect) {
            try std.testing.expectEqual(0, harness.stub.callCount());
        } else {
            try std.testing.expect(harness.stub.calledOnly(try harness.stub.printed("/{s}", .{case.carries})));
            const again = try client.lookup(case.carries);
            defer again.deinit();
            try std.testing.expectEqual(1, harness.stub.callCount());
        }

        // The mapped form alone: asked beside its plain form, a batch that sent
        // the address as given would still have been answered for the plain one.
        var fresh = try harness.client(.{ .retries = 0 });
        defer fresh.deinit();
        const before = harness.stub.callCount();
        var batch = try fresh.lookupBatch(&.{case.ip}, .{});
        defer batch.deinit();
        try std.testing.expectEqual(1, batch.count());
        try std.testing.expectEqualStrings(case.ip, batch.keys()[0]);
        try std.testing.expectEqualStrings(case.carries, batch.get(case.ip).?.ok.value.ip);
        if (case.expect) {
            try std.testing.expectEqual(before, harness.stub.callCount());
        } else {
            try std.testing.expectEqual(before + 1, harness.stub.callCount());
            const sent = try std.json.parseFromSlice(struct { ips: []const []const u8 }, gpa, harness.stub.seen()[before].body, .{});
            defer sent.deinit();
            try std.testing.expectEqual(1, sent.value.ips.len);
            try std.testing.expectEqualStrings(case.carries, sent.value.ips[0]);
        }
    }
}

test "a bogon is answered locally in the widest shape" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const want = data.value.bogonResponse;

    const harness = try Harness.start(gpa);
    defer harness.deinit();
    var client = try harness.client(.{});
    defer client.deinit();

    const result = try client.lookup("10.0.0.1");
    defer result.deinit();

    try std.testing.expect(result.value.is_bogon);
    try std.testing.expectEqualStrings("10.0.0.1", result.value.ip);
    try std.testing.expectEqualStrings("", result.raw);
    for (want.flagsFalse) |name| {
        try std.testing.expectEqual(corpus.Member{ .flag = false }, corpus.member(result.value, name));
    }
    for (want.emptyObjects) |name| {
        try std.testing.expectEqual(corpus.Member.empty_object, corpus.member(result.value, name));
    }
    for (want.emptyLists) |name| {
        try std.testing.expectEqual(corpus.Member.empty_list, corpus.member(result.value, name));
    }
    // Member for member, the corpus's answer with the address filled in.
    const encoded = try std.json.Stringify.valueAlloc(gpa, result.value, .{ .emit_null_optional_fields = false });
    defer gpa.free(encoded);
    const answered = try std.json.parseFromSlice(std.json.Value, gpa, encoded, .{});
    defer answered.deinit();
    try std.testing.expectEqual(want.answer.object.count() + 1, answered.value.object.count());
    try std.testing.expectEqualStrings("10.0.0.1", answered.value.object.get("ip").?.string);
    var members = want.answer.object.iterator();
    while (members.next()) |entry| {
        const got = answered.value.object.get(entry.key_ptr.*) orelse {
            std.debug.print("a bogon carries no {s}\n", .{entry.key_ptr.*});
            return error.TestExpectedEqual;
        };
        if (!corpus.sameJson(entry.value_ptr.*, got)) {
            std.debug.print("a bogon's {s} is {f}, expected {f}\n", .{
                entry.key_ptr.*,
                std.json.fmt(got, .{}),
                std.json.fmt(entry.value_ptr.*, .{}),
            });
            return error.TestExpectedEqual;
        }
    }
    try std.testing.expectEqual(0, harness.stub.callCount());
}

// Every case is a plan's served answer: what the plan leaves out must come back
// null, never false or 0, and that includes the paid members inside an object
// every plan answers.
test "every plan shape keeps absent apart from false, in all three lookups" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    for (data.value.lookup) |case| {
        errdefer std.debug.print("{s}\n", .{case.name});
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        const path = if (std.mem.eql(u8, case.call, "lookupAsn"))
            try harness.stub.printed("/asn/{d}", .{case.target.integer})
        else if (std.mem.eql(u8, case.call, "lookupDomain"))
            try harness.stub.printed("/domain/{s}", .{case.target.string})
        else
            try harness.stub.printed("/{s}", .{case.target.string});
        try harness.stub.route(path, .{
            .status = case.status,
            .body = try corpus.json(harness.stub.arena.allocator(), case.body),
        });

        var client = try harness.client(.{});
        defer client.deinit();
        if (std.mem.eql(u8, case.call, "lookupAsn")) {
            const result = try client.lookupAsn(@intCast(case.target.integer));
            defer result.deinit();
            try expectLookupCase(gpa, result.value, case);
        } else if (std.mem.eql(u8, case.call, "lookupDomain")) {
            const result = try client.lookupDomain(case.target.string);
            defer result.deinit();
            try expectLookupCase(gpa, result.value, case);
        } else {
            const result = try client.lookup(case.target.string);
            defer result.deinit();
            try expectLookupCase(gpa, result.value, case);
        }
        try std.testing.expect(harness.stub.calledOnly(path));
    }
}

fn expectLookupCase(gpa: std.mem.Allocator, value: anytype, case: corpus.LookupCase) !void {
    for (case.expect.present.map.keys(), case.expect.present.map.values()) |name, want| {
        corpus.expectPresent(value, name, want) catch |err| {
            std.debug.print("{s}: {s} must be present and {f}\n", .{ case.name, name, std.json.fmt(want, .{}) });
            return err;
        };
    }
    for (case.expect.objects) |name| {
        switch (corpus.member(value, name)) {
            .empty_object, .populated_object, .empty_list, .populated_list => {},
            else => {
                std.debug.print("{s}: {s} must be present as an object\n", .{ case.name, name });
                return error.TestExpectedEqual;
            },
        }
    }
    for (case.expect.empty) |name| {
        switch (corpus.member(value, name)) {
            .empty_object, .empty_list => {},
            else => {
                std.debug.print("{s}: {s} must be present and EMPTY\n", .{ case.name, name });
                return error.TestExpectedEqual;
            },
        }
    }
    for (case.expect.absent) |name| {
        std.testing.expectEqual(corpus.Member.absent, corpus.member(value, name)) catch |err| {
            std.debug.print("{s}: {s} must be ABSENT\n", .{ case.name, name });
            return err;
        };
    }
    for (case.expect.absentIn.map.keys(), case.expect.absentIn.map.values()) |object, names| {
        try corpus.expectAbsentIn(value, object, names);
    }
    // Encoded again, the answer is the body it was served, so no member the
    // body holds was dropped, renamed or read as another type, at any depth.
    const encoded = try std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
    defer gpa.free(encoded);
    const decoded = try std.json.parseFromSlice(std.json.Value, gpa, encoded, .{});
    defer decoded.deinit();
    if (!corpus.sameJson(case.body, decoded.value)) {
        std.debug.print("{s}: decoded as {s}\n", .{ case.name, encoded });
        return error.TestExpectedEqual;
    }
}

// A lookup's refusal carries its message in `error` and a database's in `rc`,
// and every case is run against both kinds of call: the three lookups here, a
// database call and the download redirect below.
test "a lookup classifies every refusal by range and by Retry-After, never by an enumerated list" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    const paths = [_][]const u8{ "/146.70.116.130", "/asn/9009", "/domain/example.com" };
    for (data.value.errors) |case| for (paths) |path| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try routeFailure(harness, path, case);

        // A case that must not be retried gets retries anyway, and the request
        // count is what shows none was spent; a retryable one gets none, so it
        // surfaces rather than looping.
        var client = try harness.client(.{ .retries = if (case.expect.retryable) 0 else 2 });
        defer client.deinit();

        var diagnostics: internetdata.Diagnostics = .{};
        const options: internetdata.CallOptions = .{ .diagnostics = &diagnostics };
        const err = if (path[1] == 'a')
            failureOf(client.lookupAsnWith(9009, options), case.name)
        else if (path[1] == 'd')
            failureOf(client.lookupDomainWith("example.com", options), case.name)
        else
            failureOf(client.lookupWith("146.70.116.130", options), case.name);
        std.testing.expectEqual(1, harness.stub.callCount()) catch |e| {
            std.debug.print("{s} on {s}: retried\n", .{ case.name, path });
            return e;
        };
        try expectCase(case, err, diagnostics);
    };
}

test "a batch dedupes, short circuits bogons and keys by address" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const case = data.value.batchCase("dedup-bogon-and-order-free-keying");

    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");
    try harness.stub.routeLookup("8.8.8.8");

    var client = try harness.client(.{});
    defer client.deinit();
    var batch = try client.lookupBatch(case.input, .{});
    defer batch.deinit();

    // Keyed by address, not positional, and in the order each was first seen.
    try std.testing.expectEqual(case.expect.keys.len, batch.count());
    for (case.expect.keys, batch.keys()) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
    try std.testing.expectEqual(case.expect.httpRequests.?, harness.stub.callCount());
    for (case.expect.bogonKeys) |ip| {
        try std.testing.expect(batch.get(ip).?.ok.value.is_bogon);
    }
}

test "one bad address does not lose the rest of the batch" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const case = data.value.batchCase("partial-failure-does-not-fail-the-batch");

    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();
    var batch = try client.lookupBatch(case.input, .{});
    defer batch.deinit();

    for (case.expect.keys, batch.keys()) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
    for (case.expect.errorKeys) |ip| {
        const failure = batch.get(ip).?.failed;
        const want = case.expect.errorKinds.?.object.get(ip).?.string;
        try std.testing.expectEqualStrings(want, internetdata.kindName(failure.err));
        try std.testing.expectEqualStrings(support.not_a_target, failure.diagnostics.message());
    }
    try std.testing.expectEqualStrings("1.1.1.1", batch.get("1.1.1.1").?.ok.value.ip);
}

test "a cache hit issues no second request" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const case = data.value.batchCase("cache-hit-issues-no-second-request");

    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    var client = try harness.client(.{});
    defer client.deinit();
    for (0..case.repeat orelse 1) |_| {
        var batch = try client.lookupBatch(case.input, .{});
        batch.deinit();
    }
    try std.testing.expectEqual(case.expect.httpRequests.?, harness.stub.callCount());
}

// Both the boundary and the absence of any cap: a batch of any size is chunks of
// 1000, never a refusal.
test "a large batch is sent in chunks of a thousand" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    for ([_][]const u8{ "chunks-of-one-thousand", "uncapped-input-is-chunked" }) |name| {
        const case = data.value.batchCase(name);
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        for (case.input) |ip| {
            try harness.stub.routeLookup(ip);
        }

        var client = try harness.client(.{ .cache = null });
        defer client.deinit();
        var batch = try client.lookupBatch(case.input, .{});
        defer batch.deinit();

        try std.testing.expectEqual(case.expect.keyCount.?, batch.count());
        std.testing.expectEqual(case.expect.httpRequests.?, harness.stub.callCount()) catch |err| {
            std.debug.print("{s}: requests\n", .{name});
            return err;
        };
        for (case.input) |ip| {
            try std.testing.expectEqualStrings(ip, batch.get(ip).?.ok.value.ip);
        }
    }
}

// A per-entry failure carries no headers, so its 429 can only be a spent
// allowance, and a 500 is the server's; neither is retried per entry, because
// retries belong to the call and the call succeeded.
test "an entry error is classified by its status" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const case = data.value.batchCase("an-entry-error-is-classified-by-its-status");

    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");
    try harness.stub.route("/8.8.8.8", .{
        .status = 429,
        .body = "{\"error\":\"overage cap reached; raise or remove it in Billing\"}",
    });
    try harness.stub.route("/9.9.9.9", .{ .status = 500, .body = "{\"error\":\"lookup failed\"}" });

    var client = try harness.client(.{ .retries = 3 });
    defer client.deinit();
    var batch = try client.lookupBatch(case.input, .{});
    defer batch.deinit();

    for (case.expect.keys, batch.keys()) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
    var kinds = case.expect.errorKinds.?.object.iterator();
    while (kinds.next()) |entry| {
        const failure = batch.get(entry.key_ptr.*).?.failed;
        try std.testing.expectEqualStrings(entry.value_ptr.string, internetdata.kindName(failure.err));
    }
    try std.testing.expectEqual(case.expect.httpRequests.?, harness.stub.callCount());
}

test "two clients never share a cached answer" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    var first = try harness.client(.{ .api_key = "key-a" });
    defer first.deinit();
    var second = try harness.client(.{ .api_key = "key-b" });
    defer second.deinit();

    (try first.lookup("1.1.1.1")).deinit();
    (try second.lookup("1.1.1.1")).deinit();

    // Two keys can be on different plans and so entitled to different fields; a
    // shared cache would serve one of them the other's shape.
    try std.testing.expectEqual(2, harness.stub.callCount());
}

test "caching can be turned off" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    var client = try harness.client(.{ .cache = null });
    defer client.deinit();
    (try client.lookup("1.1.1.1")).deinit();
    (try client.lookup("1.1.1.1")).deinit();

    try std.testing.expectEqual(2, harness.stub.callCount());
}

test "every generated range is reachable through the predicate" {
    const data = try corpus.load(std.testing.allocator);
    defer data.deinit();

    for (data.value.bogons.v4) |cidr| {
        try std.testing.expect(internetdata.isBogon(cidr[0..std.mem.indexOfScalar(u8, cidr, '/').?]));
    }
    for (data.value.bogons.v6) |cidr| {
        try std.testing.expect(internetdata.isBogon(cidr[0..std.mem.indexOfScalar(u8, cidr, '/').?]));
    }
}

test "an error is classified by range and by Retry-After, never by an enumerated list" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    for (data.value.errors) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try routeFailure(harness, metadata_path, case);

        // A case that must not be retried gets retries anyway, and the request
        // count is what shows none was spent; a retryable one gets none, so it
        // surfaces rather than looping.
        var client = try harness.client(.{ .api_key = "key", .retries = if (case.expect.retryable) 0 else 2 });
        defer client.deinit();

        var diagnostics: internetdata.Diagnostics = .{};
        const err = failureOf(client.database().metadata("bogon_ip_v1", .{ .diagnostics = &diagnostics }), case.name);
        std.testing.expectEqual(1, harness.stub.callCount()) catch |e| {
            std.debug.print("{s}: retried\n", .{case.name});
            return e;
        };
        try expectCase(case, err, diagnostics);
    }
}

// The redirect endpoint reads a refusal through its own code path: the body of a
// 302 is never read, so a failure there classifies from the status and the
// envelope separately from the JSON calls above.
test "the download redirect classifies a refusal the same way" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    for (data.value.errors) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try routeFailure(harness, download_path, case);

        var client = try harness.client(.{ .api_key = "key", .retries = if (case.expect.retryable) 0 else 2 });
        defer client.deinit();

        var diagnostics: internetdata.Diagnostics = .{};
        const err = urlFailureOf(
            client.database().downloadUrl("bogon_ip_v1", .csvgz, .{ .diagnostics = &diagnostics }),
            gpa,
            case.name,
        );
        std.testing.expectEqual(1, harness.stub.callCount()) catch |e| {
            std.debug.print("{s}: retried\n", .{case.name});
            return e;
        };
        try expectCase(case, err, diagnostics);
    }
}

// An enum tag std.json does not know fails the WHOLE response, so a value the
// API adds after this release would take every older client down with it.
test "a closed set the API may extend still parses" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const arena = harness.stub.arena.allocator();

    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, "{\"databases\":[");
    var count: usize = 0;
    for (data.value.standings) |standing| {
        for (data.value.license_type) |license_type| {
            try appendFamily(arena, &body, count, standing, license_type);
            count += 1;
        }
    }
    // Not in any documented set, and the whole point: today's client has to keep
    // reading tomorrow's answer.
    try appendFamily(arena, &body, count, "provisional", "sublicense");
    count += 1;
    try body.appendSlice(arena, "]}");
    try harness.stub.route("/api/v2/database/list", .ok(body.items));

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const catalog = try client.database().list(.{});
    defer catalog.deinit();

    try std.testing.expectEqual(count, catalog.value.len);
    try std.testing.expectEqualStrings("provisional", catalog.value[count - 1].standing);
    try std.testing.expectEqualStrings("sublicense", catalog.value[count - 1].license_type.?);
}

// A format is the one closed set that is an INPUT, so it IS an enum: a typo
// should not reach the wire to come back as a 400.
test "every documented format is one the client can ask for" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    const tags = std.meta.fieldNames(internetdata.Format);
    try std.testing.expectEqual(data.value.formats.len, tags.len);
    for (data.value.formats) |format| {
        const parsed = std.meta.stringToEnum(internetdata.Format, format) orelse {
            std.debug.print("the client cannot ask for the {s} format\n", .{format});
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(format, parsed.toString());
    }
}

// A database built for one customer is ABSENT from everybody else's listing
// rather than present with an `unlicensed` standing, so a client that fills in
// the gap from anywhere would be publishing a customer relationship.
test "the visibility contract holds, rule by rule" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    for (data.value.visibility.clientRules) |rule| {
        if (std.mem.eql(u8, rule, "listing-is-returned-as-served")) {
            try servedAsIs(gpa);
        } else if (std.mem.eql(u8, rule, "no-catalog-is-compiled-into-the-client")) {
            try nothingIsInvented(gpa);
        } else if (std.mem.eql(u8, rule, "a-listing-is-never-reused-across-clients")) {
            try neverReused(gpa);
        } else {
            std.debug.print("the corpus asks for a visibility rule this SDK does not assert: {s}\n", .{rule});
            return error.TestExpectedEqual;
        }
    }
}

/// The listing a caller reads is the one the server sent, in its order, with
/// nothing added and nothing dropped.
fn servedAsIs(gpa: std.mem.Allocator) !void {
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .ok(
        \\{"databases":[
        \\ {"base":"bogon_ip","name":"Bogon IP","summary":"s","standing":"licensed","open":false,
        \\  "license_type":"standard","starts":"2026-09-04T18:04:26.431Z","expires":null,"renews_at":null,"notice_due_at":null,
        \\  "versions":[{"id":"bogon_ip_v1","version":1,"summary":"s","formats":["csvgz","mmdb"]}]},
        \\ {"base":"cdn_ip","name":"CDN IP","summary":"s","standing":"unlicensed","open":false,
        \\  "license_type":null,"starts":null,"expires":null,"renews_at":null,"notice_due_at":null,
        \\  "versions":[{"id":"cdn_ip_v1","version":1,"summary":"s","formats":["csvgz"]}]},
        \\ {"base":"tor_ip","name":"Tor IP","summary":"s","standing":"unlicensed","open":true,
        \\  "versions":[{"id":"tor_ip_v1","version":1,"summary":"s","formats":["csvgz"]}]}]}
    ));

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const catalog = try client.database().list(.{});
    defer catalog.deinit();

    try std.testing.expectEqual(3, catalog.value.len);
    try std.testing.expectEqualStrings("bogon_ip", catalog.value[0].base);
    try std.testing.expectEqualStrings("cdn_ip", catalog.value[1].base);
    try std.testing.expectEqualStrings("tor_ip", catalog.value[2].base);
    // Not licensed, so no term and no license_type right. Null rather than a
    // stand-in value, which a caller could mistake for a grant.
    try std.testing.expect(catalog.value[1].license_type == null);
    try std.testing.expect(catalog.value[1].expires == null);
    try std.testing.expectEqualStrings("standard", catalog.value[0].license_type.?);
    // Sent as null above and left out entirely here. Both mean the same thing,
    // and neither may fall back to a value that reads as a grant.
    try std.testing.expect(catalog.value[2].license_type == null);
    try std.testing.expect(catalog.value[2].starts == null);
    try std.testing.expect(catalog.value[2].expires == null);
}

/// An empty listing comes back empty. Nothing in the library holds a catalog to
/// fall back on, so a family this key may not see has no way to appear.
fn nothingIsInvented(gpa: std.mem.Allocator) !void {
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .ok("{\"databases\":[]}"));

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const catalog = try client.database().list(.{});
    defer catalog.deinit();
    try std.testing.expectEqual(0, catalog.value.len);
}

/// Two keys can be licensed for two different sets, so an answer held for one is
/// not an answer for the other. Nothing is cached, per client or globally.
fn neverReused(gpa: std.mem.Allocator) !void {
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .ok("{\"databases\":[]}"));

    var first = try harness.client(.{ .api_key = "key-a" });
    defer first.deinit();
    var second = try harness.client(.{ .api_key = "key-b" });
    defer second.deinit();

    (try first.database().list(.{})).deinit();
    (try second.database().list(.{})).deinit();
    (try first.database().list(.{})).deinit();

    const calls = harness.stub.seen();
    try std.testing.expectEqual(3, calls.len);
    try std.testing.expectEqualStrings("Bearer key-a", calls[0].authorization);
    try std.testing.expectEqualStrings("Bearer key-b", calls[1].authorization);
    try std.testing.expectEqualStrings("Bearer key-a", calls[2].authorization);
}

fn appendFamily(
    arena: std.mem.Allocator,
    body: *std.ArrayList(u8),
    index: usize,
    standing: []const u8,
    license_type: []const u8,
) !void {
    if (index > 0) {
        try body.append(arena, ',');
    }
    try body.print(arena,
        \\{{"base":"b{d}","name":"n","summary":"s","standing":"{s}","open":false,"license_type":"{s}",
        \\ "starts":null,"expires":null,"renews_at":null,"notice_due_at":null,
        \\ "versions":[{{"id":"b{d}_v1","version":1,"summary":"s","formats":["csvgz"]}}]}}
    , .{ index, standing, license_type, index });
}

fn routeFailure(harness: *Harness, path: []const u8, case: corpus.ErrorCase) !void {
    const arena = harness.stub.arena.allocator();
    var headers: std.ArrayList(Route.Header) = .empty;
    for (case.headers.map.keys(), case.headers.map.values()) |name, value| {
        try headers.append(arena, .{ .name = name, .value = value });
    }
    try harness.stub.route(path, .{
        .status = case.status,
        .body = try corpus.json(arena, case.body),
        .headers = try headers.toOwnedSlice(arena),
    });
}

fn expectCase(
    case: corpus.ErrorCase,
    err: internetdata.CallError,
    diagnostics: internetdata.Diagnostics,
) !void {
    std.testing.expectEqualStrings(case.expect.kind, internetdata.kindName(err)) catch |e| {
        std.debug.print("{s}: wrong kind\n", .{case.name});
        return e;
    };
    try std.testing.expectEqual(case.expect.retryable, internetdata.isRetryable(err));
    try std.testing.expectEqual(case.status, diagnostics.status.?);
    if (case.expect.message) |message| {
        try std.testing.expectEqualStrings(message, diagnostics.message());
    }
    if (case.expect.retryAfterSeconds) |seconds| {
        try std.testing.expectEqual(seconds, diagnostics.retry_after_s.?);
    }
}

fn failureOf(result: anytype, name: []const u8) internetdata.CallError {
    if (result) |answer| {
        answer.deinit();
        std.debug.panic("{s}: the call should have failed", .{name});
    } else |err| {
        return err;
    }
}

fn urlFailureOf(
    result: internetdata.CallError![]u8,
    gpa: std.mem.Allocator,
    name: []const u8,
) internetdata.CallError {
    if (result) |url| {
        gpa.free(url);
        std.debug.panic("{s}: the call should have failed", .{name});
    } else |err| {
        return err;
    }
}
