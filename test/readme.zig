//! Compiles the README's examples without running them, so a rename that
//! invalidates the README fails the build rather than a reader's first attempt.
//! Mirror any README edit here.

const std = @import("std");
const internetdata = @import("internetdata");

test "the README's examples still compile" {
    // Runtime-false rather than `if (false)`, whose body Zig would not analyze.
    var never = false;
    _ = &never;
    if (never) {
        try examples(std.testing.allocator, "key");
    }
}

fn examples(gpa: std.mem.Allocator, key: []const u8) !void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var keyless = try internetdata.Client.init(gpa, threaded.io(), .{});
    defer keyless.deinit();

    const result = try keyless.lookup("146.70.116.130");
    defer result.deinit();
    std.debug.print("{s}\n", .{result.value.location.country});
    std.debug.print("{s}\n", .{result.value.asn.name});
    std.debug.print("{s}\n", .{result.value.company.name});

    var client = try internetdata.Client.init(gpa, threaded.io(), .{ .api_key = key });
    defer client.deinit();

    const paid = try client.lookup("146.70.116.130");
    defer paid.deinit();
    std.debug.print("{}\n", .{paid.value.is_vpn orelse false});
    std.debug.print("{s}\n", .{paid.value.vpn.?.provider_name.?});
    std.debug.print("{s}\n", .{paid.value.location.city.?});

    const network = try client.lookupAsn(9009);
    defer network.deinit();
    std.debug.print("{s}\n", .{network.value.name});

    const domain = try client.lookupDomain("example.com");
    defer domain.deinit();
    std.debug.print("{}\n", .{domain.value.has_mx});

    const mine = try client.myIp();
    defer mine.deinit();
    std.debug.print("{s}\n", .{mine.value.ip});

    const acct = try client.myEntitlement();
    defer acct.deinit();
    std.debug.print("{s}\n", .{acct.value.plan.key});
    std.debug.print("{d}\n", .{acct.value.usage.requests});

    var batch = try client.lookupBatch(&.{ "146.70.116.130", "8.8.8.8", "1.1.1.1" }, .{});
    defer batch.deinit();
    for (batch.keys(), batch.values()) |ip, entry| {
        switch (entry) {
            .ok => |answer| std.debug.print("{s}: {s}\n", .{ ip, answer.value.asn.name }),
            .failed => |failure| std.debug.print("{s}: {s}\n", .{ ip, failure.diagnostics.message() }),
        }
    }
    const many_ips: []const []const u8 = &.{"1.1.1.1"};
    var wider = try client.lookupBatch(many_ips, .{ .concurrency = 4, .retries = 4 });
    defer wider.deinit();

    var sized = try internetdata.Client.init(gpa, threaded.io(), .{
        .cache = .{ .max_entries = 50_000, .ttl = .fromSeconds(6 * 60 * 60) },
    });
    defer sized.deinit();
    var uncached = try internetdata.Client.init(gpa, threaded.io(), .{ .cache = null });
    defer uncached.deinit();

    const bogon = try client.lookup("192.168.1.1");
    defer bogon.deinit();
    std.debug.print("{} {d}\n", .{ bogon.value.is_bogon, bogon.raw.len });
    std.debug.print("{} {}\n", .{ client.isBogon("10.0.0.1"), internetdata.isBogon("8.8.8.8") });

    const vpn = result.value.is_vpn orelse false;
    _ = vpn;
    if (result.value.is_vpn == null or result.value.location.city == null or result.value.trial_expired == true) {
        std.debug.print("not in this plan\n", .{});
    }

    var diagnosed: internetdata.Diagnostics = .{};
    const answer = client.lookupWith("1.1.1.1", .{ .diagnostics = &diagnosed }) catch |err| {
        std.debug.print("{s} retryable={} status={?} {s}\n", .{
            internetdata.kindName(err),
            internetdata.isRetryable(err),
            diagnosed.status,
            diagnosed.message(),
        });
        return err;
    };
    defer answer.deinit();

    const catalog = try client.database().list(.{});
    defer catalog.deinit();

    for (catalog.value) |entry| {
        std.debug.print("{s} ({s})\n", .{ entry.base, entry.standing });
    }

    const family = catalog.value[0];
    _ = family.base;
    _ = family.standing;
    _ = family.license_type;
    const id = family.versions[0].id;

    const info = try client.database().metadata(id, .{});
    defer info.deinit();
    std.debug.print("{s}, {d} rows, updated {s}\n", .{
        info.value.id,
        info.value.entries,
        info.value.updated,
    });
    std.debug.print("{?d} bytes as csvgz\n", .{info.value.size.map.get("csvgz")});

    const written = try client.database().download(id, .csvgz, "bogon_ip_v1.csv.gz", .{});
    _ = written;

    const url = try client.database().downloadUrl(id, .csvgz, .{});
    defer gpa.free(url);

    const bytes = try client.database().downloadBytes(id, .csvgz, .{});
    defer gpa.free(bytes);

    const build: []const u8 = "20261105.0t53s5";
    _ = try client.database().download("vpn_ip_v1", .mmdb, "vpn_ip_v1.mmdb", .{ .build = build });

    const digests = try client.database().checksums(id, .csvgz, .{});
    defer digests.deinit();
    std.debug.print("{s}\n", .{digests.value.sha256});

    const history = try client.database().downloads(20, .{});
    defer history.deinit();
    for (history.value) |attempt| {
        std.debug.print("{s} {s} {s}\n", .{ attempt.created, attempt.dataset_id, attempt.outcome });
    }

    const retried = try client.database().list(.{ .retries = 4 });
    defer retried.deinit();

    var bounded = try internetdata.Client.init(gpa, threaded.io(), .{ .timeout = .fromSeconds(10) });
    defer bounded.deinit();
    const quick = try bounded.lookupWith("1.1.1.1", .{ .timeout = .fromMilliseconds(500) });
    defer quick.deinit();

    try signIn(gpa, &threaded);
    try signInByCode(gpa, &threaded, "code");
    try registerClient(gpa, &threaded);
}

fn signIn(gpa: std.mem.Allocator, threaded: *std.Io.Threaded) !void {
    var client = try internetdata.Client.init(gpa, threaded.io(), .{});
    defer client.deinit();
    const device = try client.oauth().deviceAuthorization("your-client-id", .{ .scope = "account.read apikeys.read apikeys.reveal" });
    defer device.deinit();
    std.debug.print("Open {s} and enter {s}\n", .{ device.value.verification_uri, device.value.user_code });

    const token = try client.oauth().pollDeviceToken("your-client-id", device.value, .{});
    defer token.deinit();
    const apikey = token.value.apikey orelse return error.NoApiKey; // none was picked, or it cannot be shown again
    var keyed = try internetdata.Client.init(gpa, threaded.io(), .{ .api_key = apikey });
    defer keyed.deinit();

    const refresh_token = token.value.refresh_token orelse "";
    client.oauth().revoke("your-client-id", refresh_token, .{}) catch |err| switch (err) {
        error.OauthAccessDenied, error.OauthExpiredToken => {},
        else => return err,
    };
}

fn registerClient(gpa: std.mem.Allocator, threaded: *std.Io.Threaded) !void {
    var client = try internetdata.Client.init(gpa, threaded.io(), .{});
    defer client.deinit();
    const registration = try client.oauth().register(&.{"http://127.0.0.1:8765/callback"}, .{ .client_name = "Your App" });
    defer registration.deinit();
}

fn signInByCode(gpa: std.mem.Allocator, threaded: *std.Io.Threaded, code: []const u8) !void {
    var client = try internetdata.Client.init(gpa, threaded.io(), .{});
    defer client.deinit();
    const redirect_uri = "http://127.0.0.1:8765/callback";
    const pkce = client.oauth().createPkce();

    const url = try client.oauth().authorizationUrl("your-client-id", redirect_uri, &pkce.challenge, .{ .scope = "apikeys.use", .state = "your-state" });
    defer gpa.free(url);
    // Open url in the browser. Its redirect to redirect_uri carries code and state.
    const token = try client.oauth().exchangeAuthorizationCode("your-client-id", code, &pkce.verifier, redirect_uri, .{});
    defer token.deinit();
}
