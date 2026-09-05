//! The official Zig client library for the [InternetData](https://internetdata.io)
//! API: licensed IP and network databases, downloaded as CSV.GZ or MMDB.
//!
//! Start with `Client.init`, then `Client.database()`. Every endpoint needs an API key
//! carrying the `db.download` scope, which is why `Options.api_key` has no
//! default: there is no anonymous tier to fall back on.
//!
//! ```
//! var threaded: std.Io.Threaded = .init(gpa, .{});
//! defer threaded.deinit();
//!
//! var client = try internetdata.Client.init(gpa, threaded.io(), .{ .api_key = key });
//! defer client.deinit();
//!
//! const catalog = try client.database().list(.{});
//! defer catalog.deinit();
//! std.debug.print("{s}\n", .{catalog.value[0].versions[0].id});
//! ```
//!
//! # What a listing is
//!
//! `database().list` is the server's answer about YOUR key. A database commissioned for a
//! single customer is absent from every other organization's listing rather than
//! present with an `unlicensed` standing, so two keys can see two different
//! catalogs and neither can be reconstructed from anywhere else.
//!
//! # Memory
//!
//! Everything the client returns is allocated with the allocator you gave
//! `Client.init` and is owned by you: a `std.json.Parsed` from the catalog calls
//! carries its arena, and `downloadUrl` and `downloadBytes` return slices. The
//! library allocates nothing you cannot free, and its test suite runs under
//! `std.testing.allocator`.

const std = @import("std");

pub const CallOptions = @import("client.zig").CallOptions;
pub const Client = @import("client.zig").Client;
pub const Options = @import("client.zig").Options;
pub const default_base_url = @import("client.zig").default_base_url;

pub const Checksums = @import("database.zig").Checksums;
pub const Database = @import("database.zig").Database;
pub const DatabaseFamily = @import("database.zig").DatabaseFamily;
pub const DatabaseMetadata = @import("database.zig").DatabaseMetadata;
pub const DatabaseMetadataColumn = @import("database.zig").DatabaseMetadataColumn;
pub const DatabaseVersion = @import("database.zig").DatabaseVersion;
pub const DownloadAttempt = @import("database.zig").DownloadAttempt;
pub const DownloadError = @import("database.zig").DownloadError;
pub const Format = @import("database.zig").Format;

pub const CallError = @import("errors.zig").CallError;
pub const Diagnostics = @import("errors.zig").Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const isRetryable = @import("errors.zig").isRetryable;
pub const kindName = @import("errors.zig").kindName;

test {
    _ = @import("client.zig");
    _ = @import("database.zig");
    _ = @import("errors.zig");
    _ = @import("http.zig");
}
