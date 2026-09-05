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

    var client = try internetdata.Client.init(gpa, threaded.io(), .{ .api_key = key });
    defer client.deinit();

    const catalog = try client.database().list(.{});
    defer catalog.deinit();

    for (catalog.value) |entry| {
        std.debug.print("{s} ({s})\n", .{ entry.base, entry.standing });
    }

    const family = catalog.value[0];
    _ = family.base;
    _ = family.standing;
    _ = family.redistribution;
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

    const digests = try client.database().checksums(id, .csvgz, .{});
    defer digests.deinit();
    std.debug.print("{s}\n", .{digests.value.sha256});

    const history = try client.database().downloads(20, .{});
    defer history.deinit();
    for (history.value) |attempt| {
        std.debug.print("{s} {s} {s}\n", .{ attempt.created, attempt.dataset_id, attempt.outcome });
    }

    var diagnostics: internetdata.Diagnostics = .{};
    const again = client.database().list(.{ .diagnostics = &diagnostics }) catch |err| {
        std.debug.print("{s} retryable={} status={?} {s}\n", .{
            internetdata.kindName(err),
            internetdata.isRetryable(err),
            diagnostics.status,
            diagnostics.message(),
        });
        return err;
    };
    defer again.deinit();

    const retried = try client.database().list(.{ .retries = 4 });
    defer retried.deinit();
}
