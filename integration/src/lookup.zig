//! The published library looking addresses up against the staging API.
//!
//! Nothing here pins a field COUNT. The tiers are asserted as a RELATION, each
//! one serving a superset of the tier below it, so a pricing change stays a
//! pricing change instead of arriving as a red SDK build. What a served answer
//! must satisfy on every tier: `ip` and `is_vpn` always; a present flag is a
//! real boolean; a field a higher tier serves is ABSENT on a lower one rather
//! than false; a populated detail object carries its documented keys; an empty
//! one means its flag is false.

const std = @import("std");
const vpndetection = @import("vpndetection");

const staging = @import("staging.zig");

const Tier = staging.tiers.Tier;

test "an unauthenticated lookup answers ip and is_vpn" {
    const gpa = std.testing.allocator;
    var fixture = try staging.answerFor(gpa, .unauth);
    defer fixture.deinit();

    try std.testing.expect(fixture.has("ip"));
    try std.testing.expect(fixture.has("is_vpn"));
    try staging.assertShape(fixture);
    std.debug.print("testing against {s}\n", .{staging.upstream});
}

test "a key reaches the wire and its answer keeps its shape" {
    const gpa = std.testing.allocator;
    for (Tier.ladder) |tier| {
        if (tier.secret() == null) {
            continue;
        }
        tier.require() catch continue;
        var fixture = try staging.answerFor(gpa, tier);
        defer fixture.deinit();
        try staging.assertShape(fixture);
    }
}

test "each tier serves a superset of the tier below" {
    const gpa = std.testing.allocator;
    var buffer: [Tier.ladder.len]Tier = undefined;
    const open = try staging.tiers.requireLadder(&buffer);

    var below: ?staging.Fixture = null;
    defer if (below) |*fixture| fixture.deinit();

    for (open) |tier| {
        var fixture = try staging.answerFor(gpa, tier);
        errdefer fixture.deinit();
        std.debug.print("{t}: {d} fields\n", .{ tier, fixture.fields() });

        if (below) |lower| {
            for (lower.served.value.object.keys()) |field| {
                if (!fixture.has(field)) {
                    std.debug.print("{t} drops {s}, which {t} serves\n", .{ tier, field, lower.rung.tier });
                    return error.TestExpectedEqual;
                }
            }
            // Without this, a run in which every key resolved to the same plan
            // would pass: identical sets satisfy containment in both directions.
            if (tier.widens() and fixture.fields() <= lower.fields()) {
                std.debug.print("{t} answers {d} field(s) and {t} answers {d}, so it is no wider\n", .{
                    tier,            fixture.fields(),
                    lower.rung.tier, lower.fields(),
                });
                return error.TestExpectedEqual;
            }
        }
        if (below) |*previous| {
            previous.deinit();
        }
        below = fixture;
    }
}

test "a field a higher tier serves is absent on a lower one, never false" {
    const gpa = std.testing.allocator;
    var buffer: [Tier.ladder.len]Tier = undefined;
    const open = try staging.tiers.requireLadder(&buffer);

    var fixtures: [Tier.ladder.len]staging.Fixture = undefined;
    var loaded: usize = 0;
    defer for (fixtures[0..loaded]) |*fixture| fixture.deinit();
    for (open) |tier| {
        fixtures[loaded] = try staging.answerFor(gpa, tier);
        loaded += 1;
    }

    // The positive half: a field the wire carried must have reached the result,
    // which is what makes a served `false` survive a mapper that copies on
    // truthiness. A field the client does not model at all is the API moving
    // ahead of the pinned spec, not a drop.
    for (fixtures[0..loaded]) |fixture| {
        for (fixture.served.value.object.keys()) |field| {
            const held = staging.modelled(fixture.lookup.value, field);
            if (held.known and !held.present) {
                std.debug.print("{t} serves {s} and the client dropped it\n", .{ fixture.rung.tier, field });
                return error.TestExpectedEqual;
            }
        }
    }

    for (fixtures[0..loaded], 0..) |lower, i| {
        for (fixtures[i + 1 .. loaded]) |higher| {
            for (higher.served.value.object.keys()) |field| {
                if (lower.has(field)) {
                    continue;
                }
                const held = staging.modelled(lower.lookup.value, field);
                if (held.known and held.present) {
                    std.debug.print("{s} is not in the {t} plan, so the result must not read as a value\n", .{
                        field,
                        lower.rung.tier,
                    });
                    return error.TestExpectedEqual;
                }
            }
        }
    }
}

test "a bogon is answered without touching the network" {
    const gpa = std.testing.allocator;
    const rung = try staging.Rung.start(gpa, .unauth, .{});
    defer rung.deinit();

    const result = try rung.client.lookup("10.0.0.1");
    defer result.deinit();

    try std.testing.expect(result.is_bogon);
    try std.testing.expect(!result.value.is_vpn);
    try std.testing.expect(vpndetection.isBogon("10.0.0.1"));
    try std.testing.expect(rung.client.isBogon("10.0.0.1"));
    try std.testing.expectEqual(0, rung.proxy.seen().len);

    // Computed rather than served, so it carries every field whatever the plan.
    // `ip` and `is_vpn` are on every plan and so are not optionals at all,
    // which is why the loop only has anything to say about the other fifteen.
    inline for (std.meta.fields(vpndetection.Answer)) |field| {
        if (@typeInfo(field.type) == .optional and @field(result.value, field.name) == null) {
            std.debug.print("{s} must be present on a bogon\n", .{field.name});
            return error.TestExpectedEqual;
        }
    }
}

test "a batch collapses duplicates and keeps bogons off the wire" {
    const gpa = std.testing.allocator;
    const rung = try staging.Rung.start(gpa, .unauth, .{ .cache = null });
    defer rung.deinit();

    const input = [_][]const u8{ staging.probe, "8.8.8.8", staging.probe, "10.0.0.1", "8.8.8.8" };
    var batch = try rung.client.lookupBatch(&input, .{});
    defer batch.deinit();

    try std.testing.expectEqual(3, batch.count());
    // Distinct paths rather than a call count, so a retry against a wobbling
    // staging cannot read as a failure to deduplicate.
    var asked: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer asked.deinit(gpa);
    for (rung.proxy.seen()) |fact| {
        try asked.put(gpa, fact.path, {});
    }
    try std.testing.expectEqual(2, asked.count());
    try std.testing.expect(asked.contains("/" ++ staging.probe));
    try std.testing.expect(asked.contains("/8.8.8.8"));

    switch (batch.get("10.0.0.1").?) {
        .ok => |answer| try std.testing.expect(answer.is_bogon),
        .failed => return error.TestExpectedEqual,
    }
    for ([_][]const u8{ staging.probe, "8.8.8.8" }) |ip| {
        try std.testing.expect(batch.get(ip).? == .ok);
    }
}
