const std = @import("std");

const client_mod = @import("client.zig");
const errors = @import("errors.zig");
const http = @import("http.zig");

const CallError = errors.CallError;
const Diagnostics = errors.Diagnostics;
const Param = http.Transport.Param;
const Parsed = std.json.Parsed;

/// Not every dataset is built in every format: the `_provider` catalogs are
/// keyed by provider id rather than by IP range, so no MMDB exists for them.
pub const Format = enum {
    csvgz,
    mmdb,

    pub fn toString(self: Format) []const u8 {
        return @tagName(self);
    }
};

/// Everything `download` can fail with.
///
/// The filesystem's errors are kept distinct from the API's rather than folded
/// into `error.Network`: a reset socket and a full disk are different problems,
/// and only one of them is ours to retry.
pub const DownloadError = CallError ||
    std.Io.File.OpenError ||
    std.Io.File.Writer.Error ||
    std.Io.Writer.Error ||
    std.Io.Dir.RenameError ||
    std.Io.Dir.DeleteFileError;

/// The licensed dataset downloads. Access is granted by contract rather than
/// self-serve, and needs a key carrying the `db.download` scope.
///
/// Reached through `Client.database`. The catalog calls return a
/// `std.json.Parsed` whose arena owns the whole answer, so `deinit` is the
/// entire cleanup; `downloadUrl` and `downloadBytes` return slices allocated
/// with the allocator you gave `Client.init` and owned by you.
pub const Database = struct {
    client: *client_mod.Client,

    /// The dataset families your organization is licensed to download.
    ///
    /// A license covers a family, so the id you pass to a download is one of
    /// `LicensedDataset.versions`, not `LicensedDataset.base`.
    pub fn list(
        self: Database,
        options: client_mod.CallOptions,
    ) CallError!Parsed([]const LicensedDataset) {
        const answer = try self.fetch(DatasetList, "/api/v1/database/list", &.{}, options);
        return .{ .arena = answer.arena, .value = answer.value.datasets };
    }

    /// What is inside one dataset: schema, samples, row count and sizes.
    ///
    /// It carries `updated` and `entries` without downloading anything, so poll
    /// it to decide whether today's build is worth fetching.
    pub fn metadata(
        self: Database,
        id: []const u8,
        options: client_mod.CallOptions,
    ) CallError!Parsed(DatasetMetadata) {
        const query = [_]Param{.{ .name = "id", .value = id }};
        return self.fetch(DatasetMetadata, "/api/v1/database/metadata", &query, options);
    }

    /// The digests of one published file, for verifying a download.
    ///
    /// The whole set is returned rather than one algorithm, because which
    /// digests a dataset publishes is the API's choice. They nest under
    /// `checksums` in the response, and reading a top-level `sha256` is how the
    /// Node SDK shipped this broken in 1.0.x.
    pub fn checksums(
        self: Database,
        id: []const u8,
        format: Format,
        options: client_mod.CallOptions,
    ) CallError!Parsed(DatasetChecksums) {
        const query = [_]Param{
            .{ .name = "id", .value = id },
            .{ .name = "format", .value = format.toString() },
        };
        const answer = try self.fetch(ChecksumResponse, "/api/v1/database/checksum", &query, options);
        return .{ .arena = answer.arena, .value = answer.value.checksums };
    }

    /// Your organization's recent download attempts, newest first. Null takes
    /// the API's own default.
    pub fn downloads(
        self: Database,
        limit: ?u32,
        options: client_mod.CallOptions,
    ) CallError!Parsed([]const Download) {
        var buffer: [16]u8 = undefined;
        var query: [1]Param = undefined;
        var count: usize = 0;
        if (limit) |n| {
            const text = std.fmt.bufPrint(&buffer, "{d}", .{n}) catch unreachable;
            query[0] = .{ .name = "limit", .value = text };
            count = 1;
        }
        const answer = try self.fetch(DownloadList, "/api/v1/database/downloads", query[0..count], options);
        return .{ .arena = answer.arena, .value = answer.value.downloads };
    }

    /// The time-limited URL for one dataset file, owned by the caller.
    ///
    /// The API answers 302 to object storage. The URL is returned rather than
    /// the bytes so the caller decides how to transfer a file that routinely
    /// runs to gigabytes; the link authorizes the START of a transfer, so one
    /// already running is not interrupted when it lapses.
    pub fn downloadUrl(
        self: Database,
        id: []const u8,
        format: Format,
        options: client_mod.CallOptions,
    ) CallError![]u8 {
        const query = [_]Param{
            .{ .name = "id", .value = id },
            .{ .name = "format", .value = format.toString() },
        };
        var scratch: Diagnostics = .{};
        return http.send(&self.client.transport, self.client.gpa, self.client.io, .{
            .kind = .location,
            .path = "/api/v1/database/download",
            .query = &query,
            .retries = options.retries orelse self.client.retries,
            .diagnostics = options.diagnostics orelse &scratch,
        });
    }

    /// Writes one dataset file to `path`, returning the bytes written.
    ///
    /// Nothing beyond a single chunk is ever held in memory, whatever the
    /// dataset weighs, so this is the call to reach for by default.
    ///
    /// The bytes land in a neighbouring `<path>.part` that is renamed on
    /// completion, and a transfer that stops short of the length the origin
    /// declared is an error rather than a short file. Nothing partial survives
    /// a failure, so a `path` that exists is a whole dataset.
    ///
    /// The redirect is followed, and that second request carries NO API key:
    /// the link authorizes itself, and object storage is a third party.
    ///
    /// `retries` applies to reaching the API for the link, not to the transfer:
    /// resuming a half-moved gigabyte is a different problem from asking again.
    pub fn download(
        self: Database,
        id: []const u8,
        format: Format,
        path: []const u8,
        options: client_mod.CallOptions,
    ) DownloadError!u64 {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const gpa = self.client.gpa;
        const io = self.client.io;

        var transfer: http.Transfer = undefined;
        try self.begin(&transfer, options, id, format, diag);
        defer transfer.deinit();

        const partial = try std.fmt.allocPrint(gpa, "{s}.part", .{path});
        defer gpa.free(partial);
        const buffer = try gpa.alloc(u8, 64 * 1024);
        defer gpa.free(buffer);

        const cwd: std.Io.Dir = .cwd();
        var file = try cwd.createFile(io, partial, .{});
        // Every way out of here but the last one removes the partial file, so a
        // failed transfer cannot leave behind something that reads as a dataset.
        errdefer cwd.deleteFile(io, partial) catch {};

        const written = written: {
            // Closed before the rename rather than at the end of the function:
            // renaming a file that is still open fails outright on Windows.
            defer file.close(io);
            var sink = file.writer(io, buffer);
            const moved = transfer.reader().streamRemaining(&sink.interface) catch |err| switch (err) {
                error.ReadFailed => return transfer.readFailure(diag),
                error.WriteFailed => return sink.err orelse error.WriteFailed,
            };
            sink.interface.flush() catch return sink.err orelse error.WriteFailed;
            break :written moved;
        };
        try transfer.verify(written, diag);

        try cwd.rename(partial, cwd, path, io);
        return written;
    }

    /// Downloads one dataset file and hands back its bytes, allocated with the
    /// allocator you gave `Client.init` and owned by you.
    ///
    /// **This holds the ENTIRE file in memory.** The catalog spans five orders
    /// of magnitude, from `cdn_ip_v1` at ~10 KB to `resproxy_ip_90d_v1` at
    /// 1.79 GB, so reach for this at the small end and use `download` for
    /// anything you have not measured. `metadata` publishes the size per format
    /// without transferring anything, which is how you find out which end you
    /// are at.
    ///
    /// Byte for byte the same file `download` writes, and short of the declared
    /// length is the same error here as there.
    pub fn downloadBytes(
        self: Database,
        id: []const u8,
        format: Format,
        options: client_mod.CallOptions,
    ) CallError![]u8 {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const gpa = self.client.gpa;

        var transfer: http.Transfer = undefined;
        try self.begin(&transfer, options, id, format, diag);
        defer transfer.deinit();

        const reader = transfer.reader();
        // Sized once from the declared length where there is one: an allocator
        // that grows by doubling spends twice the file on its final grow, which
        // at the large end of the catalog is gigabytes of nothing.
        const declared = transfer.declared orelse
            return reader.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ReadFailed => transfer.readFailure(diag),
                error.StreamTooLong => unreachable, // .unlimited has no limit to exceed
            };
        const bytes = try gpa.alloc(u8, std.math.cast(usize, declared) orelse return error.OutOfMemory);
        errdefer gpa.free(bytes);
        // Short rather than all, so a transfer that stops early is reported with
        // the two lengths rather than as a bare end-of-stream.
        const received = reader.readSliceShort(bytes) catch |err| switch (err) {
            error.ReadFailed => return transfer.readFailure(diag),
        };
        try transfer.verify(received, diag);
        return bytes;
    }

    /// Asks the API for the presigned link and opens it.
    fn begin(
        self: Database,
        transfer: *http.Transfer,
        options: client_mod.CallOptions,
        id: []const u8,
        format: Format,
        diag: *Diagnostics,
    ) CallError!void {
        const gpa = self.client.gpa;
        const url = try self.downloadUrl(id, format, .{
            .retries = options.retries,
            .diagnostics = diag,
        });
        defer gpa.free(url);
        return transfer.begin(&self.client.transport, gpa, url, diag);
    }

    fn fetch(
        self: Database,
        comptime T: type,
        path: []const u8,
        query: []const Param,
        options: client_mod.CallOptions,
    ) CallError!Parsed(T) {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const gpa = self.client.gpa;

        const body = try http.send(&self.client.transport, gpa, self.client.io, .{
            .path = path,
            .query = query,
            .retries = options.retries orelse self.client.retries,
            .diagnostics = diag,
        });
        defer gpa.free(body);

        const parsed = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(parsed);
        parsed.* = .init(gpa);
        errdefer parsed.deinit();

        const arena = parsed.allocator();
        // Parsed from a copy the arena owns, so every string in the answer
        // outlives the body this call frees.
        const owned = try arena.dupe(u8, body);
        const value = std.json.parseFromSliceLeaky(T, arena, owned, .{
            .ignore_unknown_fields = true,
        }) catch {
            diag.setMessage("the answer did not match the documented shape");
            return error.ServerError;
        };
        return .{ .arena = parsed, .value = value };
    }
};

/// Mirrors `components.schemas.LicensedDataset` in spec/openapi.yaml.
///
/// One dataset FAMILY. A license is held against the family, while a download
/// names one version of it, so the ids `download`, `downloadBytes`,
/// `downloadUrl` and `checksums` take come from `versions` rather than from
/// here.
///
/// `license_type` and the other closed sets stay strings rather than Zig
/// enums: a value added to the API after this release would otherwise fail the
/// whole response to parse, and a client that cannot read today's answer is
/// worse than one that cannot name tomorrow's value.
pub const LicensedDataset = struct {
    /// The family, e.g. `vpn_ip`. What the license is held against.
    base: []const u8,
    name: []const u8,
    summary: ?[]const u8 = null,
    /// What your license permits: `evaluation`, `internal` or `redistribute`.
    license_type: []const u8,
    starts: ?[]const u8 = null,
    /// Null when the license does not expire.
    expires: ?[]const u8 = null,
    /// False when the license has lapsed; downloads are refused.
    in_term: bool,
    /// `licensed` is a live grant, `expired` one whose term has ended, and
    /// `unlicensed` a dataset published but never bought.
    standing: []const u8,
    versions: []const LicensedVersion,
};

/// Mirrors `components.schemas.LicensedVersion`. One published version of a
/// family, and the only place a downloadable id comes from.
pub const LicensedVersion = struct {
    /// The versioned dataset id, e.g. `vpn_ip_v1`. This is what you download.
    id: []const u8,
    version: i64,
    summary: ?[]const u8 = null,
    formats: []const DatasetFormatSize,
    /// The formats an evaluation sample is published in, if any. Spelled the
    /// way the wire spells it, so `std.json` needs no rename table.
    sampleFormats: ?[]const []const u8 = null,
};

pub const DatasetFormatSize = struct {
    format: []const u8,
    /// Null when the file has not been published yet.
    bytes: ?i64,
};

pub const Download = struct {
    dataset_id: []const u8,
    format: []const u8,
    /// `ok`, `unauthorized`, `denied`, `expired`, `unknown` or `unavailable`.
    outcome: []const u8,
    bytes: ?i64 = null,
    created: []const u8,
};

pub const DatasetMetadataColumn = struct {
    name: []const u8,
    /// `type` is a keyword, so the field is spelled with an identifier literal;
    /// the wire name it matches is still `type`.
    type: []const u8,
    description: ?[]const u8 = null,
};

/// Mirrors `components.schemas.DatasetMetadata`. The three maps are keyed by
/// format, which is why they are hash maps rather than structs.
pub const DatasetMetadata = struct {
    id: []const u8,
    update_freq: ?[]const u8 = null,
    updated: []const u8,
    entries: i64,
    schema: std.json.ArrayHashMap([]const DatasetMetadataColumn) = .{},
    sample: std.json.ArrayHashMap([]const std.json.Value) = .{},
    size: std.json.ArrayHashMap(i64) = .{},
    /// How many rows the sample holds, and what it weighs per format. Keyed the
    /// same way `size` is, because a sample is published per format too.
    sample_entries: ?i64 = null,
    sample_size: std.json.ArrayHashMap(i64) = .{},
};

/// Which digests are present varies by dataset.
pub const DatasetChecksums = struct {
    md5: ?[]const u8 = null,
    sha1: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    sha512: ?[]const u8 = null,
};

const DatasetList = struct { datasets: []const LicensedDataset };
const DownloadList = struct { downloads: []const Download };
const ChecksumResponse = struct {
    id: []const u8,
    format: []const u8,
    checksums: DatasetChecksums,
};
