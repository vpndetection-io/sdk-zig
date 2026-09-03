const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The manifest is the one place the version lives; the library reads it
    // back through this so its user agent cannot drift from what was released.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const vpndetection = b.addModule("vpndetection", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = build_options.createModule() }},
    });

    const test_step = b.step("test", "Run the unit and conformance tests");
    const unit_tests = b.addTest(.{ .root_module = vpndetection });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    for ([_][]const u8{ "test/conformance.zig", "test/client.zig", "test/readme.zig" }) |path| {
        test_step.dependOn(&b.addRunArtifact(suite(b, vpndetection, target, optimize, path)).step);
    }

    const example = b.addExecutable(.{
        .name = "lookup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/lookup.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vpndetection", .module = vpndetection }},
        }),
    });
    // Built by CI so the program the README opens with cannot go stale.
    const example_step = b.step("example", "Build the example program into zig-out/bin");
    example_step.dependOn(&b.addInstallArtifact(example, .{}).step);

    // Kept out of `test` so a plain build stays offline and costs no quota.
    const live_step = b.step("live", "Query the real API (needs network, uses your daily allowance)");
    const live_tests = suite(b, vpndetection, target, optimize, "test/live.zig");
    const run_live = b.addRunArtifact(live_tests);
    run_live.has_side_effects = true;
    live_step.dependOn(&run_live.step);
}

/// A test binary that consumes the library the way a dependent package does,
/// through its published module name, with the shared conformance corpus
/// embedded so a missing or malformed one is a build failure.
fn suite(
    b: *std.Build,
    vpndetection: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    path: []const u8,
) *std.Build.Step.Compile {
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vpndetection", .module = vpndetection }},
    }) });
    tests.root_module.addAnonymousImport("corpus", .{
        .root_source_file = b.path("testdata/testdata.json"),
    });
    return tests;
}
