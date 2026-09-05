//! The staging fixtures the suite shares: a client pointed through the recording
//! proxy, and the rules that hold whatever this key happens to be licensed for.

const std = @import("std");
const internetdata = @import("internetdata");

pub const proxy = @import("proxy.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Not the library's default, which is production. Reaching it through the
/// client's own base-URL option is what makes that option worth testing.
pub const upstream = "https://staging.internetdata.io";

/// The one credential this suite has. It belongs to an organization licensed for
/// the two smallest published databases, so every artifact it may download moves
/// in kilobytes.
///
/// Empty counts as absent: CI interpolates a secret that does not exist to an
/// empty string rather than leaving the variable unset, and a client built with
/// an empty key would present no credential at all.
pub const secret = "INTERNETDATA_STAGING_KEY";

pub fn key() []const u8 {
    const value = std.testing.environ.getPosix(secret) orelse return "";
    return std.mem.trim(u8, value, " \t\r\n");
}

/// Skips the calling test, naming the secret, rather than failing a run that was
/// never given the credential.
pub fn require() !void {
    if (key().len == 0) {
        std.debug.print("SKIP: {s} is not set, so staging cannot be reached\n", .{secret});
        return error.SkipZigTest;
    }
}

/// A client, the proxy in front of it, and the `Io` both run on.
///
/// Do not copy one after `start`: the client holds intrusive lists, and the base
/// URL is a slice of the buffer below.
pub const Rung = struct {
    gpa: Allocator,
    threaded: Io.Threaded,
    proxy: *proxy.Proxy,
    client: internetdata.Client,
    url_buffer: [64]u8 = undefined,

    /// The thread budget is pinned rather than left to the CPU count: the proxy
    /// forwards from inside a task of its own, so a one-core runner with no
    /// async budget would deadlock the first request.
    pub fn start(gpa: Allocator) !*Rung {
        const self = try gpa.create(Rung);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .threaded = .init(gpa, .{ .async_limit = .limited(32) }),
            .proxy = undefined,
            .client = undefined,
        };
        const io = self.threaded.io();
        self.proxy = try proxy.Proxy.start(gpa, io, upstream, key());
        errdefer self.proxy.deinit();

        self.client = try internetdata.Client.init(gpa, io, .{
            .api_key = key(),
            .base_url = self.proxy.baseUrl(&self.url_buffer),
        });
        return self;
    }

    pub fn deinit(self: *Rung) void {
        self.client.deinit();
        self.proxy.deinit();
        self.threaded.deinit();
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    /// Fails unless the credential was actually on the wire.
    ///
    /// An unsent key answers 401, which every "this was refused" assertion would
    /// satisfy vacuously, so this is checked BEFORE anything is compared.
    pub fn assertKeyReachedTheWire(self: *Rung) !void {
        if (!self.proxy.carriedKey()) {
            std.debug.print("the staging key never reached the wire\n", .{});
            return error.TestUnexpectedResult;
        }
    }
};

pub fn expectOneOf(comptime what: []const u8, value: []const u8, allowed: []const []const u8) !void {
    for (allowed) |candidate| {
        if (std.mem.eql(u8, candidate, value)) {
            return;
        }
    }
    std.debug.print("{s} is \"{s}\", which the spec does not document\n", .{ what, value });
    return error.TestExpectedEqual;
}

/// A scratch directory, because `download` takes a PATH rather than a directory
/// handle. Do not copy one after `start`: `path` hands back a slice of its own
/// buffer.
pub const Scratch = struct {
    tmp: std.testing.TmpDir,
    buffer: [128]u8 = undefined,

    pub fn start() Scratch {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    pub fn deinit(self: *Scratch) void {
        self.tmp.cleanup();
    }

    /// `std.testing` puts its temporary directories under `.zig-cache/tmp` and
    /// hands back a handle rather than a path, so the path is spelled the same
    /// way it builds it.
    pub fn path(self: *Scratch, name: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.buffer, ".zig-cache/tmp/{s}/{s}", .{
            &self.tmp.sub_path,
            name,
        }) catch unreachable;
    }

    pub fn exists(self: *Scratch, name: []const u8) bool {
        self.tmp.dir.access(std.testing.io, name, .{}) catch return false;
        return true;
    }

    pub fn read(self: *Scratch, name: []const u8, buffer: []u8) ![]u8 {
        return self.tmp.dir.readFile(std.testing.io, name, buffer);
    }
};
