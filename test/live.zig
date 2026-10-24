//! A smoke test against the real API, kept out of `zig build test` so the suite
//! stays offline and costs no quota. Set VPNDETECTION_API_KEY to exercise a paid
//! plan's fields; without one it runs on the free tier.
//!
//!     ./scripts/zig.sh build live
//!     VPNDETECTION_API_KEY=... ./scripts/zig.sh build live

const std = @import("std");
const vpndetection = @import("vpndetection");

const Io = std.Io;

test "live lookup" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const key = std.testing.environ.getPosix("VPNDETECTION_API_KEY");
    var client = try vpndetection.Client.init(gpa, threaded.io(), .{
        .api_key = if (key) |value| (if (value.len > 0) value else null) else null,
    });
    defer client.deinit();

    const vpn = try client.lookup("45.83.91.1");
    defer vpn.deinit();
    std.debug.print("45.83.91.1: is_vpn={} is_bogon={} is_hosting={?} vpn={?}\n", .{
        vpn.value.is_vpn,
        vpn.is_bogon,
        vpn.value.is_hosting,
        vpn.value.vpn,
    });
    try std.testing.expect(vpn.value.is_vpn);

    const clean = try client.lookup("1.1.1.1");
    defer clean.deinit();
    std.debug.print("1.1.1.1: is_vpn={} is_bogon={} is_hosting={?}\n", .{
        clean.value.is_vpn,
        clean.is_bogon,
        clean.value.is_hosting,
    });
    try std.testing.expect(!clean.value.is_vpn);

    if (key == null) {
        // The one assertion a stub cannot make honestly: the free tier does not
        // include is_hosting, so it is ABSENT rather than false.
        try std.testing.expectEqual(@as(?bool, null), clean.value.is_hosting);
    }

    const private = try client.lookup("192.168.1.1");
    defer private.deinit();
    std.debug.print("192.168.1.1: is_bogon={} is_vpn={} (answered locally)\n", .{
        private.is_bogon,
        private.value.is_vpn,
    });
    try std.testing.expect(private.is_bogon);
}

// Keyless: registering stores nothing until a person approves the client, so
// it is safe against the real server, which answers a self-registered id.
test "live register" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var client = try vpndetection.Client.init(gpa, threaded.io(), .{});
    defer client.deinit();

    const registration = try client.oauth().register(&.{"http://127.0.0.1:8765/callback"}, .{
        .client_name = "VPNDetection SDK check",
    });
    defer registration.deinit();
    std.debug.print("registered {s}..., issued at {d}, shown as {s}\n", .{
        registration.value.client_id[0..12],
        registration.value.client_id_issued_at,
        registration.value.client_name,
    });
    try std.testing.expect(std.mem.startsWith(u8, registration.value.client_id, "dcr_"));
    try std.testing.expectEqualStrings("none", registration.value.token_endpoint_auth_method);
    try std.testing.expectError(error.OauthRejected, client.oauth().register(&.{"myapp://cb"}, .{}));
}
