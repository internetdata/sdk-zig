//! JSON decoding that refuses a numeric string where a number is due.
//!
//! `std.json` reads `"600"` into an integer member as 600, from a token stream
//! and from a `Value` alike, and no `ParseOptions` field turns that off. The
//! other SDKs refuse it as a member of the wrong type, so an answer is parsed
//! into a `Value` first, every numeric member is checked against `T` with a
//! comptime walk, and only then is `T` built from that `Value`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// `T` from `body`, or `error.WrongType` when a member `T` declares a number
/// holds a JSON string, at any depth. Any other way `body` fails to be a `T`
/// is the error `std.json` gives for it.
pub fn parseLeaky(comptime T: type, arena: Allocator, body: []const u8, options: std.json.ParseOptions) !T {
    const value = try std.json.parseFromSliceLeaky(Value, arena, body, .{});
    if (!conforms(T, value)) return error.WrongType;
    return std.json.parseFromValueLeaky(T, arena, value, options);
}

/// Whether no member `T` declares a number holds a string. Every other
/// mismatch is left to `std.json`, which refuses it.
fn conforms(comptime T: type, value: Value) bool {
    switch (@typeInfo(T)) {
        .int, .float => return value != .string,
        .optional => |optional| return value == .null or conforms(optional.child, value),
        .pointer => |pointer| {
            if (pointer.size != .slice or pointer.child == u8) return true;
            const array = switch (value) {
                .array => |array| array,
                else => return true,
            };
            for (array.items) |item| if (!conforms(pointer.child, item)) return false;
            return true;
        },
        .@"struct" => {
            const object = switch (value) {
                .object => |object| object,
                else => return true,
            };
            if (comptime isArrayHashMap(T)) {
                const Member = MapValue(T);
                for (object.values()) |member| if (!conforms(Member, member)) return false;
                return true;
            }
            if (comptime std.meta.hasFn(T, "jsonParseFromValue")) return true;
            // Field names and `@FieldType` read alike on Zig 0.16 and 0.17, which
            // reshaped `Type.Struct`.
            inline for (comptime std.meta.fieldNames(T)) |name| {
                if (object.get(name)) |member| {
                    if (!conforms(@FieldType(T, name), member)) return false;
                }
            }
            return true;
        },
        else => return true,
    }
}

/// A `std.json.ArrayHashMap(V)`: its own `jsonParseFromValue` reads each
/// member as a `V`, which this walk still has to look inside.
fn isArrayHashMap(comptime T: type) bool {
    return @hasField(T, "map") and std.meta.hasFn(T, "jsonParseFromValue") and
        T == std.json.ArrayHashMap(MapValue(T));
}

fn MapValue(comptime T: type) type {
    const get = @typeInfo(@TypeOf(@FieldType(T, "map").get)).@"fn";
    return @typeInfo(get.return_type.?).optional.child;
}

test "a numeric string where a number is due is refused at any depth" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Inner = struct { version: i64, label: []const u8 };
    const Outer = struct {
        entries: ?i64 = null,
        items: []const Inner = &.{},
        size: std.json.ArrayHashMap(i64) = .{},
        sample: std.json.ArrayHashMap([]const Value) = .{},
    };
    const a = arena.allocator();
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    try std.testing.expectError(error.WrongType, parseLeaky(Outer, a, "{\"entries\":\"42\"}", options));
    try std.testing.expectError(error.WrongType, parseLeaky(Outer, a, "{\"items\":[{\"version\":\"3\",\"label\":\"x\"}]}", options));
    try std.testing.expectError(error.WrongType, parseLeaky(Outer, a, "{\"size\":{\"csvgz\":\"760\"}}", options));
    const got = try parseLeaky(Outer, a, "{\"entries\":42,\"items\":[{\"version\":3,\"label\":\"7\"}],\"size\":{\"csvgz\":760},\"sample\":{\"csvgz\":[{\"n\":\"1\"}]},\"x\":\"y\"}", options);
    try std.testing.expectEqual(@as(?i64, 42), got.entries);
    try std.testing.expectEqual(@as(i64, 3), got.items[0].version);
    try std.testing.expectEqual(@as(i64, 760), got.size.map.get("csvgz").?);
    try std.testing.expectEqual(@as(?i64, null), (try parseLeaky(Outer, a, "{\"entries\":null}", options)).entries);
}
