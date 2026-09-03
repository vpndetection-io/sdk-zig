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

/// The licensed dataset downloads. Access is granted by contract rather than
/// self-serve, and needs a key carrying the `db.download` scope.
///
/// Reached through `Client.database`. Every call returns a `std.json.Parsed`
/// whose arena owns the whole answer, so `deinit` is the entire cleanup.
pub const Database = struct {
    client: *client_mod.Client,

    /// The datasets your organization is licensed to download.
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
/// `redistribution` and the other closed sets stay strings rather than Zig
/// enums: a value added to the API after this release would otherwise fail the
/// whole response to parse, and a client that cannot read today's answer is
/// worse than one that cannot name tomorrow's value.
pub const LicensedDataset = struct {
    id: []const u8,
    name: []const u8,
    summary: ?[]const u8 = null,
    /// Licensed but no longer published.
    retired: ?bool = null,
    /// What your license permits: `evaluation`, `internal` or `redistribute`.
    redistribution: []const u8,
    starts: ?[]const u8 = null,
    expires: ?[]const u8 = null,
    /// False when the license has lapsed; downloads are refused.
    in_term: bool,
    formats: []const DatasetFormatSize,
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
