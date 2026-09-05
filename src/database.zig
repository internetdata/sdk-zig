const std = @import("std");

const client_mod = @import("client.zig");
const errors = @import("errors.zig");
const http = @import("http.zig");

const CallError = errors.CallError;
const Diagnostics = errors.Diagnostics;
const Param = http.Transport.Param;
const Parsed = std.json.Parsed;

/// A format a database is published in.
///
/// Not every database is built in every format: the `_provider` catalogs are
/// keyed by provider id rather than by IP range, so no MMDB exists for them, and
/// asking for one is a 400 rather than an empty answer.
/// `DatabaseVersion.formats` says which exist.
///
/// This is an enum because it is an INPUT, where a closed set makes a typo a
/// compile error. The same values arrive on responses as plain strings; see
/// `DatabaseVersion.formats`.
pub const Format = enum {
    csvgz,
    mmdb,

    pub fn toString(self: Format) []const u8 {
        return @tagName(self);
    }
};

/// Everything `download` can fail with.
///
/// The filesystem's errors are kept distinct from the API's rather than folded
/// into `error.Network`: a reset socket and a full disk are different problems,
/// and only one of them is ours to retry.
pub const DownloadError = errors.CallError ||
    std.Io.File.OpenError ||
    std.Io.File.Writer.Error ||
    std.Io.Writer.Error ||
    std.Io.Dir.RenameError ||
    std.Io.Dir.DeleteFileError;

/// The licensed database downloads: the whole of what this API serves.
///
/// Reached through `Client.database()`. It is a namespace over a single domain
/// rather than one of several, and it is here so that a codebase holding this
/// client and the VPNDetection one spells the same seven calls the same way in
/// both.
///
/// The catalog calls return a `std.json.Parsed` whose arena owns the whole
/// answer, so `deinit` is the entire cleanup; `downloadUrl` and `downloadBytes`
/// return slices allocated with the allocator you gave `Client.init` and owned
/// by you.
pub const Database = struct {
    client: *client_mod.Client,

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
    pub fn list(self: Database, options: client_mod.CallOptions) CallError!Parsed([]const DatabaseFamily) {
        const answer = try self.fetch(DatabaseList, "/api/v2/database/list", &.{}, options);
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
        self: Database,
        id: []const u8,
        options: client_mod.CallOptions,
    ) CallError!Parsed(DatabaseMetadata) {
        const query = [_]Param{.{ .name = "id", .value = id }};
        return self.fetch(DatabaseMetadata, "/api/v2/database/metadata", &query, options);
    }

    /// The digests of one published file, for verifying a download.
    ///
    /// The whole set is returned rather than one algorithm, because which
    /// digests a caller wants is not this library's decision. They nest under
    /// `checksums` in the response, and reading a top-level `sha256` is how the
    /// Node SDK shipped this broken in 1.0.x.
    pub fn checksums(
        self: Database,
        id: []const u8,
        format: Format,
        options: client_mod.CallOptions,
    ) CallError!Parsed(Checksums) {
        const query = [_]Param{
            .{ .name = "id", .value = id },
            .{ .name = "format", .value = format.toString() },
        };
        const answer = try self.fetch(
            ChecksumResponse,
            "/api/v2/database/checksum",
            &query,
            options,
        );
        return .{ .arena = answer.arena, .value = answer.value.checksums };
    }

    /// Your organization's recent download attempts, newest first. Null takes
    /// the API's own default of 50, and it is clamped to 200.
    pub fn downloads(
        self: Database,
        limit: ?u32,
        options: client_mod.CallOptions,
    ) CallError!Parsed([]const DownloadAttempt) {
        var buffer: [16]u8 = undefined;
        var query: [1]Param = undefined;
        var count: usize = 0;
        if (limit) |n| {
            const text = std.fmt.bufPrint(&buffer, "{d}", .{n}) catch unreachable;
            query[0] = .{ .name = "limit", .value = text };
            count = 1;
        }
        const answer = try self.fetch(
            DownloadList,
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
        self: Database,
        id: []const u8,
        format: Format,
        options: client_mod.CallOptions,
    ) CallError![]u8 {
        const query = [_]Param{
            .{ .name = "id", .value = id },
            .{ .name = "format", .value = format.toString() },
        };
        var scratch: Diagnostics = .{};
        return http.send(&self.client.transport, self.client.gpa, self.client.io, .{
            .kind = .location,
            .path = "/api/v2/database/download",
            .query = &query,
            .retries = options.retries orelse self.client.retries,
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
        self: Database,
        id: []const u8,
        format: Format,
        path: []const u8,
        options: client_mod.CallOptions,
    ) DownloadError!u64 {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const gpa = self.client.gpa;
        const io = self.client.io;

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
        // failed transfer cannot leave behind something that reads as a
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
        self: Database,
        id: []const u8,
        format: Format,
        options: client_mod.CallOptions,
    ) CallError![]u8 {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const gpa = self.client.gpa;

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
        self: Database,
        transfer: *http.Transfer,
        options: client_mod.CallOptions,
        id: []const u8,
        format: Format,
        diag: *Diagnostics,
    ) CallError!void {
        const url = try self.downloadUrl(id, format, .{
            .retries = options.retries,
            .diagnostics = diag,
        });
        defer self.client.gpa.free(url);
        return transfer.begin(&self.client.transport, self.client.gpa, url, diag);
    }

    fn fetch(
        self: Database,
        comptime T: type,
        path: []const u8,
        query: []const Param,
        options: client_mod.CallOptions,
    ) CallError!Parsed(T) {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const gpa = self.client.gpa;

        const body = try http.send(&self.client.transport, gpa, self.client.io, .{
            .path = path,
            .query = query,
            .retries = options.retries orelse self.client.retries,
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

/// Mirrors `components.schemas.Database` in spec/openapi.yaml, renamed only
/// because `Database` is the API surface `Client.database()` returns.
///
/// One database FAMILY, with your organization's licence beside it. A licence
/// covers the family, while a download names one version of it, so the ids
/// `download`, `downloadBytes`, `downloadUrl`, `checksums` and `metadata` take
/// come from `versions` rather than from here.
///
/// `standing` and `redistribution` stay STRINGS rather than Zig enums: an enum
/// tag `std.json` does not know fails the WHOLE response, so a value added to
/// the API after this release would break every older client. A client that
/// cannot read today's answer is worse than one that cannot name tomorrow's
/// value.
pub const DatabaseFamily = struct {
    /// The family, e.g. `bogon_ip`. What a licence is held against.
    base: []const u8,
    name: []const u8,
    /// One line on what the newest version contains.
    summary: []const u8,
    /// `licensed` is a live grant, `expired` one whose term has ended, and
    /// `unlicensed` a database published but never bought.
    ///
    /// It never says a database does not exist. A family built for one customer
    /// is simply ABSENT from another organization's listing.
    standing: []const u8,
    /// What your licence permits you to do with the data: `evaluation`,
    /// `internal` or `redistribute`. Null when there is no licence at all, so
    /// read the optional before comparing it.
    redistribution: ?[]const u8 = null,
    starts: ?[]const u8 = null,
    /// Null when the licence has no end date, or when there is none.
    expires: ?[]const u8 = null,
    /// Every published version of this family, oldest first. Old versions are
    /// frozen rather than migrated, so both stay downloadable.
    versions: []const DatabaseVersion,
};

/// Mirrors `components.schemas.DatabaseVersion`. One published version of a
/// family, and the only place a downloadable id comes from.
pub const DatabaseVersion = struct {
    /// The versioned id, e.g. `bogon_ip_v1`. This is what you download.
    id: []const u8,
    version: i64,
    summary: []const u8,
    /// The formats this version is BUILT in, as the wire spells them.
    formats: []const []const u8,
};

/// Mirrors `components.schemas.DatabaseMetadata`. The build document the
/// exporter writes, served through unchanged.
///
/// `schema`, `sample` and `size` are keyed by FORMAT, which is why they are hash
/// maps rather than structs: one document describes every format the database is
/// built in.
pub const DatabaseMetadata = struct {
    id: []const u8,
    /// How often a new build is published.
    update_freq: ?[]const u8 = null,
    /// ISO-8601 date (YYYY-MM-DD) the published build was generated on.
    updated: []const u8,
    /// Row count in the current build.
    entries: i64,
    /// Columns, keyed by format.
    schema: std.json.ArrayHashMap([]const DatabaseMetadataColumn),
    /// A few real rows, keyed by format.
    sample: std.json.ArrayHashMap([]const std.json.Value) = .{},
    /// Bytes per format. Read this to budget a transfer before starting one.
    size: std.json.ArrayHashMap(i64),
};

pub const DatabaseMetadataColumn = struct {
    name: []const u8,
    /// `type` is a keyword, so the field is spelled with an identifier literal;
    /// the wire name it matches is still `type`.
    type: []const u8,
    description: ?[]const u8 = null,
};

/// Mirrors `components.schemas.DbChecksums`. The digests of one published file.
///
/// All four the exporter writes are returned, because which of them a caller
/// wants is not this library's decision, and the spec has every one of them
/// present on every published file.
pub const Checksums = struct {
    md5: []const u8,
    sha1: []const u8,
    sha256: []const u8,
    sha512: []const u8,
};

/// Mirrors `components.schemas.Download`. One download ATTEMPT, refusals
/// included: a denial is what answers "it stopped working", and its absence
/// answers nothing.
pub const DownloadAttempt = struct {
    dataset_id: []const u8,
    format: []const u8,
    /// `ok`, `unauthorized`, `denied`, `expired`, `unknown` or `unavailable`.
    outcome: []const u8,
    /// Object size at redirect time, NOT bytes delivered: the transfer runs
    /// straight from object storage, so how much of it was taken is never seen.
    bytes: ?i64 = null,
    http_status: ?i64 = null,
    /// The key that made the request. Null when it could not be resolved.
    apikey_id: ?[]const u8 = null,
    client_ip: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    created: []const u8,
};

/// The envelopes the list endpoints wrap their arrays in, unwrapped one level
/// before a caller ever sees them.
pub const DatabaseList = struct { databases: []const DatabaseFamily };
pub const DownloadList = struct { downloads: []const DownloadAttempt };

/// The digests hang under a `checksums` key rather than sitting at the top level
/// beside `id` and `format`. Reading a top-level `sha256` is how the Node SDK
/// shipped this broken in 1.0.x.
pub const ChecksumResponse = struct {
    id: []const u8,
    format: []const u8,
    checksums: Checksums,
};

test "a format is spelled the way the API takes it" {
    try std.testing.expectEqualStrings("csvgz", Format.csvgz.toString());
    try std.testing.expectEqualStrings("mmdb", Format.mmdb.toString());
}
