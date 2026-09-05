//! Asserts the shared conformance corpus that every InternetData SDK asserts.
//!
//! The corpus is generated into testdata/ and is identical across languages, so
//! a behavior that drifts here fails here rather than surfacing as two client
//! libraries quietly disagreeing about the same refusal.

const std = @import("std");
const internetdata = @import("internetdata");

const support = @import("support.zig");
const corpus = support.corpus;

const Harness = support.Harness;
const Route = support.Route;

const metadata_path = "/api/v2/database/metadata";
const download_path = "/api/v2/database/download";

test "an error is classified by range and by Retry-After, never by an enumerated list" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    for (data.value.errors) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try routeFailure(harness, metadata_path, case);

        // No retries, so a retryable failure surfaces rather than looping.
        var client = try harness.client(.{ .api_key = "key", .retries = 0 });
        defer client.deinit();

        var diagnostics: internetdata.Diagnostics = .{};
        const err = failureOf(client.metadata("bogon_ip_v1", .{ .diagnostics = &diagnostics }), case.name);
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

        var client = try harness.client(.{ .api_key = "key", .retries = 0 });
        defer client.deinit();

        var diagnostics: internetdata.Diagnostics = .{};
        const err = urlFailureOf(
            client.downloadUrl("bogon_ip_v1", .csvgz, .{ .diagnostics = &diagnostics }),
            gpa,
            case.name,
        );
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
        for (data.value.redistribution) |redistribution| {
            try appendFamily(arena, &body, count, standing, redistribution);
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
    const catalog = try client.list(.{});
    defer catalog.deinit();

    try std.testing.expectEqual(count, catalog.value.len);
    try std.testing.expectEqualStrings("provisional", catalog.value[count - 1].standing);
    try std.testing.expectEqualStrings("sublicense", catalog.value[count - 1].redistribution.?);
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
        \\ {"base":"bogon_ip","name":"Bogon IP","summary":"s","standing":"licensed",
        \\  "redistribution":"internal","starts":"2026-09-04T18:04:26.431Z","expires":null,
        \\  "versions":[{"id":"bogon_ip_v1","version":1,"summary":"s","formats":["csvgz","mmdb"]}]},
        \\ {"base":"cdn_ip","name":"CDN IP","summary":"s","standing":"unlicensed",
        \\  "redistribution":null,"starts":null,"expires":null,
        \\  "versions":[{"id":"cdn_ip_v1","version":1,"summary":"s","formats":["csvgz"]}]},
        \\ {"base":"tor_ip","name":"Tor IP","summary":"s","standing":"unlicensed",
        \\  "versions":[{"id":"tor_ip_v1","version":1,"summary":"s","formats":["csvgz"]}]}]}
    ));

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const catalog = try client.list(.{});
    defer catalog.deinit();

    try std.testing.expectEqual(3, catalog.value.len);
    try std.testing.expectEqualStrings("bogon_ip", catalog.value[0].base);
    try std.testing.expectEqualStrings("cdn_ip", catalog.value[1].base);
    try std.testing.expectEqualStrings("tor_ip", catalog.value[2].base);
    // Not licensed, so no term and no redistribution right. Null rather than a
    // stand-in value, which a caller could mistake for a grant.
    try std.testing.expect(catalog.value[1].redistribution == null);
    try std.testing.expect(catalog.value[1].expires == null);
    try std.testing.expectEqualStrings("internal", catalog.value[0].redistribution.?);
    // Sent as null above and left out entirely here. Both mean the same thing,
    // and neither may fall back to a value that reads as a grant.
    try std.testing.expect(catalog.value[2].redistribution == null);
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
    const catalog = try client.list(.{});
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

    (try first.list(.{})).deinit();
    (try second.list(.{})).deinit();
    (try first.list(.{})).deinit();

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
    redistribution: []const u8,
) !void {
    if (index > 0) {
        try body.append(arena, ',');
    }
    try body.print(arena,
        \\{{"base":"b{d}","name":"n","summary":"s","standing":"{s}","redistribution":"{s}",
        \\ "starts":null,"expires":null,
        \\ "versions":[{{"id":"b{d}_v1","version":1,"summary":"s","formats":["csvgz"]}}]}}
    , .{ index, standing, redistribution, index });
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
