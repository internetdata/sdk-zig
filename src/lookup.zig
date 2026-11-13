const std = @import("std");

const strict = @import("strict.zig");

const Allocator = std.mem.Allocator;

/// What the API answers for one address, exactly as the spec describes it.
///
/// **An optional member is one your plan does not include.** It never means "we
/// could not check", so `null` and `false` are genuinely different answers:
/// `null` is "not in your plan", `false` is "checked, and no". This is the
/// single most important semantic in the library, and it is why every
/// tier-gated flag is a `?bool` rather than a `bool`, and every paid member of
/// a shared object (`location.city`, `asn.rpki_status`) an optional too.
/// `orelse` is the reader for callers who only want to know whether an address
/// is flagged:
///
/// ```
/// if (result.value.is_hosting orelse false) { ... }
/// ```
///
/// A detail object that is present but empty (every field null) means the flag
/// above it is false, and so does an empty `web`. A populated one always
/// carries every one of its keys, empty values included.
///
/// Mirrors `components.schemas.LookupResponse` in spec/openapi.yaml. Field names
/// are the wire names, so `std.json` matches them without a rename table, and a
/// spec change is picked up by editing this struct.
pub const Answer = struct {
    /// The address looked up, as parsed: `::ffff:a.b.c.d` answers as `a.b.c.d`.
    ip: []const u8,
    /// Reserved space, answered from the address alone. The client answers a
    /// bogon itself, and never sends one.
    is_bogon: bool,
    is_vpn: ?bool = null,
    is_tor: bool,
    is_relay: bool,
    is_resproxy: ?bool = null,
    is_dcproxy: ?bool = null,
    is_mobproxy: ?bool = null,
    is_pubproxy: ?bool = null,
    is_hosting: ?bool = null,
    is_cdn: ?bool = null,
    is_anycast: bool,
    is_carrier: bool,
    is_satellite: bool,
    is_ssh: bool,
    is_smtp: bool,
    is_web: bool,
    is_dns_resolver: bool,
    is_bittorrent: bool,
    vpn: ?ClassDetail = null,
    tor: ClassDetail,
    relay: ClassDetail,
    resproxy: ?ProxyDetail = null,
    dcproxy: ?ProxyDetail = null,
    mobproxy: ?ProxyDetail = null,
    pubproxy: ?PubproxyDetail = null,
    hosting: ?ClassDetail = null,
    cdn: ?ClassDetail = null,
    carrier: ?CarrierDetail = null,
    satellite: ?SatelliteDetail = null,
    ssh: ?SshDetail = null,
    smtp: ?SmtpDetail = null,
    /// A row per port that answered, lowest first; empty when `is_web` is false.
    web: ?[]const WebDetail = null,
    dns_resolver: ?DnsResolverDetail = null,
    bittorrent: ?BitTorrentDetail = null,
    location: Location,
    asn: Asn,
    company: Company,
    /// The name the address's reverse DNS (PTR) record points to, empty when it
    /// has none.
    hostname: []const u8,
    abuse: AbuseContact,
    whois: ?Whois = null,
    rwhois: ?Rwhois = null,
    hosted_domains: ?HostedDomains = null,
    /// On answers to a key on the free plan only: false while its organization's
    /// daily trial lasts (every field for the first 100 lookups each UTC day),
    /// true once the answer has Unlimited's.
    trial_expired: ?bool = null,
};

/// Dates arrive as `YYYY-MM-DD` strings, or empty, and stay strings: Zig has no
/// date type in its standard library, and inventing one here would decide the
/// calendar question for every consumer.
///
/// The detail shape for VPN IP, Tor IP, Relay IP, Hosting IP and CDN IP.
pub const ClassDetail = struct {
    /// The provider's ID in its catalog; empty for an unattributed range, and on
    /// Tor.
    provider: ?[]const u8 = null,
    provider_name: ?[]const u8 = null,
    /// `high`, `medium` or `low`.
    confidence: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
};

/// The residential, datacenter and mobile proxy families, measured over a
/// rolling 90 day window.
pub const ProxyDetail = struct {
    provider: ?[]const u8 = null,
    provider_name: ?[]const u8 = null,
    first_seen: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
    hits: ?i64 = null,
    hits_days_pct: ?i64 = null,
    providers_num: ?i64 = null,
};

/// The address in Public Proxy IP: whether a public proxy listens on it
/// (`entry`), whether one's traffic leaves from it (`exit`), and their
/// protocols, empty where only the address is known.
pub const PubproxyDetail = struct {
    entry: ?bool = null,
    exit: ?bool = null,
    protocols: ?[]const []const u8 = null,
    num_ports: ?i64 = null,
    num_proxies: ?i64 = null,
    last_seen: ?[]const u8 = null,
    last_usable: ?[]const u8 = null,
};

/// The mobile carrier whose address space holds the address.
pub const CarrierDetail = struct {
    name: ?[]const u8 = null,
    mcc: ?[]const u8 = null,
    mnc: ?[]const u8 = null,
    country: ?[]const u8 = null,
    confidence: ?[]const u8 = null,
};

/// The satellite operator whose address space holds the address.
pub const SatelliteDetail = struct {
    provider: ?[]const u8 = null,
    provider_name: ?[]const u8 = null,
    orbit: ?[]const u8 = null,
    segment: ?[]const u8 = null,
    country: ?[]const u8 = null,
    asn: ?i64 = null,
    confidence: ?[]const u8 = null,
};

/// The SSH server that answered at the address.
pub const SshDetail = struct {
    port: ?i64 = null,
    banner: ?[]const u8 = null,
    host_key_fp: ?[]const u8 = null,
    session_ok: ?bool = null,
    first_seen: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
};

/// The mail server that answered at the address.
pub const SmtpDetail = struct {
    port: ?i64 = null,
    banner: ?[]const u8 = null,
    session_ok: ?bool = null,
    first_seen: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
};

/// One port a web server answered on. A row is only ever served whole.
pub const WebDetail = struct {
    port: i64,
    tls_ok: bool,
    session_ok: bool,
    status_code: i64,
    server: []const u8,
    /// Where the answer redirected, if it did.
    location: []const u8,
    title: []const u8,
    cert_subject_cn: []const u8,
    cert_subject_o: []const u8,
    cert_issuer_dn: []const u8,
    cert_browser_trusted: bool,
    tls_version: []const u8,
    first_seen: []const u8,
    last_seen: []const u8,
};

/// The open DNS resolver that answered at the address.
pub const DnsResolverDetail = struct {
    port: ?i64 = null,
    recursion_available: ?bool = null,
    rcode: ?i64 = null,
    answer_correct: ?bool = null,
    first_seen: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
};

/// The BitTorrent client seen at the address in the last 90 days.
pub const BitTorrentDetail = struct {
    verified: ?bool = null,
    id_matches_ip: ?bool = null,
    first_seen: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
    last_reachable: ?[]const u8 = null,
    days_seen: ?i64 = null,
    num_ports: ?i64 = null,
    peak_num_ports: ?i64 = null,
    indexer: ?bool = null,
    /// The two-letter codes its clients name themselves by.
    clients: ?[]const []const u8 = null,
};

/// Where the address is. The country members are on every plan, an empty string
/// where they are not known; the rest are paid members, null when your plan does
/// not include them.
pub const Location = struct {
    /// The continent code, e.g. `EU`.
    continent: []const u8,
    continent_name: []const u8,
    /// The ISO 3166-1 alpha-2 country code, e.g. `AT`.
    country: []const u8,
    country_name: []const u8,
    /// The IANA time zone, e.g. `Europe/Vienna`.
    timezone: []const u8,
    /// The ISO 4217 code of the country's currency, e.g. `EUR`.
    currency_code: []const u8,
    currency_name: []const u8,
    currency_symbol: []const u8,
    flag_emoji: []const u8,
    /// The flag's code points, e.g. `U+1F1E6 U+1F1F9`.
    flag_unicode: []const u8,
    region: ?[]const u8 = null,
    /// The ISO 3166-2 region code.
    region_code: ?[]const u8 = null,
    city: ?[]const u8 = null,
    postal_code: ?[]const u8 = null,
    latitude: ?f64 = null,
    longitude: ?f64 = null,
    /// The radius in km holding the true location with 67% confidence.
    accuracy_radius: ?i64 = null,
    geoname_id: ?[]const u8 = null,
    /// The US TV market (DMA) code.
    dma_code: ?[]const u8 = null,
    last_changed: ?[]const u8 = null,

    /// Every member present and empty, as the API answers a bogon on a paid
    /// plan.
    pub const empty: Location = .{
        .continent = "",
        .continent_name = "",
        .country = "",
        .country_name = "",
        .timezone = "",
        .currency_code = "",
        .currency_name = "",
        .currency_symbol = "",
        .flag_emoji = "",
        .flag_unicode = "",
        .region = "",
        .region_code = "",
        .city = "",
        .postal_code = "",
        .latitude = 0,
        .longitude = 0,
        .accuracy_radius = 0,
        .geoname_id = "",
        .dma_code = "",
        .last_changed = "",
    };
};

/// The autonomous system announcing the address. `asn` is 0 and the rest empty
/// where no announcement covers it.
pub const Asn = struct {
    /// The AS number, or 0.
    asn: i64,
    /// The organization that operates the AS.
    name: []const u8,
    /// The AS operator's own domain.
    domain: []const u8,
    /// The kind of network it runs, e.g. `isp` or `hosting`.
    type: []const u8,
    /// The announced prefix covering the address.
    prefix: []const u8,
    /// The country its registry assigned it to.
    country: ?[]const u8 = null,
    /// The announcement's RPKI status.
    rpki_status: ?[]const u8 = null,

    /// AS 0 and every other member present and empty, as the API answers a
    /// bogon on a paid plan.
    pub const empty: Asn = .{
        .asn = 0,
        .name = "",
        .domain = "",
        .type = "",
        .prefix = "",
        .country = "",
        .rpki_status = "",
    };
};

/// Who uses the address.
pub const Company = struct {
    name: []const u8,
    domain: []const u8,
    /// `hosting`, `isp`, `business`, `education` or `government`.
    type: ?[]const u8 = null,
    /// The ISO 3166 country code.
    country: ?[]const u8 = null,

    pub const empty: Company = .{ .name = "", .domain = "", .type = "", .country = "" };
};

/// Where to report abuse from the address.
pub const AbuseContact = struct {
    email: []const u8,
    name: ?[]const u8 = null,
    phone: ?[]const u8 = null,
    address: ?[]const u8 = null,
    country: ?[]const u8 = null,
    /// The registry block the contact was derived from.
    network: ?[]const u8 = null,
    /// Whether ARIN reports the contact answered its yearly validation.
    validated: ?bool = null,
    unvalidated_since: ?[]const u8 = null,

    pub const empty: AbuseContact = .{
        .email = "",
        .name = "",
        .phone = "",
        .address = "",
        .country = "",
        .network = "",
        .validated = false,
        .unvalidated_since = "",
    };
};

/// The most specific registry record covering the address.
pub const Whois = struct {
    /// The record's network name.
    id: []const u8,
    name: []const u8,
    /// The registry's handle for the holder.
    org: []const u8,
    country: []const u8,
    status: []const u8,
    /// The registry, or `rwhois`.
    source: []const u8,
    domain: []const u8,
    abuse_email: []const u8,
    /// The AS announcing the record's start address.
    asn: i64,

    pub const empty: Whois = .{
        .id = "",
        .name = "",
        .org = "",
        .country = "",
        .status = "",
        .source = "",
        .domain = "",
        .abuse_email = "",
        .asn = 0,
    };
};

/// The network as the operator's own RWHOIS server publishes it.
pub const Rwhois = struct {
    id: []const u8,
    name: []const u8,
    country: []const u8,
    /// The operator that published it.
    source: []const u8,
    domain: []const u8,
    abuse_email: []const u8,

    pub const empty: Rwhois = .{
        .id = "",
        .name = "",
        .country = "",
        .source = "",
        .domain = "",
        .abuse_email = "",
    };
};

pub const HostedDomains = struct {
    /// How many registered domains resolve to the address.
    total: i64,
};

/// What the API answers for one autonomous system. Absent is "not in your
/// plan" here as in `Answer`.
///
/// Mirrors `components.schemas.AsnLookupResponse` in spec/openapi.yaml.
pub const AsnAnswer = struct {
    asn: i64,
    /// Its operator.
    name: []const u8,
    /// The country its registry assigned it to.
    country: []const u8,
    /// The registry that allocated it.
    registry: []const u8,
    /// When, as `YYYY-MM-DD`.
    allocated: []const u8,
    /// Its operator's domain.
    domain: []const u8,
    type: ?[]const u8 = null,
    /// IPv4 addresses it announces.
    num_ips: ?i64 = null,
    num_prefixes4: ?i64 = null,
    num_prefixes6: ?i64 = null,
    rpki_valid: ?i64 = null,
    rpki_invalid: ?i64 = null,
    rpki_not_found: ?i64 = null,
    /// Its ASN Whois record, every column, empty where the registry states
    /// nothing.
    whois: ?std.json.ArrayHashMap([]const u8) = null,
    /// What it announces, IPv4 then IPv6, up to 20000 a family.
    prefixes: ?[]const AsnPrefix = null,
    /// As on `Answer`.
    trial_expired: ?bool = null,
};

pub const AsnPrefix = struct {
    prefix: []const u8,
    /// How many peers saw it.
    peer_count: i64,
    rpki_status: []const u8,
    first_seen: []const u8,
    /// Where its first address is.
    country: []const u8,
    /// IPv4 addresses it covers; 0 for IPv6.
    size: i64,
    /// Every other AS announcing it.
    other_origins: []const i64,
};

/// What the API answers for one domain. Absent is "not in your plan" here as in
/// `Answer`.
///
/// Mirrors `components.schemas.DomainLookupResponse` in spec/openapi.yaml.
pub const DomainAnswer = struct {
    /// The domain, lowercase and in punycode.
    domain: []const u8,
    is_registered: bool,
    is_disposable: ?bool = null,
    has_a: bool,
    has_aaaa: bool,
    has_mx: bool,
    has_ns: bool,
    has_cname: bool,
    /// The records themselves, up to 100 a type.
    dns: ?DomainDns = null,
    /// The organization's IP ranges.
    ip_ranges: ?DomainIpRanges = null,
    /// Empty when `is_disposable` is false.
    disposable: ?DisposableDetail = null,
    /// As on `Answer`.
    trial_expired: ?bool = null,
};

pub const DomainDns = struct {
    a: []const DnsAddressRecord,
    aaaa: []const DnsAddressRecord,
    mx: []const DnsMxRecord,
    ns: []const DnsNsRecord,
    cname: []const DnsCnameRecord,
};

pub const DnsAddressRecord = struct {
    ip: []const u8,
    last_seen: []const u8,
};

pub const DnsMxRecord = struct {
    priority: i64,
    host: []const u8,
    last_seen: []const u8,
};

pub const DnsNsRecord = struct {
    host: []const u8,
    last_seen: []const u8,
};

pub const DnsCnameRecord = struct {
    target: []const u8,
    last_seen: []const u8,
};

pub const DomainIpRanges = struct {
    /// The organization's domain.
    domain: []const u8,
    /// Where its home page redirects, when that is how it was reached.
    redirects_to: []const u8,
    /// How many ranges it holds.
    total: i64,
    /// IPv4 addresses across them.
    ipv4: i64,
    /// The first 1000, IPv4 before IPv6, the largest first.
    ranges: []const DomainIpRange,
};

pub const DomainIpRange = struct {
    range: []const u8,
    /// Its registry name.
    name: []const u8,
    country: []const u8,
};

/// The domain in Disposable Domain.
pub const DisposableDetail = struct {
    confidence: ?[]const u8 = null,
    providers: ?[]const []const u8 = null,
    first_seen: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
};

/// One answer for an address.
pub const Lookup = Served(Answer);
/// One answer for an autonomous system.
pub const AsnLookup = Served(AsnAnswer);
/// One answer for a domain.
pub const DomainLookup = Served(DomainAnswer);

/// One answer, and the memory behind it.
///
/// Every slice reachable from `value` and `raw` lives in this arena, so
/// `deinit` is the whole cleanup. The caller owns what a lookup returns.
pub fn Served(comptime T: type) type {
    return struct {
        /// The answer, with the wire's own optionality intact.
        value: T,
        /// The untouched response body, for a field this library does not model
        /// yet. Empty for a bogon, which was computed rather than served.
        raw: []const u8,
        arena: *std.heap.ArenaAllocator,

        pub fn deinit(self: @This()) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };
}

pub const ParseError = error{ OutOfMemory, Malformed };

/// A served answer, with `body` copied into the returned arena.
pub fn parseServed(comptime T: type, gpa: Allocator, body: []const u8) ParseError!Served(T) {
    var served = try empty(T, gpa);
    errdefer served.deinit();

    const arena = served.arena.allocator();
    served.raw = try arena.dupe(u8, body);
    served.value = strict.parseLeaky(T, arena, served.raw, .{
        // A field this version does not model must not fail the answer, or
        // every consumer breaks the day the API grows one.
        .ignore_unknown_fields = true,
    }) catch return error.Malformed;
    return served;
}

/// The answer a bogon gets, in the full shape the API serves at its widest plan:
/// every flag present and false, every detail object present and empty, `web`
/// empty, and location, AS, company, abuse contact and both registry records
/// with every member empty, `hostname` empty and `hosted_domains` 0.
///
/// This is deliberately the WIDEST shape regardless of your plan, so a caller
/// must not infer which fields their plan includes from a bogon answer.
pub fn bogonLookup(gpa: Allocator, ip: []const u8) Allocator.Error!Lookup {
    var lookup = try empty(Answer, gpa);
    errdefer lookup.deinit();

    lookup.value = .{
        .ip = try lookup.arena.allocator().dupe(u8, ip),
        .is_bogon = true,
        .is_vpn = false,
        .is_tor = false,
        .is_relay = false,
        .is_resproxy = false,
        .is_dcproxy = false,
        .is_mobproxy = false,
        .is_pubproxy = false,
        .is_hosting = false,
        .is_cdn = false,
        .is_anycast = false,
        .is_carrier = false,
        .is_satellite = false,
        .is_ssh = false,
        .is_smtp = false,
        .is_web = false,
        .is_dns_resolver = false,
        .is_bittorrent = false,
        .vpn = .{},
        .tor = .{},
        .relay = .{},
        .resproxy = .{},
        .dcproxy = .{},
        .mobproxy = .{},
        .pubproxy = .{},
        .hosting = .{},
        .cdn = .{},
        .carrier = .{},
        .satellite = .{},
        .ssh = .{},
        .smtp = .{},
        .web = &.{},
        .dns_resolver = .{},
        .bittorrent = .{},
        .location = .empty,
        .asn = .empty,
        .company = .empty,
        .hostname = "",
        .abuse = .empty,
        .whois = .empty,
        .rwhois = .empty,
        .hosted_domains = .{ .total = 0 },
    };
    return lookup;
}

fn empty(comptime T: type, gpa: Allocator) Allocator.Error!Served(T) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    return .{ .value = undefined, .raw = "", .arena = arena };
}

/// The members every plan answers, and nothing else: Unlimited's shape with no
/// country and no announcement.
const unlimited =
    \\{"ip":"1.1.1.1","is_bogon":false,"is_tor":false,"is_relay":false,"is_anycast":false,
    \\"is_carrier":false,"is_satellite":false,"is_ssh":false,"is_smtp":false,"is_web":false,
    \\"is_dns_resolver":false,"is_bittorrent":false,"tor":{},"relay":{},
    \\"location":{"continent":"","continent_name":"","country":"","country_name":"","timezone":"",
    \\"currency_code":"","currency_name":"","currency_symbol":"","flag_emoji":"","flag_unicode":""},
    \\"asn":{"asn":0,"name":"","domain":"","type":"","prefix":""},"company":{"name":"","domain":""},
    \\"hostname":"","abuse":{"email":""}
;

fn withMember(comptime member: []const u8) []const u8 {
    return unlimited ++ "," ++ member ++ "}";
}

test "an absent flag is null and a served false flag is false" {
    const free_tier = try parseServed(Answer, std.testing.allocator, unlimited ++ "}");
    defer free_tier.deinit();
    try std.testing.expectEqualStrings("1.1.1.1", free_tier.value.ip);
    try std.testing.expectEqual(false, free_tier.value.is_tor);
    try std.testing.expectEqual(@as(?bool, null), free_tier.value.is_hosting);
    try std.testing.expectEqual(false, free_tier.value.is_hosting orelse false);
    try std.testing.expectEqual(@as(?[]const u8, null), free_tier.value.location.city);
    try std.testing.expectEqual(@as(?[]const u8, null), free_tier.value.asn.rpki_status);

    const served = try parseServed(Answer, std.testing.allocator, withMember("\"is_hosting\":false"));
    defer served.deinit();
    try std.testing.expectEqual(@as(?bool, false), served.value.is_hosting);
}

test "an empty detail object is present, not absent" {
    const lookup = try parseServed(Answer, std.testing.allocator, withMember("\"vpn\":{},\"web\":[]"));
    defer lookup.deinit();
    try std.testing.expect(lookup.value.vpn != null);
    try std.testing.expectEqual(@as(?[]const u8, null), lookup.value.vpn.?.provider);
    try std.testing.expectEqual(@as(usize, 0), lookup.value.web.?.len);
    try std.testing.expect(lookup.value.hosting == null);
}

test "an unknown field does not fail the answer" {
    const lookup = try parseServed(Answer, std.testing.allocator, withMember("\"is_quantum\":true"));
    defer lookup.deinit();
    try std.testing.expectEqual(false, lookup.value.is_bogon);
}

test "a body missing a required member is malformed" {
    try std.testing.expectError(
        error.Malformed,
        parseServed(Answer, std.testing.allocator, "{\"ip\":\"1.1.1.1\",\"is_bogon\":false}"),
    );
    try std.testing.expectError(
        error.Malformed,
        parseServed(AsnAnswer, std.testing.allocator, "{\"asn\":9009,\"name\":\"n\"}"),
    );
    try std.testing.expectError(
        error.Malformed,
        parseServed(DomainAnswer, std.testing.allocator, "{\"domain\":\"example.com\"}"),
    );
}
