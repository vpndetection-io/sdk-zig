//! The licensed-download half, which only the max key can reach: it is the tier
//! holding dataset licences.
//!
//! The transfer is budgeted before it starts. Metadata publishes a size per
//! format, and that size is checked against the ceiling below FIRST, so a
//! mistaken dataset id can never quietly pull one of the gigabyte datasets
//! through CI.

const std = @import("std");
const vpndetection = @import("vpndetection");

const staging = @import("staging.zig");

const Tier = staging.tiers.Tier;

/// The max organization licenses cdn_ip for license_type, and at ~10 KB it is
/// the only dataset small enough to move in CI.
const dataset_id = "cdn_ip_v1";
const format: vpndetection.Format = .csvgz;

/// 8 MiB against a ~10 KB dataset. Three orders of magnitude of headroom, so
/// tripping it means the suite is pointed somewhere unintended, which is exactly
/// when a transfer must not go ahead.
const ceiling = 8 << 20;

/// A real catalogue id the max organization holds no licence for.
const unlicensed_id = "hosting_ip_v1";

test "the licensed catalogue answers the schema the client was written from" {
    const gpa = std.testing.allocator;
    try Tier.max.require();
    const rung = try staging.Rung.start(gpa, .max, .{});
    defer rung.deinit();

    const datasets = try rung.client.database().list(.{});
    defer datasets.deinit();

    try std.testing.expect(datasets.value.len > 0);
    // Read off the wire rather than off the structs, because a field the client
    // has no home for disappears silently into `ignore_unknown_fields`.
    const served = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        rung.proxy.body("/api/v1/database/list").?,
        .{},
    );
    defer served.deinit();
    const first = served.value.object.get("datasets").?.array.items[0].object;
    try std.testing.expect(first.contains("base"));
    try std.testing.expect(first.contains("versions"));
    // A docs-site slug, not API surface. It was in the spec once and the client
    // would happily have modelled it.
    try std.testing.expect(!first.contains("docsGroup"));

    for (datasets.value) |family| {
        try std.testing.expect(family.base.len > 0);
        try std.testing.expect(family.name.len > 0);
        try expectOneOf("standing", family.standing, &.{ "expired", "licensed", "unlicensed" });
        try expectOneOf("license_type", family.license_type, &.{ "evaluation", "standard", "redistribute" });
        // The point of the family shape: a license covers the family, and these
        // are the ids the download and checksum calls take. Before the spec was
        // corrected this list did not exist, so `list` could not tell a caller
        // what to download.
        try std.testing.expect(family.versions.len > 0);
        for (family.versions) |version| {
            try std.testing.expect(version.id.len > 0);
            try std.testing.expect(version.formats.len > 0);
            std.debug.print("licensed: {s}\n", .{version.id});
        }
    }
}

test "a dataset the organization does not license is refused cleanly" {
    const gpa = std.testing.allocator;
    try Tier.max.require();
    const rung = try staging.Rung.start(gpa, .max, .{});
    defer rung.deinit();

    var diagnostics: vpndetection.Diagnostics = .{};
    const failure = rung.client.database().downloadUrl(unlicensed_id, format, .{
        .diagnostics = &diagnostics,
    });
    if (failure) |url| {
        gpa.free(url);
        std.debug.print(
            "{s} was served, so it is licensed to this organization now: point this at one that is not\n",
            .{unlicensed_id},
        );
        return error.TestExpectedEqual;
    } else |err| {
        try std.testing.expectEqual(error.Forbidden, err);
        try std.testing.expect(!vpndetection.isRetryable(err));
    }
    try std.testing.expectEqual(@as(?u16, 403), diagnostics.status);
    // The API says WHICH refusal this is (`{"rc":"NOT_LICENSED"}`). An empty
    // message means the envelope went unread.
    try std.testing.expect(diagnostics.message().len > 0);
    std.debug.print("{s}: {s}\n", .{ unlicensed_id, diagnostics.message() });
    // A 4xx is the API saying no, not a wobble.
    try std.testing.expectEqual(1, rung.proxy.seen().len);
}

test "a real dataset moves intact, in memory and on disk" {
    const gpa = std.testing.allocator;
    try Tier.max.require();
    const rung = try staging.Rung.start(gpa, .max, .{});
    defer rung.deinit();
    const database = rung.client.database();

    const metadata = try database.metadata(dataset_id, .{});
    defer metadata.deinit();
    try std.testing.expectEqualStrings(dataset_id, metadata.value.id);
    const size = metadata.value.size.map.get(@tagName(format)) orelse {
        std.debug.print("{s} publishes no {t} size to check a transfer against\n", .{ dataset_id, format });
        return error.TestExpectedEqual;
    };
    if (size <= 0 or size > ceiling) {
        std.debug.print("{s} is {d} bytes, past the {d} ceiling, so it is not transferred\n", .{
            dataset_id, size, ceiling,
        });
        return error.TestExpectedEqual;
    }

    var scratch = Scratch.start();
    defer scratch.deinit();
    const path = scratch.path(dataset_id ++ ".csv.gz");
    const written = try database.download(dataset_id, format, path, .{});
    std.debug.print("{s}.{t}: {d} bytes, metadata says {d}\n", .{ dataset_id, format, written, size });

    try std.testing.expect(written > 0);
    // Nothing partial may outlive a transfer that finished.
    try std.testing.expect(!scratch.exists(dataset_id ++ ".csv.gz.part"));

    const on_disk = try gpa.alloc(u8, ceiling);
    defer gpa.free(on_disk);
    const bytes = try scratch.read(dataset_id ++ ".csv.gz", on_disk);
    try std.testing.expectEqual(written, bytes.len);
    try std.testing.expect(bytes.len > 1 and bytes[0] == 0x1f and bytes[1] == 0x8b);

    // Read AFTER the transfer, so a rebuild between the two calls shows up as a
    // digest mismatch rather than passing against the digest of nothing.
    const checksums = try database.checksums(dataset_id, format, .{});
    defer checksums.deinit();
    const published = checksums.value.sha256 orelse {
        std.debug.print("checksums carried no sha256, so it did not unwrap past the envelope\n", .{});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(64, published.len);
    try std.testing.expectEqualStrings(published, &digest(bytes));

    // The in-memory variant has to be the same file, not merely a similar one.
    const in_memory = try database.downloadBytes(dataset_id, format, .{});
    defer gpa.free(in_memory);
    try std.testing.expectEqualSlices(u8, bytes, in_memory);
}

fn digest(bytes: []const u8) [64]u8 {
    var sum: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sum, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&sum}) catch unreachable;
    return hex;
}

fn expectOneOf(comptime what: []const u8, value: []const u8, allowed: []const []const u8) !void {
    for (allowed) |candidate| {
        if (std.mem.eql(u8, candidate, value)) {
            return;
        }
    }
    std.debug.print("{s} is \"{s}\", which the spec does not document\n", .{ what, value });
    return error.TestExpectedEqual;
}

/// A scratch directory, because `download` takes a PATH rather than a directory
/// handle. Do not copy one after `start`: `path` hands back a slice of its own
/// buffer.
const Scratch = struct {
    tmp: std.testing.TmpDir,
    buffer: [128]u8 = undefined,

    fn start() Scratch {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn deinit(self: *Scratch) void {
        self.tmp.cleanup();
    }

    /// `std.testing` puts its temporary directories under `.zig-cache/tmp` and
    /// hands back a handle rather than a path, so the path is spelled the same
    /// way it builds it.
    fn path(self: *Scratch, name: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.buffer, ".zig-cache/tmp/{s}/{s}", .{
            &self.tmp.sub_path,
            name,
        }) catch unreachable;
    }

    fn exists(self: *Scratch, name: []const u8) bool {
        self.tmp.dir.access(std.testing.io, name, .{}) catch return false;
        return true;
    }

    fn read(self: *Scratch, name: []const u8, buffer: []u8) ![]u8 {
        return self.tmp.dir.readFile(std.testing.io, name, buffer);
    }
};
