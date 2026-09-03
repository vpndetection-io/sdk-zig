//! Compiles the README's examples without running them, so a rename that
//! invalidates the README fails the build rather than a reader's first attempt.
//! Mirror any README edit here.

const std = @import("std");
const vpndetection = @import("vpndetection");

const Io = std.Io;

test "the README's examples still compile" {
    // Runtime-false rather than `if (false)`, whose body Zig would not analyze.
    var never = false;
    _ = &never;
    if (never) {
        try examples(std.testing.allocator);
    }
}

fn examples(gpa: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var client = try vpndetection.Client.init(gpa, threaded.io(), .{});
    defer client.deinit();

    const result = try client.lookup("45.83.91.1");
    defer result.deinit();
    std.debug.print("{}\n", .{result.value.is_vpn});

    if (result.value.is_hosting) |flagged| {
        std.debug.print("{}\n", .{flagged});
    }
    const hosting = result.value.is_hosting orelse false;
    _ = hosting;

    std.debug.print("{s}\n", .{result.value.vpn.?.provider.?});

    var batch = try client.lookupBatch(&.{ "45.83.91.1", "8.8.8.8", "1.1.1.1" }, .{});
    defer batch.deinit();
    for (batch.keys(), batch.values()) |ip, entry| {
        switch (entry) {
            .ok => |answer| std.debug.print("{s}: {}\n", .{ ip, answer.value.is_vpn }),
            .failed => |failure| std.debug.print("{s}: {s}\n", .{ ip, failure.diagnostics.message() }),
        }
    }

    var wider = try client.lookupBatch(&.{"1.1.1.1"}, .{ .concurrency = 32, .retries = 4 });
    defer wider.deinit();

    var sized = try vpndetection.Client.init(gpa, threaded.io(), .{
        .cache = .{ .max_entries = 50_000, .ttl = .fromSeconds(6 * 60 * 60) },
    });
    defer sized.deinit();
    var uncached = try vpndetection.Client.init(gpa, threaded.io(), .{ .cache = null });
    defer uncached.deinit();

    const bogon = try client.lookup("192.168.1.1");
    defer bogon.deinit();
    std.debug.print("{} {}\n", .{ bogon.is_bogon, bogon.value.is_vpn });
    std.debug.print("{} {}\n", .{ client.isBogon("10.0.0.1"), vpndetection.isBogon("8.8.8.8") });

    var diagnostics: vpndetection.Diagnostics = .{};
    const answer = client.lookupWith("1.1.1.1", .{ .diagnostics = &diagnostics }) catch |err| {
        std.debug.print("{s} retryable={} status={?} {s}\n", .{
            vpndetection.kindName(err),
            vpndetection.isRetryable(err),
            diagnostics.status,
            diagnostics.message(),
        });
        return err;
    };
    defer answer.deinit();

    const datasets = try client.database().list(.{});
    defer datasets.deinit();
    const url = try client.database().downloadUrl("vpn_ip_extended_v1", .mmdb, .{});
    defer gpa.free(url);
}
