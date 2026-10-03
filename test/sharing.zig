//! Callers that miss the cache at the same moment share one request for an
//! address, a batch's included: every other caller waits for the leader's
//! answer or its failure, which is cached for no one. Each test holds the
//! request at a delayed stub, so the callers overlap while it is in flight.

const std = @import("std");
const vpndetection = @import("vpndetection");

const support = @import("support.zig");

const Harness = support.Harness;
const Io = std.Io;

const address = "45.83.91.1";
const other = "45.83.91.2";
const callers = 10;

fn lookUp(client: *vpndetection.Client, ip: []const u8) bool {
    var answer = client.lookup(ip) catch return false;
    defer answer.deinit();
    return std.mem.eql(u8, answer.value.ip, ip);
}

fn failsAsServerError(client: *vpndetection.Client, ip: []const u8) bool {
    var answer = client.lookup(ip) catch |err| return err == error.ServerError;
    answer.deinit();
    return false;
}

fn batchOf(client: *vpndetection.Client, ips: []const []const u8) bool {
    var batch = client.lookupBatch(ips, .{}) catch return false;
    defer batch.deinit();
    for (ips) |ip| {
        const entry = batch.entries.get(ip) orelse return false;
        if (entry != .ok) {
            return false;
        }
    }
    return true;
}

fn start(gpa: std.mem.Allocator, delay: Io.Duration) !*Harness {
    const harness = try Harness.start(gpa);
    errdefer harness.deinit();
    harness.stub.delay = delay;
    try harness.stub.routeLookup(address);
    try harness.stub.routeLookup(other);
    return harness;
}

test "concurrent lookups of one address send one request" {
    const harness = try start(std.testing.allocator, .fromMilliseconds(300));
    defer harness.deinit();
    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();
    const io = harness.io();

    var futures: [callers]Io.Future(bool) = undefined;
    for (&futures) |*future| {
        future.* = try io.concurrent(lookUp, .{ &client, address });
    }
    for (&futures) |*future| {
        try std.testing.expect(future.await(io));
    }
    try std.testing.expectEqual(1, harness.stub.callCount());
}

test "without a cache every lookup is served" {
    const harness = try start(std.testing.allocator, .fromMilliseconds(100));
    defer harness.deinit();
    var client = try harness.client(.{ .retries = 0, .cache = null });
    defer client.deinit();
    const io = harness.io();

    var futures: [callers]Io.Future(bool) = undefined;
    for (&futures) |*future| {
        future.* = try io.concurrent(lookUp, .{ &client, address });
    }
    for (&futures) |*future| {
        try std.testing.expect(future.await(io));
    }
    try std.testing.expectEqual(callers, harness.stub.callCount());
}

test "a shared failure reaches every waiter and is cached for none" {
    const harness = try Harness.start(std.testing.allocator);
    defer harness.deinit();
    harness.stub.delay = .fromMilliseconds(300);
    try harness.stub.sequence("/" ++ address, &.{
        .{ .status = 500, .body = "{\"error\":\"boom\"}" },
        .ok("{\"ip\":\"" ++ address ++ "\",\"is_vpn\":false}"),
    });
    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();
    const io = harness.io();

    var futures: [callers]Io.Future(bool) = undefined;
    for (&futures) |*future| {
        future.* = try io.concurrent(failsAsServerError, .{ &client, address });
    }
    for (&futures) |*future| {
        try std.testing.expect(future.await(io));
    }
    try std.testing.expectEqual(1, harness.stub.callCount());

    try std.testing.expect(lookUp(&client, address));
    try std.testing.expectEqual(2, harness.stub.callCount());
}

test "a batch waits for a lookup already in flight" {
    const harness = try start(std.testing.allocator, .fromMilliseconds(300));
    defer harness.deinit();
    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();
    const io = harness.io();

    var single = try io.concurrent(lookUp, .{ &client, address });
    try io.sleep(.fromMilliseconds(100), .awake);
    try std.testing.expect(batchOf(&client, &.{ address, other }));
    try std.testing.expect(single.await(io));

    try std.testing.expectEqual(2, harness.stub.callCount());
    for (harness.stub.seen()) |call| {
        if (std.mem.eql(u8, call.path, "/batch")) {
            try std.testing.expect(std.mem.indexOf(u8, call.body, address) == null);
            try std.testing.expect(std.mem.indexOf(u8, call.body, other) != null);
        }
    }
}

test "a lookup waits for a batch already in flight" {
    const harness = try start(std.testing.allocator, .fromMilliseconds(300));
    defer harness.deinit();
    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();
    const io = harness.io();

    var batch = try io.concurrent(batchOf, .{ &client, &[_][]const u8{ address, other } });
    try io.sleep(.fromMilliseconds(100), .awake);
    try std.testing.expect(lookUp(&client, address));
    try std.testing.expect(batch.await(io));

    try std.testing.expectEqual(1, harness.stub.callCount());
    try std.testing.expect(harness.stub.calledOnly("/batch"));
}

test "a waiter whose leader was canceled asks again" {
    const harness = try start(std.testing.allocator, .fromMilliseconds(300));
    defer harness.deinit();
    var client = try harness.client(.{});
    defer client.deinit();
    const io = harness.io();

    var leader = try io.concurrent(lookUp, .{ &client, address });
    try io.sleep(.fromMilliseconds(100), .awake);
    var waiter = try io.concurrent(lookUp, .{ &client, address });
    try io.sleep(.fromMilliseconds(50), .awake);
    try std.testing.expect(!leader.cancel(io));

    try std.testing.expect(waiter.await(io));
    try std.testing.expectEqual(2, harness.stub.callCount());
}

test "a canceled waiter returns at once and leaves the request to its leader" {
    // The leader lands seconds after the cancel, so a waiter that held on to it
    // is told apart from a slow runner.
    const harness = try start(std.testing.allocator, .fromSeconds(2));
    defer harness.deinit();
    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();
    const io = harness.io();

    var leader = try io.concurrent(lookUp, .{ &client, address });
    try io.sleep(.fromMilliseconds(100), .awake);
    var waiter = try io.concurrent(lookUp, .{ &client, address });
    try io.sleep(.fromMilliseconds(50), .awake);
    const canceled = Io.Clock.awake.now(io);
    try std.testing.expect(!waiter.cancel(io));
    try std.testing.expect(canceled.durationTo(Io.Clock.awake.now(io)).nanoseconds < std.time.ns_per_s);

    try std.testing.expect(leader.await(io));
    try std.testing.expectEqual(1, harness.stub.callCount());
}
