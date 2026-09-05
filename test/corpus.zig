//! The shared conformance corpus, generated into testdata/ by the monorepo and
//! identical across every InternetData SDK. It is embedded rather than read at
//! run time so a missing or malformed one is a build failure.
//!
//! Field names here are the corpus's own, which is why some of them are
//! camelCase: they are matched against the JSON by name, and renaming one would
//! quietly stop asserting whatever it holds.

const std = @import("std");

const Allocator = std.mem.Allocator;

const source = @embedFile("corpus");

pub const Corpus = struct {
    errors: []const ErrorCase,
    /// The closed sets the API documents. They are pinned as DATA rather than
    /// modelled as Zig enums: an unknown tag fails the whole response to parse,
    /// so a value added after this release would break every older client.
    standings: []const []const u8,
    redistribution: []const []const u8,
    formats: []const []const u8,
    visibility: Visibility,
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

/// The caller owns the arena, and every slice in the corpus lives in it.
pub fn load(gpa: Allocator) !std.json.Parsed(Corpus) {
    return std.json.parseFromSlice(Corpus, gpa, source, .{ .allocate = .alloc_always });
}

/// A fixture body as the stub has to serve it.
pub fn json(arena: Allocator, value: std.json.Value) ![]const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})});
}
