//! The staging fixtures every test file shares: a client per tier pointed
//! through the recording proxy, and the shape rules that hold whatever the plan.

const std = @import("std");
const vpndetection = @import("vpndetection");

pub const proxy = @import("proxy.zig");
pub const tiers = @import("tiers.zig");

const Allocator = std.mem.Allocator;
const Answer = vpndetection.Answer;
const Io = std.Io;
const Tier = tiers.Tier;

/// Not the library's default, which is production. Reaching it through the
/// client's own base-URL option is what makes that option worth testing.
pub const upstream = "https://api-staging.vpndetection.io";

/// A stable VPN address, and the one the README teaches.
pub const probe = "45.83.91.1";

/// One tier's client, the proxy in front of it, and the `Io` both run on.
///
/// Do not copy one after `start`: the client holds intrusive lists, and the
/// base URL is a slice of the buffer below.
pub const Rung = struct {
    gpa: Allocator,
    tier: Tier,
    threaded: Io.Threaded,
    proxy: *proxy.Proxy,
    client: vpndetection.Client,
    url_buffer: [64]u8 = undefined,

    /// The thread budget is pinned rather than left to the CPU count: the proxy
    /// forwards from inside a task of its own, so a one-core runner with no
    /// async budget would deadlock the first request.
    pub fn start(gpa: Allocator, tier: Tier, options: vpndetection.Options) !*Rung {
        const self = try gpa.create(Rung);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .tier = tier,
            .threaded = .init(gpa, .{ .async_limit = .limited(32) }),
            .proxy = undefined,
            .client = undefined,
        };
        const io = self.threaded.io();
        self.proxy = try proxy.Proxy.start(gpa, io, upstream, tier.key());
        errdefer self.proxy.deinit();

        var pointed = options;
        pointed.base_url = self.proxy.baseUrl(&self.url_buffer);
        pointed.api_key = if (tier.key().len > 0) tier.key() else null;
        self.client = try vpndetection.Client.init(gpa, io, pointed);
        return self;
    }

    pub fn deinit(self: *Rung) void {
        self.client.deinit();
        self.proxy.deinit();
        self.threaded.deinit();
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }
};

/// One tier's answer about `probe`, and what the wire carried alongside it.
pub const Fixture = struct {
    rung: *Rung,
    lookup: vpndetection.Lookup,
    /// The field names the answer actually carried, which is what the ladder
    /// compares. Read from `Lookup.raw`: the library keeps the untouched body
    /// precisely so a caller is never limited to what the struct models.
    served: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Fixture) void {
        self.served.deinit();
        self.lookup.deinit();
        self.rung.deinit();
    }

    pub fn has(self: Fixture, field: []const u8) bool {
        return self.served.value.object.contains(field);
    }

    pub fn fields(self: Fixture) usize {
        return self.served.value.object.count();
    }
};

/// Looks `probe` up on one tier and checks, BEFORE anything is compared, that
/// the key was actually on the wire.
///
/// An unsent key answers the free shape, which satisfies every containment
/// check vacuously, so a whole ladder can read as green while the credential
/// never left the process.
pub fn answerFor(gpa: Allocator, tier: Tier) !Fixture {
    const rung = try Rung.start(gpa, tier, .{});
    errdefer rung.deinit();

    const lookup = try rung.client.lookup(probe);
    errdefer lookup.deinit();

    if (tier.secret() != null and !rung.proxy.carriedKey()) {
        std.debug.print("the {t} key never reached the wire\n", .{tier});
        return error.TestUnexpectedResult;
    }

    const served = try std.json.parseFromSlice(std.json.Value, gpa, lookup.raw, .{});
    errdefer served.deinit();
    if (served.value != .object) {
        return error.TestUnexpectedResult;
    }
    return .{ .rung = rung, .lookup = lookup, .served = served };
}

/// Holds on every plan: presence is the plan, the value is the answer.
pub fn assertShape(fixture: Fixture) !void {
    const answer = fixture.lookup.value;
    try std.testing.expectEqualStrings(probe, answer.ip);
    try std.testing.expect(!fixture.lookup.is_bogon);

    // On every plan, and so a plain bool rather than an optional.
    try std.testing.expect(fixture.has("is_vpn"));
    try std.testing.expectEqual(fixture.served.value.object.get("is_vpn").?.bool, answer.is_vpn);

    try assertVpn(answer.vpn);
    inline for (.{ "hosting", "relay", "tor", "cdn" }) |name| {
        try assertClass(name, @field(answer, name), @field(answer, "is_" ++ name));
    }
    inline for (.{ "resproxy", "dcproxy", "mobproxy" }) |name| {
        try assertProxy(name, @field(answer, name), @field(answer, "is_" ++ name));
    }
}

fn assertVpn(detail: ?vpndetection.VpnDetail) !void {
    const value = detail orelse return;
    if (isEmpty(value)) {
        return;
    }
    try expectPresent("vpn", "provider", value.provider);
    try expectPresent("vpn", "last_seen", value.last_seen);
}

fn assertClass(comptime name: []const u8, detail: ?vpndetection.ClassDetail, flag: ?bool) !void {
    const value = detail orelse return;
    // A detail object without its flag would leave a caller reading the object
    // to find out whether the address is flagged at all.
    try std.testing.expect(flag != null);
    if (isEmpty(value)) {
        try std.testing.expectEqual(@as(?bool, false), flag);
        return;
    }
    try expectPresent(name, "provider", value.provider);
    try expectPresent(name, "confidence", value.confidence);
    try expectPresent(name, "last_seen", value.last_seen);
}

fn assertProxy(comptime name: []const u8, detail: ?vpndetection.ProxyDetail, flag: ?bool) !void {
    const value = detail orelse return;
    try std.testing.expect(flag != null);
    if (isEmpty(value)) {
        try std.testing.expectEqual(@as(?bool, false), flag);
        return;
    }
    try expectPresent(name, "provider", value.provider);
    try expectPresent(name, "first_seen", value.first_seen);
    try expectPresent(name, "last_seen", value.last_seen);
    try expectPresent(name, "hits", value.hits);
    try expectPresent(name, "hits_days_pct", value.hits_days_pct);
    try expectPresent(name, "providers_num", value.providers_num);
}

fn expectPresent(comptime object: []const u8, comptime key: []const u8, value: anytype) !void {
    if (value == null) {
        std.debug.print("{s} is populated but carries no {s}\n", .{ object, key });
        return error.TestExpectedEqual;
    }
}

/// A detail object every one of whose fields is null: present, and meaning the
/// flag above it is false.
fn isEmpty(value: anytype) bool {
    inline for (std.meta.fields(@TypeOf(value))) |field| {
        if (@field(value, field.name) != null) {
            return false;
        }
    }
    return true;
}

/// Whether the client holds a value for the WIRE name `field`, and whether that
/// name is one the client models at all.
///
/// Asked by wire name on purpose: a test says "this field is absent" about the
/// name the API serves rather than whatever the binding happened to call it.
pub fn modelled(answer: Answer, field: []const u8) struct { known: bool, present: bool } {
    inline for (std.meta.fields(Answer)) |member| {
        if (std.mem.eql(u8, member.name, field)) {
            const value = @field(answer, member.name);
            return .{
                .known = true,
                .present = switch (@typeInfo(member.type)) {
                    .optional => value != null,
                    else => true,
                },
            };
        }
    }
    return .{ .known = false, .present = false };
}
