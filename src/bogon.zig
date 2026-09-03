const std = @import("std");

const bogons = @import("bogons.zig");

/// Whether an address is a bogon: private, loopback, link-local, documentation,
/// multicast or otherwise not routable on the public internet, including the
/// IPv6 equivalents and the 6to4 and Teredo ranges that wrap them.
///
/// These can never be VPN or proxy infrastructure, so the client answers them
/// itself and they never cost a request. An address that will not parse is not
/// a bogon: the API is the authority on what is a valid address, and answering
/// `false` is what sends it there.
pub fn isBogon(ip: []const u8) bool {
    // A 4-in-6 form (::ffff:10.0.0.1) is tested against the v6 table, matching
    // every other binding: the colon decides the family, not the notation.
    if (std.mem.indexOfScalar(u8, ip, ':') != null) {
        const addr = parseV6(ip) orelse return false;
        for (v6_ranges) |range| {
            if (addr & range.mask == range.net) {
                return true;
            }
        }
        return false;
    }
    const addr = parseV4(ip) orelse return false;
    for (v4_ranges) |range| {
        if (addr & range.mask == range.net) {
            return true;
        }
    }
    return false;
}

/// The canonical ranges, masked at COMPILE time. The table costs nothing at run
/// time and a malformed entry is a compile error rather than a silent miss.
const v4_ranges: [bogons.bogon_v4.len]Range(u32) = blk: {
    @setEvalBranchQuota(100_000);
    var out: [bogons.bogon_v4.len]Range(u32) = undefined;
    for (bogons.bogon_v4, 0..) |cidr, i| {
        out[i] = parseCidr(u32, cidr, parseV4);
    }
    break :blk out;
};

const v6_ranges: [bogons.bogon_v6.len]Range(u128) = blk: {
    @setEvalBranchQuota(100_000);
    var out: [bogons.bogon_v6.len]Range(u128) = undefined;
    for (bogons.bogon_v6, 0..) |cidr, i| {
        out[i] = parseCidr(u128, cidr, parseV6);
    }
    break :blk out;
};

fn Range(comptime T: type) type {
    return struct { net: T, mask: T };
}

fn parseCidr(comptime T: type, comptime cidr: []const u8, comptime parse: anytype) Range(T) {
    const width = @bitSizeOf(T);
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse
        @compileError("bogon range without a prefix length: " ++ cidr);
    const bits = std.fmt.parseInt(u8, cidr[slash + 1 ..], 10) catch
        @compileError("bogon range with an unreadable prefix length: " ++ cidr);
    if (bits > width) {
        @compileError("bogon range wider than its family: " ++ cidr);
    }
    const net = parse(cidr[0..slash]) orelse @compileError("unparseable bogon range: " ++ cidr);
    const shift: std.math.Log2Int(T) = @intCast(width - bits);
    const mask: T = if (bits == 0) 0 else ~@as(T, 0) << shift;
    return .{ .net = net & mask, .mask = mask };
}

fn parseV4(text: []const u8) ?u32 {
    var out: u32 = 0;
    var seen: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part| {
        if (seen == 4 or part.len == 0 or part.len > 3) {
            return null;
        }
        var octet: u32 = 0;
        for (part) |c| {
            if (c < '0' or c > '9') {
                return null;
            }
            octet = octet * 10 + (c - '0');
        }
        if (octet > 255) {
            return null;
        }
        out = (out << 8) | octet;
        seen += 1;
    }
    return if (seen == 4) out else null;
}

/// Handles the `::` run and a trailing IPv4 literal (::ffff:1.2.3.4), which
/// several of the canonical ranges use.
fn parseV6(text: []const u8) ?u128 {
    var head: [8]u16 = undefined;
    var tail: [8]u16 = undefined;

    const run = std.mem.indexOf(u8, text, "::") orelse {
        const groups = parseGroups(text, &head) orelse return null;
        return if (groups == 8) assemble(head[0..8], &.{}) else null;
    };
    const head_len = parseGroups(text[0..run], &head) orelse return null;
    const tail_len = parseGroups(text[run + 2 ..], &tail) orelse return null;
    if (head_len + tail_len > 8) {
        return null;
    }
    return assemble(head[0..head_len], tail[0..tail_len]);
}

fn assemble(head: []const u16, tail: []const u16) u128 {
    var out: u128 = 0;
    for (head) |group| {
        out = (out << 16) | group;
    }
    for (0..8 - head.len - tail.len) |_| {
        out <<= 16;
    }
    for (tail) |group| {
        out = (out << 16) | group;
    }
    return out;
}

fn parseGroups(text: []const u8, out: *[8]u16) ?usize {
    if (text.len == 0) {
        return 0;
    }
    var seen: usize = 0;
    var it = std.mem.splitScalar(u8, text, ':');
    while (it.next()) |part| {
        if (seen == 8) {
            return null;
        }
        // A v4 literal only ever occupies the last two groups.
        if (std.mem.indexOfScalar(u8, part, '.') != null) {
            const v4 = parseV4(part) orelse return null;
            if (seen + 2 > 8 or it.next() != null) {
                return null;
            }
            out[seen] = @truncate(v4 >> 16);
            out[seen + 1] = @truncate(v4);
            return seen + 2;
        }
        if (part.len == 0 or part.len > 4) {
            return null;
        }
        var group: u16 = 0;
        for (part) |c| {
            const digit: u16 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return null,
            };
            group = (group << 4) | digit;
        }
        out[seen] = group;
        seen += 1;
    }
    return seen;
}

test "every generated range is reachable through the predicate" {
    for (bogons.bogon_v4) |cidr| {
        const slash = std.mem.indexOfScalar(u8, cidr, '/').?;
        try std.testing.expect(isBogon(cidr[0..slash]));
    }
    for (bogons.bogon_v6) |cidr| {
        const slash = std.mem.indexOfScalar(u8, cidr, '/').?;
        try std.testing.expect(isBogon(cidr[0..slash]));
    }
}

test "a 4-in-6 form is answered by the v6 table" {
    // ::ffff:0:0/96 is itself a canonical range, so an IPv4-mapped address is a
    // bogon whatever it wraps. The colon decides the family, never the notation,
    // which is what keeps this binding agreeing with the others.
    try std.testing.expect(isBogon("::ffff:10.0.0.1"));
    try std.testing.expect(isBogon("::ffff:8.8.8.8"));
    try std.testing.expect(!isBogon("8.8.8.8"));
}

test "an address that will not parse is not a bogon" {
    try std.testing.expect(!isBogon("notanip"));
    try std.testing.expect(!isBogon(""));
    try std.testing.expect(!isBogon("10.0.0"));
    try std.testing.expect(!isBogon("10.0.0.256"));
    try std.testing.expect(!isBogon("fe80:::1"));
}
