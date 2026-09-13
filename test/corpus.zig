//! The shared conformance corpus, generated into testdata/ by the monorepo and
//! identical across every VPNDetection SDK. It is embedded rather than read at
//! run time so a missing or malformed corpus is a build failure.
//!
//! Field names here are the corpus's own, which is why they are camelCase: they
//! are matched against the JSON by name, and renaming one would quietly stop
//! asserting whatever it holds.

const std = @import("std");
const vpndetection = @import("vpndetection");

const Allocator = std.mem.Allocator;
const Answer = vpndetection.Answer;

const source = @embedFile("corpus");

pub const Corpus = struct {
    isBogon: []const BogonCase,
    bogonResponse: BogonResponse,
    lookup: []const LookupCase,
    errors: []const ErrorCase,
    batch: []const BatchCase,
    bogons: Bogons,

    pub fn batchCase(self: Corpus, name: []const u8) BatchCase {
        for (self.batch) |case| {
            if (std.mem.eql(u8, case.name, name)) {
                return case;
            }
        }
        std.debug.panic("the corpus has no batch case named {s}", .{name});
    }
};

pub const BogonCase = struct {
    ip: []const u8,
    expect: bool,
    why: []const u8,
};

pub const BogonResponse = struct {
    why: []const u8,
    flagsFalse: []const []const u8,
    emptyObjects: []const []const u8,
};

pub const LookupCase = struct {
    name: []const u8,
    why: ?[]const u8 = null,
    status: u16,
    body: std.json.Value,
    expect: LookupExpect,
};

pub const LookupExpect = struct {
    ip: []const u8,
    isBogon: bool,
    present: std.json.ArrayHashMap(bool) = .{},
    absent: []const []const u8 = &.{},
    emptyPresent: []const []const u8 = &.{},
    vpn: ?std.json.Value = null,
    hosting: ?std.json.Value = null,
    dcproxy: ?std.json.Value = null,
};

pub const ErrorCase = struct {
    name: []const u8,
    why: ?[]const u8 = null,
    status: u16,
    headers: std.json.ArrayHashMap([]const u8) = .{},
    body: std.json.Value,
    expect: ErrorExpect,
};

pub const ErrorExpect = struct {
    kind: []const u8,
    retryable: bool,
    message: ?[]const u8 = null,
    retryAfterSeconds: ?u64 = null,
};

pub const BatchCase = struct {
    name: []const u8,
    why: ?[]const u8 = null,
    input: []const []const u8,
    repeat: ?u32 = null,
    expect: BatchExpect,
};

pub const BatchExpect = struct {
    keys: []const []const u8,
    httpRequests: ?usize = null,
    bogonKeys: []const []const u8 = &.{},
    errorKeys: []const []const u8 = &.{},
};

pub const Bogons = struct {
    v4: []const []const u8,
    v6: []const []const u8,
};

/// The caller owns the arena, and every slice in the corpus lives in it.
///
/// Unknown fields are ignored, which is not optional: the corpus is shared by
/// every SDK and grows whenever any ONE of them needs a new case, so a strict
/// parse here turns another language's addition into a build failure in this
/// one. Zig is the only binding whose default is strict.
pub fn load(gpa: Allocator) !std.json.Parsed(Corpus) {
    return std.json.parseFromSlice(Corpus, gpa, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

/// A fixture body as the stub has to serve it.
pub fn json(arena: Allocator, value: std.json.Value) ![]const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})});
}

/// What one member of an answer is, in the terms the corpus asserts: absent
/// (not in your plan), a flag, or a detail object that is empty or populated.
pub const Member = union(enum) {
    unknown,
    absent,
    flag: bool,
    empty_object,
    populated_object,
};

pub fn member(answer: Answer, name: []const u8) Member {
    inline for (std.meta.fields(Answer)) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return stateOf(field.type, @field(answer, field.name));
        }
    }
    return .unknown;
}

fn stateOf(comptime T: type, value: T) Member {
    return switch (@typeInfo(T)) {
        .bool => .{ .flag = value },
        .optional => |optional| if (value) |inner| stateOf(optional.child, inner) else .absent,
        .@"struct" => if (allNull(value)) .empty_object else .populated_object,
        else => .unknown,
    };
}

fn allNull(value: anytype) bool {
    inline for (std.meta.fields(@TypeOf(value))) |field| {
        if (@field(value, field.name) != null) {
            return false;
        }
    }
    return true;
}

/// Compares a populated detail object against the fixture's expectation, key by
/// key, so a field this library spells differently from the wire is caught here
/// rather than reading as an absent one.
pub fn expectDetail(expected: std.json.Value, actual: anytype) !void {
    try std.testing.expect(expected == .object);
    const want = expected.object;
    var matched: usize = 0;
    inline for (std.meta.fields(@TypeOf(actual))) |field| {
        if (want.get(field.name)) |value| {
            matched += 1;
            const got = @field(actual, field.name) orelse {
                std.debug.print("{s} is absent, expected {f}\n", .{ field.name, std.json.fmt(value, .{}) });
                return error.TestExpectedEqual;
            };
            if (comptime @typeInfo(field.type).optional.child == []const u8) {
                try std.testing.expectEqualStrings(value.string, got);
            } else {
                try std.testing.expectEqual(value.integer, got);
            }
        }
    }
    try std.testing.expectEqual(want.count(), matched);
}
