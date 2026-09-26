//! The `oauth` accessor against the shared corpus: what leaves the client, how
//! answers decode, how failures classify, which calls retry, and the poll, whose
//! waits run on a clock this file substitutes through `std.Io` itself.

const std = @import("std");
const vpndetection = @import("vpndetection");

const support = @import("support.zig");

const corpus = support.corpus;
const Harness = support.Harness;
const Io = std.Io;
const Route = support.Route;

const client_id = "vpndetection-cli";

/// Satisfies every operation's required members at once.
const every_required_member =
    \\{"issuer":"https://api.example.test",
    \\"authorization_endpoint":"https://api.example.test/oauth/authorize",
    \\"token_endpoint":"https://api.example.test/oauth/token","device_code":"mo_dc_x",
    \\"user_code":"BCDF-GHJK","verification_uri":"https://app.example.test/device",
    \\"expires_in":900,"interval":1,"access_token":"mo_at_x","token_type":"Bearer"}
;

const oauth_paths = [_][]const u8{
    "/.well-known/oauth-authorization-server",
    "/oauth/device_authorization",
    "/oauth/token",
    "/oauth/revoke",
};

test "no OAuth request carries the API key" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const credential = data.value.oauth.noCredential;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try routeEveryPath(harness, .ok(every_required_member));

    var client = try harness.client(.{ .api_key = credential.apiKey });
    defer client.deinit();
    const oauth = client.oauth();
    (try oauth.metadata(.{})).deinit();
    const device = try oauth.deviceAuthorization(client_id, .{
        .scope = "account.read",
        .resource = "https://x.test/",
    });
    defer device.deinit();
    (try oauth.exchangeDeviceCode(client_id, "mo_dc_x", .{})).deinit();
    (try oauth.exchangeRefreshToken(client_id, "mo_rt_x", .{})).deinit();
    try oauth.revoke(client_id, "mo_rt_x", .{});
    (try oauth.pollDeviceToken(client_id, device.value, .{})).deinit();

    const calls = harness.stub.seen();
    try std.testing.expectEqual(6, calls.len);
    for (calls) |call| {
        for (credential.forbiddenHeaders) |name| {
            if (call.header(name)) |value| {
                std.debug.print("{s} carried {s}: {s}\n", .{ call.path, name, value });
                return error.TestUnexpectedResult;
            }
        }
        if (std.mem.indexOfScalar(u8, call.target, '?')) |start| {
            var pairs = std.mem.splitScalar(u8, call.target[start + 1 ..], '&');
            while (pairs.next()) |pair| {
                const key = pair[0 .. std.mem.indexOfScalar(u8, pair, '=') orelse pair.len];
                for (credential.forbiddenQuery) |forbidden| {
                    try std.testing.expect(!std.mem.eql(u8, key, forbidden));
                }
            }
        }
        try std.testing.expect(std.mem.indexOf(u8, call.head, credential.apiKey) == null);
        try std.testing.expect(std.mem.indexOf(u8, call.body, credential.apiKey) == null);
    }
}

// Asserted on what the client REQUESTED, from a client built with no key.
test "each form goes to its endpoint with exactly its fields" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const oauth_data = data.value.oauth;

    for (oauth_data.forms.cases) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try routeEveryPath(harness, .ok(every_required_member));
        var client = try harness.client(.{});
        defer client.deinit();

        callOperation(&client, case.operation, case.args) catch |err| {
            std.debug.print("{s}: {s}\n", .{ case.name, @errorName(err) });
            return err;
        };

        const calls = harness.stub.seen();
        try std.testing.expectEqual(1, calls.len);
        const endpoint = endpointNamed(oauth_data, case.endpoint);
        try expectSentTo(case.name, calls[0], endpoint);
        const content_type = calls[0].header("content-type") orelse "";
        try std.testing.expect(std.mem.startsWith(u8, content_type, oauth_data.forms.contentType));

        const fields = try decodeForm(harness.stub.arena.allocator(), calls[0].body);
        std.testing.expectEqual(case.fields.map.count(), fields.count()) catch |err| {
            std.debug.print("{s}: sent {s}\n", .{ case.name, calls[0].body });
            return err;
        };
        for (case.fields.map.keys(), case.fields.map.values()) |name, want| {
            const got = fields.get(name) orelse {
                std.debug.print("{s}: no {s} in {s}\n", .{ case.name, name, calls[0].body });
                return error.TestExpectedEqual;
            };
            std.testing.expectEqualStrings(want, got) catch |err| {
                std.debug.print("{s}: {s}\n", .{ case.name, name });
                return err;
            };
        }
    }

    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try routeEveryPath(harness, .ok(every_required_member));
    var client = try harness.client(.{});
    defer client.deinit();
    (try client.oauth().metadata(.{})).deinit();
    try expectSentTo("metadata", harness.stub.seen()[0], oauth_data.endpoints.metadata);
}

test "answers decode with absent members absent" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const responses = data.value.oauth.responses;

    for (responses.metadata) |case| {
        const harness = try servingCase(gpa, case.status, case.body);
        defer harness.deinit();
        var client = try harness.client(.{ .retries = 0 });
        defer client.deinit();
        const got = try client.oauth().metadata(.{});
        defer got.deinit();
        try expectMembers(case.name, got.value, case.expect.present, case.expect.absent);
    }
    for (responses.deviceAuthorization) |case| {
        const harness = try servingCase(gpa, case.status, case.body);
        defer harness.deinit();
        var client = try harness.client(.{ .retries = 0 });
        defer client.deinit();
        const got = try client.oauth().deviceAuthorization(client_id, .{});
        defer got.deinit();
        try expectMembers(case.name, got.value, case.expect.present, case.expect.absent);
    }
    for (responses.token) |case| {
        const harness = try servingCase(gpa, case.status, case.body);
        defer harness.deinit();
        var client = try harness.client(.{ .retries = 0 });
        defer client.deinit();
        const got = try client.oauth().exchangeDeviceCode(client_id, "mo_dc_x", .{});
        defer got.deinit();
        try expectMembers(case.name, got.value, case.expect.present, case.expect.absent);
    }
    for (responses.revoke) |served| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try routeEveryPath(harness, .{
            .status = served.status,
            .body = try served.text(harness.stub.arena.allocator()),
        });
        var client = try harness.client(.{ .retries = 0 });
        defer client.deinit();
        client.oauth().revoke(client_id, "mo_rt_x", .{}) catch |err| {
            std.debug.print("revoke {s}: {s}\n", .{ served.name, @errorName(err) });
            return err;
        };
    }
}

test "failures are classified as the corpus says" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    for (data.value.oauth.errors.cases) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        const served = case.served();
        try routeEveryPath(harness, .{
            .status = served.status,
            .body = try served.text(harness.stub.arena.allocator()),
        });
        var client = try harness.client(.{ .retries = 0 });
        defer client.deinit();

        var diagnostics: vpndetection.Diagnostics = .{};
        if (client.oauth().exchangeDeviceCode(client_id, "mo_dc_x", .{ .diagnostics = &diagnostics })) |token| {
            token.deinit();
            std.debug.print("{s}: succeeded\n", .{case.name});
            return error.TestUnexpectedResult;
        } else |err| {
            try expectFailure(case.name, err, &diagnostics, case.expect, case.expect.type.?);
        }
    }
}

// With the client at its default retries. The count is asserted before the
// outcome, so an extra attempt fails here rather than on what it was answered.
test "only the calls that consume nothing are retried" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const oauth_data = data.value.oauth;

    for (oauth_data.retries.cases) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        const path = endpointNamed(oauth_data, endpointOf(case.operation)).path;
        try harness.stub.sequence(path, try routesFor(harness, case.responses));
        var client = try harness.client(.{});
        defer client.deinit();

        var diagnostics: vpndetection.Diagnostics = .{};
        const outcome = callOperationWith(&client, case.operation, case.args, &diagnostics);

        std.testing.expectEqual(case.expect.requests.?, harness.stub.callCount()) catch |err| {
            std.debug.print("{s}: requests\n", .{case.name});
            return err;
        };
        if (outcome) |_| {
            try std.testing.expectEqualStrings("ok", case.expect.outcome.?);
        } else |err| {
            try expectFailure(case.name, err, &diagnostics, case.expect, case.expect.outcome.?);
        }
    }
}

// Each required member left out on its own, then a body that is not JSON: every
// one is the ordinary `error.ServerError` with the status kept, never a value
// with a hole in it.
test "a 2xx without a required member is an ordinary error" {
    const gpa = std.testing.allocator;
    const required = [_]struct { operation: []const u8, members: []const []const u8 }{
        .{ .operation = "metadata", .members = &.{ "issuer", "authorization_endpoint", "token_endpoint" } },
        .{ .operation = "deviceAuthorization", .members = &.{ "device_code", "user_code", "verification_uri", "expires_in", "interval" } },
        .{ .operation = "exchangeDeviceCode", .members = &.{ "access_token", "token_type", "expires_in" } },
        .{ .operation = "exchangeRefreshToken", .members = &.{ "access_token", "token_type", "expires_in" } },
    };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct { operation: []const u8, body: []const u8 };
    var cases: std.ArrayList(Case) = .empty;
    try cases.append(arena, .{ .operation = "metadata", .body = "<html>not json</html>" });
    for (required) |each| {
        for (each.members) |member| {
            var body = try std.json.parseFromSliceLeaky(std.json.Value, arena, every_required_member, .{});
            _ = body.object.orderedRemove(member);
            try cases.append(arena, .{ .operation = each.operation, .body = try corpus.json(arena, body) });
        }
    }

    for (cases.items) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try routeEveryPath(harness, .ok(case.body));
        var client = try harness.client(.{ .retries = 0 });
        defer client.deinit();

        var diagnostics: vpndetection.Diagnostics = .{};
        const args: corpus.OauthArgs = .{ .deviceCode = "x", .refreshToken = "x" };
        const outcome = callOperationWith(&client, case.operation, args, &diagnostics);
        std.testing.expectError(error.ServerError, outcome) catch |err| {
            std.debug.print("{s} {s}\n", .{ case.operation, case.body });
            return err;
        };
        try std.testing.expectEqual(@as(?u16, 200), diagnostics.status);
        try std.testing.expect(diagnostics.errorCode() == null);
    }
}

test "the poll follows every corpus case" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    for (data.value.oauth.poll.cases) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try harness.stub.sequence("/oauth/token", try routesFor(harness, case.responses));
        var url_buffer: [64]u8 = undefined;
        var client = try vpndetection.Client.init(gpa, FakeClock.install(harness.io()), .{
            .base_url = harness.stub.baseUrl(&url_buffer),
        });
        defer client.deinit();

        var diagnostics: vpndetection.Diagnostics = .{};
        const outcome = client.oauth().pollDeviceToken(case.clientId, case.device, .{
            .diagnostics = &diagnostics,
        });
        defer if (outcome) |token| token.deinit() else |_| {};

        const calls = harness.stub.seen();
        std.testing.expectEqual(case.expect.requests.?, calls.len) catch |err| {
            std.debug.print("{s}: requests\n", .{case.name});
            return err;
        };
        std.testing.expectEqualSlices(i64, case.expect.waits, FakeClock.waitsInSeconds()) catch |err| {
            std.debug.print("{s}: waits\n", .{case.name});
            return err;
        };
        for (calls) |call| {
            try std.testing.expectEqualStrings("POST", call.method);
            try std.testing.expectEqualStrings("/oauth/token", call.path);
            const fields = try decodeForm(harness.stub.arena.allocator(), call.body);
            try std.testing.expectEqual(3, fields.count());
            try std.testing.expectEqualStrings("urn:ietf:params:oauth:grant-type:device_code", fields.get("grant_type").?);
            try std.testing.expectEqualStrings(case.device.device_code, fields.get("device_code").?);
            try std.testing.expectEqualStrings(case.clientId, fields.get("client_id").?);
        }
        if (outcome) |token| {
            try std.testing.expectEqualStrings("token", case.expect.outcome.?);
            if (case.expect.token) |want| {
                try expectMembers(case.name, token.value, want, &.{});
            }
        } else |err| {
            try expectFailure(case.name, err, &diagnostics, case.expect, case.expect.outcome.?);
        }
    }
}

// The corpus's pending-then-token case on the real clock, within its tolerance,
// so the clock the case above replaces is known to be the one the poll uses.
test "the poll waits on the real clock" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const case = for (data.value.oauth.poll.cases) |candidate| {
        if (std.mem.eql(u8, candidate.name, "pending-then-token")) {
            break candidate;
        }
    } else unreachable;

    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.sequence("/oauth/token", try routesFor(harness, case.responses));
    var client = try harness.client(.{});
    defer client.deinit();

    const start = Io.Clock.awake.now(harness.io());
    const token = try client.oauth().pollDeviceToken(case.clientId, case.device, .{});
    defer token.deinit();
    const settled = start.durationTo(Io.Clock.awake.now(harness.io()));

    const calls = harness.stub.seen();
    try std.testing.expectEqual(case.expect.requests.?, calls.len);
    var previous = start;
    var total: i64 = 0;
    for (calls, case.expect.waits) |call, wait_s| {
        const gap_ms = previous.durationTo(call.at).toMilliseconds();
        try std.testing.expect(gap_ms >= wait_s * 1000 - 50);
        try std.testing.expect(gap_ms < wait_s * 1000 + 1000);
        previous = call.at;
        total += wait_s;
    }
    try std.testing.expect(settled.toMilliseconds() >= total * 1000 - 50);
    try std.testing.expectEqualStrings("mo_at_poll", token.value.access_token);
}

// A `slow_down` at the top of an i64 interval: `interval += 5` panicked with
// integer overflow in 4.3.2. It saturates, and the wait after it ends at the
// deadline rather than a full interval later.
test "a slow_down at the top of the interval saturates" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.sequence("/oauth/token", &.{.{ .status = 400, .body = "{\"error\":\"slow_down\"}" }});
    var url_buffer: [64]u8 = undefined;
    var client = try vpndetection.Client.init(gpa, FakeClock.install(harness.io()), .{
        .base_url = harness.stub.baseUrl(&url_buffer),
    });
    defer client.deinit();

    const max = std.math.maxInt(i64);
    try std.testing.expectError(error.OauthExpiredToken, client.oauth().pollDeviceToken(client_id, .{
        .device_code = "mo_dc_x",
        .user_code = "BCDF-GHJK",
        .verification_uri = "https://app.example.test/device",
        .expires_in = max,
        .interval = max - 2,
    }, .{}));
    try std.testing.expectEqual(1, harness.stub.seen().len);
    try std.testing.expectEqualSlices(i64, &.{ max - 2, 2 }, FakeClock.waitsInSeconds());
}

/// A `std.Io` whose `sleep` records the wait and returns at once, and whose
/// clock reads the sum of those waits, over a real `Io` for everything else.
/// Global state, because a vtable function receives only the real `Io`'s
/// userdata; the test runner runs one test at a time.
const FakeClock = struct {
    var vtable: Io.VTable = undefined;
    var waits: [wait_bound]i96 = undefined;
    var wait_count: usize = 0;
    var elapsed: i96 = 0;

    /// Past this many waits the process ends: the poll could shrug off an error
    /// from `sleep`, and a wait that never returns would hang the suite.
    const wait_bound = 16;

    fn install(real: Io) Io {
        vtable = real.vtable.*;
        vtable.now = now;
        vtable.sleep = sleep;
        wait_count = 0;
        elapsed = 0;
        return .{ .userdata = real.userdata, .vtable = &vtable };
    }

    fn waitsInSeconds() []const i64 {
        const S = struct {
            var seconds: [wait_bound]i64 = undefined;
        };
        for (waits[0..wait_count], 0..) |wait, i| {
            S.seconds[i] = @intCast(@divTrunc(wait, std.time.ns_per_s));
        }
        return S.seconds[0..wait_count];
    }

    fn now(_: ?*anyopaque, _: Io.Clock) Io.Timestamp {
        return .{ .nanoseconds = elapsed };
    }

    fn sleep(_: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
        if (wait_count == wait_bound) {
            std.debug.print("the poll waited {d} times without ending\n", .{wait_bound});
            std.process.exit(1);
        }
        const wait = timeout.duration.raw.nanoseconds;
        waits[wait_count] = wait;
        wait_count += 1;
        elapsed += wait;
    }
};

fn expectFailure(
    name: []const u8,
    err: vpndetection.OauthCallError,
    diagnostics: *const vpndetection.Diagnostics,
    want: corpus.OauthExpect,
    outcome: []const u8,
) !void {
    const got: []const u8 = switch (err) {
        error.OauthAccessDenied => "accessDenied",
        error.OauthExpiredToken => "expiredToken",
        error.OauthRejected => "oauth",
        else => "client",
    };
    std.testing.expectEqualStrings(outcome, got) catch |e| {
        std.debug.print("{s}: which error ({s})\n", .{ name, @errorName(err) });
        return e;
    };
    errdefer std.debug.print("{s}: {s}\n", .{ name, diagnostics.message() });
    if (want.errorCode) |code| {
        std.testing.expectEqualStrings(code, diagnostics.errorCode() orelse "(none)") catch |e| {
            std.debug.print("{s}: error code\n", .{name});
            return e;
        };
    }
    switch (want.errorDescription) {
        .string => |description| std.testing.expectEqualStrings(
            description,
            diagnostics.errorDescription() orelse "(none)",
        ) catch |e| {
            std.debug.print("{s}: description\n", .{name});
            return e;
        },
        .null => std.testing.expect(diagnostics.errorDescription() == null) catch |e| {
            std.debug.print("{s}: description\n", .{name});
            return e;
        },
        else => {},
    }
    switch (want.status) {
        .integer => |status| std.testing.expectEqual(@as(?u16, @intCast(status)), diagnostics.status) catch |e| {
            std.debug.print("{s}: status\n", .{name});
            return e;
        },
        .null => std.testing.expect(diagnostics.status == null) catch |e| {
            std.debug.print("{s}: status\n", .{name});
            return e;
        },
        else => {},
    }
    if (std.mem.eql(u8, got, "client")) {
        try std.testing.expect(diagnostics.errorCode() == null);
        const ordinary: vpndetection.CallError = switch (err) {
            error.OauthAccessDenied, error.OauthExpiredToken, error.OauthRejected => unreachable,
            else => |e| e,
        };
        if (want.kind) |kind| {
            try std.testing.expectEqualStrings(kind, vpndetection.kindName(ordinary));
        }
        if (want.retryable) |retryable| {
            try std.testing.expectEqual(retryable, vpndetection.isRetryable(ordinary));
        }
    }
}

/// Every present member has its value, and every absent one is null. Members
/// are matched to fields by name, which the types share with the wire except
/// for `apikey_id` and `apikey`, the names the corpus uses too.
fn expectMembers(
    name: []const u8,
    value: anytype,
    present: std.json.ArrayHashMap(std.json.Value),
    absent: []const []const u8,
) !void {
    for (present.map.keys(), present.map.values()) |member, want| {
        // Still in the corpus's metadata document, no longer served, and not a
        // member of this release's type (sdk-go 14e52de skips it too).
        if (std.mem.eql(u8, member, "client_id_metadata_document_supported")) {
            continue;
        }
        expectMember(value, member, want) catch |err| {
            std.debug.print("{s}: {s}\n", .{ name, member });
            return err;
        };
    }
    for (absent) |member| {
        expectAbsent(value, member) catch |err| {
            std.debug.print("{s}: {s} must be ABSENT\n", .{ name, member });
            return err;
        };
    }
}

fn expectMember(value: anytype, member: []const u8, want: std.json.Value) !void {
    inline for (std.meta.fields(@TypeOf(value))) |field| {
        if (std.mem.eql(u8, field.name, member)) {
            return expectValue(field.type, @field(value, field.name), want);
        }
    }
    return error.TestUnknownMember;
}

fn expectAbsent(value: anytype, member: []const u8) !void {
    inline for (std.meta.fields(@TypeOf(value))) |field| {
        if (std.mem.eql(u8, field.name, member)) {
            if (@typeInfo(field.type) != .optional) {
                return error.TestRequiredMemberCannotBeAbsent;
            }
            return std.testing.expect(@field(value, field.name) == null);
        }
    }
    return error.TestUnknownMember;
}

fn expectValue(comptime T: type, got: T, want: std.json.Value) !void {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            const inner = got orelse return error.TestExpectedPresent;
            return expectValue(optional.child, inner, want);
        },
        .bool => return std.testing.expectEqual(want.bool, got),
        .int => return std.testing.expectEqual(want.integer, got),
        .pointer => if (T == []const u8) {
            return std.testing.expectEqualStrings(want.string, got);
        } else {
            try std.testing.expectEqual(want.array.items.len, got.len);
            for (want.array.items, got) |item, element| {
                try std.testing.expectEqualStrings(item.string, element);
            }
        },
        else => return error.TestUnsupportedMemberType,
    }
}

fn callOperation(client: *vpndetection.Client, operation: []const u8, args: corpus.OauthArgs) !void {
    var diagnostics: vpndetection.Diagnostics = .{};
    return callOperationWith(client, operation, args, &diagnostics);
}

fn callOperationWith(
    client: *vpndetection.Client,
    operation: []const u8,
    args: corpus.OauthArgs,
    diagnostics: *vpndetection.Diagnostics,
) vpndetection.OauthCallError!void {
    const oauth = client.oauth();
    const id = args.clientId orelse client_id;
    const options: vpndetection.OauthOptions = .{ .diagnostics = diagnostics };
    if (std.mem.eql(u8, operation, "metadata")) {
        (try oauth.metadata(options)).deinit();
    } else if (std.mem.eql(u8, operation, "deviceAuthorization")) {
        (try oauth.deviceAuthorization(id, .{
            .scope = args.scope,
            .resource = args.resource,
            .diagnostics = diagnostics,
        })).deinit();
    } else if (std.mem.eql(u8, operation, "exchangeDeviceCode")) {
        (try oauth.exchangeDeviceCode(id, args.deviceCode orelse "", options)).deinit();
    } else if (std.mem.eql(u8, operation, "exchangeRefreshToken")) {
        (try oauth.exchangeRefreshToken(id, args.refreshToken orelse "", options)).deinit();
    } else if (std.mem.eql(u8, operation, "revoke")) {
        try oauth.revoke(id, args.token orelse "", options);
    } else {
        std.debug.panic("the corpus names an operation this release lacks: {s}", .{operation});
    }
}

fn endpointOf(operation: []const u8) []const u8 {
    if (std.mem.eql(u8, operation, "exchangeDeviceCode") or std.mem.eql(u8, operation, "exchangeRefreshToken")) {
        return "token";
    }
    return operation;
}

fn endpointNamed(oauth_data: corpus.Oauth, name: []const u8) corpus.Endpoint {
    inline for (std.meta.fields(@TypeOf(oauth_data.endpoints))) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return @field(oauth_data.endpoints, field.name);
        }
    }
    std.debug.panic("the corpus names no endpoint {s}", .{name});
}

fn expectSentTo(name: []const u8, call: support.Call, endpoint: corpus.Endpoint) !void {
    std.testing.expectEqualStrings(endpoint.method, call.method) catch |err| {
        std.debug.print("{s}: method\n", .{name});
        return err;
    };
    std.testing.expectEqualStrings(endpoint.path, call.path) catch |err| {
        std.debug.print("{s}: path\n", .{name});
        return err;
    };
}

fn routeEveryPath(harness: *Harness, route: Route) !void {
    for (oauth_paths) |path| {
        try harness.stub.route(path, route);
    }
}

fn servingCase(gpa: std.mem.Allocator, status: u16, body: std.json.Value) !*Harness {
    const harness = try Harness.start(gpa);
    errdefer harness.deinit();
    try routeEveryPath(harness, .{ .status = status, .body = try corpus.json(harness.stub.arena.allocator(), body) });
    return harness;
}

fn routesFor(harness: *Harness, responses: []const corpus.Served) ![]const Route {
    const arena = harness.stub.arena.allocator();
    const routes = try arena.alloc(Route, responses.len);
    for (responses, routes) |served, *route| {
        route.* = .{ .status = served.status, .body = try served.text(arena) };
    }
    return routes;
}

/// A form body decoded the way a server decodes one: `+` is a space and every
/// `%XX` a byte. A field sent twice is refused rather than read as its last.
fn decodeForm(arena: std.mem.Allocator, body: []const u8) !std.StringArrayHashMapUnmanaged([]const u8) {
    var fields: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const name = try decodeComponent(arena, pair[0..equals]);
        const value = try decodeComponent(arena, if (equals < pair.len) pair[equals + 1 ..] else "");
        const gop = try fields.getOrPut(arena, name);
        if (gop.found_existing) {
            return error.TestFieldSentTwice;
        }
        gop.value_ptr.* = value;
    }
    return fields;
}

fn decodeComponent(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const copy = try arena.dupe(u8, text);
    std.mem.replaceScalar(u8, copy, '+', ' ');
    return std.Uri.percentDecodeInPlace(copy);
}
