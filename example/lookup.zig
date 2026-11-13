//! The library's smallest useful program, and the one the README opens with.
//!
//!     zig build example
//!     ./zig-out/bin/lookup 146.70.116.130

const std = @import("std");
const internetdata = @import("internetdata");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const ip = if (args.len > 1) args[1] else "146.70.116.130";

    var client = try internetdata.Client.init(init.gpa, init.io, .{});
    defer client.deinit();

    const result = try client.lookup(ip);
    defer result.deinit();

    std.debug.print("{s}: {s}, {s}, is_vpn={}\n", .{
        result.value.ip,
        result.value.location.country,
        result.value.asn.name,
        result.value.is_vpn orelse false,
    });
}
