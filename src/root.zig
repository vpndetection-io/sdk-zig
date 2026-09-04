//! The official Zig client library for the [VPNDetection](https://vpndetection.io)
//! API: anonymity detection covering VPNs, residential proxies, Tor nodes,
//! hosting servers, CDNs and relays.
//!
//! Start with `Client.init` and `Client.lookup`. No API key is needed: the free
//! tier answers `ip` and `is_vpn` and allows 1000 requests per day per source
//! address.
//!
//! ```
//! var threaded: std.Io.Threaded = .init(gpa, .{});
//! defer threaded.deinit();
//!
//! var client = try vpndetection.Client.init(gpa, threaded.io(), .{});
//! defer client.deinit();
//!
//! const result = try client.lookup("45.83.91.1");
//! defer result.deinit();
//! std.debug.print("{}\n", .{result.value.is_vpn});
//! ```
//!
//! # Absent is not false
//!
//! Every field beyond `ip` and `is_vpn` is optional, because your plan decides
//! which of them the API sends. `null` means "not in your plan", which is a
//! different answer from `false`. Read the optional itself wherever that
//! matters, or `orelse false` when all you want to know is whether an address
//! is flagged.
//!
//! # Memory
//!
//! Everything the client returns is allocated with the allocator you gave
//! `Client.init` and is owned by you: a `Lookup` and a `Batch` carry a `deinit`,
//! a `std.json.Parsed` from the database catalog carries its arena, and
//! `downloadUrl` and `downloadBytes` return slices to free. The library
//! allocates nothing you cannot free, and its test suite runs under
//! `std.testing.allocator`.

const std = @import("std");

pub const Client = @import("client.zig").Client;
pub const Batch = @import("client.zig").Batch;
pub const BatchOptions = @import("client.zig").BatchOptions;
pub const CacheOptions = @import("client.zig").CacheOptions;
pub const CallOptions = @import("client.zig").CallOptions;
pub const Options = @import("client.zig").Options;
pub const default_base_url = @import("client.zig").default_base_url;

pub const Answer = @import("lookup.zig").Answer;
pub const ClassDetail = @import("lookup.zig").ClassDetail;
pub const Lookup = @import("lookup.zig").Lookup;
pub const ProxyDetail = @import("lookup.zig").ProxyDetail;
pub const VpnDetail = @import("lookup.zig").VpnDetail;

pub const Database = @import("database.zig").Database;
pub const DatasetChecksums = @import("database.zig").DatasetChecksums;
pub const DatasetFormatSize = @import("database.zig").DatasetFormatSize;
pub const DatasetMetadata = @import("database.zig").DatasetMetadata;
pub const DatasetMetadataColumn = @import("database.zig").DatasetMetadataColumn;
pub const Download = @import("database.zig").Download;
pub const DownloadError = @import("database.zig").DownloadError;
pub const Format = @import("database.zig").Format;
pub const LicensedDataset = @import("database.zig").LicensedDataset;
pub const LicensedVersion = @import("database.zig").LicensedVersion;

pub const CallError = @import("errors.zig").CallError;
pub const Diagnostics = @import("errors.zig").Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const isRetryable = @import("errors.zig").isRetryable;
pub const kindName = @import("errors.zig").kindName;

pub const isBogon = @import("bogon.zig").isBogon;

test {
    _ = @import("bogon.zig");
    _ = @import("cache.zig");
    _ = @import("client.zig");
    _ = @import("database.zig");
    _ = @import("errors.zig");
    _ = @import("http.zig");
    _ = @import("lookup.zig");
}
