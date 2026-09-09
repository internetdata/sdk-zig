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

    for ([_]?[]const u8{ null, "" }) |api_key| {
        var client = try harness.client(.{ .api_key = api_key });
        defer client.deinit();
        (try client.database().list(.{})).deinit();
    }

    for (harness.stub.seen()) |call| {
        try std.testing.expectEqualStrings("", call.authorization);
    }
    try std.testing.expectEqual(2, harness.stub.callCount());
}

// A licence covers a FAMILY, and the downloadable ids hang off its versions. A
// client that reads `base` as an id asks for a database that does not exist.
test "the catalog unwraps a family and its versions" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v2/database/list", .ok(
        \\{"databases":[{"base":"bogon_ip","name":"Bogon IP",
        \\ "summary":"Reserved, private or otherwise non-routable IP ranges.",
        \\ "standing":"licensed","license_type":"standard",
        \\ "starts":"2026-09-04T18:04:26.431Z","expires":null,"renews_at":null,"notice_due_at":null,
        \\ "versions":[{"id":"bogon_ip_v1","version":1,"summary":"s",
        \\   "formats":["csvgz","mmdb"]}]}]}
    ));

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const catalog = try client.database().list(.{});
    defer catalog.deinit();

    try std.testing.expectEqual(1, catalog.value.len);
    const family = catalog.value[0];
    try std.testing.expectEqualStrings("bogon_ip", family.base);
    try std.testing.expectEqualStrings("licensed", family.standing);
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
        \\ "bytes":null,"http_status":403,"apikey_id":null,"client_ip":"203.0.113.7",
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

// A 404 from a misspelled id is a CLIENT error. Letting it fall through to the
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

// A licence refusal is the API saying no, not a wobble: retrying it spends quota
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
