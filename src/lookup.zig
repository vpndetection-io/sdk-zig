const std = @import("std");

const strict = @import("strict.zig");

const Allocator = std.mem.Allocator;

/// What the API answers for one address, exactly as the spec describes it.
///
/// **An optional member is one your plan does not include.** It never means "we
/// could not check", so `null` and `false` are genuinely different answers:
/// `null` is "not in your plan", `false` is "checked, and no". This is the
/// single most important semantic in the library, and it is why every
/// tier-gated flag is a `?bool` rather than a `bool`. `orelse` is the reader
/// for callers who only want to know whether an address is flagged:
///
/// ```
/// if (result.value.is_hosting orelse false) { ... }
/// ```
///
/// A detail object that is present but empty (every field null) means the flag
/// above it is false. A populated one always carries every one of its keys,
/// empty values included.
///
/// Mirrors `components.schemas.LookupResponse` in spec/openapi.yaml. Field names
/// are the wire names, so `std.json` matches them without a rename table, and a
/// spec change is picked up by editing this struct.
pub const Answer = struct {
    ip: []const u8,
    is_bogon: ?bool = null,
    is_vpn: bool,
    is_hosting: ?bool = null,
    is_relay: ?bool = null,
    is_tor: ?bool = null,
    is_cdn: ?bool = null,
    /// Whether an automated client uses the address: a search engine's or an AI
    /// company's crawler, an uptime monitor, an internet scanner, a webhook
    /// sender. Every answer carries it, with or without a key.
    is_bot: ?bool = null,
    is_resproxy: ?bool = null,
    is_dcproxy: ?bool = null,
    is_mobproxy: ?bool = null,
    is_pubproxy: ?bool = null,
    /// Announced from many places at once. Every answer carries it, with or
    /// without a key.
    is_anycast: ?bool = null,
    is_carrier: ?bool = null,
    is_satellite: ?bool = null,
    is_ssh: ?bool = null,
    is_smtp: ?bool = null,
    is_web: ?bool = null,
    is_dns_resolver: ?bool = null,
    is_bittorrent: ?bool = null,
    vpn: ?VpnDetail = null,
    hosting: ?ClassDetail = null,
    relay: ?ClassDetail = null,
    tor: ?ClassDetail = null,
    cdn: ?ClassDetail = null,
    /// Whose bot uses the address, on a paid plan; empty when `is_bot` is false.
    bot: ?BotDetail = null,
    resproxy: ?ProxyDetail = null,
    dcproxy: ?ProxyDetail = null,
    mobproxy: ?ProxyDetail = null,
    pubproxy: ?PubproxyDetail = null,
    carrier: ?CarrierDetail = null,
    satellite: ?SatelliteDetail = null,
    ssh: ?SshDetail = null,
    smtp: ?SmtpDetail = null,
    /// A row per port a web server answered on; empty when `is_web` is false.
    web: ?[]const WebDetail = null,
    dns_resolver: ?DnsResolverDetail = null,
    bittorrent: ?BitTorrentDetail = null,
    /// Where the address is. Every answer carries it, with or without a key.
    location: ?Location = null,
    /// The AS announcing the address. Every answer carries it, with or without
    /// a key.
    asn: ?Asn = null,
    /// Who uses the address, on a paid plan.
    company: ?Company = null,
    /// The name the address's reverse DNS (PTR) record points to, empty when it
    /// has none. Every answer carries it, with or without a key.
    hostname: ?[]const u8 = null,
    /// Where to report abuse from the address, on a paid plan.
    abuse: ?AbuseContact = null,
    /// On answers to a key on the free plan only: false while its organization's
    /// trial of every field lasts, true once the answer has Unlimited's.
    trial_expired: ?bool = null,
    /// On answers to a key on a paid plan only: false while the answer has every
    /// field, true once its organization's overage cap is reached and the answer
    /// has Unlimited's. Lookups answered past the cap are not billed.
    cap_reached: ?bool = null,
};

/// Dates arrive as `YYYY-MM-DD` strings and stay strings: Zig has no date type
/// in its standard library, and inventing one here would decide the calendar
/// question for every consumer.
pub const VpnDetail = struct {
    provider: ?[]const u8 = null,
    /// The name the provider catalog gives `provider`, the ID to key on.
    provider_name: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
    confidence: ?[]const u8 = null,
    /// Deprecated: no plan is answered with it since 2026-10-20, so it is
    /// always null; read `confidence` instead. It goes in the next major.
    method: ?[]const u8 = null,
};

/// The shared detail shape for the hosting, relay, tor and cdn datasets.
pub const ClassDetail = struct {
    provider: ?[]const u8 = null,
    provider_name: ?[]const u8 = null,
    confidence: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
};

/// Whose bot uses the address: its operator, the bots the address serves (for
/// one that is not verified, the bots it claimed to be), what they do, and how
/// that is known. `agents` and `categories` keep the order the API sends.
pub const BotDetail = struct {
    /// The bot operator's ID, empty where no operator is known.
    provider: ?[]const u8 = null,
    /// The operator's name, empty where no operator is known.
    provider_name: ?[]const u8 = null,
    /// The bots, as their user agents name them, e.g. `Googlebot`; empty when
    /// none is named.
    agents: ?[]const []const u8 = null,
    /// What those bots do, e.g. `search_engine`, `ai_training` or `monitoring`;
    /// empty where unknown.
    categories: ?[]const []const u8 = null,
    /// Whether the operator vouches for the address, so the bots in `agents`
    /// really are its.
    verified: ?bool = null,
    /// `verified`, `declared`, `spoofed` or `undeclared`.
    identity: ?[]const u8 = null,
    /// How a verified address verified: `list`, `rdns` or `owner`; empty when
    /// it is not verified.
    verified_by: ?[]const u8 = null,
    /// `high`, `medium` or `low`.
    confidence: ?[]const u8 = null,
    first_seen: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
};

/// The shared detail shape for the residential, datacenter and mobile proxy
/// families, measured over a rolling 90 day window.
pub const ProxyDetail = struct {
    provider: ?[]const u8 = null,
    provider_name: ?[]const u8 = null,
    first_seen: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
    hits: ?i64 = null,
    hits_days_pct: ?i64 = null,
    providers_num: ?i64 = null,
};

/// The address in Public Proxy IP, open proxies anyone can connect through,
/// over a rolling 90 day window: whether a public proxy listens on it
/// (`entry`), whether one's traffic leaves from it (`exit`), and their
/// protocols, empty where only the address is known. `num_ports` counts the
/// ports a proxy listens on there (0 when it is only an exit) and `num_proxies`
/// the proxies whose traffic left from it (0 when it is only an entry).
/// `last_usable` is the empty string when no request through a proxy on the
/// address was answered.
pub const PubproxyDetail = struct {
    entry: ?bool = null,
    exit: ?bool = null,
    protocols: ?[]const []const u8 = null,
    num_ports: ?i64 = null,
    num_proxies: ?i64 = null,
    last_seen: ?[]const u8 = null,
    last_usable: ?[]const u8 = null,
};

/// The mobile network whose address space holds the address.
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
/// where they are not known, so none has a default and an answer missing one
/// fails to parse; the rest are a paid plan's, null when your plan does not
/// include them.
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

    /// Every member present and empty, as the API answers a bogon.
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
/// where no announcement covers it. Every member is present whenever the object
/// is.
pub const Asn = struct {
    /// The AS number, or 0.
    asn: i64,
    /// The organization that operates the AS.
    name: []const u8,
    /// The AS operator's own registrable domain.
    domain: []const u8,
    /// `isp`, `hosting`, `education`, `government` or `business`.
    type: []const u8,
    /// The announced prefix covering the address, the most specific when
    /// several do.
    prefix: []const u8,
    /// The country its registry assigned it to.
    country: ?[]const u8 = null,
    /// The announcement's RPKI status: `valid`, `invalid` or `not_found`.
    rpki_status: ?[]const u8 = null,

    /// AS 0 and every other member present and empty, as the API answers a
    /// bogon.
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

/// One answer, and the memory behind it.
///
/// Every slice reachable from `value` and `raw` lives in this arena, so
/// `deinit` is the whole cleanup. The caller owns what `lookup` returns.
pub const Lookup = struct {
    /// The answer, with the wire's own optionality intact.
    value: Answer,
    /// The untouched response body, for a field this library does not model
    /// yet. Empty for a bogon, which was computed rather than served.
    raw: []const u8,
    /// True for reserved space (private, loopback, documentation and the
    /// like), which this library answers locally without a request. A served
    /// answer carries the API's own `is_bogon`, and this reads it.
    is_bogon: bool,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: Lookup) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

pub const ParseError = error{ OutOfMemory, Malformed };

/// A served answer, with `body` copied into the returned arena.
pub fn parseServed(gpa: Allocator, body: []const u8) ParseError!Lookup {
    var lookup = try empty(gpa);
    errdefer lookup.deinit();

    const arena = lookup.arena.allocator();
    lookup.raw = try arena.dupe(u8, body);
    lookup.value = strict.parseLeaky(Answer, arena, lookup.raw, .{
        // A field this version does not model must not fail the answer, or
        // every consumer breaks the day the API grows one.
        .ignore_unknown_fields = true,
    }) catch return error.Malformed;
    lookup.is_bogon = lookup.value.is_bogon orelse false;
    return lookup;
}

/// The answer a bogon gets, in the full shape the API serves at its widest plan:
/// every flag present and false, every detail object present and empty (`web`
/// an empty list), `hostname` empty, and a location, AS, company and abuse
/// contact with every member empty or zero.
///
/// This is deliberately the WIDEST shape regardless of your plan, so a caller
/// must not infer which fields their plan includes from a bogon answer.
pub fn bogonLookup(gpa: Allocator, ip: []const u8) Allocator.Error!Lookup {
    var lookup = try empty(gpa);
    errdefer lookup.deinit();

    lookup.is_bogon = true;
    lookup.value = .{
        .ip = try lookup.arena.allocator().dupe(u8, ip),
        .is_bogon = true,
        .is_vpn = false,
        .is_hosting = false,
        .is_relay = false,
        .is_tor = false,
        .is_cdn = false,
        .is_bot = false,
        .is_resproxy = false,
        .is_dcproxy = false,
        .is_mobproxy = false,
        .is_pubproxy = false,
        .is_anycast = false,
        .is_carrier = false,
        .is_satellite = false,
        .is_ssh = false,
        .is_smtp = false,
        .is_web = false,
        .is_dns_resolver = false,
        .is_bittorrent = false,
        .vpn = .{},
        .hosting = .{},
        .relay = .{},
        .tor = .{},
        .cdn = .{},
        .bot = .{},
        .resproxy = .{},
        .dcproxy = .{},
        .mobproxy = .{},
        .pubproxy = .{},
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
    };
    return lookup;
}

fn empty(gpa: Allocator) Allocator.Error!Lookup {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    return .{
        .value = .{ .ip = "", .is_vpn = false },
        .raw = "",
        .is_bogon = false,
        .arena = arena,
    };
}

test "a served is_bogon reaches the lookup" {
    const flagged = try parseServed(std.testing.allocator, "{\"ip\":\"8.8.8.8\",\"is_bogon\":true,\"is_vpn\":false}");
    defer flagged.deinit();
    try std.testing.expect(flagged.is_bogon);
    const served = try parseServed(std.testing.allocator, "{\"ip\":\"8.8.4.4\",\"is_bogon\":false,\"is_vpn\":false}");
    defer served.deinit();
    try std.testing.expect(!served.is_bogon);
    const named = try parseServed(
        std.testing.allocator,
        "{\"ip\":\"8.8.8.8\",\"is_vpn\":true,\"vpn\":{\"provider\":\"nordvpn\",\"provider_name\":\"NordVPN\"}}",
    );
    defer named.deinit();
    try std.testing.expectEqualStrings("NordVPN", named.value.vpn.?.provider_name.?);
}

test "an absent flag is null and a served false flag is false" {
    const free_tier = try parseServed(std.testing.allocator, "{\"ip\":\"1.1.1.1\",\"is_vpn\":false}");
    defer free_tier.deinit();
    try std.testing.expectEqualStrings("1.1.1.1", free_tier.value.ip);
    try std.testing.expectEqual(false, free_tier.value.is_vpn);
    try std.testing.expectEqual(@as(?bool, null), free_tier.value.is_hosting);
    try std.testing.expectEqual(false, free_tier.value.is_hosting orelse false);

    const served = try parseServed(
        std.testing.allocator,
        "{\"ip\":\"8.8.4.4\",\"is_vpn\":false,\"is_hosting\":false}",
    );
    defer served.deinit();
    try std.testing.expectEqual(@as(?bool, false), served.value.is_hosting);
}

test "an empty detail object is present, not absent" {
    const lookup = try parseServed(
        std.testing.allocator,
        "{\"ip\":\"8.8.4.4\",\"is_vpn\":false,\"vpn\":{}}",
    );
    defer lookup.deinit();
    try std.testing.expect(lookup.value.vpn != null);
    try std.testing.expectEqual(@as(?[]const u8, null), lookup.value.vpn.?.provider);
    try std.testing.expect(lookup.value.hosting == null);
}

test "an unknown field does not fail the answer" {
    const lookup = try parseServed(
        std.testing.allocator,
        "{\"ip\":\"1.1.1.1\",\"is_vpn\":true,\"is_quantum\":true}",
    );
    defer lookup.deinit();
    try std.testing.expectEqual(true, lookup.value.is_vpn);
}

test "a body missing a required member is malformed" {
    try std.testing.expectError(
        error.Malformed,
        parseServed(std.testing.allocator, "{\"ip\":\"1.1.1.1\"}"),
    );
}
