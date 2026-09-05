const std = @import("std");

const database = @import("database.zig");
const errors = @import("errors.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;
const CallError = errors.CallError;
const Diagnostics = errors.Diagnostics;
const Format = database.Format;
const Io = std.Io;
const Param = http.Transport.Param;
const Parsed = std.json.Parsed;

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

    /// The published catalog, with your organization's licence beside each
    /// family. The caller owns the result and must `deinit` it.
    ///
    /// A licence covers a family, so the id you pass to a download is one of
    /// `DatabaseFamily.versions`, not `DatabaseFamily.base`.
    ///
    /// **This is the SERVER's answer about YOUR key, and nothing else assembles
    /// it.** A database commissioned for a single customer is ABSENT for every
    /// other organization rather than listed with an `unlicensed` standing, so
    /// what you get back is not necessarily what another key gets back, and
    /// neither the catalog nor any part of it can be reconstructed elsewhere.
    pub fn list(self: *Client, options: CallOptions) CallError!Parsed([]const database.DatabaseFamily) {
        const answer = try self.fetch(database.DatabaseList, "/api/v2/database/list", &.{}, options);
        return .{ .arena = answer.arena, .value = answer.value.databases };
    }

    /// What is inside one database: its columns per format, sample rows, the row
    /// count and the byte size of each file.
    ///
    /// It carries `updated` and `entries` without downloading anything, so poll
    /// it to decide whether today's build is worth fetching, and read `size` to
    /// budget a transfer before starting one.
    ///
    /// One document describes every format the database is built in, which is
    /// why there is no format argument.
    pub fn metadata(
        self: *Client,
        id: []const u8,
        options: CallOptions,
    ) CallError!Parsed(database.DatabaseMetadata) {
        const query = [_]Param{.{ .name = "id", .value = id }};
        return self.fetch(database.DatabaseMetadata, "/api/v2/database/metadata", &query, options);
    }

    /// The digests of one published file, for verifying a download.
    ///
    /// The whole set is returned rather than one algorithm, because which
    /// digests a caller wants is not this library's decision. They nest under
    /// `checksums` in the response, and reading a top-level `sha256` is how the
    /// Node SDK shipped this broken in 1.0.x.
    pub fn checksums(
        self: *Client,
        id: []const u8,
        format: Format,
        options: CallOptions,
    ) CallError!Parsed(database.Checksums) {
        const query = [_]Param{
            .{ .name = "id", .value = id },
            .{ .name = "format", .value = format.toString() },
        };
        const answer = try self.fetch(
            database.ChecksumResponse,
            "/api/v2/database/checksum",
            &query,
            options,
        );
        return .{ .arena = answer.arena, .value = answer.value.checksums };
    }

    /// Your organization's recent download attempts, newest first. Null takes
    /// the API's own default of 50, and it is clamped to 200.
    pub fn downloads(
        self: *Client,
        limit: ?u32,
        options: CallOptions,
    ) CallError!Parsed([]const database.DownloadAttempt) {
        var buffer: [16]u8 = undefined;
        var query: [1]Param = undefined;
        var count: usize = 0;
        if (limit) |n| {
            const text = std.fmt.bufPrint(&buffer, "{d}", .{n}) catch unreachable;
            query[0] = .{ .name = "limit", .value = text };
            count = 1;
        }
        const answer = try self.fetch(
            database.DownloadList,
            "/api/v2/database/downloads",
            query[0..count],
            options,
        );
        return .{ .arena = answer.arena, .value = answer.value.downloads };
    }

    /// The time-limited URL for one database file, owned by the caller.
    ///
    /// The API answers 302 to object storage and the redirect is NOT followed:
    /// the URL is returned so a caller can decide how to move a file that runs
    /// to gigabytes, hand it to a downloader, or pass it on WITHOUT passing on
    /// the API key. The link is presigned and so authorizes itself; it
    /// authorizes the START of a transfer, so one already running is not
    /// interrupted when it lapses.
    pub fn downloadUrl(
        self: *Client,
        id: []const u8,
        format: Format,
        options: CallOptions,
    ) CallError![]u8 {
        const query = [_]Param{
            .{ .name = "id", .value = id },
            .{ .name = "format", .value = format.toString() },
        };
        var scratch: Diagnostics = .{};
        return http.send(&self.transport, self.gpa, self.io, .{
            .kind = .location,
            .path = "/api/v2/database/download",
            .query = &query,
            .retries = options.retries orelse self.retries,
            .diagnostics = options.diagnostics orelse &scratch,
        });
    }

    /// Writes one database file to `path`, returning the bytes written.
    ///
    /// Nothing beyond a single chunk is ever held in memory, whatever the file
    /// weighs, so this is the call to reach for by default.
    ///
    /// The bytes land in a neighbouring `<path>.part` that is renamed on
    /// completion, and a transfer that stops short of the length the origin
    /// declared is an error rather than a short file. Nothing partial survives a
    /// failure, so a `path` that exists is a whole database and a failed refresh
    /// cannot destroy the copy already there.
    ///
    /// The redirect is followed, and that second request carries NO API key: the
    /// link authorizes itself, and object storage is a third party.
    ///
    /// `retries` applies to reaching the API for the link, not to the transfer:
    /// resuming a half-moved gigabyte is a different problem from asking again.
    pub fn download(
        self: *Client,
        id: []const u8,
        format: Format,
        path: []const u8,
        options: CallOptions,
    ) database.DownloadError!u64 {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const gpa = self.gpa;
        const io = self.io;

        var transfer: http.Transfer = undefined;
        try self.begin(&transfer, options, id, format, diag);
        defer transfer.deinit();

        const partial = try std.fmt.allocPrint(gpa, "{s}.part", .{path});
        defer gpa.free(partial);
        const buffer = try gpa.alloc(u8, 64 * 1024);
        defer gpa.free(buffer);

        const cwd: std.Io.Dir = .cwd();
        var file = try cwd.createFile(io, partial, .{});
        // Every way out of here but the last one removes the partial file, so a
        // failed transfer cannot leave behind something that reads as a database.
        errdefer cwd.deleteFile(io, partial) catch {};

        const written = written: {
            // Closed before the rename rather than at the end of the function:
            // renaming a file that is still open fails outright on Windows.
            defer file.close(io);
            var sink = file.writer(io, buffer);
            const moved = transfer.reader().streamRemaining(&sink.interface) catch |err| switch (err) {
                error.ReadFailed => return transfer.readFailure(diag),
                error.WriteFailed => return sink.err orelse error.WriteFailed,
            };
            sink.interface.flush() catch return sink.err orelse error.WriteFailed;
            break :written moved;
        };
        try transfer.verify(written, diag);

        try cwd.rename(partial, cwd, path, io);
        return written;
    }

    /// Downloads one database file and hands back its bytes, allocated with the
    /// allocator you gave `init` and owned by you.
    ///
    /// **This holds the ENTIRE file in memory.** The catalog spans seven orders
    /// of magnitude, from `bogon_asn_v1` at a few hundred bytes to the largest
    /// IP feeds at several gigabytes, so reach for this at the small end and use
    /// `download` for anything you have not measured. `metadata` publishes the
    /// size per format without transferring anything, which is how you find out
    /// which end you are at.
    ///
    /// Byte for byte the same file `download` writes, and short of the declared
    /// length is the same error here as there.
    pub fn downloadBytes(
        self: *Client,
        id: []const u8,
        format: Format,
        options: CallOptions,
    ) CallError![]u8 {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const gpa = self.gpa;

        var transfer: http.Transfer = undefined;
        try self.begin(&transfer, options, id, format, diag);
        defer transfer.deinit();

        const reader = transfer.reader();
        // Sized once from the declared length where there is one: an allocator
        // that grows by doubling spends twice the file on its final grow, which
        // at the large end of the catalog is gigabytes of nothing.
        const declared = transfer.declared orelse
            return reader.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ReadFailed => transfer.readFailure(diag),
                error.StreamTooLong => unreachable, // .unlimited has no limit to exceed
            };
        const bytes = try gpa.alloc(u8, std.math.cast(usize, declared) orelse return error.OutOfMemory);
        errdefer gpa.free(bytes);
        // Short rather than all, so a transfer that stops early is reported with
        // the two lengths rather than as a bare end-of-stream.
        const received = reader.readSliceShort(bytes) catch |err| switch (err) {
            error.ReadFailed => return transfer.readFailure(diag),
        };
        try transfer.verify(received, diag);
        return bytes;
    }

    /// Asks the API for the presigned link and opens it.
    fn begin(
        self: *Client,
        transfer: *http.Transfer,
        options: CallOptions,
        id: []const u8,
        format: Format,
        diag: *Diagnostics,
    ) CallError!void {
        const url = try self.downloadUrl(id, format, .{
            .retries = options.retries,
            .diagnostics = diag,
        });
        defer self.gpa.free(url);
        return transfer.begin(&self.transport, self.gpa, url, diag);
    }

    fn fetch(
        self: *Client,
        comptime T: type,
        path: []const u8,
        query: []const Param,
        options: CallOptions,
    ) CallError!Parsed(T) {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const gpa = self.gpa;

        const body = try http.send(&self.transport, gpa, self.io, .{
            .path = path,
            .query = query,
            .retries = options.retries orelse self.retries,
            .diagnostics = diag,
        });
        defer gpa.free(body);

        const parsed = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(parsed);
        parsed.* = .init(gpa);
        errdefer parsed.deinit();

        const arena = parsed.allocator();
        // Parsed from a copy the arena owns, so every string in the answer
        // outlives the body this call frees.
        const owned = try arena.dupe(u8, body);
        const value = std.json.parseFromSliceLeaky(T, arena, owned, .{
            // A field this release has no home for is DROPPED rather than
            // fatal, so the API may grow without breaking a client built today.
            .ignore_unknown_fields = true,
        }) catch {
            diag.setMessage("the answer did not match the documented shape");
            return error.ServerError;
        };
        return .{ .arena = parsed, .value = value };
    }
};

test "a client without a key does not build" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    try std.testing.expectError(error.MissingApiKey, Client.init(gpa, threaded.io(), .{ .api_key = "" }));
    try std.testing.expectError(error.MissingApiKey, Client.init(gpa, threaded.io(), .{ .api_key = "  " }));
}
