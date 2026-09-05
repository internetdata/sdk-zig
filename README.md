# [<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" height="28"/>](https://internetdata.io/) InternetData Zig Client Library

[![CI](https://github.com/internetdata/sdk-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/internetdata/sdk-zig/actions/workflows/ci.yml)
[![license](https://img.shields.io/github/license/internetdata/sdk-zig.svg)](LICENSE)

The official Zig client library for the [InternetData](https://internetdata.io) API.

The library helps you browse and download InternetData's licensed IP and network databases: VPN, residential, datacenter and mobile proxy ranges, hosting and CDN address space, Tor nodes, relays and more, published as CSV.GZ and MMDB.

## Getting Started

```bash
zig fetch --save git+https://github.com/internetdata/sdk-zig#v1.0.0
```

Then add the module to whatever you are building, in `build.zig`:

```zig
const internetdata = b.dependency("internetdata", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("internetdata", internetdata.module("internetdata"));
```

Requires Zig **0.16.0**. Zig is pre-1.0 and its standard library still changes shape between releases, so no other version is supported; this one is pinned in CI and in `scripts/Dockerfile`.

## Usage

Every endpoint published today needs an API key carrying the `db.download` scope. Create a key in the [console](https://app.internetdata.io); keys are default-deny, so an existing one does not reach these endpoints until the scope is added to it. `api_key` is optional at construction: a client built without one sends no `Authorization` header rather than refusing to build, so it is ready for a dataset served without a licence.

```zig
const std = @import("std");
const internetdata = @import("internetdata");

pub fn main(init: std.process.Init) !void {
    var client = try internetdata.Client.init(init.gpa, init.io, .{ .api_key = key });
    defer client.deinit();

    const catalog = try client.database().list(.{});
    defer catalog.deinit();

    for (catalog.value) |family| {
        std.debug.print("{s} ({s})\n", .{ family.base, family.standing });
    }
}
```

The whole program is in [example/catalog.zig](example/catalog.zig); `zig build example` builds it.

Every call lives under `client.database()`. The downloads are the whole of this API today, but the sibling VPNDetection client spells the same seven calls the same way, so a program holding both does not have to remember which one is flat.

`init.io` is the `std.Io` implementation your program already runs on. Outside `main`, build your own:

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();

var client = try internetdata.Client.init(gpa, threaded.io(), .{ .api_key = key });
defer client.deinit();
```

### Memory

Everything the client hands back is allocated with the allocator you gave `init`, and is yours to free. The catalog calls return a `std.json.Parsed` that owns its arena, and `downloadUrl` and `downloadBytes` return slices. The test suite runs under `std.testing.allocator`, so a leak fails the build.

### The catalog

A licence covers a database *family*, and a download names one of its versions, so the id you pass to everything else comes from `versions`:

```zig
const catalog = try client.database().list(.{});
defer catalog.deinit();

const family = catalog.value[0];
family.base;                    // bogon_ip - what a licence is held against
family.standing;                // licensed, expired, or unlicensed
family.redistribution;          // evaluation, internal, redistribute, or null
const id = family.versions[0].id; // bogon_ip_v1 - what you download
```

`list` is the server's answer about *your* key, and nothing else assembles it. A database commissioned for a single customer is **absent** from every other organization's listing rather than present with an `unlicensed` standing, so two keys can see two different catalogs, and neither the catalog nor any part of it can be reconstructed from another source. Read a listing as an answer about the key that fetched it, and do not reuse one across keys.

### Metadata

`metadata` says what is inside a database without transferring anything, so poll it to decide whether today's build is worth fetching, and read `size` to budget a transfer before starting one. One document covers every format the database is built in, which is why it takes no format:

```zig
const info = try client.database().metadata(id, .{});
defer info.deinit();

std.debug.print("{s}, {d} rows, updated {s}\n", .{ info.value.id, info.value.entries, info.value.updated });
std.debug.print("{?d} bytes as csvgz\n", .{info.value.size.map.get("csvgz")});
```

### Downloads

```zig
// Straight to a file, which is the one to reach for by default.
const written = try client.database().download(id, .csvgz, "bogon_ip_v1.csv.gz", .{});

// A time-limited link, so something else can do the transfer.
const url = try client.database().downloadUrl(id, .csvgz, .{});
defer gpa.free(url);

// The bytes, in memory.
const bytes = try client.database().downloadBytes(id, .csvgz, .{});
defer gpa.free(bytes);
```

`download` holds nothing but a single chunk in memory whatever the database weighs. It writes to a neighbouring `.part` file and renames it on completion, and a transfer that stops short of the length the origin declared is an error rather than a short file, so a path that exists is a whole database, nothing partial survives a failure, and a failed refresh cannot destroy the copy already there.

`downloadBytes` holds the **entire file** in memory. The catalog spans seven orders of magnitude, from `bogon_asn_v1` at a few hundred bytes to `resproxy_ip_14d_v1` at 5.34 GiB, and a 5.34 GiB database is 5.34 GiB of resident memory here, so reach for it at the small end. `metadata` publishes the size per format without transferring anything, which is how you find out which end you are at.

`downloadUrl` hands back the link rather than the bytes, so you choose how to move the file, hand it to a downloader, or pass it on without passing on your API key. The link is presigned and authorizes itself; it authorizes the START of a transfer, so one already running is not interrupted when it lapses. The client never follows that redirect for you. `download` and `downloadBytes` do follow it, and that second request carries no API key: object storage has no business holding your credential.

### Verifying a download

`checksums` publishes all four digests for one published file, so you can check the bytes you received:

```zig
const digests = try client.database().checksums(id, .csvgz, .{});
defer digests.deinit();
std.debug.print("{s}\n", .{digests.value.sha256});
```

### Download history

`downloads` is your organization's recent attempts, newest first, refusals included: a denial is what answers "it stopped working", and its absence answers nothing. A null limit takes the API's own default of 50, and it is clamped to 200.

```zig
const history = try client.database().downloads(20, .{});
defer history.deinit();

for (history.value) |attempt| {
    std.debug.print("{s} {s} {s}\n", .{ attempt.created, attempt.dataset_id, attempt.outcome });
}
```

### Errors

Failures are values in `internetdata.Error`, and the detail behind one arrives in a `Diagnostics` you pass in:

```zig
var diagnostics: internetdata.Diagnostics = .{};

const catalog = client.database().list(.{ .diagnostics = &diagnostics }) catch |err| {
    std.debug.print("{s} retryable={} status={?} {s}\n", .{
        internetdata.kindName(err),
        internetdata.isRetryable(err),
        diagnostics.status,
        diagnostics.message(),
    });
    return err;
};
defer catalog.deinit();
```

The error set is `BadRequest`, `Unauthorized`, `Forbidden`, `RateLimited`, `QuotaExceeded`, `ServerError` and `Network`, plus `OutOfMemory` from the allocator. `diagnostics.message()` is the API's own result code, so a 403 tells you whether it was `NOT_LICENSED` or `LICENSE_EXPIRED`.

Retries and how many of them are per call as well as per client:

```zig
const catalog = try client.database().list(.{ .retries = 4 });
```

Note that `RateLimited` and `QuotaExceeded` both arrive as HTTP 429 and are not the same thing. A rate limit is when the API faces extreme traffic bursts and so retrying later works; but a spent quota needs your allowance raised or the window to roll over. The library retries rate limits for you, but not if your quota is exceeded. Nothing else in the 4xx range is retried at all: a misspelled database id is a 404, and asking for it three times gets the same answer three times.

### Nothing is cached

The client caches nothing. What your organization may see depends on the key, so a listing held from one client is not an answer for another, and the catalog is small enough that re-reading it costs less than being wrong about whose it was.

## Other Libraries

There are official InternetData client libraries available for many languages including PHP, Python, Go, Java, Ruby, and many popular frameworks such as Django, Rails, and Laravel. See our GitHub at https://github.com/internetdata for more.

## About InternetData

InternetData: licensed IP and network intelligence databases covering VPN, proxy, hosting, CDN, relay and Tor address space, published daily as CSV.GZ and MMDB.

[<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" width="96"/>](https://internetdata.io/)

## License

This project is licensed under the [MIT License](LICENSE).
