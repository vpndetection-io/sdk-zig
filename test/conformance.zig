//! Asserts the shared conformance corpus that every VPNDetection SDK asserts.
//!
//! The corpus is generated into testdata/ and is identical across languages, so
//! a behavior that drifts here fails here rather than surfacing as two client
//! libraries quietly disagreeing about the same address.

const std = @import("std");
const vpndetection = @import("vpndetection");

const support = @import("support.zig");
const corpus = support.corpus;

const Harness = support.Harness;
const Route = support.Route;

test "isBogon matches the canonical ranges" {
    const data = try corpus.load(std.testing.allocator);
    defer data.deinit();

    for (data.value.isBogon) |case| {
        std.testing.expectEqual(case.expect, vpndetection.isBogon(case.ip)) catch |err| {
            std.debug.print("isBogon({s}) should be {} ({s})\n", .{ case.ip, case.expect, case.why });
            return err;
        };
    }
}

test "a bogon is answered locally in the full max shape" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    const harness = try Harness.start(gpa);
    defer harness.deinit();
    var client = try harness.client(.{});
    defer client.deinit();

    const result = try client.lookup("10.0.0.1");
    defer result.deinit();

    try std.testing.expect(result.is_bogon);
    try std.testing.expectEqualStrings("10.0.0.1", result.value.ip);
    for (data.value.bogonResponse.flagsFalse) |name| {
        try std.testing.expectEqual(corpus.Member{ .flag = false }, corpus.member(result.value, name));
    }
    for (data.value.bogonResponse.emptyObjects) |name| {
        try std.testing.expectEqual(corpus.Member.empty_object, corpus.member(result.value, name));
    }
    try std.testing.expectEqual(0, harness.stub.callCount());
}

test "a lookup preserves absent versus false across every plan shape" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    for (data.value.lookup) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();

        const ip = case.body.object.get("ip").?.string;
        const body = try corpus.json(harness.stub.arena.allocator(), case.body);
        try harness.stub.route(try harness.stub.printed("/{s}", .{ip}), .{
            .status = case.status,
            .body = body,
        });

        var client = try harness.client(.{});
        defer client.deinit();
        const result = try client.lookup(ip);
        defer result.deinit();

        try std.testing.expectEqualStrings(case.expect.ip, result.value.ip);
        try std.testing.expectEqual(case.expect.isBogon, result.is_bogon);
        for (case.expect.present.map.keys(), case.expect.present.map.values()) |name, want| {
            std.testing.expectEqual(
                corpus.Member{ .flag = want },
                corpus.member(result.value, name),
            ) catch |err| {
                std.debug.print("{s}: {s} must be present and {}\n", .{ case.name, name, want });
                return err;
            };
        }
        for (case.expect.absent) |name| {
            std.testing.expectEqual(corpus.Member.absent, corpus.member(result.value, name)) catch |err| {
                std.debug.print("{s}: {s} must be ABSENT\n", .{ case.name, name });
                return err;
            };
        }
        for (case.expect.emptyPresent) |name| {
            std.testing.expectEqual(
                corpus.Member.empty_object,
                corpus.member(result.value, name),
            ) catch |err| {
                std.debug.print("{s}: {s} must be present and EMPTY\n", .{ case.name, name });
                return err;
            };
        }
        if (case.expect.vpn) |expected| {
            try corpus.expectDetail(expected, result.value.vpn.?);
        }
        if (case.expect.hosting) |expected| {
            try corpus.expectDetail(expected, result.value.hosting.?);
        }
        if (case.expect.dcproxy) |expected| {
            try corpus.expectDetail(expected, result.value.dcproxy.?);
        }
    }
}

test "a 429 is classified by Retry-After, not by its status" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();

    for (data.value.errors) |case| {
        const harness = try Harness.start(gpa);
        defer harness.deinit();

        const arena = harness.stub.arena.allocator();
        var headers: std.ArrayList(Route.Header) = .empty;
        for (case.headers.map.keys(), case.headers.map.values()) |name, value| {
            try headers.append(arena, .{ .name = name, .value = value });
        }
        try harness.stub.route("/1.1.1.1", .{
            .status = case.status,
            .body = try corpus.json(arena, case.body),
            .headers = try headers.toOwnedSlice(arena),
        });

        // No retries, so a retryable failure surfaces rather than looping.
        var client = try harness.client(.{ .retries = 0 });
        defer client.deinit();

        var diagnostics: vpndetection.Diagnostics = .{};
        const err = errorOf(client.lookupWith("1.1.1.1", .{ .diagnostics = &diagnostics }), case.name);
        std.testing.expectEqualStrings(case.expect.kind, vpndetection.kindName(err)) catch |e| {
            std.debug.print("{s}: wrong kind\n", .{case.name});
            return e;
        };
        try std.testing.expectEqual(case.expect.retryable, vpndetection.isRetryable(err));
        try std.testing.expectEqual(case.status, diagnostics.status.?);
        if (case.expect.message) |message| {
            try std.testing.expectEqualStrings(message, diagnostics.message());
        }
        if (case.expect.retryAfterSeconds) |seconds| {
            try std.testing.expectEqual(seconds, diagnostics.retry_after_s.?);
        }
    }
}

test "a batch dedupes, short circuits bogons and keys by address" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const case = data.value.batchCase("dedup-bogon-and-order-free-keying");

    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");
    try harness.stub.routeLookup("8.8.8.8");

    var client = try harness.client(.{});
    defer client.deinit();
    var batch = try client.lookupBatch(case.input, .{});
    defer batch.deinit();

    // Keyed by address, not positional, and in the order each was first seen.
    try std.testing.expectEqual(case.expect.keys.len, batch.count());
    for (case.expect.keys, batch.keys()) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
    try std.testing.expectEqual(case.expect.httpRequests.?, harness.stub.callCount());
    for (case.expect.bogonKeys) |ip| {
        try std.testing.expect(batch.get(ip).?.ok.is_bogon);
    }
}

test "one bad address does not lose the rest of the batch" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const case = data.value.batchCase("partial-failure-does-not-fail-the-batch");

    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    var client = try harness.client(.{ .retries = 0 });
    defer client.deinit();
    var batch = try client.lookupBatch(case.input, .{});
    defer batch.deinit();

    for (case.expect.keys, batch.keys()) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
    for (case.expect.errorKeys) |ip| {
        const failure = batch.get(ip).?.failed;
        try std.testing.expectEqual(error.BadRequest, failure.err);
        try std.testing.expectEqualStrings("not a valid IP address", failure.diagnostics.message());
    }
    try std.testing.expect(!batch.get("1.1.1.1").?.ok.value.is_vpn);
}

test "a cache hit issues no second request" {
    const gpa = std.testing.allocator;
    const data = try corpus.load(gpa);
    defer data.deinit();
    const case = data.value.batchCase("cache-hit-issues-no-second-request");

    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    var client = try harness.client(.{});
    defer client.deinit();
    for (0..case.repeat orelse 1) |_| {
        var batch = try client.lookupBatch(case.input, .{});
        batch.deinit();
    }
    try std.testing.expectEqual(case.expect.httpRequests.?, harness.stub.callCount());
}

test "two clients never share a cached answer" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    var first = try harness.client(.{ .api_key = "key-a" });
    defer first.deinit();
    var second = try harness.client(.{ .api_key = "key-b" });
    defer second.deinit();

    (try first.lookup("1.1.1.1")).deinit();
    (try second.lookup("1.1.1.1")).deinit();

    // Two keys can be on different plans and so entitled to different fields; a
    // shared cache would serve one of them the other's shape.
    try std.testing.expectEqual(2, harness.stub.callCount());
}

test "caching can be turned off" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    var client = try harness.client(.{ .cache = null });
    defer client.deinit();
    (try client.lookup("1.1.1.1")).deinit();
    (try client.lookup("1.1.1.1")).deinit();

    try std.testing.expectEqual(2, harness.stub.callCount());
}

test "every generated range is reachable through the predicate" {
    const data = try corpus.load(std.testing.allocator);
    defer data.deinit();

    for (data.value.bogons.v4) |cidr| {
        try std.testing.expect(vpndetection.isBogon(cidr[0..std.mem.indexOfScalar(u8, cidr, '/').?]));
    }
    for (data.value.bogons.v6) |cidr| {
        try std.testing.expect(vpndetection.isBogon(cidr[0..std.mem.indexOfScalar(u8, cidr, '/').?]));
    }
}

fn errorOf(result: vpndetection.CallError!vpndetection.Lookup, name: []const u8) vpndetection.CallError {
    if (result) |answer| {
        answer.deinit();
        std.debug.panic("{s}: the lookup should have failed", .{name});
    } else |err| {
        return err;
    }
}
