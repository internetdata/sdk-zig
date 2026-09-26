//! The shared conformance corpus, generated into testdata/ and
//! identical across every InternetData SDK. It is embedded rather than read at
//! run time so a missing or malformed one is a build failure.
//!
//! Field names here are the corpus's own, which is why some of them are
//! camelCase: they are matched against the JSON by name, and renaming one would
//! quietly stop asserting whatever it holds.

const std = @import("std");
const internetdata = @import("internetdata");

const Allocator = std.mem.Allocator;

const source = @embedFile("corpus");

pub const Corpus = struct {
    errors: []const ErrorCase,
    /// The closed sets the API documents. They are pinned as DATA rather than
    /// modelled as Zig enums: an unknown tag fails the whole response to parse,
    /// so a value added after this release would break every older client.
    standings: []const []const u8,
    license_type: []const []const u8,
    formats: []const []const u8,
    visibility: Visibility,
    oauth: Oauth,
};

pub const ErrorCase = struct {
    name: []const u8,
    why: ?[]const u8 = null,
    status: u16,
    headers: std.json.ArrayHashMap([]const u8) = .{},
    body: std.json.Value,
    expect: ErrorExpect,
};

pub const ErrorExpect = struct {
    kind: []const u8,
    retryable: bool,
    message: ?[]const u8 = null,
    retryAfterSeconds: ?u64 = null,
};

/// What a private database being ABSENT from a listing demands of a client.
/// Each rule is asserted by name in conformance.zig, and a rule this SDK does
/// not recognise fails rather than passing silently.
pub const Visibility = struct {
    why: []const u8,
    clientRules: []const []const u8,
};

/// The `oauth` section. `deferred` names operations this release does not ship,
/// so it is never declared here and the loader skips it with every other
/// unknown member.
pub const Oauth = struct {
    endpoints: struct {
        metadata: Endpoint,
        deviceAuthorization: Endpoint,
        token: Endpoint,
        revoke: Endpoint,
    },
    noCredential: struct {
        apiKey: []const u8,
        forbiddenHeaders: []const []const u8,
        forbiddenQuery: []const []const u8,
    },
    forms: struct {
        contentType: []const u8,
        cases: []const FormCase,
    },
    responses: struct {
        metadata: []const ResponseCase,
        deviceAuthorization: []const ResponseCase,
        token: []const ResponseCase,
        revoke: []const Served,
    },
    errors: struct { cases: []const OauthErrorCase },
    retries: struct { cases: []const RetryCase },
    poll: struct { cases: []const PollCase },
};

pub const Endpoint = struct { method: []const u8, path: []const u8 };

pub const OauthArgs = struct {
    clientId: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    resource: ?[]const u8 = null,
    deviceCode: ?[]const u8 = null,
    refreshToken: ?[]const u8 = null,
    token: ?[]const u8 = null,
};

pub const FormCase = struct {
    name: []const u8,
    operation: []const u8,
    endpoint: []const u8,
    args: OauthArgs,
    fields: std.json.ArrayHashMap([]const u8),
};

/// One canned response: `body` is served as JSON, `rawBody` verbatim.
pub const Served = struct {
    name: []const u8 = "",
    status: u16,
    body: ?std.json.Value = null,
    rawBody: ?[]const u8 = null,

    pub fn text(self: Served, arena: Allocator) ![]const u8 {
        if (self.rawBody) |raw| {
            return raw;
        }
        return if (self.body) |value| json(arena, value) else "";
    }
};

pub const ResponseCase = struct {
    name: []const u8,
    status: u16,
    body: std.json.Value,
    expect: struct {
        present: std.json.ArrayHashMap(std.json.Value),
        absent: []const []const u8,
    },
};

pub const OauthErrorCase = struct {
    name: []const u8,
    status: u16,
    body: ?std.json.Value = null,
    rawBody: ?[]const u8 = null,
    expect: OauthExpect,

    pub fn served(self: OauthErrorCase) Served {
        return .{ .name = self.name, .status = self.status, .body = self.body, .rawBody = self.rawBody };
    }
};

/// A member left out of the corpus is not asserted, which `unstated` stands
/// for: JSON null is a stated absence, so it cannot double as "not said".
pub const unstated: std.json.Value = .{ .bool = false };

pub const OauthExpect = struct {
    type: ?[]const u8 = null,
    outcome: ?[]const u8 = null,
    errorCode: ?[]const u8 = null,
    errorDescription: std.json.Value = unstated,
    status: std.json.Value = unstated,
    kind: ?[]const u8 = null,
    retryable: ?bool = null,
    requests: ?usize = null,
    waits: []const i64 = &.{},
    token: ?std.json.ArrayHashMap(std.json.Value) = null,
};

pub const RetryCase = struct {
    name: []const u8,
    operation: []const u8,
    args: OauthArgs,
    responses: []const Served,
    expect: OauthExpect,
};

pub const PollCase = struct {
    name: []const u8,
    clientId: []const u8,
    device: internetdata.DeviceAuthorization,
    responses: []const Served,
    expect: OauthExpect,
};

/// The caller owns the arena, and every slice in the corpus lives in it.
///
/// Unknown fields are ignored, which is not optional: the corpus is shared by
/// every SDK and grows whenever any ONE of them needs a new case, so a strict
/// parse here turns another language's addition into a build failure in this
/// one. Zig is the only binding whose default is strict.
pub fn load(gpa: Allocator) !std.json.Parsed(Corpus) {
    return std.json.parseFromSlice(Corpus, gpa, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

/// A fixture body as the stub has to serve it.
pub fn json(arena: Allocator, value: std.json.Value) ![]const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})});
}
