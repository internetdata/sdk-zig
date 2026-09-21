//! The published library's OAuth accessor against staging, on a KEYLESS client.
//!
//! Only what is safe to repeat: discovery, revoking junk, exchanging a junk
//! device code, and at most ONE device authorization per run, because staging
//! allows 30 a minute per source address and every SDK built here shares one.
//! Never a poll: nobody approves the code. That no request carries a key is
//! asserted offline, against a client built with one.

const std = @import("std");
const internetdata = @import("internetdata");

const staging = @import("staging.zig");

/// The one client ID staging accepts, already public in the CLI's source.
const client_id = "internetdata-cli";
/// Where staging sends a person to approve a device sign-in.
const staging_console = "https://app-staging.internetdata.io";

test "staging publishes its authorization server metadata" {
    const keyless = try Keyless.start(std.testing.allocator);
    defer keyless.deinit();

    const metadata = try keyless.client.oauth().metadata(.{});
    defer metadata.deinit();

    try std.testing.expectEqualStrings(staging.upstream, metadata.value.issuer);
    try std.testing.expect(metadata.value.device_authorization_endpoint != null);
    const methods = metadata.value.code_challenge_methods_supported orelse &.{};
    for (methods) |method| {
        if (std.mem.eql(u8, method, "S256")) {
            break;
        }
    } else return error.TestExpectedS256;
}

test "revoking a token that does not exist succeeds" {
    const keyless = try Keyless.start(std.testing.allocator);
    defer keyless.deinit();

    try keyless.client.oauth().revoke(client_id, "mo_rt_sdk-ci-not-a-token", .{});
}

test "an unknown device code is an expired token" {
    const keyless = try Keyless.start(std.testing.allocator);
    defer keyless.deinit();

    var diagnostics: internetdata.Diagnostics = .{};
    const outcome = keyless.client.oauth().exchangeDeviceCode(client_id, "mo_dc_sdk-ci-not-a-code", .{
        .diagnostics = &diagnostics,
    });
    if (outcome) |token| {
        token.deinit();
    } else |_| {}
    try std.testing.expectError(error.OauthExpiredToken, outcome);
    try std.testing.expectEqual(@as(?u16, 400), diagnostics.status);
}

// The one device authorization this run spends. `slow_down` passes too: it is
// the limiter answering for every SDK that ran from this address this minute.
test "a device authorization starts or is throttled" {
    const keyless = try Keyless.start(std.testing.allocator);
    defer keyless.deinit();

    var diagnostics: internetdata.Diagnostics = .{};
    if (keyless.client.oauth().deviceAuthorization(client_id, .{
        .scope = "account.read",
        .diagnostics = &diagnostics,
    })) |device| {
        defer device.deinit();
        try std.testing.expect(device.value.device_code.len > 0 and device.value.user_code.len > 0);
        // The console's, not the apex's: the API is served at the apex here, so a
        // page taken from the API host would be the landing page's, which a
        // `/device` suffix alone still passes.
        try std.testing.expectEqualStrings(staging_console ++ "/device", device.value.verification_uri);
        try std.testing.expect(device.value.expires_in > 0 and device.value.interval > 0);
    } else |err| {
        try std.testing.expectEqual(error.OauthRejected, err);
        try std.testing.expectEqualStrings("slow_down", diagnostics.errorCode().?);
    }
}

/// A client straight at staging with no key and no proxy in front: nothing here
/// needs the wire recorded.
const Keyless = struct {
    threaded: std.Io.Threaded,
    client: internetdata.Client,

    fn start(gpa: std.mem.Allocator) !*Keyless {
        const self = try gpa.create(Keyless);
        errdefer gpa.destroy(self);
        self.threaded = .init(gpa, .{ .async_limit = .limited(32) });
        errdefer self.threaded.deinit();
        self.client = try internetdata.Client.init(gpa, self.threaded.io(), .{
            .base_url = staging.upstream,
        });
        return self;
    }

    fn deinit(self: *Keyless) void {
        const gpa = self.client.gpa;
        self.client.deinit();
        self.threaded.deinit();
        gpa.destroy(self);
    }
};
