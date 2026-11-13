//! The Zig-specific API surface, as distinct from the shared conformance corpus
//! in conformance.zig.

const std = @import("std");
const internetdata = @import("internetdata");

const support = @import("support.zig");

const Harness = support.Harness;
const Io = std.Io;
const Route = support.Route;
const storage_path = support.storage_path;

test "an unusable base url is refused before any request" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    for ([_][]const u8{ "not a url", "/relative", "" }) |base_url| {
        try std.testing.expectError(error.InvalidBaseUrl, internetdata.Client.init(gpa, threaded.io(), .{
            .api_key = "key",
            .base_url = base_url,
        }));
    }
}

// Every path starts with `/`, and `//api/...` is another path: production
// answers it with a redirect this client never follows, so every call would
// fail. The call's own outcome is not what is asserted, so a doubled path
// fails at the path it asked for: one to three slashes reached each of these
// at a local origin (2.5.0, measured 2026-10-03).
test "a trailing slash on the base url is dropped, however many" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .ok("{\"databases\":[]}"));

    var buffer: [64]u8 = undefined;
    const base = harness.stub.baseUrl(&buffer);
    const want = [_][]const u8{
        "/api/v2/database/list",
        "/api/v2/database/download",
        "/.well-known/oauth-authorization-server",
        "/oauth/revoke",
    };
    for ([_][]const u8{ "/", "//", "///" }) |slashes| {
        const base_url = try std.mem.concat(gpa, u8, &.{ base, slashes });
        defer gpa.free(base_url);
        var client = try internetdata.Client.init(gpa, harness.io(), .{ .api_key = "key", .base_url = base_url, .retries = 0 });
        defer client.deinit();
        if (client.database().list(.{})) |catalog| catalog.deinit() else |_| {}
        if (client.database().downloadUrl("bogon_ip_v1", .csvgz, .{})) |url| gpa.free(url) else |_| {}
        if (client.oauth().metadata(.{})) |metadata| metadata.deinit() else |_| {}
        client.oauth().revoke("x", "x", .{}) catch {};

        const authorize = try client.oauth().authorizationUrl("x", "https://example.test/cb", "x", .{});
        defer gpa.free(authorize);
        const prefix = try std.mem.concat(gpa, u8, &.{ base, "/oauth/authorize?" });
        defer gpa.free(prefix);
        try std.testing.expect(std.mem.startsWith(u8, authorize, prefix));
    }

    const calls = harness.stub.seen();
    try std.testing.expectEqual(3 * want.len, calls.len);
    for (calls, 0..) |call, i| {
        try std.testing.expectEqualStrings(want[i % want.len], call.path);
    }
}

test "the API key reaches the wire as a bearer token" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .ok("{\"databases\":[]}"));

    var client = try harness.client(.{ .api_key = "mk_test_1234" });
    defer client.deinit();
    (try client.database().list(.{})).deinit();

    try std.testing.expectEqualStrings(
        "Bearer mk_test_1234",
        harness.stub.callFor("/api/v2/database/list").?.authorization,
    );
    // std.http.Client sends its own user agent unless the header is overridden,
    // and the version in ours comes from the manifest through build options.
    try std.testing.expect(std.mem.startsWith(u8, harness.stub.lastUserAgent(), "internetdata-zig/"));
}

// Today every endpoint is licensed, so a keyless client only ever gets a 401.
// It still has to BUILD and to send no credential at all: an empty key is what a
// missing CI secret interpolates to, and `Bearer ` is a worse answer than none.
test "a keyless client sends no authorization header at all" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .ok("{\"databases\":[]}"));

    for ([_]?[]const u8{ null, "", "   ", "\t", " \r\n " }) |api_key| {
        var client = try harness.client(.{ .api_key = api_key });
        defer client.deinit();
        (try client.database().list(.{})).deinit();
    }

    for (harness.stub.seen()) |call| {
        try std.testing.expectEqualStrings("", call.authorization);
    }
    try std.testing.expectEqual(5, harness.stub.callCount());
}

// `std.http.Client` writes a header value out as given: a CR LF inside the key
// put a second header on the wire, and any other control character went out
// whole. The blanks around a key, a file's newline among them, are no part of it.
test "a key holding a control character is refused before anything is sent" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .ok("{\"databases\":[]}"));

    for ([_][]const u8{ "mk_test\r\nX-Injected: 1", "mk\x01test", "mk_test\x7f", "mk\ttest" }) |api_key| {
        var client = try harness.client(.{ .api_key = api_key, .retries = 2 });
        defer client.deinit();
        var diagnostics: internetdata.Diagnostics = .{};
        try std.testing.expectError(error.BadRequest, client.database().list(.{ .diagnostics = &diagnostics }));
        try std.testing.expectEqualStrings("the API key holds a control character", diagnostics.message());
        try std.testing.expectError(error.BadRequest, client.database().downloadUrl("bogon_ip_v1", .mmdb, .{}));
    }
    try std.testing.expectEqual(0, harness.stub.callCount());

    var client = try harness.client(.{ .api_key = " mk_test_1234\r\n" });
    defer client.deinit();
    (try client.database().list(.{})).deinit();
    try std.testing.expectEqualStrings("Bearer mk_test_1234", harness.stub.callFor("/api/v2/database/list").?.authorization);
}

// A proxy's page or a cut-off body is the server's fault like any 5xx: parsed
// after the retries were spent, it failed after exactly one request.
test "a 2xx the call cannot read is retried, carrying its status" {
    const gpa = std.testing.allocator;
    const bodies = [_][]const u8{ "<html>gateway</html>", "{\"databases\":", "", "null", "[]", "{}", "{\"databases\":{}}" };
    for (bodies) |body| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try harness.stub.route("/api/v2/database/list", .ok(body));
        var client = try harness.client(.{ .api_key = "key", .retries = 2 });
        defer client.deinit();
        var diagnostics: internetdata.Diagnostics = .{};
        try std.testing.expectError(error.ServerError, client.database().list(.{ .diagnostics = &diagnostics }));
        try std.testing.expectEqual(3, harness.stub.callCount());
        try std.testing.expectEqual(@as(?u16, 200), diagnostics.status);
    }
}

// `std.json` reads a numeric string into an integer member, so through 2.7.0 a
// version served as "3" came back as 3 and an `entries` of "42" as 42, each
// sent once as if it were the answer, where every other SDK refuses one.
test "a numeric string where an integer is due is retried, carrying its status" {
    const gpa = std.testing.allocator;
    const family =
        \\{"base":"bogon_ip","name":"Bogon IP","summary":"s","standing":"licensed","open":false,
        \\"license_type":"standard","starts":null,"expires":null,"versions":[{"id":"bogon_ip_v1",
    ;
    const metadata = "{\"id\":\"bogon_ip_v1\",\"updated\":\"2026-09-04\",\"schema\":{},";
    const download =
        \\{"dataset_id":"bogon_ip_v1","format":"csvgz","outcome":"ok","sample":false,"open":true,
        \\"apikey_id":null,"client_ip":null,"user_agent":null,"created":"2026-09-04T10:00:00Z",
    ;
    const cases = [_]struct { path: []const u8, body: []const u8 }{
        .{ .path = "/api/v2/database/list", .body = "{\"databases\":[" ++ family ++ "\"version\":\"3\",\"summary\":\"v1\",\"formats\":[\"csvgz\"]}]}]}" },
        .{ .path = "/api/v2/database/metadata", .body = metadata ++ "\"entries\":\"42\",\"size\":{\"csvgz\":760}}" },
        .{ .path = "/api/v2/database/metadata", .body = metadata ++ "\"entries\":42,\"size\":{\"csvgz\":\"760\"}}" },
        .{ .path = "/api/v2/database/downloads", .body = "{\"downloads\":[" ++ download ++ "\"bytes\":\"10\",\"http_status\":200}]}" },
        .{ .path = "/api/v2/database/downloads", .body = "{\"downloads\":[" ++ download ++ "\"bytes\":10,\"http_status\":\"200\"}]}" },
    };
    for (cases) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try harness.stub.route(case.path, .ok(case.body));
        var client = try harness.client(.{ .api_key = "key", .retries = 2 });
        defer client.deinit();
        var diagnostics: internetdata.Diagnostics = .{};
        const outcome = if (std.mem.endsWith(u8, case.path, "/list"))
            if (client.database().list(.{ .diagnostics = &diagnostics })) |parsed| parsed.deinit() else |err| err
        else if (std.mem.endsWith(u8, case.path, "/metadata"))
            if (client.database().metadata("bogon_ip_v1", .{ .diagnostics = &diagnostics })) |parsed| parsed.deinit() else |err| err
        else if (client.database().downloads(null, .{ .diagnostics = &diagnostics })) |parsed| parsed.deinit() else |err| err;
        std.testing.expectError(error.ServerError, outcome) catch |err| {
            std.debug.print("{s}\n", .{case.body});
            return err;
        };
        try std.testing.expectEqual(3, harness.stub.callCount());
        try std.testing.expectEqual(@as(?u16, 200), diagnostics.status);
    }
}

// A date stays a string here, and a sample row a `Value`, so through 2.9.1 any
// string passed for a date (`x`, 30 February, no zone, `+24:00`) and any JSON
// for a row came back as the answer, sent once.
test "a date out of its form, or a sample row that is no object, is retried, carrying its status" {
    const gpa = std.testing.allocator;
    const family =
        \\{"base":"bogon_ip","name":"Bogon IP","summary":"s","standing":"licensed","open":false,
        \\"license_type":"standard","versions":[{"id":"bogon_ip_v1","version":1,"summary":"v1","formats":["csvgz"]}],
    ;
    const metadata = "{\"id\":\"bogon_ip_v1\",\"entries\":44,\"schema\":{},\"size\":{\"csvgz\":760},";
    const download =
        \\{"dataset_id":"bogon_ip_v1","format":"csvgz","outcome":"ok","sample":false,"open":true,
        \\"bytes":10,"http_status":200,"apikey_id":null,"client_ip":null,"user_agent":null,
    ;
    const cases = [_]struct { path: []const u8, body: []const u8 }{
        .{ .path = "/api/v2/database/list", .body = "{\"databases\":[" ++ family ++ "\"starts\":\"x\"}]}" },
        .{ .path = "/api/v2/database/list", .body = "{\"databases\":[" ++ family ++ "\"starts\":\"2026-02-30T00:00:00Z\"}]}" },
        .{ .path = "/api/v2/database/list", .body = "{\"databases\":[" ++ family ++ "\"expires\":\"2026-10-05T10:00:00\"}]}" },
        .{ .path = "/api/v2/database/list", .body = "{\"databases\":[" ++ family ++ "\"renews_at\":\"2026-10-05T24:00:00Z\"}]}" },
        .{ .path = "/api/v2/database/list", .body = "{\"databases\":[" ++ family ++ "\"notice_due_at\":\"2026-10-05T10:00:00+24:00\"}]}" },
        .{ .path = "/api/v2/database/metadata", .body = metadata ++ "\"updated\":\"tomorrow\"}" },
        .{ .path = "/api/v2/database/metadata", .body = metadata ++ "\"updated\":\"2026-11-31\"}" },
        .{ .path = "/api/v2/database/metadata", .body = metadata ++ "\"updated\":\"2026-10-05T10:00:00Z\"}" },
        .{ .path = "/api/v2/database/metadata", .body = metadata ++ "\"updated\":\"2026-10-05\",\"sample\":{\"csvgz\":[null]}}" },
        .{ .path = "/api/v2/database/metadata", .body = metadata ++ "\"updated\":\"2026-10-05\",\"sample\":{\"csvgz\":[1]}}" },
        .{ .path = "/api/v2/database/downloads", .body = "{\"downloads\":[" ++ download ++ "\"created\":\"2026-10-05T10:00:00+0500\"}]}" },
    };
    for (cases) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try harness.stub.route(case.path, .ok(case.body));
        var client = try harness.client(.{ .api_key = "key", .retries = 2 });
        defer client.deinit();
        var diagnostics: internetdata.Diagnostics = .{};
        const outcome = if (std.mem.endsWith(u8, case.path, "/list"))
            if (client.database().list(.{ .diagnostics = &diagnostics })) |parsed| parsed.deinit() else |err| err
        else if (std.mem.endsWith(u8, case.path, "/metadata"))
            if (client.database().metadata("bogon_ip_v1", .{ .diagnostics = &diagnostics })) |parsed| parsed.deinit() else |err| err
        else if (client.database().downloads(null, .{ .diagnostics = &diagnostics })) |parsed| parsed.deinit() else |err| err;
        std.testing.expectError(error.ServerError, outcome) catch |err| {
            std.debug.print("{s}\n", .{case.body});
            return err;
        };
        try std.testing.expectEqual(3, harness.stub.callCount());
        try std.testing.expectEqual(@as(?u16, 200), diagnostics.status);
    }
}

// RFC 3339 lets the `T` and the `Z` be lowercase, and a date-time carry a
// fraction and any offset within a day.
test "a date-time in any of RFC 3339's spellings is read" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .ok(
        \\{"databases":[{"base":"bogon_ip","name":"Bogon IP","summary":"s","standing":"licensed","open":false,
        \\"license_type":"standard","starts":"2026-10-05t10:00:00z","expires":"2027-10-05T10:00:00.123456-08:00",
        \\"renews_at":"2027-09-05T10:00:00+05:30","notice_due_at":null,
        \\"versions":[{"id":"bogon_ip_v1","version":1,"summary":"v1","formats":["csvgz"]}]}]}
    ));
    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const catalog = try client.database().list(.{});
    defer catalog.deinit();
    try std.testing.expectEqualStrings("2026-10-05t10:00:00z", catalog.value[0].starts.?);
    try std.testing.expectEqualStrings("2027-10-05T10:00:00.123456-08:00", catalog.value[0].expires.?);
    try std.testing.expectEqual(1, harness.stub.callCount());
}

// A license covers a FAMILY, and the downloadable IDs hang off its versions. A
// client that reads `base` as an ID asks for a database that does not exist.
test "the catalog unwraps a family and its versions" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .ok(
        \\{"databases":[{"base":"bogon_ip","name":"Bogon IP",
        \\ "summary":"Reserved, private or otherwise non-routable IP ranges.",
        \\ "standing":"licensed","open":false,"license_type":"standard",
        \\ "starts":"2026-09-04T18:04:26.431Z","expires":null,"renews_at":null,"notice_due_at":null,
        \\ "versions":[{"id":"bogon_ip_v1","version":1,"summary":"s",
        \\   "formats":["csvgz","mmdb"]}]},
        \\ {"base":"asn","name":"ASN","summary":"s","standing":"unlicensed","open":true,
        \\ "license_type":null,"starts":null,"expires":null,"renews_at":null,"notice_due_at":null,
        \\ "versions":[{"id":"asn_v1","version":1,"summary":"s","formats":["csvgz"]}]}]}
    ));

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const catalog = try client.database().list(.{});
    defer catalog.deinit();

    try std.testing.expectEqual(2, catalog.value.len);
    const family = catalog.value[0];
    try std.testing.expectEqualStrings("bogon_ip", family.base);
    try std.testing.expectEqualStrings("licensed", family.standing);
    // An Open family's standing stays as served, never derived from `open`.
    try std.testing.expect(!family.open);
    try std.testing.expect(catalog.value[1].open);
    try std.testing.expectEqualStrings("unlicensed", catalog.value[1].standing);
    try std.testing.expectEqual(1, family.versions.len);
    try std.testing.expectEqualStrings("bogon_ip_v1", family.versions[0].id);
    try std.testing.expectEqual(1, family.versions[0].version);
    try std.testing.expectEqualStrings("csvgz", family.versions[0].formats[0]);
    try std.testing.expectEqualStrings("mmdb", family.versions[0].formats[1]);
}

// Which digests a database publishes hangs under a `checksums` key rather than
// sitting at the top level; reading a top-level `sha256` is how the Node SDK
// shipped this broken in 1.0.x.
test "checksums returns the whole digest set from under its key" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/checksum", .ok(
        \\{"id":"bogon_ip_v1","format":"mmdb",
        \\ "checksums":{"md5":"m","sha1":"s1","sha256":"s256","sha512":"s512"}}
    ));

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const digests = try client.database().checksums("bogon_ip_v1", .mmdb, .{});
    defer digests.deinit();

    try std.testing.expectEqualStrings("m", digests.value.md5);
    try std.testing.expectEqualStrings("s1", digests.value.sha1);
    try std.testing.expectEqualStrings("s256", digests.value.sha256);
    try std.testing.expectEqualStrings("s512", digests.value.sha512);
}

// The maps are keyed by FORMAT, which is what makes one metadata document
// enough for every format a database is built in.
test "metadata is keyed by format and carries a size to budget against" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/metadata", .ok(
        \\{"id":"bogon_ip_v1","update_freq":"daily","updated":"2026-09-04","entries":44,
        \\ "schema":{"csvgz":[{"name":"range_start","type":"string","description":"d"}],
        \\           "mmdb":[{"name":"network","type":"string"}]},
        \\ "sample":{"csvgz":[{"range_start":"0.0.0.0"}]},
        \\ "size":{"csvgz":760,"mmdb":3524}}
    ));

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const info = try client.database().metadata("bogon_ip_v1", .{});
    defer info.deinit();

    try std.testing.expectEqualStrings("bogon_ip_v1", info.value.id);
    try std.testing.expectEqualStrings("daily", info.value.update_freq.?);
    try std.testing.expectEqual(44, info.value.entries);
    try std.testing.expectEqual(760, info.value.size.map.get("csvgz").?);
    try std.testing.expectEqual(3524, info.value.size.map.get("mmdb").?);
    try std.testing.expectEqualStrings("range_start", info.value.schema.map.get("csvgz").?[0].name);
    try std.testing.expectEqualStrings("d", info.value.schema.map.get("csvgz").?[0].description.?);
    // Absent on the mmdb column, and absent is not the empty string.
    try std.testing.expect(info.value.schema.map.get("mmdb").?[0].description == null);
    try std.testing.expectEqual(1, info.value.sample.map.get("csvgz").?.len);
}

// Refusals are listed too: a denial is what answers "it stopped working", and a
// null field there is a fact the API could not resolve rather than a zero.
test "the download history keeps a refusal and its nulls" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/downloads", .ok(
        \\{"downloads":[{"dataset_id":"bogon_ip_v1","format":"csvgz","outcome":"denied",
        \\ "sample":true,"open":false,"bytes":null,"http_status":403,"apikey_id":null,"client_ip":"203.0.113.7",
        \\ "user_agent":null,"created":"2026-09-04T18:04:26.431Z"}]}
    ));

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const history = try client.database().downloads(10, .{});
    defer history.deinit();

    try std.testing.expectEqual(1, history.value.len);
    try std.testing.expectEqualStrings("denied", history.value[0].outcome);
    try std.testing.expectEqual(@as(?i64, 403), history.value[0].http_status);
    try std.testing.expect(history.value[0].bytes == null);
    try std.testing.expect(history.value[0].apikey_id == null);
    try std.testing.expectEqualStrings("203.0.113.7", history.value[0].client_ip.?);
    try std.testing.expect(history.value[0].sample);
    try std.testing.expect(!history.value[0].open);
}

test "a limit is only sent when one was asked for" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/downloads", .ok("{\"downloads\":[]}"));

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    (try client.database().downloads(null, .{})).deinit();
    try std.testing.expectEqual(1, harness.stub.callCount());
}

test "retries are configurable per call" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .{
        .status = 500,
        .body = "{\"rc\":\"INTERNAL\"}",
    });

    var client = try harness.client(.{ .api_key = "key", .retries = 0 });
    defer client.deinit();
    try std.testing.expectError(error.ServerError, client.database().list(.{ .retries = 2 }));

    // One initial attempt plus two retries, rather than the client's zero.
    try std.testing.expectEqual(3, harness.stub.callCount());
}

// A 429 with no Retry-After is a spent allowance, and retrying it is hammering
// a quota that will not recover until its window rolls over.
test "a spent quota is never retried" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .{
        .status = 429,
        .body = "{\"rc\":\"QUOTA_EXCEEDED\"}",
    });

    var client = try harness.client(.{ .api_key = "key", .retries = 5 });
    defer client.deinit();
    try std.testing.expectError(error.QuotaExceeded, client.database().list(.{}));
    try std.testing.expectEqual(1, harness.stub.callCount());
}

test "a rate limit is retried after the server supplied wait" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .{
        .status = 429,
        .body = "{\"rc\":\"RATE_LIMITED\"}",
        .headers = &.{.{ .name = "Retry-After", .value = "1" }},
    });

    var client = try harness.client(.{ .api_key = "key", .retries = 1 });
    defer client.deinit();
    const started = Io.Clock.awake.now(harness.io());
    try std.testing.expectError(error.RateLimited, client.database().list(.{}));

    try std.testing.expectEqual(2, harness.stub.callCount());
    // The header, not the backoff schedule, decides the wait.
    const waited = started.untilNow(harness.io(), .awake);
    try std.testing.expect(waited.toMilliseconds() >= 1000);
}

// Past what `Io.Duration` counts in seconds, the header still marks a throttle,
// but the client's own backoff decides the wait rather than a panic.
test "a Retry-After too long to count is waited out on the client's own backoff" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .{
        .status = 429,
        .body = "{\"rc\":\"RATE_LIMITED\"}",
        .headers = &.{.{ .name = "Retry-After", .value = "9223372036854775808" }},
    });

    var client = try harness.client(.{ .api_key = "key", .retries = 1 });
    defer client.deinit();
    var diagnostics: internetdata.Diagnostics = .{};
    const started = Io.Clock.awake.now(harness.io());
    try std.testing.expectError(error.RateLimited, client.database().list(.{ .diagnostics = &diagnostics }));

    try std.testing.expectEqual(2, harness.stub.callCount());
    try std.testing.expectEqual(@as(?u64, null), diagnostics.retry_after_s);
    try std.testing.expect(started.untilNow(harness.io(), .awake).toMilliseconds() < 5000);
}

// Past 2^31 - 1 ms a `Retry-After` is read like one that will not parse: still
// a throttle, waited out on the client's own backoff. `Io.sleep` takes any
// wait, so 2.5.0 held the call 24.8 days for 2147484 and for good for
// 9223372036854775807 (measured 2026-10-03). 2147483 is still waited as given,
// which is why it is not asserted here.
test "a Retry-After past 2^31 - 1 ms is waited out on the client's own backoff" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "2147484", "9223372036854775807" }) |value| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try harness.stub.route("/api/v2/database/list", .{
            .status = 429,
            .body = "{\"rc\":\"RATE_LIMITED\"}",
            .headers = &.{.{ .name = "Retry-After", .value = value }},
        });

        var client = try harness.client(.{ .api_key = "key", .retries = 1 });
        defer client.deinit();
        const started = Io.Clock.awake.now(harness.io());
        try std.testing.expectError(error.RateLimited, client.database().list(.{}));

        try std.testing.expectEqual(2, harness.stub.callCount());
        try std.testing.expect(started.untilNow(harness.io(), .awake).toMilliseconds() < 5000);
    }
}

// A 404 from a misspelled ID is a CLIENT error. Letting it fall through to the
// retryable server_error default is the mistake three of four VPNDetection SDKs
// shipped with.
test "an unknown database is not retried" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/metadata", .{
        .status = 404,
        .body = "{\"rc\":\"UNKNOWN_DATASET\"}",
    });

    var client = try harness.client(.{ .api_key = "key", .retries = 3 });
    defer client.deinit();
    var diagnostics: internetdata.Diagnostics = .{};
    try std.testing.expectError(
        error.BadRequest,
        client.database().metadata("no_such_database_v1", .{ .diagnostics = &diagnostics }),
    );

    try std.testing.expectEqualStrings("UNKNOWN_DATASET", diagnostics.message());
    try std.testing.expectEqual(1, harness.stub.callCount());
}

// The download endpoint answers 302 to object storage, and the database behind
// it runs to gigabytes. The origin here PROMISES 8 GiB, so a client that follows
// the redirect is caught by the request count rather than by the wait.
test "downloadUrl returns the redirect rather than following it" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();

    var url_buffer: [64]u8 = undefined;
    const location = try harness.stub.printed(
        "{s}/huge.mmdb",
        .{harness.stub.baseUrl(&url_buffer)},
    );
    try harness.stub.route("/api/v2/database/download", .{
        .status = 302,
        .headers = &.{.{ .name = "Location", .value = location }},
    });
    try harness.stub.route("/huge.mmdb", .{ .promised_length = 8 * 1024 * 1024 * 1024 });

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const url = try client.database().downloadUrl("bogon_ip_v1", .mmdb, .{});
    defer gpa.free(url);

    try std.testing.expectEqualStrings(location, url);
    try std.testing.expect(harness.stub.calledOnly("/api/v2/database/download"));
}

test "download streams a database to disk and sends no key to object storage" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const body = try support.payload(harness);
    try support.routeDownload(harness, .ok(body));

    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "mk_test_1234" });
    defer client.deinit();
    const written = try client.database().download("bogon_ip_v1", .csvgz, scratch.path("data.csv.gz"), .{});

    try std.testing.expectEqual(body.len, written);
    var read_buffer: [64_000]u8 = undefined;
    try std.testing.expectEqualSlices(u8, body, try scratch.read("data.csv.gz", &read_buffer));
    try std.testing.expect(!scratch.exists("data.csv.gz.part"));

    // The presigned link authorizes itself. Handing object storage the API key
    // as well would give a third party a credential it can spend.
    try std.testing.expectEqualStrings(
        "Bearer mk_test_1234",
        harness.stub.callFor("/api/v2/database/download").?.authorization,
    );
    try std.testing.expectEqualStrings("", harness.stub.callFor(storage_path).?.authorization);
}

test "a build goes on the download request, and none without one" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try support.routeDownload(harness, .ok(try support.payload(harness)));

    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const db = client.database();
    const named = "20261105.0t53s5";

    gpa.free(try db.downloadUrl("bogon_ip_v1", .csvgz, .{ .build = named }));
    gpa.free(try db.downloadBytes("bogon_ip_v1", .csvgz, .{ .build = named }));
    _ = try db.download("bogon_ip_v1", .csvgz, scratch.path("built.csv.gz"), .{ .build = named });
    gpa.free(try db.downloadUrl("bogon_ip_v1", .csvgz, .{ .build = "" }));
    gpa.free(try db.downloadBytes("bogon_ip_v1", .csvgz, .{}));

    const with_build = "/api/v2/database/download?id=bogon_ip_v1&format=csvgz&build=" ++ named;
    const live = "/api/v2/database/download?id=bogon_ip_v1&format=csvgz";
    const want = [_][]const u8{ with_build, with_build, with_build, live, live };
    var asked: usize = 0;
    for (harness.stub.seen()) |call| {
        if (!std.mem.eql(u8, call.path, "/api/v2/database/download")) continue;
        try std.testing.expect(asked < want.len);
        try std.testing.expectEqualStrings(want[asked], call.target);
        asked += 1;
    }
    try std.testing.expectEqual(want.len, asked);
}

test "a gone build is a bad request, asked once" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/download", .{
        .status = 410,
        .body = "{\"rc\":\"BUILD_GONE\"}",
    });

    var client = try harness.client(.{ .api_key = "key", .retries = 2 });
    defer client.deinit();
    var diagnostics: internetdata.Diagnostics = .{};

    try std.testing.expectError(
        error.BadRequest,
        client.database().downloadUrl("bogon_ip_v1", .csvgz, .{
            .build = "20261029.aaaaaa",
            .diagnostics = &diagnostics,
        }),
    );
    try std.testing.expectEqualStrings("BUILD_GONE", diagnostics.message());
    try std.testing.expectEqual(1, harness.stub.callCount());
}

// The bytes have to hash to what `checksums` publishes, so they are read
// UNDECOMPRESSED. Without this the file on disk would be whatever object storage
// chose to encode it as.
test "a transfer asks for identity only" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try support.routeDownload(harness, .ok(try support.payload(harness)));

    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    _ = try client.database().download("bogon_ip_v1", .csvgz, scratch.path("data.csv.gz"), .{});

    try std.testing.expectEqualStrings(
        "identity",
        harness.stub.callFor(storage_path).?.accept_encoding,
    );
}

// Belt and braces on the header above: an origin that compresses anyway must be
// refused rather than writing bytes that will not match the published digest.
test "a compressed transfer is refused rather than written" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const arena = harness.stub.arena.allocator();
    const headers = try arena.dupe(Route.Header, &.{
        .{ .name = "Content-Encoding", .value = "gzip" },
    });
    try support.routeDownload(harness, .{ .body = try support.payload(harness), .headers = headers });

    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "key", .retries = 0 });
    defer client.deinit();
    try std.testing.expectError(error.Network, client.database().download(
        "bogon_ip_v1",
        .csvgz,
        scratch.path("data.csv.gz"),
        .{},
    ));
    try std.testing.expect(!scratch.exists("data.csv.gz"));
    try std.testing.expect(!scratch.exists("data.csv.gz.part"));
}

test "downloadBytes agrees with the streamed copy byte for byte" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const body = try support.payload(harness);
    try support.routeDownload(harness, .ok(body));

    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const written = try client.database().download("bogon_ip_v1", .csvgz, scratch.path("data.csv.gz"), .{});

    const bytes = try client.database().downloadBytes("bogon_ip_v1", .csvgz, .{});
    defer gpa.free(bytes);

    try std.testing.expectEqual(written, bytes.len);
    var read_buffer: [64_000]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try scratch.read("data.csv.gz", &read_buffer), bytes);
}

// Silence here is how a truncated database gets renamed into place and read for
// weeks as a complete one.
test "a transfer that stops short fails and leaves nothing behind" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    // Announces 40,000 bytes, writes 16, then closes.
    try support.routeDownload(harness, .{ .body = "0123456789abcdef", .promised_length = 40_000 });

    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "key", .retries = 0 });
    defer client.deinit();
    var diagnostics: internetdata.Diagnostics = .{};
    try std.testing.expectError(error.Network, client.database().download(
        "bogon_ip_v1",
        .csvgz,
        scratch.path("data.csv.gz"),
        .{ .diagnostics = &diagnostics },
    ));

    try std.testing.expect(!scratch.exists("data.csv.gz"));
    try std.testing.expect(!scratch.exists("data.csv.gz.part"));
    try std.testing.expect(diagnostics.message().len > 0);

    // The in-memory variant reads the same body through the same check.
    try std.testing.expectError(
        error.Network,
        client.database().downloadBytes("bogon_ip_v1", .csvgz, .{}),
    );
}

// Only the header phase of a transfer retries: object storage failing with a 5xx
// before any byte has moved is asked again.
test "an object storage 5xx before the first byte is retried" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const body = try support.payload(harness);
    try support.routeDownload(harness, .ok(body));
    const arena = harness.stub.arena.allocator();
    try harness.stub.sequence(storage_path, try arena.dupe(Route, &.{ .{ .status = 503 }, .ok(body) }));

    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const written = try client.database().download("bogon_ip_v1", .csvgz, scratch.path("data.csv.gz"), .{});

    try std.testing.expectEqual(2, storageRequests(harness));
    try std.testing.expectEqual(body.len, written);
    var read_buffer: [64_000]u8 = undefined;
    try std.testing.expectEqualSlices(u8, body, try scratch.read("data.csv.gz", &read_buffer));
}

// Object storage's `Retry-After` is bounded like the API's: past 2^31 - 1 ms it
// is waited out on the backoff, where 2.5.0 held the transfer 24.8 days for
// 2147484 and for good for 9223372036854775807 (measured 2026-10-03).
test "an object storage Retry-After past its bound waits the backoff" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "2147484", "9223372036854775807" }) |value| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        const body = try support.payload(harness);
        try support.routeDownload(harness, .ok(body));
        const arena = harness.stub.arena.allocator();
        const headers = try arena.dupe(Route.Header, &.{.{ .name = "Retry-After", .value = value }});
        try harness.stub.sequence(storage_path, try arena.dupe(Route, &.{ .{ .status = 429, .headers = headers }, .ok(body) }));

        var client = try harness.client(.{ .api_key = "key" });
        defer client.deinit();
        const started = Io.Clock.awake.now(harness.io());
        const bytes = try client.database().downloadBytes("bogon_ip_v1", .csvgz, .{});
        defer gpa.free(bytes);

        try std.testing.expectEqual(2, storageRequests(harness));
        try std.testing.expectEqualSlices(u8, body, bytes);
        try std.testing.expect(started.untilNow(harness.io(), .awake).toMilliseconds() < 5000);
    }
}

// A body that dies part way is NEVER fetched again: a second copy would land
// behind the bytes already moved. Paired with the 503 test above, so neither
// count can pass by accident.
test "a transfer that dies part way is never fetched again" {
    const gpa = std.testing.allocator;
    for ([_]bool{ true, false }) |to_disk| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try support.routeDownload(harness, .{ .body = "0123456789abcdef", .promised_length = 40_000 });

        var scratch = support.Scratch.start();
        defer scratch.deinit();

        var client = try harness.client(.{ .api_key = "key", .retries = 3 });
        defer client.deinit();
        if (to_disk) {
            try std.testing.expectError(
                error.Network,
                client.database().download("bogon_ip_v1", .csvgz, scratch.path("data.csv.gz"), .{}),
            );
        } else {
            try std.testing.expectError(error.Network, client.database().downloadBytes("bogon_ip_v1", .csvgz, .{}));
        }
        std.testing.expectEqual(1, storageRequests(harness)) catch |err| {
            std.debug.print("the dead transfer was fetched again (to disk: {})\n", .{to_disk});
            return err;
        };
    }
}

fn storageRequests(harness: *Harness) usize {
    var count: usize = 0;
    for (harness.stub.seen()) |call| {
        if (std.mem.eql(u8, call.path, storage_path)) {
            count += 1;
        }
    }
    return count;
}

// A license refusal is the API saying no, not a wobble: retrying it spends quota
// to be told the same thing again.
test "a database the organization does not license is refused once" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/download", .{
        .status = 403,
        .body = "{\"rc\":\"NOT_LICENSED\"}",
    });

    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "key", .retries = 3 });
    defer client.deinit();
    var diagnostics: internetdata.Diagnostics = .{};
    try std.testing.expectError(error.Forbidden, client.database().download(
        "hosting_ip_v1",
        .csvgz,
        scratch.path("data.csv.gz"),
        .{ .diagnostics = &diagnostics },
    ));

    try std.testing.expect(!internetdata.isRetryable(error.Forbidden));
    try std.testing.expectEqual(1, harness.stub.callCount());
    try std.testing.expectEqual(@as(?u16, 403), diagnostics.status);
    // The API says WHICH refusal this is. Falling back to the status would mean
    // the envelope went unread.
    try std.testing.expectEqualStrings("NOT_LICENSED", diagnostics.message());
    // Nothing may be created for a download that never started.
    try std.testing.expect(!scratch.exists("data.csv.gz.part"));
}

// v1 streamed the file at 200 from this same path shape. A client pointed at
// one must not hand back a gigabyte of CSV as though it were a link.
test "a 200 where a redirect belongs is a server fault, not a file" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/download", .ok("range_start,range_end\n"));

    var client = try harness.client(.{ .api_key = "key", .retries = 0 });
    defer client.deinit();
    var diagnostics: internetdata.Diagnostics = .{};
    try std.testing.expectError(
        error.ServerError,
        client.database().downloadUrl("bogon_ip_v1", .csvgz, .{ .diagnostics = &diagnostics }),
    );
    try std.testing.expectEqualStrings("expected a redirect to object storage", diagnostics.message());
}

test "a per-call retry budget reaches the redirect too" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/download", .{
        .status = 503,
        .body = "{\"rc\":\"NOT_AVAILABLE\"}",
    });

    var client = try harness.client(.{ .api_key = "key", .retries = 0 });
    defer client.deinit();
    try std.testing.expectError(
        error.ServerError,
        client.database().downloadUrl("bogon_ip_v1", .csvgz, .{ .retries = 2 }),
    );
    try std.testing.expectEqual(3, harness.stub.callCount());
}

// A caller budgets a transfer against `size`, and the largest database in the
// catalog is gigabytes, so a metadata document without one is not an answer to
// read a zero out of.
test "a metadata answer with no size is refused" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/metadata", .ok(
        \\{"id":"bogon_ip_v1","updated":"2026-09-04","entries":44,
        \\ "schema":{"csvgz":[{"name":"range_start","type":"string"}]}}
    ));

    var client = try harness.client(.{ .api_key = "key", .retries = 0 });
    defer client.deinit();
    var diagnostics: internetdata.Diagnostics = .{};
    try std.testing.expectError(
        error.ServerError,
        client.database().metadata("bogon_ip_v1", .{ .diagnostics = &diagnostics }),
    );
    try std.testing.expectEqualStrings(
        "the answer did not match the documented shape",
        diagnostics.message(),
    );
}

// Lookups

// Enough addresses for seven chunks of the batch endpoint's 1000, so a
// concurrency bound has something to bound: one request per chunk, and only
// the chunks overlap.
const many = 6001;
const chunks_of_many = 7;

fn routeMany(harness: *Harness) !std.ArrayList([]const u8) {
    var ips: std.ArrayList([]const u8) = .empty;
    for (0..many) |i| {
        const ip = try harness.stub.printed("9.{d}.{d}.{d}", .{ 1 + i / 65536, (i / 256) % 256, i % 256 });
        try harness.stub.routeLookup(ip);
        try ips.append(harness.stub.arena.allocator(), ip);
    }
    return ips;
}

fn lookupBody(harness: *Harness, ip: []const u8, extra: []const u8) ![]const u8 {
    return support.lookupBody(harness.stub.arena.allocator(), ip, extra);
}

// Peak in-flight is the only measurement that tells a real limit from an option
// that was accepted and ignored.
test "batch concurrency is configurable per call" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    harness.stub.delay = .fromMilliseconds(20);
    const ips = try routeMany(harness);

    var client = try harness.client(.{ .cache = null });
    defer client.deinit();
    var batch = try client.lookupBatch(ips.items, .{ .concurrency = 3 });
    defer batch.deinit();

    try std.testing.expectEqual(chunks_of_many, harness.stub.callCount());
    try std.testing.expect(harness.stub.peak() <= 3);
    try std.testing.expect(harness.stub.peak() > 1);
}

test "a per call concurrency overrides the client default" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    harness.stub.delay = .fromMilliseconds(20);
    const ips = try routeMany(harness);

    var client = try harness.client(.{ .cache = null, .concurrency = 2 });
    defer client.deinit();
    var batch = try client.lookupBatch(ips.items, .{ .concurrency = 6 });
    defer batch.deinit();

    const peak = harness.stub.peak();
    try std.testing.expect(peak > 2);
    try std.testing.expect(peak <= 6);
}

test "without an override the client concurrency still applies" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    harness.stub.delay = .fromMilliseconds(20);
    const ips = try routeMany(harness);

    var client = try harness.client(.{ .cache = null, .concurrency = 2 });
    defer client.deinit();
    var batch = try client.lookupBatch(ips.items, .{});
    defer batch.deinit();

    try std.testing.expect(harness.stub.peak() <= 2);
}

// Chunking is the library's job, so a batch has no size limit of its own: 2,500
// addresses are three requests of at most 1000, never a refusal and never a
// request per address.
test "a batch of any size is chunked rather than refused" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const ips = try routeMany(harness);
    const addresses = ips.items[0..2500];

    var client = try harness.client(.{ .cache = null });
    defer client.deinit();
    var batch = try client.lookupBatch(addresses, .{});
    defer batch.deinit();

    try std.testing.expectEqual(3, harness.stub.callCount());
    for (harness.stub.seen()) |call| {
        try std.testing.expectEqualStrings("/batch", call.path);
        try std.testing.expectEqualStrings("POST", call.method);
    }
    try std.testing.expectEqual(2500, batch.count());
    for (addresses) |ip| {
        try std.testing.expectEqualStrings(ip, batch.get(ip).?.ok.value.ip);
    }
}

// Zero would leave nothing to run the chunks, so the whole batch is refused,
// every address answered with that refusal, before any request.
test "a per call concurrency below one is refused before any request" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");
    try harness.stub.routeLookup("9.9.9.9");

    var client = try harness.client(.{ .cache = null });
    defer client.deinit();
    var batch = try client.lookupBatch(&.{ "1.1.1.1", "10.0.0.1", "9.9.9.9" }, .{ .concurrency = 0 });
    defer batch.deinit();

    try std.testing.expectEqual(0, harness.stub.callCount());
    try std.testing.expectEqual(3, batch.count());
    for (batch.values()) |entry| {
        try std.testing.expectEqual(internetdata.CallError.BadRequest, entry.failed.err);
        try std.testing.expect(!internetdata.isRetryable(entry.failed.err));
    }
}

test "a lookup's retries are configurable per call" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    for ([_][]const u8{ "/9.9.9.9", "/asn/9009", "/domain/example.com" }) |path| {
        try harness.stub.route(path, .{ .status = 500, .body = "{\"error\":\"lookup failed\"}" });
    }

    var client = try harness.client(.{ .cache = null, .retries = 0 });
    defer client.deinit();
    try std.testing.expectError(error.ServerError, client.lookupWith("9.9.9.9", .{ .retries = 2 }));
    try std.testing.expectError(error.ServerError, client.lookupAsnWith(9009, .{ .retries = 2 }));
    try std.testing.expectError(error.ServerError, client.lookupDomainWith("example.com", .{ .retries = 2 }));

    // One initial attempt plus two retries each, rather than the client's zero.
    try std.testing.expectEqual(9, harness.stub.callCount());
}

// This API answers an AS or a domain at the lookup path, so one sent there
// comes back as an answer the call cannot read, retried as a server error. A
// batch sends what it is given: the API refuses a non-address entry by entry.
test "lookup refuses what is not an address before sending, naming the calls that take one" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    var client = try harness.client(.{ .retries = 2 });
    defer client.deinit();
    for ([_][]const u8{ "example.com", "AS9009", "9009", "notanip", "", "1.1.1.1 " }) |target| {
        var diagnostics: internetdata.Diagnostics = .{};
        try std.testing.expectError(error.BadRequest, client.lookupWith(target, .{ .diagnostics = &diagnostics }));
        try std.testing.expect(std.mem.indexOf(u8, diagnostics.message(), "lookupAsn") != null);
        try std.testing.expect(std.mem.indexOf(u8, diagnostics.message(), "lookupDomain") != null);
    }
    try std.testing.expectError(error.BadRequest, client.lookup("example.com"));
    try std.testing.expectEqual(0, harness.stub.callCount());

    var batch = try client.lookupBatch(&.{ "example.com", "1.1.1.1" }, .{});
    defer batch.deinit();
    try std.testing.expectEqual(1, harness.stub.callCount());
    const sent = try std.json.parseFromSlice(struct { ips: []const []const u8 }, gpa, harness.stub.seen()[0].body, .{});
    defer sent.deinit();
    try std.testing.expectEqual(2, sent.value.ips.len);
    try std.testing.expectEqualStrings(support.not_a_target, batch.get("example.com").?.failed.diagnostics.message());
    try std.testing.expect(batch.get("1.1.1.1").? == .ok);
}

// The spec gives each lookup path a server of its own, the production host,
// and a client honoring it would send lookups there whatever base URL it was
// built with.
test "every lookup goes to the client's base URL, never the spec's own server" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");
    try harness.stub.routeLookup("8.8.8.8");
    try harness.stub.route("/myip", .ok(try lookupBody(harness, "45.83.91.1", "")));
    try harness.stub.route("/api/v1/entitlement", .ok(entitlement_ok));
    try harness.stub.route("/asn/9009", .ok(asn_ok));
    try harness.stub.route("/domain/example.com", .ok(domain_ok));

    var client = try harness.client(.{ .api_key = "key", .cache = null });
    defer client.deinit();
    (try client.lookup("1.1.1.1")).deinit();
    (try client.lookupAsn(9009)).deinit();
    (try client.lookupDomain("example.com")).deinit();
    (try client.myIp()).deinit();
    (try client.myEntitlement()).deinit();
    var batch = try client.lookupBatch(&.{ "1.1.1.1", "8.8.8.8" }, .{});
    batch.deinit();

    var url_buffer: [64]u8 = undefined;
    const host = harness.stub.baseUrl(&url_buffer)["http://".len..];
    try std.testing.expectEqual(6, harness.stub.callCount());
    for (harness.stub.seen()) |call| {
        try std.testing.expectEqualStrings(host, call.header("host").?);
    }
}

// The same key on every lookup surface, and none at all from a keyless client:
// an empty key is what a missing CI secret interpolates to.
test "every lookup carries the key as a bearer token, and a keyless client none" {
    const gpa = std.testing.allocator;
    const paths = [_][]const u8{ "/1.1.1.1", "/myip", "/api/v1/entitlement", "/asn/9009", "/domain/example.com", "/batch" };
    for ([_][]const u8{ "mk_test_1234", "", " \r\n " }) |api_key| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try harness.stub.routeLookup("1.1.1.1");
        try harness.stub.routeLookup("8.8.8.8");
        try harness.stub.route("/myip", .ok(try lookupBody(harness, "45.83.91.1", "")));
        try harness.stub.route("/api/v1/entitlement", .ok(entitlement_ok));
        try harness.stub.route("/asn/9009", .ok(asn_ok));
        try harness.stub.route("/domain/example.com", .ok(domain_ok));

        var client = try harness.client(.{ .api_key = api_key, .cache = null });
        defer client.deinit();
        (try client.lookup("1.1.1.1")).deinit();
        (try client.myIp()).deinit();
        (try client.myEntitlement()).deinit();
        (try client.lookupAsn(9009)).deinit();
        (try client.lookupDomain("example.com")).deinit();
        var batch = try client.lookupBatch(&.{ "1.1.1.1", "8.8.8.8" }, .{});
        batch.deinit();

        const want = if (api_key.len > 0 and api_key[0] == 'm') "Bearer mk_test_1234" else "";
        try std.testing.expectEqual(paths.len, harness.stub.callCount());
        for (paths) |path| {
            try std.testing.expectEqualStrings(want, harness.stub.callFor(path).?.authorization);
        }
        try std.testing.expect(std.mem.startsWith(u8, harness.stub.lastUserAgent(), "internetdata-zig/"));
    }
}

// `std.http.Client` writes a header value out as given: a CR LF inside the key
// put a second header on the wire, and any other control character went out
// whole.
test "a key holding a control character is refused before any lookup is sent" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    for ([_][]const u8{ "mk_test\r\nX-Injected: 1", "mk\x01test", "mk_test\x7f", "mk\ttest" }) |api_key| {
        var client = try harness.client(.{ .api_key = api_key, .retries = 2 });
        defer client.deinit();
        var diagnostics: internetdata.Diagnostics = .{};
        try std.testing.expectError(error.BadRequest, client.lookupWith("1.1.1.1", .{ .diagnostics = &diagnostics }));
        try std.testing.expectEqualStrings("the API key holds a control character", diagnostics.message());
        try std.testing.expectError(error.BadRequest, client.myIp());
        try std.testing.expectError(error.BadRequest, client.myEntitlement());
        try std.testing.expectError(error.BadRequest, client.lookupAsn(9009));
        try std.testing.expectError(error.BadRequest, client.lookupDomain("example.com"));
        var batch = try client.lookupBatch(&.{"1.1.1.1"}, .{});
        defer batch.deinit();
        switch (batch.get("1.1.1.1").?) {
            .ok => return error.TestUnexpectedResult,
            .failed => |failure| try std.testing.expectEqual(error.BadRequest, failure.err),
        }
    }
    try std.testing.expectEqual(0, harness.stub.callCount());
}

// One to three trailing slashes on the base URL are dropped, never doubled into
// a path, on every lookup as on the database calls above.
test "a trailing slash on the base url is dropped on every lookup path" {
    const gpa = std.testing.allocator;
    const want = [_][]const u8{ "/8.8.8.8", "/myip", "/batch", "/asn/9009", "/domain/example.com", "/api/v1/entitlement" };
    for ([_][]const u8{ "/", "//", "///" }) |slashes| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        var url_buffer: [64]u8 = undefined;
        const base_url = try std.mem.concat(gpa, u8, &.{ harness.stub.baseUrl(&url_buffer), slashes });
        defer gpa.free(base_url);
        var client = try internetdata.Client.init(gpa, harness.io(), .{ .base_url = base_url, .cache = null, .retries = 0 });
        defer client.deinit();

        if (client.lookup("8.8.8.8")) |answer| answer.deinit() else |_| {}
        if (client.myIp()) |answer| answer.deinit() else |_| {}
        var batch = try client.lookupBatch(&.{ "8.8.4.4", "1.1.1.1" }, .{});
        batch.deinit();
        if (client.lookupAsn(9009)) |answer| answer.deinit() else |_| {}
        if (client.lookupDomain("example.com")) |answer| answer.deinit() else |_| {}
        if (client.myEntitlement()) |answer| answer.deinit() else |_| {}

        const calls = harness.stub.seen();
        try std.testing.expectEqual(want.len, calls.len);
        for (want, calls) |path, call| {
            try std.testing.expectEqualStrings(path, call.path);
        }
    }
}

// A proxy's page or a cut-off body is the server's fault like any 5xx, and a
// batch's `[]` or `{}` is the whole chunk's: each is retried, carrying its
// status, never handed back as an answer.
test "a 2xx no lookup can read is retried, carrying its status" {
    const gpa = std.testing.allocator;
    const bodies = [_][]const u8{ "<html>Bad gateway</html>", "{\"ip\":\"1.1.1.1\",\"is_b", "", "null", "[]", "{}" };
    const paths = [_][]const u8{ "/1.1.1.1", "/myip", "/api/v1/entitlement", "/batch", "/asn/9009", "/domain/example.com" };
    for (bodies) |body| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        for (paths) |path| {
            try harness.stub.route(path, .{ .body = body, .verbatim = true });
        }
        var client = try harness.client(.{ .retries = 1 });
        defer client.deinit();
        var failed: [paths.len]?anyerror = @splat(null);
        var diagnostics: [paths.len]internetdata.Diagnostics = @splat(.{});

        if (client.lookupWith("1.1.1.1", .{ .diagnostics = &diagnostics[0] })) |answer| answer.deinit() else |err| failed[0] = err;
        if (client.myIpWith(.{ .diagnostics = &diagnostics[1] })) |answer| answer.deinit() else |err| failed[1] = err;
        if (client.myEntitlementWith(.{ .diagnostics = &diagnostics[2] })) |answer| answer.deinit() else |err| failed[2] = err;
        {
            var batch = try client.lookupBatch(&.{"1.1.1.1"}, .{});
            defer batch.deinit();
            switch (batch.get("1.1.1.1").?) {
                .ok => {},
                .failed => |failure| {
                    failed[3] = failure.err;
                    diagnostics[3] = failure.diagnostics;
                },
            }
        }
        if (client.lookupAsnWith(9009, .{ .diagnostics = &diagnostics[4] })) |answer| answer.deinit() else |err| failed[4] = err;
        if (client.lookupDomainWith("example.com", .{ .diagnostics = &diagnostics[5] })) |answer| answer.deinit() else |err| failed[5] = err;

        for (paths, 0..) |path, i| {
            var sent: usize = 0;
            for (harness.stub.seen()) |call| {
                if (std.mem.eql(u8, call.path, path)) sent += 1;
            }
            std.testing.expectEqual(@as(?anyerror, error.ServerError), failed[i]) catch |err| {
                std.debug.print("{s} answering \"{s}\"\n", .{ path, body });
                return err;
            };
            try std.testing.expectEqual(2, sent);
            try std.testing.expectEqual(@as(?u16, 200), diagnostics[i].status);
        }
    }
}

// A chunk is retried whole only when it cannot be read as a whole. One entry
// that is not a lookup is that address's error alone.
test "a batch entry no call can read fails that address alone, once" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const body = try harness.stub.printed("{{\"results\":{{\"8.8.8.8\":\"not an object\",\"1.1.1.1\":{{\"ip\":\"1.1.1.1\"}},\"9.9.9.9\":{s}}}}}", .{
        try lookupBody(harness, "9.9.9.9", ""),
    });
    try harness.stub.route("/batch", .{ .body = body, .verbatim = true });
    var client = try harness.client(.{ .retries = 2 });
    defer client.deinit();
    var batch = try client.lookupBatch(&.{ "8.8.8.8", "1.1.1.1", "9.9.9.9" }, .{});
    defer batch.deinit();

    try std.testing.expectEqual(1, harness.stub.callCount());
    for ([_][]const u8{ "8.8.8.8", "1.1.1.1" }) |ip| switch (batch.get(ip).?) {
        .ok => return error.TestUnexpectedResult,
        .failed => |failure| {
            try std.testing.expectEqual(error.ServerError, failure.err);
            try std.testing.expectEqual(@as(?u16, 200), failure.diagnostics.status);
        },
    };
    try std.testing.expect(batch.get("9.9.9.9").? == .ok);
}

test "isBogon is on the client and agrees with the standalone function" {
    const gpa = std.testing.allocator;
    const data = try support.corpus.load(gpa);
    defer data.deinit();
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    var client = try harness.client(.{});
    defer client.deinit();

    for (data.value.isBogon) |case| {
        try std.testing.expectEqual(case.expect, client.isBogon(case.ip));
        try std.testing.expectEqual(internetdata.isBogon(case.ip), client.isBogon(case.ip));
    }
}

// The single most important semantic in the library, asserted natively rather
// than through the corpus's JSON view: a plan that omits a member leaves it
// null, and a plan that includes it answers false, or an empty string.
test "absent and false are different values" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");
    try harness.stub.route("/8.8.4.4", .ok(try lookupBody(harness, "8.8.4.4", "\"is_hosting\":false")));

    var client = try harness.client(.{});
    defer client.deinit();

    const free_tier = try client.lookup("1.1.1.1");
    defer free_tier.deinit();
    try std.testing.expectEqual(@as(?bool, null), free_tier.value.is_hosting);
    try std.testing.expectEqual(false, free_tier.value.is_hosting orelse false);
    try std.testing.expectEqual(@as(?[]const u8, null), free_tier.value.location.city);
    try std.testing.expectEqual(@as(?bool, null), free_tier.value.abuse.validated);

    const served = try client.lookup("8.8.4.4");
    defer served.deinit();
    try std.testing.expectEqual(@as(?bool, false), served.value.is_hosting);
}

test "an ipv6 address survives the path template" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("2606:4700:4700::1111");

    var client = try harness.client(.{});
    defer client.deinit();
    const result = try client.lookup("2606:4700:4700::1111");
    defer result.deinit();
    try std.testing.expectEqualStrings("2606:4700:4700::1111", result.value.ip);
    try std.testing.expectEqualStrings("/2606%3A4700%3A4700%3A%3A1111", harness.stub.seen()[0].target);
}

// The number goes as given and the domain path-escaped, so a name that is not
// what the API documents cannot reach another path: the API answers what it
// cannot read with a 400.
test "an AS number and a domain go into the path as given" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/asn/4294967295", .ok(asn_ok));
    try harness.stub.route("/asn/0", .ok(asn_ok));
    try harness.stub.route("/domain/bücher.example", .ok(domain_ok));
    try harness.stub.route("/domain/a/b?c", .ok(domain_ok));

    var client = try harness.client(.{});
    defer client.deinit();
    (try client.lookupAsn(std.math.maxInt(u32))).deinit();
    (try client.lookupAsn(0)).deinit();
    (try client.lookupDomain("bücher.example")).deinit();
    (try client.lookupDomain("a/b?c")).deinit();

    const want = [_][]const u8{ "/asn/4294967295", "/asn/0", "/domain/b%C3%BCcher.example", "/domain/a%2Fb%3Fc" };
    const calls = harness.stub.seen();
    try std.testing.expectEqual(want.len, calls.len);
    for (want, calls) |target, call| {
        try std.testing.expectEqualStrings(target, call.target);
        try std.testing.expectEqualStrings("GET", call.method);
    }
}

// Only an address is cached: an AS and a domain are asked each time.
test "an AS and a domain are not cached" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/asn/9009", .ok(asn_ok));
    try harness.stub.route("/domain/example.com", .ok(domain_ok));

    var client = try harness.client(.{});
    defer client.deinit();
    for (0..2) |_| {
        const asn = try client.lookupAsn(9009);
        defer asn.deinit();
        try std.testing.expectEqual(9009, asn.value.asn);
        const domain = try client.lookupDomain("example.com");
        defer domain.deinit();
        try std.testing.expectEqualStrings("example.com", domain.value.domain);
    }
    try std.testing.expectEqual(4, harness.stub.callCount());
}

// The corpus's dedup case runs with the cache on, where a repeated address
// costs nothing either way. With the cache off, deduping is the only thing
// keeping a repeated address out of the chunk: five inputs are two entries
// in one request.
test "a batch dedupes even with the cache disabled" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");
    try harness.stub.routeLookup("8.8.8.8");

    var client = try harness.client(.{ .cache = null });
    defer client.deinit();
    const input = [_][]const u8{ "1.1.1.1", "8.8.8.8", "1.1.1.1", "8.8.8.8", "1.1.1.1" };
    var batch = try client.lookupBatch(&input, .{});
    defer batch.deinit();

    try std.testing.expectEqual(2, batch.count());
    try std.testing.expectEqual(1, harness.stub.callCount());
}

test "a batch keeps its own copy of the addresses it was given" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    var client = try harness.client(.{});
    defer client.deinit();

    const ip = try gpa.dupe(u8, "1.1.1.1");
    const input = [_][]const u8{ip};
    var batch = try client.lookupBatch(&input, .{});
    defer batch.deinit();
    gpa.free(ip);

    try std.testing.expectEqualStrings("1.1.1.1", batch.keys()[0]);
    try std.testing.expect(batch.get("1.1.1.1") != null);
}

// Every entry owns its answer, so an address asked under two spellings is two
// answers from one request: sharing one would free it twice.
test "a batch sends an address asked under several spellings once and answers each" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("8.8.8.8");

    const input = [_][]const u8{ "::ffff:8.8.8.8", "::ffff:808:808", "8.8.8.8", "::ffff:10.0.0.1", "::FFFF:10.0.0.1", "10.0.0.1" };
    for ([_]?internetdata.CacheOptions{ .{}, null }) |cache| {
        var client = try harness.client(.{ .cache = cache });
        defer client.deinit();
        const before = harness.stub.callCount();
        var batch = try client.lookupBatch(&input, .{});
        defer batch.deinit();

        try std.testing.expectEqual(input.len, batch.count());
        for (input, batch.keys()) |want, got| {
            try std.testing.expectEqualStrings(want, got);
        }
        for (input[0..3]) |ip| {
            const answer = batch.get(ip).?.ok;
            try std.testing.expectEqualStrings("8.8.8.8", answer.value.ip);
            try std.testing.expect(!answer.value.is_bogon);
        }
        for (input[3..]) |ip| {
            const answer = batch.get(ip).?.ok;
            try std.testing.expectEqualStrings("10.0.0.1", answer.value.ip);
            try std.testing.expect(answer.value.is_bogon);
        }
        try std.testing.expectEqual(before + 1, harness.stub.callCount());
        const sent = try std.json.parseFromSlice(struct { ips: []const []const u8 }, gpa, harness.stub.seen()[before].body, .{});
        defer sent.deinit();
        try std.testing.expectEqual(1, sent.value.ips.len);
        try std.testing.expectEqualStrings("8.8.8.8", sent.value.ips[0]);
    }
}

test "myIp looks up the calling address" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/myip", .ok(try lookupBody(harness, "146.70.116.130", "\"is_vpn\":true")));

    var client = try harness.client(.{});
    defer client.deinit();

    var answer = try client.myIp();
    defer answer.deinit();

    try std.testing.expectEqualStrings("146.70.116.130", answer.value.ip);
    try std.testing.expectEqual(@as(?bool, true), answer.value.is_vpn);
}

// The cache is keyed by address, and which address this is IS the question: a
// machine that moves between networks would otherwise be told where it used to be.
test "myIp is not cached" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/myip", .ok(try lookupBody(harness, "146.70.116.130", "")));

    var client = try harness.client(.{});
    defer client.deinit();

    var first = try client.myIp();
    first.deinit();
    var second = try client.myIp();
    second.deinit();

    try std.testing.expectEqual(@as(usize, 2), harness.stub.callCount());
}

const entitlement_body =
    \\{
    \\  "org_id": "85bb51e4-2eb6-4a31-8e4d-02ba8b98fe61",
    \\  "apikey": { "id": "0ab424cc-7619-4dad-b027-afacdc2cedb0", "expires": null, "allowed_cidrs": [] },
    \\  "plan": { "key": "max", "tier": "max" },
    \\  "usage": {
    \\    "requests": 580,
    \\    "quota": 5000000,
    \\    "hard_limit": null,
    \\    "window_start": "2026-09-04T07:00:00Z",
    \\    "window_end": "2026-10-04T07:00:00Z"
    \\  }
    \\}
;

test "myEntitlement reports the plan and the usage" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v1/entitlement", .ok(entitlement_body));

    var client = try harness.client(.{});
    defer client.deinit();

    const entitlement = try client.myEntitlement();
    defer entitlement.deinit();

    try std.testing.expectEqualStrings("max", entitlement.value.plan.key);
    try std.testing.expectEqualStrings("max", entitlement.value.plan.tier);
    try std.testing.expectEqual(@as(i64, 580), entitlement.value.usage.requests);
    try std.testing.expectEqual(@as(i64, 5_000_000), entitlement.value.usage.quota);
    // Null means NEVER stop, which is not the same as a limit of zero.
    try std.testing.expectEqual(@as(?i64, null), entitlement.value.usage.hard_limit);
    try std.testing.expectEqual(@as(usize, 0), entitlement.value.apikey.allowed_cidrs.len);
}

// The whole point is what has been spent.
test "myEntitlement is not cached" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v1/entitlement", .ok(entitlement_body));

    var client = try harness.client(.{});
    defer client.deinit();

    const first = try client.myEntitlement();
    first.deinit();
    const second = try client.myEntitlement();
    second.deinit();

    try std.testing.expectEqual(@as(usize, 2), harness.stub.callCount());
}

// Unlike a lookup there is no useful unauthenticated answer.
test "myEntitlement surfaces an unauthorized key" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v1/entitlement", .{
        .status = 401,
        .body = "{\"error\":\"invalid API key\"}",
    });

    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();

    var diagnostics: internetdata.Diagnostics = .{};
    try std.testing.expectError(error.Unauthorized, client.myEntitlementWith(.{ .diagnostics = &diagnostics }));
    try std.testing.expectEqualStrings("invalid API key", diagnostics.message());
}

// A member of the wrong type at any depth, a numeric string where a number is
// due among them, a date-time the spec's format does not name, and a member the
// spec requires that is missing: each is an answer the call cannot read, so it
// is retried like a 5xx and carries its status, as a body that is not JSON is.
const lookup_ok =
    \\{"ip":"1.1.1.1","is_bogon":false,"is_vpn":true,"is_tor":false,"is_relay":false,"is_dcproxy":true,
    \\"is_pubproxy":true,"is_anycast":false,"is_carrier":false,"is_satellite":false,"is_ssh":false,"is_smtp":false,
    \\"is_web":true,"is_dns_resolver":false,"is_bittorrent":false,
    \\"vpn":{"provider":"p","provider_name":"P","confidence":"high","last_seen":"2026-10-20"},"tor":{},"relay":{},
    \\"dcproxy":{"provider":"d","provider_name":"D","first_seen":"2026-10-01","last_seen":"2026-10-20","hits":3,
    \\"hits_days_pct":10,"providers_num":1},
    \\"pubproxy":{"entry":true,"exit":false,"protocols":["http"],"num_ports":2,"num_proxies":0,"last_seen":"2026-10-20",
    \\"last_usable":""},
    \\"web":[{"port":443,"tls_ok":true,"session_ok":true,"status_code":301,"server":"s","location":"","title":"",
    \\"cert_subject_cn":"","cert_subject_o":"","cert_issuer_dn":"","cert_browser_trusted":true,"tls_version":"TLSv1.3",
    \\"first_seen":"2026-08-12","last_seen":"2026-10-31"}],
    \\"location":{"continent":"OC","continent_name":"Oceania","country":"AU","country_name":"Australia",
    \\"timezone":"Australia/Brisbane","currency_code":"AUD","currency_name":"Dollar","currency_symbol":"A$",
    \\"flag_emoji":"","flag_unicode":"U+1F1E6 U+1F1FA","latitude":-27.5,"accuracy_radius":20},
    \\"asn":{"asn":5,"name":"n","domain":"d","type":"t","prefix":"p"},"company":{"name":"c","domain":"d"},
    \\"hostname":"h","abuse":{"email":"a"},
    \\"whois":{"id":"","name":"","org":"","country":"","status":"","source":"","domain":"","abuse_email":"","asn":13335}}
;
const asn_ok =
    \\{"asn":9009,"name":"n","country":"RO","registry":"ripe","allocated":"2005-06-06","domain":"d","num_ips":3,
    \\"whois":{"handle":"M247"},"prefixes":[{"prefix":"p","peer_count":1,"rpki_status":"valid","first_seen":"2026-10-02",
    \\"country":"VN","size":1024,"other_origins":[1]}]}
;
const domain_ok =
    \\{"domain":"example.com","is_registered":true,"has_a":true,"has_aaaa":false,"has_mx":true,"has_ns":true,
    \\"has_cname":false,"dns":{"a":[{"ip":"192.0.2.10","last_seen":"2026-11-08"}],"aaaa":[],
    \\"mx":[{"priority":10,"host":"m","last_seen":"2026-11-08"}],"ns":[],"cname":[]},
    \\"ip_ranges":{"domain":"example.com","redirects_to":"","total":1,"ipv4":256,
    \\"ranges":[{"range":"192.0.2.0/24","name":"N","country":"US"}]}}
;
const entitlement_ok =
    \\{"org_id":"o","apikey":{"id":"k","expires":null,"allowed_cidrs":[]},"plan":{"key":"max","tier":"max"},
    \\"usage":{"requests":1,"quota":10,"hard_limit":null,"window_start":"2026-10-01T00:00:00Z","window_end":"2026-11-01T00:00:00.5+02:00"}}
;

const Case = struct { path: []const u8, body: []const u8, from: []const u8 = "", to: []const u8 = "" };

// Each case is a well-formed answer with one member replaced, so the answer
// itself is what the call must refuse.
const wrong_answers = [_]Case{
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "\"hits\":3", .to = "\"hits\":\"3\"" },
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "\"num_ports\":2", .to = "\"num_ports\":\"2\"" },
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "\"asn\":5", .to = "\"asn\":\"5\"" },
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "\"asn\":13335", .to = "\"asn\":\"13335\"" },
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "\"port\":443", .to = "\"port\":\"443\"" },
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "\"latitude\":-27.5", .to = "\"latitude\":\"-27.5\"" },
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "\"accuracy_radius\":20", .to = "\"accuracy_radius\":\"20\"" },
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "\"is_vpn\":true", .to = "\"is_vpn\":\"false\"" },
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "[\"http\"]", .to = "[null]" },
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "\"hostname\":\"h\",", .to = "" },
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "\"is_tor\":false,", .to = "" },
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "\"country\":\"AU\",", .to = "" },
    .{ .path = "/1.1.1.1", .body = lookup_ok, .from = "\"title\":\"\",", .to = "" },
    .{ .path = "/myip", .body = lookup_ok, .from = "\"hits\":3", .to = "\"hits\":\"3\"" },
    .{ .path = "/myip", .body = lookup_ok, .from = "\"company\":{\"name\":\"c\",\"domain\":\"d\"},", .to = "" },
    .{ .path = "/asn/9009", .body = asn_ok, .from = "\"num_ips\":3", .to = "\"num_ips\":\"3\"" },
    .{ .path = "/asn/9009", .body = asn_ok, .from = "\"peer_count\":1", .to = "\"peer_count\":\"1\"" },
    .{ .path = "/asn/9009", .body = asn_ok, .from = "[1]", .to = "[\"1\"]" },
    .{ .path = "/asn/9009", .body = asn_ok, .from = "\"handle\":\"M247\"", .to = "\"handle\":1" },
    .{ .path = "/asn/9009", .body = asn_ok, .from = "\"registry\":\"ripe\",", .to = "" },
    .{ .path = "/domain/example.com", .body = domain_ok, .from = "\"priority\":10", .to = "\"priority\":\"10\"" },
    .{ .path = "/domain/example.com", .body = domain_ok, .from = "\"ipv4\":256", .to = "\"ipv4\":\"256\"" },
    .{ .path = "/domain/example.com", .body = domain_ok, .from = "\"has_a\":true", .to = "\"has_a\":\"true\"" },
    .{ .path = "/domain/example.com", .body = domain_ok, .from = "\"has_mx\":true,", .to = "" },
    .{ .path = "/domain/example.com", .body = domain_ok, .from = "\"aaaa\":[],", .to = "" },
    .{ .path = "/api/v1/entitlement", .body = entitlement_ok, .from = "\"requests\":1", .to = "\"requests\":\"1\"" },
    .{ .path = "/api/v1/entitlement", .body = entitlement_ok, .from = "\"window_start\":\"2026-10-01T00:00:00Z\"", .to = "\"window_start\":\"x\"" },
    .{ .path = "/api/v1/entitlement", .body = entitlement_ok, .from = "\"window_start\":\"2026-10-01T00:00:00Z\"", .to = "\"window_start\":\"2026-10-01T24:00:00Z\"" },
    .{ .path = "/api/v1/entitlement", .body = entitlement_ok, .from = "\"window_start\":\"2026-10-01T00:00:00Z\"", .to = "\"window_start\":\"2026-10-01T10:00:00\"" },
    .{ .path = "/api/v1/entitlement", .body = entitlement_ok, .from = "\"window_start\":\"2026-10-01T00:00:00Z\"", .to = "\"window_start\":\"2026-02-30T00:00:00Z\"" },
    .{ .path = "/api/v1/entitlement", .body = entitlement_ok, .from = "\"window_start\":\"2026-10-01T00:00:00Z\"", .to = "\"window_start\":\"2026-10-01\"" },
    .{ .path = "/api/v1/entitlement", .body = entitlement_ok, .from = "\"expires\":null", .to = "\"expires\":\"monday\"" },
    .{ .path = "/api/v1/entitlement", .body = entitlement_ok, .from = "\"expires\":null,", .to = "" },
};

fn lookupCall(client: *internetdata.Client, path: []const u8, diag: *internetdata.Diagnostics) ?anyerror {
    const options: internetdata.CallOptions = .{ .diagnostics = diag };
    if (std.mem.eql(u8, path, "/1.1.1.1")) {
        const answer = client.lookupWith("1.1.1.1", options) catch |err| return err;
        answer.deinit();
    } else if (std.mem.eql(u8, path, "/myip")) {
        const answer = client.myIpWith(options) catch |err| return err;
        answer.deinit();
    } else if (std.mem.eql(u8, path, "/asn/9009")) {
        const answer = client.lookupAsnWith(9009, options) catch |err| return err;
        answer.deinit();
    } else if (std.mem.eql(u8, path, "/domain/example.com")) {
        const answer = client.lookupDomainWith("example.com", options) catch |err| return err;
        answer.deinit();
    } else if (std.mem.eql(u8, path, "/api/v1/entitlement")) {
        const answer = client.myEntitlementWith(options) catch |err| return err;
        answer.deinit();
    } else if (std.mem.eql(u8, path, "/api/v2/database/list")) {
        const answer = client.database().list(options) catch |err| return err;
        answer.deinit();
    } else if (std.mem.eql(u8, path, "/api/v2/database/metadata")) {
        const answer = client.database().metadata("bogon_ip_v1", options) catch |err| return err;
        answer.deinit();
    } else if (std.mem.eql(u8, path, "/api/v2/database/checksum")) {
        const answer = client.database().checksums("bogon_ip_v1", .csvgz, options) catch |err| return err;
        answer.deinit();
    } else if (std.mem.eql(u8, path, "/api/v2/database/downloads")) {
        const answer = client.database().downloads(null, options) catch |err| return err;
        answer.deinit();
    } else if (std.mem.eql(u8, path, "/api/v2/database/download")) {
        const url = client.database().downloadUrl("bogon_ip_v1", .csvgz, options) catch |err| return err;
        client.gpa.free(url);
    } else unreachable;
    return null;
}

test "a lookup answer with a member of the wrong type or missing, or a malformed date, is retried" {
    const gpa = std.testing.allocator;
    // Every well-formed answer above reads, so each case below fails on its
    // one change alone.
    {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        for ([_]Case{
            .{ .path = "/1.1.1.1", .body = lookup_ok },                 .{ .path = "/myip", .body = lookup_ok },
            .{ .path = "/asn/9009", .body = asn_ok },                   .{ .path = "/domain/example.com", .body = domain_ok },
            .{ .path = "/api/v1/entitlement", .body = entitlement_ok },
        }) |case| try harness.stub.route(case.path, .{ .body = case.body });
        var client = try harness.client(.{ .retries = 0, .cache = null });
        defer client.deinit();
        for ([_][]const u8{ "/1.1.1.1", "/myip", "/asn/9009", "/domain/example.com", "/api/v1/entitlement" }) |path| {
            var diag: internetdata.Diagnostics = .{};
            if (lookupCall(&client, path, &diag)) |err| {
                std.debug.print("{s} refused its well-formed answer: {s} {s}\n", .{ path, @errorName(err), diag.message() });
                return err;
            }
        }
    }
    var failures: usize = 0;
    for (wrong_answers) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        const body = try std.mem.replaceOwned(u8, harness.stub.arena.allocator(), case.body, case.from, case.to);
        std.debug.assert(!std.mem.eql(u8, body, case.body));
        try harness.stub.route(case.path, .{ .body = body });
        var client = try harness.client(.{ .retries = 1, .cache = null });
        defer client.deinit();
        var diag: internetdata.Diagnostics = .{};
        const failed = lookupCall(&client, case.path, &diag);
        var sent: usize = 0;
        for (harness.stub.seen()) |call| {
            if (std.mem.eql(u8, call.path, case.path)) sent += 1;
        }
        const refused = if (failed) |err| err == error.ServerError else false;
        if (!refused or sent != 2 or diag.status != 200) {
            std.debug.print("{s} with {s}: {s}, sent {d}, status {?d}\n", .{ case.path, if (case.to.len > 0) case.to else case.from, if (failed) |err| @errorName(err) else "answered", sent, diag.status });
            failures += 1;
        }
    }
    try std.testing.expectEqual(0, failures);
}

test "a batch entry with a member of the wrong type or missing fails that address alone" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const body = try harness.stub.printed("{{\"results\":{{\"1.1.1.1\":{s},\"8.8.8.8\":{s},\"9.9.9.9\":{s}}}}}", .{
        try lookupBody(harness, "1.1.1.1", "\"dcproxy\":{\"hits\":\"3\"}"),
        try std.mem.replaceOwned(u8, harness.stub.arena.allocator(), try lookupBody(harness, "8.8.8.8", ""), "\"hostname\":\"\",", ""),
        try lookupBody(harness, "9.9.9.9", "\"vpn\":{\"last_seen\":\"2026-10-20\"}"),
    });
    try harness.stub.route("/batch", .{ .body = body, .verbatim = true });
    var client = try harness.client(.{ .retries = 2 });
    defer client.deinit();
    var batch = try client.lookupBatch(&.{ "1.1.1.1", "8.8.8.8", "9.9.9.9" }, .{});
    defer batch.deinit();

    try std.testing.expectEqual(1, harness.stub.callCount());
    for ([_][]const u8{ "1.1.1.1", "8.8.8.8" }) |ip| switch (batch.get(ip).?) {
        .ok => {
            std.debug.print("{s} answered\n", .{ip});
            return error.TestUnexpectedResult;
        },
        .failed => |failure| {
            try std.testing.expectEqual(error.ServerError, failure.err);
            try std.testing.expectEqual(@as(?u16, 200), failure.diagnostics.status);
        },
    };
    try std.testing.expect(batch.get("9.9.9.9").? == .ok);
}

test "an entitlement date-time in any of RFC 3339's spellings is read" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const arena = harness.stub.arena.allocator();
    try harness.stub.route("/api/v1/entitlement", .{ .body = try std.mem.replaceOwned(u8, arena, entitlement_ok, "2026-10-01T00:00:00Z", "2026-10-01t00:00:00z") });
    var client = try harness.client(.{ .retries = 2 });
    defer client.deinit();

    const entitlement = try client.myEntitlement();
    defer entitlement.deinit();
    try std.testing.expectEqualStrings("2026-10-01t00:00:00z", entitlement.value.usage.window_start);
    try std.testing.expectEqual(1, harness.stub.callCount());
}

// A proxy's or a gateway's own refusal is classified by its status alone, and
// sent once, whatever its body is and whatever it is labeled as.
test "a 4xx whose body is not the API's is classified by its status and sent once" {
    const gpa = std.testing.allocator;
    const Refusal = struct { status: u16, body: []const u8, want: anyerror };
    const refusals = [_]Refusal{
        .{ .status = 401, .body = "<html><body>401 Authorization Required</body></html>", .want = error.Unauthorized },
        .{ .status = 403, .body = "", .want = error.Forbidden },
        .{ .status = 429, .body = "<html><body>Too Many Requests</body></html>", .want = error.QuotaExceeded },
        .{ .status = 400, .body = "<html><body>Bad Request</body></html>", .want = error.BadRequest },
    };
    const labels = [_][]const u8{ "text/html", "application/json" };
    for (refusals) |refusal| for (labels) |label| for (paths_of_every_call) |path| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        const headers = try harness.stub.arena.allocator().dupe(Route.Header, &.{.{ .name = "Content-Type", .value = label }});
        try harness.stub.route(path, .{ .status = refusal.status, .body = refusal.body, .headers = headers, .verbatim = true });
        var client = try harness.client(.{ .api_key = "key", .retries = 2, .cache = null });
        defer client.deinit();
        var diag: internetdata.Diagnostics = .{};
        const failed: ?anyerror = if (std.mem.eql(u8, path, "/batch")) blk: {
            var batch = try client.lookupBatch(&.{ "1.1.1.1", "8.8.8.8" }, .{});
            defer batch.deinit();
            break :blk switch (batch.get("1.1.1.1").?) {
                .ok => null,
                .failed => |failure| failed: {
                    diag = failure.diagnostics;
                    break :failed failure.err;
                },
            };
        } else lookupCall(&client, path, &diag);
        std.testing.expectEqual(@as(?anyerror, refusal.want), failed) catch |err| {
            std.debug.print("{s} answering {d} as {s}\n", .{ path, refusal.status, label });
            return err;
        };
        try std.testing.expectEqual(1, harness.stub.callCount());
        try std.testing.expectEqual(@as(?u16, refusal.status), diag.status);
    };
}

const paths_of_every_call = [_][]const u8{
    "/1.1.1.1",                  "/myip",                      "/api/v1/entitlement",       "/batch",
    "/asn/9009",                 "/domain/example.com",        "/api/v2/database/list",     "/api/v2/database/metadata",
    "/api/v2/database/checksum", "/api/v2/database/downloads", "/api/v2/database/download",
};
