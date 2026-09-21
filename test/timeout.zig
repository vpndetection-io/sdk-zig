//! The per-attempt timeout, on real sockets: a body that stalls after its head,
//! one trickled a byte at a time, the per-call value against the client's, a
//! download that outlives the bound, and what cancelation leaves behind.

const std = @import("std");
const vpndetection = @import("vpndetection");

const support = @import("support.zig");

const Diagnostics = vpndetection.Diagnostics;
const Harness = support.Harness;
const Io = std.Io;
const Route = support.Route;

const ip = "9.9.9.9";
const lookup_body = "{\"ip\":\"9.9.9.9\",\"is_vpn\":false}";
/// Longer than any bound under test, so an unbounded call fails its elapsed
/// assertion instead of hanging. Tearing the stub down ends it early.
const stall: Io.Duration = .fromSeconds(5);
/// How late past its bound a canceled attempt may still return.
const slack_ms = 1000;

// No single read waits more than 20 ms here, so only a bound on the whole
// attempt ends it. The stub then proves the attempt is gone rather than left
// running: its next write finds the connection closed.
test "a trickled body times out at the bound and its connection is dropped" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/" ++ ip, .{
        .body = (" " ** 300) ++ lookup_body,
        .trickle = .fromMilliseconds(20),
    });
    var client = try harness.client(.{ .retries = 0, .timeout = .fromMilliseconds(250) });
    defer client.deinit();

    var diagnostics: Diagnostics = .{};
    const start = Io.Clock.awake.now(harness.io());
    const outcome = lookupOnce(&client, .{ .diagnostics = &diagnostics });
    const took_ms = since(harness, start);
    try expectTimedOut("trickled body", outcome, &diagnostics, took_ms, 250, 250 + slack_ms);

    var waited_ms: usize = 0;
    while (harness.stub.hangupCount() == 0 and waited_ms < 1000) : (waited_ms += 10) {
        try harness.io().sleep(.fromMilliseconds(10), .awake);
    }
    std.testing.expectEqual(1, harness.stub.hangupCount()) catch |err| {
        std.debug.print("the timed-out attempt never dropped its connection\n", .{});
        return err;
    };
}

test "a body that stalls after its head times out at the client's bound" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/" ++ ip, stalledBody(lookup_body));
    var client = try harness.client(.{ .retries = 0, .timeout = .fromMilliseconds(250) });
    defer client.deinit();

    var diagnostics: Diagnostics = .{};
    const start = Io.Clock.awake.now(harness.io());
    const outcome = lookupOnce(&client, .{ .diagnostics = &diagnostics });
    const took_ms = since(harness, start);
    try expectTimedOut("stalled body", outcome, &diagnostics, took_ms, 250, 250 + slack_ms);
    try std.testing.expectEqual(1, harness.stub.callCount());
}

// The client's own bound is well above the call's, so a call that ignores its
// value fails on elapsed time; the second call then shows the first did not
// leave its value behind.
test "a per-call timeout below the client's fires, and the next call keeps the client's" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/" ++ ip, stalledBody(lookup_body));
    var client = try harness.client(.{ .retries = 0, .timeout = .fromMilliseconds(1000) });
    defer client.deinit();

    var diagnostics: Diagnostics = .{};
    var start = Io.Clock.awake.now(harness.io());
    var outcome = lookupOnce(&client, .{ .timeout = .fromMilliseconds(250), .diagnostics = &diagnostics });
    var took_ms = since(harness, start);
    try expectTimedOut("per-call value", outcome, &diagnostics, took_ms, 250, 900);

    start = Io.Clock.awake.now(harness.io());
    outcome = lookupOnce(&client, .{ .diagnostics = &diagnostics });
    took_ms = since(harness, start);
    try expectTimedOut("client value after it", outcome, &diagnostics, took_ms, 1000, 1000 + slack_ms);
}

// Zero or below, every attempt times out before it starts, so the call would
// fail as a network error only after the whole backoff; past the bound the
// deadline overflows and the process panics. Both are refused where they are
// set, on every call, before a request.
test "a timeout no attempt can meet is refused before any request" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v1/database/list", .ok("{\"databases\":[]}"));
    try routeDownload(harness, .ok("unused"));
    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .retries = 2 });
    defer client.deinit();
    const database = client.database();
    const oauth = client.oauth();

    const refused = [_]Io.Duration{
        .zero,
        .fromMilliseconds(-5000),
        .fromNanoseconds(std.math.maxInt(i64) + 1),
        .max,
    };
    for (refused) |timeout| {
        var diagnostics: Diagnostics = .{};
        const options: vpndetection.CallOptions = .{ .timeout = timeout, .diagnostics = &diagnostics };
        const oauth_options: vpndetection.OauthOptions = .{ .timeout = timeout, .diagnostics = &diagnostics };
        const start = Io.Clock.awake.now(harness.io());
        try std.testing.expectError(error.BadRequest, client.lookupWith(ip, options));
        try std.testing.expectError(error.BadRequest, client.myIpWith(options));
        try std.testing.expectError(error.BadRequest, client.myEntitlementWith(options));
        var batch = try client.lookupBatch(&.{ ip, "8.8.8.8" }, .{ .timeout = timeout });
        defer batch.deinit();
        for (batch.values()) |entry| {
            try std.testing.expectEqual(error.BadRequest, entry.failed.err);
        }
        try std.testing.expectError(error.BadRequest, database.list(options));
        try std.testing.expectError(error.BadRequest, database.metadata("x", options));
        try std.testing.expectError(error.BadRequest, database.checksums("x", .mmdb, options));
        try std.testing.expectError(error.BadRequest, database.downloads(null, options));
        try std.testing.expectError(error.BadRequest, database.downloadUrl("x", .mmdb, options));
        try std.testing.expectError(error.BadRequest, database.downloadBytes("x", .mmdb, options));
        try std.testing.expectError(error.BadRequest, database.download(
            "x",
            .mmdb,
            scratch.path("x.mmdb"),
            options,
        ));
        try std.testing.expectError(error.BadRequest, oauth.metadata(oauth_options));
        try std.testing.expectError(error.BadRequest, oauth.deviceAuthorization("x", .{
            .timeout = timeout,
            .diagnostics = &diagnostics,
        }));
        try std.testing.expectError(error.BadRequest, oauth.exchangeDeviceCode("x", "x", oauth_options));
        try std.testing.expectError(error.BadRequest, oauth.exchangeRefreshToken("x", "x", oauth_options));
        try std.testing.expectError(error.BadRequest, oauth.revoke("x", "x", oauth_options));
        // Refused rather than retried: the first backoff alone is 250 ms.
        try std.testing.expect(since(harness, start) < 250);
        try std.testing.expect(std.mem.startsWith(u8, diagnostics.message(), "timeout must be positive"));
        // The poll waits out its interval before the request it bounds.
        try std.testing.expectError(error.BadRequest, oauth.pollDeviceToken("x", .{
            .device_code = "x",
            .user_code = "x",
            .verification_uri = "x",
            .expires_in = 60,
            .interval = 1,
        }, oauth_options));
    }
    try std.testing.expectEqual(0, harness.stub.callCount());
    try std.testing.expect(!scratch.exists("x.mmdb.part"));

    // The bound itself is a timeout like any other.
    (try database.list(.{ .timeout = .fromNanoseconds(std.math.maxInt(i64)) })).deinit();
    try std.testing.expectEqual(1, harness.stub.callCount());
}

// Every call with a per-call options surface, each against the one path it
// stalls. The client's bound is far above the call's, so each call that
// ignores its own value fails on elapsed time.
test "every call honors its own timeout" {
    const gpa = std.testing.allocator;
    for (std.meta.tags(Call)) |call| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();
        try call.stall(harness);
        var client = try harness.client(.{ .retries = 0, .timeout = .fromMilliseconds(2000) });
        defer client.deinit();

        var diagnostics: Diagnostics = .{};
        const start = Io.Clock.awake.now(harness.io());
        const outcome = call.run(&client, .fromMilliseconds(250), &diagnostics);
        const took_ms = since(harness, start);
        // The poll waits out its interval before the request it bounds.
        const floor_ms: i64 = if (call == .poll) 1250 else 250;
        try expectTimedOut(@tagName(call), outcome, &diagnostics, took_ms, floor_ms, floor_ms + slack_ms);
    }
}

// One deadline for the whole call would leave the retry none to spend.
test "each retry gets the whole bound again" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const arena = harness.stub.arena.allocator();
    const answers = try arena.dupe(Route, &.{ stalledBody(lookup_body), .ok(lookup_body) });
    try harness.stub.sequence("/" ++ ip, answers);
    var client = try harness.client(.{ .retries = 1, .timeout = .fromMilliseconds(250) });
    defer client.deinit();

    const result = try client.lookup(ip);
    defer result.deinit();
    try std.testing.expectEqualStrings(ip, result.value.ip);
    try std.testing.expectEqual(2, harness.stub.callCount());
}

test "a download that runs past the timeout still completes" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const body = "0123456789abcdef" ** 4;
    try routeDownload(harness, .{ .body = body, .stall = .fromMilliseconds(600), .stall_after = 16 });

    var scratch = support.Scratch.start();
    defer scratch.deinit();
    var client = try harness.client(.{ .api_key = "key", .retries = 0, .timeout = .fromMilliseconds(200) });
    defer client.deinit();

    var diagnostics: Diagnostics = .{};
    var start = Io.Clock.awake.now(harness.io());
    const written = client.database().download("cdn_ip_v1", .csvgz, scratch.path("data.csv.gz"), .{
        .diagnostics = &diagnostics,
    }) catch |err| {
        std.debug.print("download failed after {d} ms: {s} {s}\n", .{
            since(harness, start), @errorName(err), diagnostics.message(),
        });
        return err;
    };
    try std.testing.expect(since(harness, start) >= 600);
    try std.testing.expectEqual(body.len, written);
    var read_buffer: [128]u8 = undefined;
    try std.testing.expectEqualSlices(u8, body, try scratch.read("data.csv.gz", &read_buffer));

    start = Io.Clock.awake.now(harness.io());
    const options: vpndetection.CallOptions = .{ .diagnostics = &diagnostics };
    const bytes = client.database().downloadBytes("cdn_ip_v1", .csvgz, options) catch |err| {
        std.debug.print("downloadBytes failed after {d} ms: {s} {s}\n", .{
            since(harness, start), @errorName(err), diagnostics.message(),
        });
        return err;
    };
    defer gpa.free(bytes);
    try std.testing.expect(since(harness, start) >= 600);
    try std.testing.expectEqualSlices(u8, body, bytes);
}

// The bound's own wait is a cancelation point. Canceling the task running a
// call ends it at once, and ends its retries with it.
test "canceling the task that runs a call ends the call at once" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/" ++ ip, stalledBody(lookup_body));
    var client = try harness.client(.{ .retries = 2, .timeout = .fromSeconds(3) });
    defer client.deinit();

    const io = harness.io();
    var task = try io.concurrent(lookupTask, .{&client});
    try io.sleep(.fromMilliseconds(200), .awake);
    const start = Io.Clock.awake.now(io);
    const outcome = task.cancel(io);
    const took_ms = since(harness, start);
    try std.testing.expectError(error.Network, outcome);
    if (took_ms >= slack_ms) {
        std.debug.print("the canceled call took {d} ms to end\n", .{took_ms});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(1, harness.stub.callCount());
}

// Through `std.Io` itself, as test/oauth.zig replaces the clock: an `Io` with
// no task to race the attempt on runs it inline rather than failing the call.
test "a call completes on an Io that cannot start a concurrent task" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup(ip);
    try harness.stub.routeLookup("1.1.1.1");
    var url_buffer: [64]u8 = undefined;
    var client = try vpndetection.Client.init(gpa, NoConcurrency.install(harness.io()), .{
        .base_url = harness.stub.baseUrl(&url_buffer),
        .timeout = .fromMilliseconds(250),
    });
    defer client.deinit();

    const result = try client.lookup(ip);
    defer result.deinit();
    var batch = try client.lookupBatch(&.{ ip, "1.1.1.1" }, .{ .concurrency = 2 });
    defer batch.deinit();
    try std.testing.expect(batch.get("1.1.1.1").? == .ok);
}

/// Every call that takes a per-call timeout, by the path its request goes to.
const Call = enum {
    lookup,
    my_ip,
    my_entitlement,
    batch,
    list,
    metadata,
    checksums,
    downloads,
    download_url,
    download,
    download_bytes,
    oauth_metadata,
    device_authorization,
    exchange_device_code,
    exchange_refresh_token,
    revoke,
    poll,

    fn stall(call: Call, harness: *Harness) !void {
        const stub = harness.stub;
        switch (call) {
            .lookup => try stub.route("/" ++ ip, stalledBody(lookup_body)),
            .my_ip => try stub.route("/myip", stalledBody(lookup_body)),
            .my_entitlement => try stub.route("/api/v1/entitlement", stalledBody("{\"org_id\":\"x\"}")),
            .batch => try stub.route("/batch", stalledBody("")),
            .list => try stub.route("/api/v1/database/list", stalledBody("{\"databases\":[]}")),
            .metadata => try stub.route("/api/v1/database/metadata", stalledBody("{\"id\":\"x\"}")),
            .checksums => try stub.route("/api/v1/database/checksum", stalledBody("{\"id\":\"x\"}")),
            .downloads => try stub.route("/api/v1/database/downloads", stalledBody("{\"downloads\":[]}")),
            .download_url => try stub.route("/api/v1/database/download", stalledHead()),
            .download, .download_bytes => try routeDownload(harness, stalledHead()),
            .oauth_metadata => {
                try stub.route("/.well-known/oauth-authorization-server", stalledBody("{\"issuer\":\"x\"}"));
            },
            .device_authorization => {
                try stub.route("/oauth/device_authorization", stalledBody("{\"device_code\":\"x\"}"));
            },
            .exchange_device_code, .exchange_refresh_token, .poll => {
                try stub.route("/oauth/token", stalledBody("{\"access_token\":\"x\"}"));
            },
            .revoke => try stub.route("/oauth/revoke", stalledBody("{\"revoked\":true}")),
        }
    }

    /// Makes the call, freeing whatever it answers: an answer is the failure
    /// here, and the caller reports it.
    fn run(call: Call, client: *vpndetection.Client, timeout: Io.Duration, diag: *Diagnostics) anyerror!void {
        const options: vpndetection.CallOptions = .{ .timeout = timeout, .diagnostics = diag };
        const oauth: vpndetection.OauthOptions = .{ .timeout = timeout, .diagnostics = diag };
        const database = client.database();
        switch (call) {
            .lookup => (try client.lookupWith(ip, options)).deinit(),
            .my_ip => (try client.myIpWith(options)).deinit(),
            .my_entitlement => (try client.myEntitlementWith(options)).deinit(),
            .batch => {
                var batch = try client.lookupBatch(&.{ip}, .{ .timeout = timeout });
                defer batch.deinit();
                switch (batch.get(ip).?) {
                    .ok => {},
                    .failed => |failure| {
                        diag.* = failure.diagnostics;
                        return failure.err;
                    },
                }
            },
            .list => (try database.list(options)).deinit(),
            .metadata => (try database.metadata("x", options)).deinit(),
            .checksums => (try database.checksums("x", .mmdb, options)).deinit(),
            .downloads => (try database.downloads(null, options)).deinit(),
            .download_url => client.gpa.free(try database.downloadUrl("x", .mmdb, options)),
            .download => {
                var scratch = support.Scratch.start();
                defer scratch.deinit();
                _ = try database.download("x", .mmdb, scratch.path("x.mmdb"), options);
            },
            .download_bytes => client.gpa.free(try database.downloadBytes("x", .mmdb, options)),
            .oauth_metadata => (try client.oauth().metadata(oauth)).deinit(),
            .device_authorization => (try client.oauth().deviceAuthorization("x", .{
                .timeout = timeout,
                .diagnostics = diag,
            })).deinit(),
            .exchange_device_code => (try client.oauth().exchangeDeviceCode("x", "x", oauth)).deinit(),
            .exchange_refresh_token => (try client.oauth().exchangeRefreshToken("x", "x", oauth)).deinit(),
            .revoke => try client.oauth().revoke("x", "x", oauth),
            .poll => (try client.oauth().pollDeviceToken("x", .{
                .device_code = "x",
                .user_code = "x",
                .verification_uri = "x",
                .expires_in = 60,
                .interval = 1,
            }, oauth)).deinit(),
        }
    }
};

/// Elapsed time first, because a call that failed the right way at the wrong
/// bound is the regression a weaker check lets through.
fn expectTimedOut(
    name: []const u8,
    outcome: anyerror!void,
    diagnostics: *const Diagnostics,
    took_ms: i64,
    at_least_ms: i64,
    below_ms: i64,
) !void {
    if (took_ms < at_least_ms or took_ms >= below_ms) {
        std.debug.print("{s}: took {d} ms, expected {d} to {d}\n", .{ name, took_ms, at_least_ms, below_ms });
        return error.TestUnexpectedResult;
    }
    if (outcome) |_| {
        std.debug.print("{s}: answered instead of timing out\n", .{name});
        return error.TestUnexpectedResult;
    } else |err| if (err != error.Network) {
        std.debug.print("{s}: failed with {s}, not as a network error\n", .{ name, @errorName(err) });
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, diagnostics.message(), "timed out") == null) {
        std.debug.print("{s}: the timeout was reported as \"{s}\"\n", .{ name, diagnostics.message() });
        return error.TestUnexpectedResult;
    }
}

fn lookupOnce(client: *vpndetection.Client, options: vpndetection.CallOptions) anyerror!void {
    const result = try client.lookupWith(ip, options);
    result.deinit();
}

fn lookupTask(client: *vpndetection.Client) vpndetection.CallError!void {
    const result = try client.lookup(ip);
    result.deinit();
}

fn since(harness: *Harness, start: Io.Timestamp) i64 {
    return start.durationTo(Io.Clock.awake.now(harness.io())).toMilliseconds();
}

/// The head and a few bytes at once, then nothing for longer than any bound.
fn stalledBody(body: []const u8) Route {
    return .{ .body = body, .stall = stall, .stall_after = @min(body.len, 8) };
}

/// Nothing at all for longer than any bound, not even the status line.
fn stalledHead() Route {
    return .{ .body = "{}", .stall = stall, .stall_after = null };
}

const storage_path = "/storage/x.mmdb";

/// The download endpoint answers at once, pointing at `file` on the same stub.
fn routeDownload(harness: *Harness, file: Route) !void {
    const arena = harness.stub.arena.allocator();
    var url_buffer: [64]u8 = undefined;
    const location = try harness.stub.printed("{s}" ++ storage_path, .{harness.stub.baseUrl(&url_buffer)});
    const headers = try arena.dupe(Route.Header, &.{.{ .name = "Location", .value = location }});
    try harness.stub.route("/api/v1/database/download", .{ .status = 302, .headers = headers });
    try harness.stub.route(storage_path, file);
}

/// A `std.Io` whose `concurrent` always refuses, over a real one for everything
/// else. Global state, because a vtable function receives only the userdata.
const NoConcurrency = struct {
    var vtable: Io.VTable = undefined;

    fn install(real: Io) Io {
        vtable = real.vtable.*;
        vtable.concurrent = refuse;
        return .{ .userdata = real.userdata, .vtable = &vtable };
    }

    fn refuse(
        _: ?*anyopaque,
        _: usize,
        _: std.mem.Alignment,
        _: []const u8,
        _: std.mem.Alignment,
        _: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) Io.ConcurrentError!*Io.AnyFuture {
        return error.ConcurrencyUnavailable;
    }
};
