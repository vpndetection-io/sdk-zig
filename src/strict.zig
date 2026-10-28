//! JSON decoding that refuses what `std.json` would read into a wrong answer.
//!
//! `std.json` reads `"600"` into an integer member as 600, from a token stream
//! and from a `Value` alike, and no `ParseOptions` field turns that off. A date
//! stays a string here, so any string passes for one, and a member the spec
//! requires but a struct gives a default (so a caller can build one by hand)
//! reads as that default when the wire leaves it out. The other SDKs refuse all
//! three as an answer they cannot read, so an answer is parsed into a `Value`
//! first, checked against `T` with a comptime walk, and only then is `T` built
//! from that `Value`.

const std = @import("std");

const database = @import("database.zig");
const entitlement = @import("entitlement.zig");
const lookup = @import("lookup.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// `T` from `body`, or `error.WrongType` when a member `T` declares a number
/// holds a JSON string, a date is not in the form the spec names, or a member
/// the spec requires is missing, at any depth. Any other way `body` fails to be
/// a `T` is the error `std.json` gives for it.
pub fn parseLeaky(comptime T: type, arena: Allocator, body: []const u8, options: std.json.ParseOptions) !T {
    const value = try std.json.parseFromSliceLeaky(Value, arena, body, .{});
    if (!conforms(T, value)) return error.WrongType;
    return std.json.parseFromValueLeaky(T, arena, value, options);
}

/// The form the spec gives a member that its Zig type cannot hold to.
const Form = enum {
    /// `format: date`: RFC 3339's `full-date`, on a day that exists.
    date,
    /// `format: date-time`: RFC 3339's `date-time`, with its zone.
    date_time,
    /// A map of lists whose every entry is a JSON object, held as `Value`s.
    objects,
};

/// What the spec says of one member that its Zig type does not: its form, and
/// whether the wire must carry it though the struct gives it a default, so a
/// caller can still build one by hand.
const Entry = struct { T: type, name: []const u8, required: bool = false, form: ?Form = null };

/// Every member the spec says more of than its type does, by the struct that
/// holds it. A re-pin that adds a date or a required member with a default to
/// one of these types adds it here.
const rules = [_]Entry{
    .{ .T = lookup.VpnDetail, .name = "last_seen", .form = .date },
    .{ .T = lookup.ClassDetail, .name = "last_seen", .form = .date },
    .{ .T = lookup.ProxyDetail, .name = "first_seen", .form = .date },
    .{ .T = lookup.ProxyDetail, .name = "last_seen", .form = .date },
    .{ .T = lookup.PubproxyDetail, .name = "last_seen", .form = .date },
    .{ .T = entitlement.EntitlementApikey, .name = "expires", .form = .date_time },
    .{ .T = entitlement.EntitlementUsage, .name = "window_start", .form = .date_time },
    .{ .T = entitlement.EntitlementUsage, .name = "window_end", .form = .date_time },
    .{ .T = database.Database, .name = "summary", .required = true },
    .{ .T = database.Database, .name = "license_type", .required = true },
    .{ .T = database.Database, .name = "starts", .required = true, .form = .date_time },
    .{ .T = database.Database, .name = "expires", .required = true, .form = .date_time },
    .{ .T = database.Database, .name = "renews_at", .required = true, .form = .date_time },
    .{ .T = database.Database, .name = "notice_due_at", .required = true, .form = .date_time },
    .{ .T = database.Database, .name = "open", .required = true },
    .{ .T = database.Download, .name = "bytes", .required = true },
    .{ .T = database.Download, .name = "created", .form = .date_time },
    .{ .T = database.Download, .name = "open", .required = true },
    .{ .T = database.DatabaseMetadata, .name = "updated", .form = .date },
    .{ .T = database.DatabaseMetadata, .name = "schema", .required = true },
    .{ .T = database.DatabaseMetadata, .name = "sample", .form = .objects },
};

comptime {
    for (rules) |entry| {
        if (!@hasField(entry.T, entry.name)) {
            @compileError(@typeName(entry.T) ++ " has no member " ++ entry.name);
        }
    }
}

fn entryFor(comptime T: type, comptime name: []const u8) ?Entry {
    for (rules) |entry| {
        if (entry.T == T and std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Whether `value` holds nothing `std.json` would read into a wrong `T`. Every
/// other mismatch is left to `std.json`, which refuses it.
fn conforms(comptime T: type, value: Value) bool {
    switch (@typeInfo(T)) {
        .int, .float => return value != .string,
        .optional => |optional| return value == .null or conforms(optional.child, value),
        .pointer => |pointer| {
            if (pointer.size != .slice or pointer.child == u8) return true;
            const array = switch (value) {
                .array => |array| array,
                else => return true,
            };
            for (array.items) |item| if (!conforms(pointer.child, item)) return false;
            return true;
        },
        .@"struct" => {
            const object = switch (value) {
                .object => |object| object,
                else => return true,
            };
            if (comptime isArrayHashMap(T)) {
                const Member = MapValue(T);
                for (object.values()) |member| if (!conforms(Member, member)) return false;
                return true;
            }
            if (comptime std.meta.hasFn(T, "jsonParseFromValue")) return true;
            // Field names and `@FieldType` read alike on Zig 0.16 and 0.17, which
            // reshaped `Type.Struct`.
            inline for (comptime std.meta.fieldNames(T)) |name| {
                const entry = comptime entryFor(T, name);
                const required = comptime if (entry) |e| e.required else false;
                const form: ?Form = comptime if (entry) |e| e.form else null;
                if (object.get(name)) |member| {
                    if (!conforms(@FieldType(T, name), member)) return false;
                    if (form) |given| if (!follows(given, member)) return false;
                } else if (required) {
                    return false;
                }
            }
            return true;
        },
        else => return true,
    }
}

/// Whether a member present on the wire keeps its `Form`. A null, or a value
/// of another JSON type, is the member's type's to judge.
fn follows(form: Form, member: Value) bool {
    return switch (form) {
        .date => member != .string or isDate(member.string),
        .date_time => member != .string or isDateTime(member.string),
        .objects => switch (member) {
            .object => |object| {
                for (object.values()) |rows| {
                    if (rows != .array) continue;
                    for (rows.array.items) |row| if (row != .object) return false;
                }
                return true;
            },
            else => true,
        },
    };
}

/// `YYYY-MM-DD`, on a day that exists.
pub fn isDate(text: []const u8) bool {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return false;
    const year = number(text[0..4]) orelse return false;
    const month = number(text[5..7]) orelse return false;
    const day = number(text[8..10]) orelse return false;
    if (month < 1 or month > 12 or day < 1) return false;
    const days: u32 = switch (month) {
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
    return day <= days;
}

/// `YYYY-MM-DDTHH:MM:SS`, an optional fraction, then `Z` or `+HH:MM`/`-HH:MM`,
/// its `T` and `Z` in either case, at a time that exists: no hour 24, no minute
/// or second 60, in the time and in the zone alike.
pub fn isDateTime(text: []const u8) bool {
    if (text.len < 20 or !isDate(text[0..10]) or (text[10] != 'T' and text[10] != 't')) return false;
    if (!isClock(text[11..19], true)) return false;
    var rest = text[19..];
    if (rest[0] == '.') {
        var digits: usize = 1;
        while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
        if (digits == 1) return false;
        rest = rest[digits..];
    }
    if (rest.len == 1) return rest[0] == 'Z' or rest[0] == 'z';
    return rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and isClock(rest[1..6], false);
}

/// `HH:MM`, or `HH:MM:SS` when `seconds`, within a day.
fn isClock(text: []const u8, seconds: bool) bool {
    if (text.len != @as(usize, if (seconds) 8 else 5) or text[2] != ':') return false;
    if ((number(text[0..2]) orelse return false) > 23) return false;
    if ((number(text[3..5]) orelse return false) > 59) return false;
    if (!seconds) return true;
    return text[5] == ':' and (number(text[6..8]) orelse return false) <= 59;
}

/// Decimal digits alone, never a sign, an underscore or a base prefix.
fn number(digits: []const u8) ?u32 {
    var total: u32 = 0;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
        total = total * 10 + (c - '0');
    }
    return total;
}

/// A `std.json.ArrayHashMap(V)`: its own `jsonParseFromValue` reads each
/// member as a `V`, which this walk still has to look inside.
fn isArrayHashMap(comptime T: type) bool {
    return @hasField(T, "map") and std.meta.hasFn(T, "jsonParseFromValue") and
        T == std.json.ArrayHashMap(MapValue(T));
}

fn MapValue(comptime T: type) type {
    const get = @typeInfo(@TypeOf(@FieldType(T, "map").get)).@"fn";
    return @typeInfo(get.return_type.?).optional.child;
}

test "a numeric string where a number is due is refused at any depth" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Inner = struct { version: i64, label: []const u8 };
    const Outer = struct {
        entries: ?i64 = null,
        items: []const Inner = &.{},
        size: std.json.ArrayHashMap(i64) = .{},
        sample: std.json.ArrayHashMap([]const Value) = .{},
    };
    const a = arena.allocator();
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    try std.testing.expectError(error.WrongType, parseLeaky(Outer, a, "{\"entries\":\"42\"}", options));
    try std.testing.expectError(error.WrongType, parseLeaky(Outer, a, "{\"items\":[{\"version\":\"3\",\"label\":\"x\"}]}", options));
    try std.testing.expectError(error.WrongType, parseLeaky(Outer, a, "{\"size\":{\"csvgz\":\"760\"}}", options));
    const got = try parseLeaky(Outer, a, "{\"entries\":42,\"items\":[{\"version\":3,\"label\":\"7\"}],\"size\":{\"csvgz\":760},\"sample\":{\"csvgz\":[{\"n\":\"1\"}]},\"x\":\"y\"}", options);
    try std.testing.expectEqual(@as(?i64, 42), got.entries);
    try std.testing.expectEqual(@as(i64, 3), got.items[0].version);
    try std.testing.expectEqual(@as(i64, 760), got.size.map.get("csvgz").?);
    try std.testing.expectEqual(@as(?i64, null), (try parseLeaky(Outer, a, "{\"entries\":null}", options)).entries);
}

test "a date is a full-date and a date-time carries its zone, each on a day and at a time that exist" {
    for ([_][]const u8{ "2026-10-20", "2028-02-29", "2000-02-29", "0001-01-01" }) |text| {
        try std.testing.expect(isDate(text));
    }
    for ([_][]const u8{
        "",           "x",                    "tomorrow",   "monday",     "2026-02-30", "2027-02-29",  "1900-02-29",
        "2026-04-31", "2026-13-01",           "2026-00-10", "2026-10-00", "2026-10-5",  " 2026-10-20", "+2026-10-20",
        "2026/10/20", "2026-10-20T10:00:00Z",
    }) |text| {
        try std.testing.expect(!isDate(text));
    }
    for ([_][]const u8{
        "2026-10-20T10:00:00Z", "2026-10-20T23:59:59.999999+05:30", "2026-10-20T00:00:00-23:59", "2028-02-29T12:00:00.5Z",
        "2026-10-20t10:00:00Z", "2026-10-20T10:00:00z",             "2026-10-20t10:00:00z",
    }) |text| {
        try std.testing.expect(isDateTime(text));
    }
    for ([_][]const u8{
        "2026-10-20",               "2026-10-20T10:00:00",       "2026-10-20 10:00:00Z",      "2026-10-20x10:00:00Z",
        "2026-10-20T10:00:00y",     "2026-10-20T24:00:00Z",      "2026-10-20T10:60:00Z",      "2026-10-20T23:59:60Z",
        "2026-10-20T10:00:00+0500", "2026-10-20T10:00:00+24:00", "2026-10-20T10:00:00+05:60", "2026-10-20T10:00:00.Z",
        "2026-02-30T10:00:00Z",     "2026-10-20T10:00Z",         "tomorrow",                  "2026-10-20T10:00:00Z ",
        "+2026-10-20T10:00:00Z",
    }) |text| {
        try std.testing.expect(!isDateTime(text));
    }
}
