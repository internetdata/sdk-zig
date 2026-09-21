//! The per-attempt timeout, on real sockets: a body that stalls after its head,
//! one trickled a byte at a time, the per-call value against the client's, a
//! download that outlives the bound, and what cancelation leaves behind.

const std = @import("std");
const internetdata = @import("internetdata");

const support = @import("support.zig");

const Diagnostics = internetdata.Diagnostics;
const Harness = support.Harness;
const Io = std.Io;
const Route = support.Route;

const list_path = "/api/v2/database/list";
const list_body = "{\"databases\":[]}";
/// Longer than any bound under test, so an unbounded call fails its elapsed
/// assertion instead of hanging. Tearing the stub down ends it early.
const stall: Io.Duration = .fromSeconds(5);
/// How late past its bound a canceled attempt may still return.
const slack_ms = 1000;

// No single read waits more than 20 ms here, so only a bound on the whole
// attempt ends it. The stub then proves the attempt is gone rather than left
// running: its next write finds the connection closed.
test "a trickled body times out at the bound and its connection is dropped" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route(list_path, .{
        .body = (" " ** 300) ++ list_body,
        .trickle = .fromMilliseconds(20),
    });
    var client = try harness.client(.{ .retries = 0, .timeout = .fromMilliseconds(250) });
    defer client.deinit();

    var diagnostics: Diagnostics = .{};
    const start = Io.Clock.awake.now(harness.io());
    const outcome = listOnce(&client, .{ .diagnostics = &diagnostics });
    const took_ms = since(harness, start);
    try expectTimedOut("trickled body", outcome, &diagnostics, took_ms, 250, 250 + slack_ms);

    var waited_ms: usize = 0;
    while (harness.stub.hangupCount() == 0 and waited_ms < 1000) : (waited_ms += 10) {
        try harness.io().sleep(.fromMilliseconds(10), .awake);
    }
    std.testing.expectEqual(1, harness.stub.hangupCount()) catch |err| {
        std.debug.print("the timed-out attempt never dropped its connection\n", .{});
        return err;
    };
}

test "a body that stalls after its head times out at the client's bound" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route(list_path, stalledBody(list_body));
    var client = try harness.client(.{ .retries = 0, .timeout = .fromMilliseconds(250) });
    defer client.deinit();

    var diagnostics: Diagnostics = .{};
    const start = Io.Clock.awake.now(harness.io());
    const outcome = listOnce(&client, .{ .diagnostics = &diagnostics });
    const took_ms = since(harness, start);
    try expectTimedOut("stalled body", outcome, &diagnostics, took_ms, 250, 250 + slack_ms);
    try std.testing.expectEqual(1, harness.stub.callCount());
}

// The client's own bound is well above the call's, so a call that ignores its
// value fails on elapsed time; the second call then shows the first did not
// leave its value behind.
test "a per-call timeout below the client's fires, and the next call keeps the client's" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route(list_path, stalledBody(list_body));
    var client = try harness.client(.{ .retries = 0, .timeout = .fromMilliseconds(1000) });
    defer client.deinit();

    var diagnostics: Diagnostics = .{};
    var start = Io.Clock.awake.now(harness.io());
    var outcome = listOnce(&client, .{ .timeout = .fromMilliseconds(250), .diagnostics = &diagnostics });
    var took_ms = since(harness, start);
    try expectTimedOut("per-call value", outcome, &diagnostics, took_ms, 250, 900);

    start = Io.Clock.awake.now(harness.io());
    outcome = listOnce(&client, .{ .diagnostics = &diagnostics });
    took_ms = since(harness, start);
    try expectTimedOut("client value after it", outcome, &diagnostics, took_ms, 1000, 1000 + slack_ms);
}

// Zero or below, every attempt times out before it starts, so the call would
// fail as a network error only after the whole backoff; past the bound the
// deadline overflows and the process panics. Both are refused where they are
// set, on every call, before a request.
test "a timeout no attempt can meet is refused before any request" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route(list_path, .ok(list_body));
    try support.routeDownload(harness, .ok("unused"));
    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "key", .retries = 2 });
    defer client.deinit();
    const database = client.database();
    const oauth = client.oauth();

    const refused = [_]Io.Duration{
        .zero,
        .fromMilliseconds(-5000),
        .fromNanoseconds(std.math.maxInt(i64) + 1),
        .max,
    };
    for (refused) |timeout| {
        var diagnostics: Diagnostics = .{};
        const options: internetdata.CallOptions = .{ .timeout = timeout, .diagnostics = &diagnostics };
        const oauth_options: internetdata.OauthOptions = .{ .timeout = timeout, .diagnostics = &diagnostics };
        const start = Io.Clock.awake.now(harness.io());
        try std.testing.expectError(error.BadRequest, database.list(options));
        try std.testing.expectError(error.BadRequest, database.metadata("bogon_ip_v1", options));
        try std.testing.expectError(error.BadRequest, database.checksums("bogon_ip_v1", .csvgz, options));
        try std.testing.expectError(error.BadRequest, database.downloads(null, options));
        try std.testing.expectError(error.BadRequest, database.downloadUrl("bogon_ip_v1", .csvgz, options));
        try std.testing.expectError(error.BadRequest, database.downloadBytes("bogon_ip_v1", .csvgz, options));
        try std.testing.expectError(error.BadRequest, database.download(
            "bogon_ip_v1",
            .csvgz,
            scratch.path("data.csv.gz"),
            options,
        ));
        try std.testing.expectError(error.BadRequest, oauth.metadata(oauth_options));
        try std.testing.expectError(error.BadRequest, oauth.deviceAuthorization("x", .{
            .timeout = timeout,
            .diagnostics = &diagnostics,
        }));
        try std.testing.expectError(error.BadRequest, oauth.exchangeDeviceCode("x", "x", oauth_options));
        try std.testing.expectError(error.BadRequest, oauth.exchangeRefreshToken("x", "x", oauth_options));
        try std.testing.expectError(error.BadRequest, oauth.revoke("x", "x", oauth_options));
        // Refused rather than retried: the first backoff alone is 250 ms.
        try std.testing.expect(since(harness, start) < 250);
        try std.testing.expect(std.mem.startsWith(u8, diagnostics.message(), "timeout must be positive"));
        // The poll waits out its interval before the request it bounds.
        try std.testing.expectError(error.BadRequest, oauth.pollDeviceToken("x", .{
            .device_code = "x",
            .user_code = "x",
            .verification_uri = "x",
            .expires_in = 60,
            .interval = 1,
        }, oauth_options));
    }
    try std.testing.expectEqual(0, harness.stub.callCount());
    try std.testing.expect(!scratch.exists("data.csv.gz.part"));

    // The bound itself is a timeout like any other.
    (try database.list(.{ .timeout = .fromNanoseconds(std.math.maxInt(i64)) })).deinit();
    try std.testing.expectEqual(1, harness.stub.callCount());
}

// Each call against the one path it stalls, first on the client's bound, then
// on its own below a client's far above it, so a call that ignores either value
// fails on elapsed time.
test "every call honors the client's timeout and its own" {
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |per_call| {
        for (std.meta.tags(Call)) |call| {
            const harness = try Harness.start(gpa);
            defer harness.deinit();
            try call.stall(harness);
            var client = try harness.client(.{
                .api_key = "key",
                .retries = 0,
                .timeout = .fromMilliseconds(if (per_call) 2000 else 250),
            });
            defer client.deinit();

            var diagnostics: Diagnostics = .{};
            const options: internetdata.CallOptions = .{
                .timeout = if (per_call) .fromMilliseconds(250) else null,
                .diagnostics = &diagnostics,
            };
            const start = Io.Clock.awake.now(harness.io());
            const outcome = call.run(&client, options);
            const took_ms = since(harness, start);
            var name_buffer: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "{s}{s}", .{
                @tagName(call),
                if (per_call) " per call" else "",
            });
            // The poll waits out its interval before the request it bounds.
            const floor_ms: i64 = if (call == .poll) 1250 else 250;
            try expectTimedOut(name, outcome, &diagnostics, took_ms, floor_ms, floor_ms + slack_ms);
        }
    }
}

// One deadline for the whole call would leave the retry none to spend.
test "each retry gets the whole bound again" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const arena = harness.stub.arena.allocator();
    const answers = try arena.dupe(Route, &.{ stalledBody(list_body), .ok(list_body) });
    try harness.stub.sequence(list_path, answers);
    var client = try harness.client(.{ .retries = 1, .timeout = .fromMilliseconds(250) });
    defer client.deinit();

    const catalog = try client.database().list(.{});
    defer catalog.deinit();
    try std.testing.expectEqual(0, catalog.value.len);
    try std.testing.expectEqual(2, harness.stub.callCount());
}

test "a download that runs past the timeout still completes" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const body = "0123456789abcdef" ** 4;
    try support.routeDownload(harness, .{ .body = body, .stall = .fromMilliseconds(600), .stall_after = 16 });

    var scratch = support.Scratch.start();
    defer scratch.deinit();
    var client = try harness.client(.{ .api_key = "key", .retries = 0, .timeout = .fromMilliseconds(200) });
    defer client.deinit();

    var diagnostics: Diagnostics = .{};
    var start = Io.Clock.awake.now(harness.io());
    const written = client.database().download("bogon_ip_v1", .csvgz, scratch.path("data.csv.gz"), .{
        .diagnostics = &diagnostics,
    }) catch |err| {
        std.debug.print("download failed after {d} ms: {s} {s}\n", .{
            since(harness, start), @errorName(err), diagnostics.message(),
        });
        return err;
    };
    try std.testing.expect(since(harness, start) >= 600);
    try std.testing.expectEqual(body.len, written);
    var read_buffer: [128]u8 = undefined;
    try std.testing.expectEqualSlices(u8, body, try scratch.read("data.csv.gz", &read_buffer));

    start = Io.Clock.awake.now(harness.io());
    const options: internetdata.CallOptions = .{
        .timeout = .fromMilliseconds(150),
        .diagnostics = &diagnostics,
    };
    const bytes = client.database().downloadBytes("bogon_ip_v1", .csvgz, options) catch |err| {
        std.debug.print("downloadBytes failed after {d} ms: {s} {s}\n", .{
            since(harness, start), @errorName(err), diagnostics.message(),
        });
        return err;
    };
    defer gpa.free(bytes);
    try std.testing.expect(since(harness, start) >= 600);
    try std.testing.expectEqualSlices(u8, body, bytes);
}

// The bound's own wait is a cancelation point. Canceling the task running a
// call ends it at once, and ends its retries with it.
test "canceling the task that runs a call ends the call at once" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route(list_path, stalledBody(list_body));
    var client = try harness.client(.{ .retries = 2, .timeout = .fromSeconds(3) });
    defer client.deinit();

    const io = harness.io();
    var task = try io.concurrent(listTask, .{&client});
    try io.sleep(.fromMilliseconds(200), .awake);
    const start = Io.Clock.awake.now(io);
    const outcome = task.cancel(io);
    const took_ms = since(harness, start);
    try std.testing.expectError(error.Network, outcome);
    if (took_ms >= slack_ms) {
        std.debug.print("the canceled call took {d} ms to end\n", .{took_ms});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(1, harness.stub.callCount());
}

// Through `std.Io` itself: an `Io` with no task to race the attempt on runs it
// inline rather than failing the call.
test "a call completes on an Io that cannot start a concurrent task" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route(list_path, .ok(list_body));
    var url_buffer: [64]u8 = undefined;
    var client = try internetdata.Client.init(gpa, NoConcurrency.install(harness.io()), .{
        .base_url = harness.stub.baseUrl(&url_buffer),
        .timeout = .fromMilliseconds(250),
    });
    defer client.deinit();

    const catalog = try client.database().list(.{});
    defer catalog.deinit();
    try std.testing.expectEqual(0, catalog.value.len);
}

/// Every call, by the path its request goes to. `download_link` stalls the
/// API's answer to a download rather than object storage's.
const Call = enum {
    list,
    metadata,
    checksums,
    downloads,
    download_url,
    download_link,
    download,
    download_bytes,
    oauth_metadata,
    device_authorization,
    exchange_device_code,
    exchange_refresh_token,
    revoke,
    poll,

    fn stall(call: Call, harness: *Harness) !void {
        const stub = harness.stub;
        switch (call) {
            .list => try stub.route(list_path, stalledBody(list_body)),
            .metadata => try stub.route("/api/v2/database/metadata", stalledBody("{\"id\":\"x\"}")),
            .checksums => try stub.route("/api/v2/database/checksum", stalledBody("{\"id\":\"x\"}")),
            .downloads => try stub.route("/api/v2/database/downloads", stalledBody("{\"downloads\":[]}")),
            .download_url, .download_link => try stub.route("/api/v2/database/download", stalledHead()),
            .download, .download_bytes => try support.routeDownload(harness, stalledHead()),
            .oauth_metadata => {
                try stub.route("/.well-known/oauth-authorization-server", stalledBody("{\"issuer\":\"x\"}"));
            },
            .device_authorization => {
                try stub.route("/oauth/device_authorization", stalledBody("{\"device_code\":\"x\"}"));
            },
            .exchange_device_code, .exchange_refresh_token, .poll => {
                try stub.route("/oauth/token", stalledBody("{\"access_token\":\"x\"}"));
            },
            .revoke => try stub.route("/oauth/revoke", stalledBody("{\"revoked\":true}")),
        }
    }

    /// Makes the call, freeing whatever it answers: an answer is the failure
    /// here, and the caller reports it.
    fn run(call: Call, client: *internetdata.Client, options: internetdata.CallOptions) anyerror!void {
        const database = client.database();
        const oauth: internetdata.OauthOptions = .{ .timeout = options.timeout, .diagnostics = options.diagnostics };
        switch (call) {
            .list => (try database.list(options)).deinit(),
            .metadata => (try database.metadata("x", options)).deinit(),
            .checksums => (try database.checksums("x", .mmdb, options)).deinit(),
            .downloads => (try database.downloads(null, options)).deinit(),
            .download_url => client.gpa.free(try database.downloadUrl("x", .mmdb, options)),
            .download, .download_link => {
                var scratch = support.Scratch.start();
                defer scratch.deinit();
                _ = try database.download("x", .mmdb, scratch.path("x.mmdb"), options);
            },
            .download_bytes => client.gpa.free(try database.downloadBytes("x", .mmdb, options)),
            .oauth_metadata => (try client.oauth().metadata(oauth)).deinit(),
            .device_authorization => (try client.oauth().deviceAuthorization("x", .{
                .timeout = options.timeout,
                .diagnostics = options.diagnostics,
            })).deinit(),
            .exchange_device_code => (try client.oauth().exchangeDeviceCode("x", "x", oauth)).deinit(),
            .exchange_refresh_token => (try client.oauth().exchangeRefreshToken("x", "x", oauth)).deinit(),
            .revoke => try client.oauth().revoke("x", "x", oauth),
            .poll => (try client.oauth().pollDeviceToken("x", .{
                .device_code = "x",
                .user_code = "x",
                .verification_uri = "x",
                .expires_in = 60,
                .interval = 1,
            }, oauth)).deinit(),
        }
    }
};

/// Elapsed time first, because a call that failed the right way at the wrong
/// bound is the regression a weaker check lets through.
fn expectTimedOut(
    name: []const u8,
    outcome: anyerror!void,
    diagnostics: *const Diagnostics,
    took_ms: i64,
    at_least_ms: i64,
    below_ms: i64,
) !void {
    if (took_ms < at_least_ms or took_ms >= below_ms) {
        std.debug.print("{s}: took {d} ms, expected {d} to {d}\n", .{ name, took_ms, at_least_ms, below_ms });
        return error.TestUnexpectedResult;
    }
    if (outcome) |_| {
        std.debug.print("{s}: answered instead of timing out\n", .{name});
        return error.TestUnexpectedResult;
    } else |err| if (err != error.Network) {
        std.debug.print("{s}: failed with {s}, not as a network error\n", .{ name, @errorName(err) });
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, diagnostics.message(), "timed out") == null) {
        std.debug.print("{s}: the timeout was reported as \"{s}\"\n", .{ name, diagnostics.message() });
        return error.TestUnexpectedResult;
    }
}

fn listOnce(client: *internetdata.Client, options: internetdata.CallOptions) anyerror!void {
    const catalog = try client.database().list(options);
    catalog.deinit();
}

fn listTask(client: *internetdata.Client) internetdata.CallError!void {
    const catalog = try client.database().list(.{});
    catalog.deinit();
}

fn since(harness: *Harness, start: Io.Timestamp) i64 {
    return start.durationTo(Io.Clock.awake.now(harness.io())).toMilliseconds();
}

/// The head and a few bytes at once, then nothing for longer than any bound.
fn stalledBody(body: []const u8) Route {
    return .{ .body = body, .stall = stall, .stall_after = @min(body.len, 8) };
}

/// Nothing at all for longer than any bound, not even the status line.
fn stalledHead() Route {
    return .{ .body = "{}", .stall = stall, .stall_after = null };
}

/// A `std.Io` whose `concurrent` always refuses, over a real one for everything
/// else. Global state, because a vtable function receives only the userdata.
const NoConcurrency = struct {
    var vtable: Io.VTable = undefined;

    fn install(real: Io) Io {
        vtable = real.vtable.*;
        vtable.concurrent = refuse;
        return .{ .userdata = real.userdata, .vtable = &vtable };
    }

    fn refuse(
        _: ?*anyopaque,
        _: usize,
        _: std.mem.Alignment,
        _: []const u8,
        _: std.mem.Alignment,
        _: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) Io.ConcurrentError!*Io.AnyFuture {
        return error.ConcurrencyUnavailable;
    }
};
