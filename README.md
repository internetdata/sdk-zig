# [<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" height="28"/>](https://internetdata.io/) InternetData Zig Client Library

[![CI](https://github.com/internetdata/sdk-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/internetdata/sdk-zig/actions/workflows/ci.yml)
[![license](https://img.shields.io/github/license/internetdata/sdk-zig.svg)](LICENSE)

The official Zig client library for the [InternetData](https://internetdata.io) API.

It tells you what InternetData's databases say about an IP address, an AS or a domain, and downloads the licensed databases themselves as CSV.GZ or MMDB.

## Getting Started

```bash
zig fetch --save git+https://github.com/internetdata/sdk-zig#v2.11.0
```

Then add the module to whatever you are building, in `build.zig`:

```zig
const internetdata = b.dependency("internetdata", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("internetdata", internetdata.module("internetdata"));
```

Requires Zig **0.16.0**, **0.17.0** or **0.17.1**. Zig is pre-1.0 and its standard library still changes shape between releases, so no other version is supported; CI builds and tests on each, and 0.16.0 is pinned in `scripts/Dockerfile`.

## Usage

**No API key needed to start.** Unlimited, the free plan, answers every flag but the paid ones below, Tor's and relay's detail, `location`, `asn`, `company`, `abuse` and `hostname`, limited per address per minute.

```zig
const std = @import("std");
const internetdata = @import("internetdata");

pub fn main(init: std.process.Init) !void {
    var client = try internetdata.Client.init(init.gpa, init.io, .{});
    defer client.deinit();

    const result = try client.lookup("146.70.116.130");
    defer result.deinit();

    std.debug.print("{s}\n", .{result.value.location.country}); // AT
    std.debug.print("{s}\n", .{result.value.asn.name});         // M247 Europe SRL
    std.debug.print("{s}\n", .{result.value.company.name});     // who uses the address
}
```

The whole program is in [example/lookup.zig](example/lookup.zig); `zig build example` builds it.

`init.io` is the `std.Io` implementation your program already runs on. Outside `main`, build your own:

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();

var client = try internetdata.Client.init(gpa, threaded.io(), .{});
defer client.deinit();
```

### Memory

Everything the client hands back is allocated with the allocator you gave `init`, and is yours to free. A `Lookup` and a `Batch` each carry a `deinit`, the catalog calls return a `std.json.Parsed` that owns its arena, and `downloadUrl` and `downloadBytes` return slices. The test suite runs under `std.testing.allocator`, so a leak fails the build.

### With an API key

Every paid plan answers every field: `is_vpn`, `is_hosting`, `is_cdn` and the four proxy flags as well, the detail behind each flag, the rest of `location`, `asn`, `company` and `abuse`, and `whois`, `rwhois` and `hosted_domains`. The plans differ only in how many lookups they include, and a free account tries every field, 100 lookups a day. Create a key in the [console](https://app.internetdata.io), then pass it in:

```zig
var client = try internetdata.Client.init(gpa, io, .{ .api_key = key });
defer client.deinit();

const result = try client.lookup("146.70.116.130");
defer result.deinit();

std.debug.print("{}\n", .{result.value.is_vpn orelse false});    // true, on a paid plan
std.debug.print("{s}\n", .{result.value.vpn.?.provider_name.?}); // Mullvad, on a paid plan
std.debug.print("{s}\n", .{result.value.location.city.?});       // Vienna, on a paid plan
```

The blanks around a key, a file's trailing newline among them, are dropped, and a key of blanks alone is no key at all. A key holding any other control character is refused: every call that would send it fails with `BadRequest` before anything leaves the client.

### AS and domain lookups

```zig
const network = try client.lookupAsn(9009);
defer network.deinit();
std.debug.print("{s}\n", .{network.value.name}); // M247 Europe SRL

const domain = try client.lookupDomain("example.com");
defer domain.deinit();
std.debug.print("{}\n", .{domain.value.has_mx});
```

Both answer on every plan, and a paid one adds an AS's Whois record and the prefixes it announces with their RPKI status, and a domain's DNS records, its organization's IP ranges and whether it's a disposable email domain. Neither is cached or batched. `lookupAsnWith` and `lookupDomainWith` take a call's own options. `lookup` takes an IP address alone, and fails anything else with `BadRequest` before sending it.

### Your own address

```zig
const result = try client.myIp();
defer result.deinit();

std.debug.print("{s}\n", .{result.value.ip});   // the address we saw this call come from
```

Same answer `lookup` would give for that address, and the same cost against your allowance. It is deliberately not cached: which address you are is the whole question, and a machine that moves between networks would otherwise be told where it used to be.

### Your plan and usage

```zig
const acct = try client.myEntitlement();
defer acct.deinit();

std.debug.print("{s}\n", .{acct.value.plan.key});        // max
std.debug.print("{d}\n", .{acct.value.usage.requests});  // 580
```

Usage counts against the anniversary of your subscription on a paid plan, not the calendar month and not the billing period, and against the UTC day on the free plan; it is the same number a lookup is gated on. `hard_limit` is `null` on an uncapped plan, which is not the same as zero.

Both are yours to free, like everything else the client hands back. `myIpWith` and `myEntitlementWith` take this call's own retry budget and a `Diagnostics`.

### Batch lookup

Look up many addresses at once. Bogons and cached answers are handled locally, and everything else goes to the batch endpoint in chunks of up to 1000 addresses, in parallel. The batch endpoint needs a paid plan:

```zig
var batch = try client.lookupBatch(&.{ "146.70.116.130", "8.8.8.8", "1.1.1.1" }, .{});
defer batch.deinit();

for (batch.keys(), batch.values()) |ip, entry| {
    switch (entry) {
        .ok => |answer| std.debug.print("{s}: {s}\n", .{ ip, answer.value.asn.name }),
        .failed => |failure| std.debug.print("{s}: {s}\n", .{ ip, failure.diagnostics.message() }),
    }
}
```

Results are keyed by address, in the order you first listed each one, so duplicates in your list collapse into a single entry and one address failing never loses the rest: it carries its error as its value, with the status the API would have given that address on its own.

How many chunks are in flight at once, and how many times a failed chunk is retried, are configurable per call:

```zig
var batch = try client.lookupBatch(many_ips, .{ .concurrency = 4, .retries = 4 });
defer batch.deinit();
```

A batch is only as concurrent as the `std.Io` you gave the client: `std.Io.Threaded` runs the requests on its thread pool, and an implementation that cannot start a second task answers them one at a time.

### Caching

Address lookups are cached by default, so repeat lookups of the same address are free:

```zig
const first = try client.lookup("146.70.116.130");  // API request
defer first.deinit();

const second = try client.lookup("146.70.116.130"); // no API request, served from the cache
defer second.deinit();
```

You can change the default cache variables (max size, TTL) on initialization, or even disable it:

```zig
var client = try internetdata.Client.init(gpa, io, .{
    .cache = .{ .max_entries = 50_000, .ttl = .fromSeconds(6 * 60 * 60) },
});

var uncached = try internetdata.Client.init(gpa, io, .{ .cache = null });
```

Nothing else is cached. What your organization may download depends on the key, so a listing held from one client is not an answer for another.

### Private and reserved addresses

Private, loopback, link-local, documentation and multicast addresses (and their IPv6 equivalents, including the 6to4 and Teredo ranges) are answered locally, so they cost no request and no quota. The answer is the one the API gives such an address on a paid plan, so it carries every member whatever your plan; don't read your plan off it:

```zig
const result = try client.lookup("192.168.1.1");
defer result.deinit();

result.value.is_bogon; // true
result.raw.len;        // 0, this answer was computed rather than served
```

The check is available on the client, which is handy when your inputs are addresses anyway:

```zig
client.isBogon("10.0.0.1"); // true
client.isBogon("8.8.8.8");  // false
```

It is also callable on its own, if you want it without a client:

```zig
internetdata.isBogon("10.0.0.1"); // true
```

### Database downloads

If your key carries the `db.download` scope, the licensed databases are available through `client.database()`. Keys are default-deny, so an existing one doesn't reach them until the scope is added to it.

```zig
var client = try internetdata.Client.init(init.gpa, init.io, .{ .api_key = key });
defer client.deinit();

const catalog = try client.database().list(.{});
defer catalog.deinit();

for (catalog.value) |family| {
    std.debug.print("{s} ({s})\n", .{ family.base, family.standing });
}
```

The whole program is in [example/catalog.zig](example/catalog.zig).

### The catalog

A license covers a database *family*, and a download names one of its versions, so the ID you pass to everything else comes from `versions`:

```zig
const catalog = try client.database().list(.{});
defer catalog.deinit();

const family = catalog.value[0];
family.base;                    // bogon_ip - what a license is held against
family.standing;                // licensed, expired, or unlicensed
family.license_type;          // evaluation, standard, redistribute, or null
const id = family.versions[0].id; // bogon_ip_v1 - what you download
```

`list` is the server's answer about *your* key, and nothing else assembles it.

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

Each of the three downloads the build that is live unless `build` names one. A `database.updated` webhook names the build it announces and carries its `sha256`, so a receiver that downloads after the next publish asks for that build to get the file the hash is of:

```zig
_ = try client.database().download("vpn_ip_v1", .mmdb, "vpn_ip_v1.mmdb", .{ .build = build });
```

A build is kept 7 days. Past that the call fails with `error.BadRequest`, `diagnostics` carrying `BUILD_GONE`, and downloading without `build` fetches the live one.

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

const result = client.lookupWith("1.1.1.1", .{ .diagnostics = &diagnostics }) catch |err| {
    std.debug.print("{s} retryable={} status={?} {s}\n", .{
        internetdata.kindName(err),
        internetdata.isRetryable(err),
        diagnostics.status,
        diagnostics.message(),
    });
    return err;
};
defer result.deinit();
```

The error set is `BadRequest`, `Unauthorized`, `Forbidden`, `RateLimited`, `QuotaExceeded`, `ServerError` and `Network`, plus `OutOfMemory` from the allocator. `diagnostics.message()` is the API's own explanation, and a database call's result code, so a 403 there tells you whether it was `NOT_LICENSED`, `LICENSE_EXPIRED` or `IP_NOT_ALLOWED`, a call from an address the key or its organization does not allow.

Retries and how many of them are per call as well as per client:

```zig
const catalog = try client.database().list(.{ .retries = 4 });
```

`RateLimited` and `QuotaExceeded` both arrive as HTTP 429 and are not the same thing. `RateLimited` carries `Retry-After`, as Unlimited's per-minute limit does, and the library waits and retries it for you. `QuotaExceeded` doesn't: your key's overage cap is reached, raising it in Billing is what helps, and the library never retries it. Nothing else in the 4xx range is retried at all: a misspelled database ID is a 404, and asking for it three times gets the same answer three times.

### Timeouts

Each attempt of a call gets 30 seconds by default, from connecting to the last byte of the answer. Set your own with `timeout`, on the client or on a single call:

```zig
var client = try internetdata.Client.init(gpa, threaded.io(), .{ .timeout = .fromSeconds(10) });
defer client.deinit();

const result = try client.lookupWith("1.1.1.1", .{ .timeout = .fromMilliseconds(500) });
defer result.deinit();
```

A call's own value replaces the client's, longer or shorter, and `BatchOptions`, `OauthOptions` and `DeviceAuthorizationOptions` take one too. A call that runs out of time fails with `error.Network`, which is retried like any other network failure, and each retry gets the whole timeout again. A download is only held to it until object storage starts answering, so a large database is never cut off part way, and `pollDeviceToken` holds each request to it rather than the whole wait. A timeout has to be positive and at most `std.math.maxInt(i64)` nanoseconds, about 292 years. A call given one outside that fails with `error.BadRequest` without sending anything, and `Client.init` asserts it.

The timeout needs a `std.Io` that can run a second task, such as `std.Io.Threaded`. On one that can't, a call runs without it.

### Sign in with OAuth (device flow)

A program running on the person's own machine can let them sign in with a browser and pick one of their API keys, instead of asking them to paste it:

```zig
var client = try internetdata.Client.init(gpa, threaded.io(), .{});
defer client.deinit();
const device = try client.oauth().deviceAuthorization("your-client-id", .{ .scope = "account.read apikeys.read apikeys.reveal" });
defer device.deinit();
std.debug.print("Open {s} and enter {s}\n", .{ device.value.verification_uri, device.value.user_code });

const token = try client.oauth().pollDeviceToken("your-client-id", device.value, .{});
defer token.deinit();
const apikey = token.value.apikey orelse return error.NoApiKey; // none was picked, or it cannot be shown again
var keyed = try internetdata.Client.init(gpa, threaded.io(), .{ .api_key = apikey });
defer keyed.deinit();
```

A denied sign-in fails with `error.OauthAccessDenied` and a code that ran out with `error.OauthExpiredToken`. Client IDs are issued on request from support@internetdata.io, and `client.oauth().revoke("your-client-id", refresh_token, .{})` signs the machine out again.

### Sign in with OAuth (authorization code)

An app that can take a browser redirect signs the person in there instead, with a PKCE pair made for that one sign-in:

```zig
var client = try internetdata.Client.init(gpa, threaded.io(), .{});
defer client.deinit();
const redirect_uri = "http://127.0.0.1:8765/callback";
const pkce = client.oauth().createPkce();

const url = try client.oauth().authorizationUrl("your-client-id", redirect_uri, &pkce.challenge, .{ .scope = "apikeys.use", .state = "your-state" });
defer gpa.free(url);
// Open url in the browser. Its redirect to redirect_uri carries code and state.
const token = try client.oauth().exchangeAuthorizationCode("your-client-id", code, &pkce.verifier, redirect_uri, .{});
defer token.deinit();
```

Check that `state` came back as you sent it before you exchange `code`, which works once. The client ID can also be the https URL of a client metadata document your app serves, and such an app is never handed a key, so `token.value.apikey` stays `null`.

### Register a client

An app with no client ID, and no client metadata document to use as one, registers itself, then signs in with the `client_id` it gets back as the client ID for `authorizationUrl` and `exchangeAuthorizationCode`:

```zig
var client = try internetdata.Client.init(gpa, threaded.io(), .{});
defer client.deinit();
const registration = try client.oauth().register(&.{"http://127.0.0.1:8765/callback"}, .{ .client_name = "Your App" });
defer registration.deinit();
```

Each redirect URI must be https on a public host name, or http on a loopback address, which then matches any port. Nothing is kept until a person approves the client, so an app with no client ID saved can simply register again.

### Absent is not false

Unlimited leaves out `is_vpn`, `is_hosting`, `is_cdn` and the four proxy flags, the detail behind every flag but Tor's and relay's, `whois`, `rwhois` and `hosted_domains`, and the rest of `location`, `asn`, `company` and `abuse`; a free-plan key's answer carries `trial_expired`, true once its daily trial is spent. Every member the API doesn't always send is optional, because your key decides which of them it sends. `null` means "not in your plan", not "checked, and no".

```zig
const vpn = result.value.is_vpn orelse false;    // when you only want the flag
if (result.value.is_vpn == null) { ... }         // on Unlimited: not in your plan
if (result.value.location.city == null) { ... }  // the same, inside an object every plan answers
if (result.value.trial_expired == true) { ... }  // a free-plan key's daily trial is spent
```

## Other Libraries

There are official InternetData client libraries available for many languages including PHP, Python, Go, Java, and Ruby. See our GitHub at https://github.com/internetdata for more.

## About InternetData

Geolocation, anonymity, ownership and network data for IP addresses, AS numbers and domains, looked up over the API or licensed as files you download and query yourself.

[<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" height="64"/>](https://internetdata.io/)

## License

This project is licensed under the [MIT License](LICENSE).
