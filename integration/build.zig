const std = @import("std");

/// Builds the staging suite against the PUBLISHED library.
///
/// `b.dependency` resolves whatever `build.zig.zon` names, which scripts/run.sh
/// has rewritten to the newest published tag. Before the first release there is
/// no dependency at all and this file is never reached: the script skips.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk = b.dependency("vpndetection", .{ .target = target, .optimize = optimize });

    const test_step = b.step("test", "Run the staging integration suite");
    for ([_][]const u8{ "src/lookup.zig", "src/database.zig" }) |path| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vpndetection", .module = sdk.module("vpndetection") }},
        }) });
        const run = b.addRunArtifact(tests);
        // Every one of these talks to staging, so a cached "already ran" result
        // would report on a build that happened days ago.
        run.has_side_effects = true;
        test_step.dependOn(&run.step);
    }
    b.default_step.dependOn(test_step);
}
