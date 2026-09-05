const std = @import("std");

const errors = @import("errors.zig");

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

/// Mirrors `components.schemas.Database` in spec/openapi.yaml, renamed only
/// because `Client.database` would collide with it.
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
