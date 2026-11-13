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
    isBogon: []const BogonCase,
    ipv4Mapped: []const MappedCase,
    bogonResponse: BogonResponse,
    lookup: []const LookupCase,
    batch: []const BatchCase,
    bogons: Bogons,
    errors: []const ErrorCase,
    /// The closed sets the API documents. They are pinned as DATA rather than
    /// modelled as Zig enums: an unknown tag fails the whole response to parse,
    /// so a value added after this release would break every older client.
    standings: []const []const u8,
    license_type: []const []const u8,
    formats: []const []const u8,
    visibility: Visibility,
    oauth: Oauth,

    pub fn batchCase(self: Corpus, name: []const u8) BatchCase {
        for (self.batch) |case| {
            if (std.mem.eql(u8, case.name, name)) {
                return case;
            }
        }
        std.debug.panic("the corpus has no batch case named {s}", .{name});
    }
};

pub const BogonCase = struct {
    ip: []const u8,
    expect: bool,
    why: []const u8,
};

pub const MappedCase = struct {
    ip: []const u8,
    carries: []const u8,
    expect: bool,
    why: []const u8,
};

/// What a bogon is answered with: `answer`, with the address filled in.
pub const BogonResponse = struct {
    why: []const u8,
    flagsFalse: []const []const u8,
    emptyObjects: []const []const u8,
    emptyLists: []const []const u8,
    answer: std.json.Value,
};

/// One served answer: `call` is `lookup`, `lookupAsn` or `lookupDomain`, and
/// `target` the address, AS number or domain it is asked about.
pub const LookupCase = struct {
    name: []const u8,
    why: ?[]const u8 = null,
    call: []const u8,
    target: std.json.Value,
    status: u16,
    body: std.json.Value,
    expect: LookupExpect,
};

/// `objects` are present, as an object or a list, `empty` present and empty,
/// `absent` null, and `absentIn` names the members absent inside an object
/// that is itself present.
pub const LookupExpect = struct {
    present: std.json.ArrayHashMap(std.json.Value) = .{},
    objects: []const []const u8 = &.{},
    empty: []const []const u8 = &.{},
    absent: []const []const u8 = &.{},
    absentIn: std.json.ArrayHashMap([]const []const u8) = .{},
};

pub const BatchCase = struct {
    name: []const u8,
    why: ?[]const u8 = null,
    input: []const []const u8,
    repeat: ?u32 = null,
    expect: BatchExpect,
};

pub const BatchExpect = struct {
    keys: []const []const u8 = &.{},
    httpRequests: ?usize = null,
    bogonKeys: []const []const u8 = &.{},
    errorKeys: []const []const u8 = &.{},
    keyCount: ?usize = null,
    /// Address to the corpus's spelling of an error kind, as a JSON object.
    errorKinds: ?std.json.Value = null,
};

pub const Bogons = struct {
    v4: []const []const u8,
    v6: []const []const u8,
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

/// The `oauth` section. `deferred` holds the authorization code flow's
/// vectors, whose form and retry cases join the main ones' loops.
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
    deferred: struct {
        pkce: struct {
            verifier: []const u8,
            challenge: []const u8,
            method: []const u8,
            generatedVerifierPattern: []const u8,
        },
        authorizationUrl: []const AuthorizationUrlCase,
        forms: []const FormCase,
        retries: []const RetryCase,
    },
    register: struct {
        endpoint: Endpoint,
        contentType: []const u8,
        bodies: struct { cases: []const struct { name: []const u8, args: RegisterArgs, body: std.json.Value } },
        refusals: struct { cases: []const struct { name: []const u8, args: RegisterArgs } },
        responses: struct { cases: []const ResponseCase },
        unreadable: struct { cases: []const Served },
        retries: []const struct { name: []const u8, args: RegisterArgs, responses: []const Served, expect: OauthExpect },
        errors: []const OauthErrorCase,
    },
};

pub const RegisterArgs = struct {
    redirectUris: []const []const u8,
    clientName: ?[]const u8 = null,
};

pub const AuthorizationUrlCase = struct {
    name: []const u8,
    baseUrl: []const u8,
    clientId: []const u8,
    redirectUri: []const u8,
    codeChallenge: []const u8,
    scope: ?[]const u8 = null,
    state: ?[]const u8 = null,
    resource: ?[]const u8 = null,
    expect: []const u8,
};

pub const Endpoint = struct { method: []const u8, path: []const u8 };

pub const OauthArgs = struct {
    clientId: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    resource: ?[]const u8 = null,
    deviceCode: ?[]const u8 = null,
    refreshToken: ?[]const u8 = null,
    token: ?[]const u8 = null,
    code: ?[]const u8 = null,
    codeVerifier: ?[]const u8 = null,
    redirectUri: ?[]const u8 = null,
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

/// What one member of an answer is, in the terms the corpus asserts: absent
/// (not in your plan), a flag, a detail object or list that is empty or
/// populated, or any other value.
pub const Member = union(enum) {
    unknown,
    absent,
    flag: bool,
    empty_object,
    populated_object,
    empty_list,
    populated_list,
    scalar,
};

/// The member of `value`, a struct, whose wire name is `name`.
pub fn member(value: anytype, name: []const u8) Member {
    const T = @TypeOf(value);
    inline for (comptime std.meta.fieldNames(T)) |field_name| {
        if (std.mem.eql(u8, field_name, name)) {
            return stateOf(@FieldType(T, field_name), @field(value, field_name));
        }
    }
    return .unknown;
}

fn stateOf(comptime T: type, value: T) Member {
    return switch (@typeInfo(T)) {
        .bool => .{ .flag = value },
        .optional => |optional| if (value) |inner| stateOf(optional.child, inner) else .absent,
        .@"struct" => if (comptime @hasField(T, "map"))
            (if (value.map.count() == 0) .empty_object else .populated_object)
        else if (allNull(value)) .empty_object else .populated_object,
        .pointer => |pointer| if (pointer.child == u8)
            .scalar
        else if (value.len == 0) .empty_list else .populated_list,
        .int, .float => .scalar,
        else => .unknown,
    };
}

fn allNull(value: anytype) bool {
    inline for (comptime std.meta.fieldNames(@TypeOf(value))) |field_name| {
        const field = @field(value, field_name);
        // A required member, as the location's country is, is always there.
        if (comptime @typeInfo(@TypeOf(field)) != .optional) {
            return false;
        } else if (field != null) {
            return false;
        }
    }
    return true;
}

/// Fails unless the member of `value` named `name` is present and equal to
/// `want`, a JSON scalar.
pub fn expectPresent(value: anytype, name: []const u8, want: std.json.Value) !void {
    const T = @TypeOf(value);
    inline for (comptime std.meta.fieldNames(T)) |field_name| {
        if (std.mem.eql(u8, field_name, name)) {
            return expectScalar(@FieldType(T, field_name), @field(value, field_name), want);
        }
    }
    std.debug.print("{s} is not a member the client models\n", .{name});
    return error.TestExpectedEqual;
}

fn expectScalar(comptime T: type, got: T, want: std.json.Value) !void {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            const inner = got orelse {
                std.debug.print("absent, expected {f}\n", .{std.json.fmt(want, .{})});
                return error.TestExpectedEqual;
            };
            return expectScalar(optional.child, inner, want);
        },
        .bool => return std.testing.expectEqual(want.bool, got),
        .int => return std.testing.expectEqual(want.integer, got),
        .float => return std.testing.expectEqual(switch (want) {
            .integer => |number| @as(f64, @floatFromInt(number)),
            else => want.float,
        }, got),
        else => {
            if (comptime T == []const u8) {
                return std.testing.expectEqualStrings(want.string, got);
            }
            std.debug.print("expected a scalar, found a {s}\n", .{@typeName(T)});
            return error.TestExpectedEqual;
        },
    }
}

/// Fails unless every member `names` lists is absent inside the member of
/// `value` called `object`, which must itself be present.
pub fn expectAbsentIn(value: anytype, object: []const u8, names: []const []const u8) !void {
    const T = @TypeOf(value);
    inline for (comptime std.meta.fieldNames(T)) |field_name| {
        const Field = @FieldType(T, field_name);
        const Inner = switch (@typeInfo(Field)) {
            .optional => |optional| optional.child,
            else => Field,
        };
        if (comptime @typeInfo(Inner) == .@"struct") {
            if (std.mem.eql(u8, field_name, object)) {
                const inner: Inner = if (comptime Inner == Field) @field(value, field_name) else @field(value, field_name) orelse {
                    std.debug.print("{s} is absent, so nothing inside it can be asserted\n", .{object});
                    return error.TestExpectedEqual;
                };
                for (names) |name| {
                    std.testing.expectEqual(Member.absent, member(inner, name)) catch |err| {
                        std.debug.print("{s}.{s} must be ABSENT\n", .{ object, name });
                        return err;
                    };
                }
                return;
            }
        }
    }
    std.debug.print("{s} is not an object the client models\n", .{object});
    return error.TestExpectedEqual;
}

/// Whether two JSON values say the same thing: objects by key whatever the
/// order, and a whole number the same written as an integer or a float.
pub fn sameJson(a: std.json.Value, b: std.json.Value) bool {
    switch (a) {
        .null => return b == .null,
        .bool => |value| return b == .bool and b.bool == value,
        .integer, .float => {
            const left: f64 = if (a == .integer) @floatFromInt(a.integer) else a.float;
            const right: f64 = switch (b) {
                .integer => |number| @floatFromInt(number),
                .float => |number| number,
                else => return false,
            };
            return left == right;
        },
        .number_string => |text| return b == .number_string and std.mem.eql(u8, text, b.number_string),
        .string => |text| return b == .string and std.mem.eql(u8, text, b.string),
        .array => |items| {
            if (b != .array or b.array.items.len != items.items.len) return false;
            for (items.items, b.array.items) |left, right| {
                if (!sameJson(left, right)) return false;
            }
            return true;
        },
        .object => |object| {
            if (b != .object or b.object.count() != object.count()) return false;
            var it = object.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse return false;
                if (!sameJson(entry.value_ptr.*, other)) return false;
            }
            return true;
        },
    }
}
