//! The user agent of the request being decided on: sent as `user_agent` with a
//! lookup or `myIp`, and as `user_agents` with a batch, keyed by each address
//! as `ips` sends it. Answers are cached and shared on the address and the
//! agent together; a bogon carries none and sends nothing.

const std = @import("std");
const vpndetection = @import("vpndetection");

const support = @import("support.zig");

const Harness = support.Harness;
const Io = std.Io;

const address = "45.83.91.1";
const googlebot = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html) a&b=c#d%e";
// Every reserved character percent-encoded, `+` and the space included.
const googlebot_encoded = "Mozilla%2F5.0%20%28compatible%3B%20Googlebot%2F2.1%3B%20%2Bhttp%3A%2F%2Fwww.google.com%2Fbot.html%29%20a%26b%3Dc%23d%25e";
const verdict =
    \\{"ip":"45.83.91.1","is_vpn":false,"user_agent":{"agent":"Googlebot","kind":"bot","verdict":"verified"}}
;

fn targets(harness: *Harness) []const support.Call {
    return harness.stub.seen();
}

test "a lookup and myIp send the agent percent-encoded, and the answer carries its verdict" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/" ++ address, .ok(verdict));
    try harness.stub.route("/myip", .ok(verdict));
    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();

    {
        const answer = try client.lookupWith(address, .{ .user_agent = googlebot });
        defer answer.deinit();
        const got = answer.value.user_agent.?;
        try std.testing.expectEqualStrings("Googlebot", got.agent);
        try std.testing.expectEqualStrings("bot", got.kind);
        try std.testing.expectEqualStrings("verified", got.verdict);
    }
    for (0..2) |_| {
        const answer = try client.myIpWith(.{ .user_agent = googlebot });
        defer answer.deinit();
        try std.testing.expectEqualStrings("verified", answer.value.user_agent.?.verdict);
    }
    const calls = harness.stub.seen();
    // myIp stays uncached with an agent too.
    try std.testing.expectEqual(3, calls.len);
    try std.testing.expectEqualStrings("/" ++ address ++ "?user_agent=" ++ googlebot_encoded, calls[0].target);
    try std.testing.expectEqualStrings("/myip?user_agent=" ++ googlebot_encoded, calls[1].target);
    try std.testing.expectEqualStrings("/myip?user_agent=" ++ googlebot_encoded, calls[2].target);
}

test "no agent, or an empty one, sends none and the answer carries none" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup(address);
    try harness.stub.routeLookup("45.83.91.2");
    try harness.stub.route("/myip", .ok("{\"ip\":\"45.83.91.1\",\"is_vpn\":false}"));
    var client = try harness.client(.{ .retries = 0, .cache = null });
    defer client.deinit();

    {
        const answer = try client.lookup(address);
        defer answer.deinit();
        try std.testing.expect(answer.value.user_agent == null);
    }
    {
        const answer = try client.lookupWith("45.83.91.2", .{ .user_agent = "" });
        answer.deinit();
    }
    {
        const answer = try client.myIpWith(.{ .user_agent = "" });
        answer.deinit();
    }
    const calls = harness.stub.seen();
    try std.testing.expectEqual(3, calls.len);
    try std.testing.expectEqualStrings("/" ++ address, calls[0].target);
    try std.testing.expectEqualStrings("/45.83.91.2", calls[1].target);
    try std.testing.expectEqualStrings("/myip", calls[2].target);
}

test "an agent longer than the API reads is sent whole" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup(address);
    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();

    const long = "a" ** 2000;
    const answer = try client.lookupWith(address, .{ .user_agent = long });
    answer.deinit();
    const calls = harness.stub.seen();
    try std.testing.expectEqual(1, calls.len);
    try std.testing.expectEqualStrings("/" ++ address ++ "?user_agent=" ++ long, calls[0].target);
}

test "the cache keys on the address and the agent together" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup(address);
    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();

    for ([_][]const u8{ "", "agent-one", "agent-two", "agent-one", "", "agent-two" }) |agent| {
        const answer = try client.lookupWith(address, .{ .user_agent = agent });
        answer.deinit();
    }
    // The plain answer, then one per agent; every repeat is a hit.
    const calls = harness.stub.seen();
    try std.testing.expectEqual(3, calls.len);
    try std.testing.expectEqualStrings("/" ++ address, calls[0].target);
    try std.testing.expectEqualStrings("/" ++ address ++ "?user_agent=agent-one", calls[1].target);
    try std.testing.expectEqualStrings("/" ++ address ++ "?user_agent=agent-two", calls[2].target);
}

fn lookUpAs(client: *vpndetection.Client, agent: []const u8) bool {
    var answer = client.lookupWith(address, .{ .user_agent = agent }) catch return false;
    defer answer.deinit();
    return std.mem.eql(u8, answer.value.ip, address);
}

test "concurrent misses for one address and agent share one request" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    harness.stub.delay = .fromMilliseconds(300);
    try harness.stub.routeLookup(address);
    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();
    const io = harness.io();

    var futures: [12]Io.Future(bool) = undefined;
    for (&futures, 0..) |*future, i| {
        future.* = try io.concurrent(lookUpAs, .{ &client, if (i % 2 == 0) "agent-one" else "agent-two" });
    }
    for (&futures) |*future| {
        try std.testing.expect(future.await(io));
    }
    // One request per agent, never one per caller nor one for both.
    const calls = harness.stub.seen();
    try std.testing.expectEqual(2, calls.len);
    var one: usize = 0;
    for (calls) |call| {
        if (std.mem.eql(u8, call.target, "/" ++ address ++ "?user_agent=agent-one")) one += 1;
    }
    try std.testing.expectEqual(1, one);
}

test "a bogon carries no agent and sends nothing" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();

    const answer = try client.lookupWith("10.0.0.1", .{ .user_agent = googlebot });
    defer answer.deinit();
    try std.testing.expect(answer.is_bogon);
    try std.testing.expect(answer.value.user_agent == null);

    var agents: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer agents.deinit(gpa);
    try agents.put(gpa, "10.0.0.2", googlebot);
    var batch = try client.lookupBatch(&.{ "10.0.0.2", "192.168.0.1" }, .{ .user_agents = agents });
    defer batch.deinit();
    for (batch.values()) |entry| {
        try std.testing.expect(entry.ok.is_bogon);
        try std.testing.expect(entry.ok.value.user_agent == null);
    }
    try std.testing.expectEqual(0, harness.stub.callCount());
}

const BatchBody = struct {
    ips: []const []const u8,
    user_agents: ?std.json.ArrayHashMap([]const u8) = null,
};

test "a batch sends each agent keyed by the address as ips sends it" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    for ([_][]const u8{ "8.8.8.8", "1.1.1.1", "9.9.9.9" }) |ip| try harness.stub.routeLookup(ip);
    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();

    var agents: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer agents.deinit(gpa);
    try agents.put(gpa, "8.8.8.8", "agent-a");
    try agents.put(gpa, "::ffff:1.1.1.1", "agent-b");
    try agents.put(gpa, "9.9.9.9", "");
    try agents.put(gpa, "10.0.0.1", "agent-c");
    var batch = try client.lookupBatch(&.{ "8.8.8.8", "::ffff:1.1.1.1", "9.9.9.9", "10.0.0.1" }, .{ .user_agents = agents });
    defer batch.deinit();
    for (batch.values()) |entry| try std.testing.expect(entry == .ok);
    try std.testing.expect(batch.get("10.0.0.1").?.ok.value.user_agent == null);

    const calls = harness.stub.seen();
    try std.testing.expectEqual(1, calls.len);
    const body = try std.json.parseFromSlice(BatchBody, gpa, calls[0].body, .{});
    defer body.deinit();
    try std.testing.expectEqual(3, body.value.ips.len);
    const sent = body.value.user_agents.?.map;
    try std.testing.expectEqual(2, sent.count());
    try std.testing.expectEqualStrings("agent-a", sent.get("8.8.8.8").?);
    try std.testing.expectEqualStrings("agent-b", sent.get("1.1.1.1").?);

    // Each answer is cached on its pair: the same pair is a hit, the plain
    // address is not.
    {
        const hit = try client.lookupWith("8.8.8.8", .{ .user_agent = "agent-a" });
        hit.deinit();
    }
    try std.testing.expectEqual(1, harness.stub.callCount());
    {
        const plain = try client.lookup("8.8.8.8");
        plain.deinit();
    }
    try std.testing.expectEqual(2, harness.stub.callCount());
}

test "a batch where no address carries an agent sends no user_agents" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    for ([_][]const u8{ "8.8.8.8", "1.1.1.1" }) |ip| try harness.stub.routeLookup(ip);
    var client = try harness.client(.{ .retries = 0, .cache = null });
    defer client.deinit();

    var agents: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer agents.deinit(gpa);
    try agents.put(gpa, "1.1.1.1", "");
    try agents.put(gpa, "10.0.0.1", "agent-c");
    for ([_]vpndetection.BatchOptions{ .{}, .{ .user_agents = agents } }) |options| {
        var batch = try client.lookupBatch(&.{ "8.8.8.8", "1.1.1.1", "10.0.0.1" }, options);
        batch.deinit();
    }
    const calls = harness.stub.seen();
    try std.testing.expectEqual(2, calls.len);
    for (calls) |call| {
        try std.testing.expect(std.mem.indexOf(u8, call.body, "user_agents") == null);
    }
}

test "one address asked under two spellings with two agents is answered for each" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");
    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();

    var agents: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer agents.deinit(gpa);
    try agents.put(gpa, "1.1.1.1", "agent-a");
    try agents.put(gpa, "::ffff:1.1.1.1", "agent-b");
    var batch = try client.lookupBatch(&.{ "1.1.1.1", "::ffff:1.1.1.1", "::ffff:0101:0101" }, .{ .user_agents = agents });
    defer batch.deinit();
    for (batch.values()) |entry| try std.testing.expectEqualStrings("1.1.1.1", entry.ok.value.ip);

    // A request holds an address once, so the second agent goes on its own;
    // the third spelling, with no agent, is the plain answer, a third pair.
    const calls = harness.stub.seen();
    var sent_b = false;
    for (calls) |call| {
        if (std.mem.eql(u8, call.target, "/1.1.1.1?user_agent=agent-b")) sent_b = true;
        if (std.mem.eql(u8, call.path, "/batch")) {
            const body = try std.json.parseFromSlice(BatchBody, gpa, call.body, .{});
            defer body.deinit();
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(gpa);
            for (body.value.ips) |ip| try std.testing.expect(!(try seen.getOrPut(gpa, ip)).found_existing);
        }
    }
    try std.testing.expect(sent_b);
}
