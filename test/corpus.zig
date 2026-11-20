//! The shared conformance corpus, generated into testdata/ and
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
    ipv4Mapped: []const MappedCase,
    bogonResponse: BogonResponse,
    lookup: []const LookupCase,
    errors: []const ErrorCase,
    batch: []const BatchCase,
    bogons: Bogons,
    oauth: Oauth,
    vocabulary: Vocabulary,

    pub fn batchCase(self: Corpus, name: []const u8) BatchCase {
        for (self.batch) |case| {
            if (std.mem.eql(u8, case.name, name)) {
                return case;
            }
        }
        std.debug.panic("the corpus has no batch case named {s}", .{name});
    }
};

/// A closed vocabulary in an answer is the API's to extend: each case serves an
/// answer carrying a value no published list holds, which must come back as
/// served. Each `expect` key is a dotted path of wire names through the answer,
/// a number indexing a list.
pub const Vocabulary = struct {
    cases: []const VocabularyCase,
};

pub const VocabularyCase = struct {
    name: []const u8,
    why: ?[]const u8 = null,
    call: []const u8,
    answer: std.json.Value,
    expect: std.json.ArrayHashMap(std.json.Value),
};

/// The member at `path` (`databases.0.standing`) in `value`, or null when the
/// path leads nowhere.
pub fn at(value: std.json.Value, path: []const u8) ?std.json.Value {
    var current = value;
    var segments = std.mem.splitScalar(u8, path, '.');
    while (segments.next()) |segment| {
        switch (current) {
            .object => |object| current = object.get(segment) orelse return null,
            .array => |array| {
                const index = std.fmt.parseInt(usize, segment, 10) catch return null;
                if (index >= array.items.len) return null;
                current = array.items[index];
            },
            else => return null,
        }
    }
    return current;
}

pub const BogonCase = struct {
    ip: []const u8,
    expect: bool,
    why: []const u8,
};

pub const MappedCase = struct {
    ip: []const u8,
    carries: []const u8,
    expect: bool,
    why: []const u8,
};

/// The bogon answer's lists. Every other key the corpus gives it is a member the
/// answer must hold as written, read by `members`.
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

/// A lookup case's keys naming a role. Every other key of its `expect` is a
/// member the answer must hold as written, read by `members`.
pub const LookupExpect = struct {
    ip: []const u8,
    isBogon: bool,
    present: std.json.ArrayHashMap(bool) = .{},
    absent: []const []const u8 = &.{},
    emptyPresent: []const []const u8 = &.{},
};

/// Where `members` reads: the bogon answer, or one lookup case's `expect`.
pub const Expectation = union(enum) {
    bogon,
    lookup: usize,
};

/// Every member the corpus expects of an answer beyond the keys naming a role,
/// read from the corpus as JSON rather than from a list of the members known
/// when this was written, so a member the corpus gains cannot pass unasserted.
pub fn members(arena: Allocator, of: Expectation) !std.json.ObjectMap {
    const whole = try std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{});
    const object, const roles: []const []const u8 = switch (of) {
        .bogon => .{
            whole.object.get("bogonResponse").?.object,
            &.{ "why", "flagsFalse", "emptyObjects" },
        },
        .lookup => |index| .{
            whole.object.get("lookup").?.array.items[index].object.get("expect").?.object,
            &.{ "ip", "isBogon", "present", "absent", "emptyPresent" },
        },
    };
    var beyond = try object.clone(arena);
    for (roles) |role| {
        _ = beyond.orderedRemove(role);
    }
    return beyond;
}

/// Asserts the answer's member `name` holds `expected`: the typed member is
/// written back out as JSON, so a member the decoder dropped or spelled
/// differently cannot come back, and every key `expected` names must match. An
/// answer with no member of that name fails.
pub fn expectMember(arena: Allocator, answer: Answer, name: []const u8, expected: std.json.Value) !void {
    inline for (comptime std.meta.fieldNames(Answer)) |field_name| {
        if (std.mem.eql(u8, field_name, name)) {
            const text = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(
                @field(answer, field_name),
                .{ .emit_null_optional_fields = false },
            )});
            const actual = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
            if (!holds(expected, actual)) {
                std.debug.print("{s} = {s}, want {f}\n", .{ name, text, std.json.fmt(expected, .{}) });
                return error.TestExpectedEqual;
            }
            return;
        }
    }
    std.debug.print("the answer has no member {s}\n", .{name});
    return error.TestExpectedEqual;
}

/// Whether `got` holds `want`: every key of an object, every item of a list in
/// order, and an equal scalar, a number compared by value.
fn holds(want: std.json.Value, got: std.json.Value) bool {
    switch (want) {
        .object => |object| {
            if (got != .object) return false;
            var it = object.iterator();
            while (it.next()) |entry| {
                const inner = got.object.get(entry.key_ptr.*) orelse return false;
                if (!holds(entry.value_ptr.*, inner)) return false;
            }
            return true;
        },
        .array => |array| {
            if (got != .array or got.array.items.len != array.items.len) return false;
            for (array.items, got.array.items) |want_item, got_item| {
                if (!holds(want_item, got_item)) return false;
            }
            return true;
        },
        .string => |text| return got == .string and std.mem.eql(u8, text, got.string),
        .bool => |flag| return got == .bool and got.bool == flag,
        .null => return got == .null,
        .integer, .float, .number_string => {
            const a = number(want) orelse return false;
            const b = number(got) orelse return false;
            return a == b;
        },
    }
}

fn number(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}

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
    keys: []const []const u8 = &.{},
    httpRequests: ?usize = null,
    bogonKeys: []const []const u8 = &.{},
    errorKeys: []const []const u8 = &.{},
    keyCount: ?usize = null,
    /// Address to the corpus's spelling of an error kind, as a JSON object.
    errorKinds: ?std.json.Value = null,
};

pub const Bogons = struct {
    v4: []const []const u8,
    v6: []const []const u8,
};

/// The `oauth` section. `deferred` holds the authorization code flow's
/// vectors, whose form and retry cases join the main ones' loops.
pub const Oauth = struct {
    endpoints: struct {
        metadata: Endpoint,
        deviceAuthorization: Endpoint,
        token: Endpoint,
        revoke: Endpoint,
    },
    noCredential: struct {
        apiKey: []const u8,
        forbiddenHeaders: []const []const u8,
        forbiddenQuery: []const []const u8,
    },
    forms: struct {
        contentType: []const u8,
        cases: []const FormCase,
    },
    responses: struct {
        metadata: []const ResponseCase,
        deviceAuthorization: []const ResponseCase,
        token: []const ResponseCase,
        revoke: []const Served,
    },
    errors: struct { cases: []const OauthErrorCase },
    retries: struct { cases: []const RetryCase },
    poll: struct { cases: []const PollCase },
    deferred: struct {
        pkce: struct {
            verifier: []const u8,
            challenge: []const u8,
            method: []const u8,
            generatedVerifierPattern: []const u8,
        },
        authorizationUrl: []const AuthorizationUrlCase,
        forms: []const FormCase,
        retries: []const RetryCase,
    },
    register: struct {
        endpoint: Endpoint,
        contentType: []const u8,
        bodies: struct { cases: []const struct { name: []const u8, args: RegisterArgs, body: std.json.Value } },
        refusals: struct { cases: []const struct { name: []const u8, args: RegisterArgs } },
        responses: struct { cases: []const ResponseCase },
        unreadable: struct { cases: []const Served },
        retries: []const struct { name: []const u8, args: RegisterArgs, responses: []const Served, expect: OauthExpect },
        errors: []const OauthErrorCase,
    },
};

pub const RegisterArgs = struct {
    redirectUris: []const []const u8,
    clientName: ?[]const u8 = null,
};

pub const AuthorizationUrlCase = struct {
    name: []const u8,
    baseUrl: []const u8,
    clientId: []const u8,
    redirectUri: []const u8,
    codeChallenge: []const u8,
    scope: ?[]const u8 = null,
    state: ?[]const u8 = null,
    resource: ?[]const u8 = null,
    expect: []const u8,
};

pub const Endpoint = struct { method: []const u8, path: []const u8 };

pub const OauthArgs = struct {
    clientId: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    resource: ?[]const u8 = null,
    deviceCode: ?[]const u8 = null,
    refreshToken: ?[]const u8 = null,
    token: ?[]const u8 = null,
    code: ?[]const u8 = null,
    codeVerifier: ?[]const u8 = null,
    redirectUri: ?[]const u8 = null,
};

pub const FormCase = struct {
    name: []const u8,
    operation: []const u8,
    endpoint: []const u8,
    args: OauthArgs,
    fields: std.json.ArrayHashMap([]const u8),
};

/// One canned response: `body` is served as JSON, `rawBody` verbatim.
pub const Served = struct {
    name: []const u8 = "",
    status: u16,
    body: ?std.json.Value = null,
    rawBody: ?[]const u8 = null,

    pub fn text(self: Served, arena: Allocator) ![]const u8 {
        if (self.rawBody) |raw| {
            return raw;
        }
        return if (self.body) |value| json(arena, value) else "";
    }
};

pub const ResponseCase = struct {
    name: []const u8,
    status: u16,
    body: std.json.Value,
    expect: struct {
        present: std.json.ArrayHashMap(std.json.Value),
        absent: []const []const u8,
    },
};

pub const OauthErrorCase = struct {
    name: []const u8,
    status: u16,
    body: ?std.json.Value = null,
    rawBody: ?[]const u8 = null,
    expect: OauthExpect,

    pub fn served(self: OauthErrorCase) Served {
        return .{ .name = self.name, .status = self.status, .body = self.body, .rawBody = self.rawBody };
    }
};

/// A member left out of the corpus is not asserted, which `unstated` stands
/// for: JSON null is a stated absence, so it cannot double as "not said".
pub const unstated: std.json.Value = .{ .bool = false };

pub const OauthExpect = struct {
    type: ?[]const u8 = null,
    outcome: ?[]const u8 = null,
    errorCode: ?[]const u8 = null,
    errorDescription: std.json.Value = unstated,
    status: std.json.Value = unstated,
    kind: ?[]const u8 = null,
    retryable: ?bool = null,
    requests: ?usize = null,
    waits: []const i64 = &.{},
    token: ?std.json.ArrayHashMap(std.json.Value) = null,
};

pub const RetryCase = struct {
    name: []const u8,
    operation: []const u8,
    args: OauthArgs,
    responses: []const Served,
    expect: OauthExpect,
};

pub const PollCase = struct {
    name: []const u8,
    clientId: []const u8,
    device: vpndetection.DeviceAuthorization,
    responses: []const Served,
    expect: OauthExpect,
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
    inline for (comptime std.meta.fieldNames(Answer)) |field_name| {
        if (std.mem.eql(u8, field_name, name)) {
            return stateOf(@FieldType(Answer, field_name), @field(answer, field_name));
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
    inline for (comptime std.meta.fieldNames(@TypeOf(value))) |field_name| {
        const field = @field(value, field_name);
        // A required member, as every one of the location's and the AS's is,
        // is always there.
        if (comptime @typeInfo(@TypeOf(field)) != .optional) {
            return false;
        } else if (field != null) {
            return false;
        }
    }
    return true;
}
