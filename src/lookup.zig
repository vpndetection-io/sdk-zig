const std = @import("std");

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
    is_vpn: bool,
    is_hosting: ?bool = null,
    is_relay: ?bool = null,
    is_tor: ?bool = null,
    is_cdn: ?bool = null,
    is_resproxy: ?bool = null,
    is_dcproxy: ?bool = null,
    is_mobproxy: ?bool = null,
    vpn: ?VpnDetail = null,
    hosting: ?ClassDetail = null,
    relay: ?ClassDetail = null,
    tor: ?ClassDetail = null,
    cdn: ?ClassDetail = null,
    resproxy: ?ProxyDetail = null,
    dcproxy: ?ProxyDetail = null,
    mobproxy: ?ProxyDetail = null,
};

/// Dates arrive as `YYYY-MM-DD` strings and stay strings: Zig has no date type
/// in its standard library, and inventing one here would decide the calendar
/// question for every consumer.
pub const VpnDetail = struct {
    provider: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
    confidence: ?[]const u8 = null,
    method: ?[]const u8 = null,
};

/// The shared detail shape for the hosting, relay, tor and cdn datasets.
pub const ClassDetail = struct {
    provider: ?[]const u8 = null,
    confidence: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
};

/// The shared detail shape for the residential, datacenter and mobile proxy
/// families, measured over a rolling 90 day window.
pub const ProxyDetail = struct {
    provider: ?[]const u8 = null,
    first_seen: ?[]const u8 = null,
    last_seen: ?[]const u8 = null,
    hits: ?i64 = null,
    hits_days_pct: ?i64 = null,
    providers_num: ?i64 = null,
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
    /// True when this answer was computed locally rather than served, which
    /// happens for a bogon and only for a bogon.
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
    lookup.value = std.json.parseFromSliceLeaky(Answer, arena, lookup.raw, .{
        // A field this version does not model must not fail the answer, or
        // every consumer breaks the day the API grows one.
        .ignore_unknown_fields = true,
    }) catch return error.Malformed;
    return lookup;
}

/// The answer a bogon gets, in the full shape the API serves at its widest plan:
/// every flag present and false, every detail object present and empty.
///
/// This is deliberately the WIDEST shape regardless of your plan, so a caller
/// must not infer which fields their plan includes from a bogon answer.
pub fn bogonLookup(gpa: Allocator, ip: []const u8) Allocator.Error!Lookup {
    var lookup = try empty(gpa);
    errdefer lookup.deinit();

    lookup.is_bogon = true;
    lookup.value = .{
        .ip = try lookup.arena.allocator().dupe(u8, ip),
        .is_vpn = false,
        .is_hosting = false,
        .is_relay = false,
        .is_tor = false,
        .is_cdn = false,
        .is_resproxy = false,
        .is_dcproxy = false,
        .is_mobproxy = false,
        .vpn = .{},
        .hosting = .{},
        .relay = .{},
        .tor = .{},
        .cdn = .{},
        .resproxy = .{},
        .dcproxy = .{},
        .mobproxy = .{},
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
