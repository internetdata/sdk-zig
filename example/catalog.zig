//! The library's smallest useful program, and the one the README opens with.
//!
//!     zig build example
//!     ./zig-out/bin/catalog <api-key>

const std = @import("std");
const internetdata = @import("internetdata");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: catalog <api-key>\n", .{});
        return error.MissingApiKey;
    }

    var client = try internetdata.Client.init(init.gpa, init.io, .{ .api_key = args[1] });
    defer client.deinit();

    const catalog = try client.database().list(.{});
    defer catalog.deinit();

    for (catalog.value) |family| {
        std.debug.print("{s} ({s}): {s}\n", .{ family.base, family.standing, family.name });
        for (family.versions) |version| {
            std.debug.print("  {s}\n", .{version.id});
        }
    }
}
