const std = @import("std");

const database_mod = @import("database.zig");
const errors = @import("errors.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = errors.Diagnostics;
const Io = std.Io;

/// The production API. Override it with `Options.base_url`.
pub const default_base_url = "https://internetdata.io";

pub const Options = struct {
    /// A key from the console carrying the `db.download` scope. It has no
    /// default because there is no anonymous tier to fall back on: every
    /// endpoint here is behind a licence, so a client without a key can do
    /// nothing at all and omitting it should not compile.
    api_key: []const u8,
    base_url: []const u8 = default_base_url,
    /// Further attempts a transient failure gets.
    retries: u32 = 2,
};

/// Per-call overrides for one request. Anything left null falls back to the
/// client's setting.
pub const CallOptions = struct {
    retries: ?u32 = null,
    /// Filled in with the status, the wait and the API's own result code when
    /// the call fails. A Zig error carries no payload, so this is how the detail
    /// behind one is reached.
    diagnostics: ?*Diagnostics = null,
};

/// A client for the InternetData API: licensed IP and network databases,
/// downloaded as CSV.GZ or MMDB.
///
/// Everything it returns is allocated with the allocator passed to `init` and is
/// owned by the caller: the catalog calls return a `std.json.Parsed` that owns
/// its arena, and `downloadUrl` and `downloadBytes` return slices to free.
///
/// Safe to share between concurrent tasks. Do NOT copy it after `init`: like
/// `std.http.Client`, it holds intrusive lists that point at themselves.
///
/// **Nothing it answers is cached.** What your organization may see depends on
/// the key, so a listing held from one client is not an answer for another, and
/// the catalog is small enough that re-reading it costs less than being wrong
/// about whose it was.
pub const Client = struct {
    gpa: Allocator,
    io: Io,
    transport: http.Transport,
    retries: u32,

    pub const InitError = Allocator.Error || error{ InvalidBaseUrl, MissingApiKey };

    /// `io` is the same `std.Io` implementation the rest of your program uses;
    /// `std.Io.Threaded` is the usual one.
    pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Client {
        const api_key = std.mem.trim(u8, options.api_key, " \t\r\n");
        if (api_key.len == 0) {
            return error.MissingApiKey;
        }

        const base_url = std.mem.trimEnd(u8, options.base_url, "/");
        const uri = std.Uri.parse(base_url) catch return error.InvalidBaseUrl;
        if (uri.host == null) {
            return error.InvalidBaseUrl;
        }

        const owned_base_url = try gpa.dupe(u8, base_url);
        errdefer gpa.free(owned_base_url);

        // Bearer only. A v1 `?apikey=` credential is a different vocabulary the
        // v2 endpoints do not accept, and a key belongs in a header rather than
        // in a query string a proxy will log.
        const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key});

        return .{
            .gpa = gpa,
            .io = io,
            .transport = .{
                .http = .{ .allocator = gpa, .io = io },
                .base_url = owned_base_url,
                .authorization = authorization,
            },
            .retries = options.retries,
        };
    }

    pub fn deinit(self: *Client) void {
        self.transport.deinit();
        self.gpa.free(self.transport.base_url);
        self.gpa.free(self.transport.authorization);
        self.* = undefined;
    }

    /// The licensed database downloads, which is every call this API has.
    ///
    /// A namespace over one domain rather than several, kept because the
    /// sibling VPNDetection client spells the same seven calls the same way.
    pub fn database(self: *Client) database_mod.Database {
        return .{ .client = self };
    }
};

test "a client without a key does not build" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    try std.testing.expectError(error.MissingApiKey, Client.init(gpa, threaded.io(), .{ .api_key = "" }));
    try std.testing.expectError(error.MissingApiKey, Client.init(gpa, threaded.io(), .{ .api_key = "  " }));
}
