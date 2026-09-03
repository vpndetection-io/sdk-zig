//! The library's smallest useful program, and the one the README opens with.
//!
//!     zig build example
//!     ./zig-out/bin/lookup 45.83.91.1

const std = @import("std");
const vpndetection = @import("vpndetection");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const ip = if (args.len > 1) args[1] else "45.83.91.1";

    var client = try vpndetection.Client.init(init.gpa, init.io, .{});
    defer client.deinit();

    const result = try client.lookup(ip);
    defer result.deinit();

    std.debug.print("{s}: is_vpn={} is_hosting={}\n", .{
        result.value.ip,
        result.value.is_vpn,
        result.value.is_hosting orelse false,
    });
}
