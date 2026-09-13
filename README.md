# [<img src="https://s3.vpndetection.io/vpndetection-public/brand/mark.svg" alt="VPNDetection" width="24"/>](https://vpndetection.io/) VPNDetection Zig Client Library

[![CI](https://github.com/vpndetection-io/sdk-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/vpndetection-io/sdk-zig/actions/workflows/ci.yml)
[![license](https://img.shields.io/github/license/vpndetection-io/sdk-zig.svg)](LICENSE)

The official Zig client library for the [VPNDetection](https://vpndetection.io) API.

The library helps you query VPNDetection's APIs for anonymity detection including VPNs, residential proxies, Tor nodes, hosting servers, CDNs, relays and more.

## Getting Started

```bash
zig fetch --save git+https://github.com/vpndetection-io/sdk-zig#v1.0.0
```

Then add the module to whatever you are building, in `build.zig`:

```zig
const vpndetection = b.dependency("vpndetection", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("vpndetection", vpndetection.module("vpndetection"));
```

Requires Zig **0.16.0**. Zig is pre-1.0 and its standard library still changes shape between releases, so no other version is supported; this one is pinned in CI and in `scripts/Dockerfile`.

## Usage

**No API key needed to start.** The free tier answers `ip` and `is_vpn`, and allows 1000 requests per day per source address.

```zig
const std = @import("std");
const vpndetection = @import("vpndetection");

pub fn main(init: std.process.Init) !void {
    var client = try vpndetection.Client.init(init.gpa, init.io, .{});
    defer client.deinit();

    const result = try client.lookup("45.83.91.1");
    defer result.deinit();

    std.debug.print("{}\n", .{result.value.is_vpn}); // true
}
```

The whole program is in [example/lookup.zig](example/lookup.zig); `zig build example` builds it.

`init.io` is the `std.Io` implementation your program already runs on. Outside `main`, build your own:

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();

var client = try vpndetection.Client.init(gpa, threaded.io(), .{});
defer client.deinit();
```

### Memory

Everything the client hands back is allocated with the allocator you gave `init`, and is yours to free. A `Lookup` and a `Batch` each carry a `deinit`, the catalog calls return a `std.json.Parsed` that owns its arena, and `downloadUrl` and `downloadBytes` return slices. The test suite runs under `std.testing.allocator`, so a leak fails the build.

### With an API key

An API key raises your quota, and raises your features on a paid plan. Create one in the [console](https://app.vpndetection.io), then pass it in:

```zig
var client = try vpndetection.Client.init(gpa, io, .{ .api_key = key });
defer client.deinit();

const result = try client.lookup("45.83.91.1");
defer result.deinit();

std.debug.print("{}\n", .{result.value.is_vpn});                  // true
std.debug.print("{s}\n", .{result.value.vpn.?.provider.?});       // mullvad
std.debug.print("{}\n", .{result.value.is_hosting orelse false}); // true
```

### Batch lookup

You can do batch lookups with a list, which parallelizes requests for you efficiently:

```zig
var batch = try client.lookupBatch(&.{ "45.83.91.1", "8.8.8.8", "1.1.1.1" }, .{});
defer batch.deinit();

for (batch.keys(), batch.values()) |ip, entry| {
    switch (entry) {
        .ok => |answer| std.debug.print("{s}: {}\n", .{ ip, answer.value.is_vpn }),
        .failed => |failure| std.debug.print("{s}: {s}\n", .{ ip, failure.diagnostics.message() }),
    }
}
```

Results are keyed by address, so duplicates in your list collapse into a single request and one address failing never loses the rest. Keys stay in the order the addresses were first seen.

Concurrency and other variables are configurable per-call:

```zig
var batch = try client.lookupBatch(many_ips, .{ .concurrency = 32, .retries = 4 });
defer batch.deinit();
```

A batch is only as concurrent as the `std.Io` you gave the client: `std.Io.Threaded` runs the requests on its thread pool, and an implementation that cannot start a second task answers them one at a time.

### Caching

Answers are cached by default, so repeat lookups of the same address are free:

```zig
const first = try client.lookup("45.83.91.1");  // API request
defer first.deinit();

const second = try client.lookup("45.83.91.1"); // no API request, served from the cache
defer second.deinit();
```

You can change the default cache variables (max size, TTL) on initialization, or even disable it:

```zig
var client = try vpndetection.Client.init(gpa, io, .{
    .cache = .{ .max_entries = 50_000, .ttl = .fromSeconds(6 * 60 * 60) },
});

var uncached = try vpndetection.Client.init(gpa, io, .{ .cache = null });
```

### Private and reserved addresses

Private, loopback, link-local, documentation and multicast addresses (and their IPv6 equivalents, including the 6to4 and Teredo ranges) can never be VPN or proxy infrastructure. The library answers them locally, so they cost no request and no quota:

```zig
const result = try client.lookup("192.168.1.1");
defer result.deinit();

result.is_bogon;      // true, this answer was computed rather than served
result.value.is_vpn;  // false
```

The check is available on the client, which is handy when your inputs are addresses anyway:

```zig
client.isBogon("10.0.0.1"); // true
client.isBogon("8.8.8.8");  // false
```

It is also callable on its own, if you want it without a client:

```zig
vpndetection.isBogon("10.0.0.1"); // true
```

### Errors

Failures are values in `vpndetection.Error`, and the detail behind one arrives in a `Diagnostics` you pass in:

```zig
var diagnostics: vpndetection.Diagnostics = .{};

const result = client.lookupWith("1.1.1.1", .{ .diagnostics = &diagnostics }) catch |err| {
    std.debug.print("{s} retryable={} status={?} {s}\n", .{
        vpndetection.kindName(err),
        vpndetection.isRetryable(err),
        diagnostics.status,
        diagnostics.message(),
    });
    return err;
};
defer result.deinit();
```

The error set is `BadRequest`, `Unauthorized`, `Forbidden`, `RateLimited`, `QuotaExceeded`, `ServerError` and `Network`, plus `OutOfMemory` from the allocator.

Note that `RateLimited` and `QuotaExceeded` both arrive as HTTP 429 and are not the same thing. A rate limit is when the API faces extreme traffic bursts and so retrying later works; but a spent quota needs your allowance raised or the window to roll over. The library retries rate limits for you, but not if your quota is exceeded.

### Database downloads

If your key carries the `db.download` scope, the licensed databases are available through `client.database()`. A licence covers a database *family*, and you download one of its versions:

```zig
const databases = try client.database().list(.{});
defer databases.deinit();
const id = databases.value[0].versions[0].id; // e.g. vpn_ip_extended_v1

// A time-limited link, so something else can do the transfer.
const url = try client.database().downloadUrl(id, .mmdb, .{});
defer gpa.free(url);

// The bytes, in memory.
const bytes = try client.database().downloadBytes(id, .mmdb, .{});
defer gpa.free(bytes);

// Straight to a file, which is the one to reach for by default.
const written = try client.database().download(id, .mmdb, "vpn_ip.mmdb", .{});
```

`download` holds nothing but a single chunk in memory whatever the dataset weighs. It writes to a neighbouring `.part` file and renames it on completion, and a transfer that stops short of the length the origin declared is an error rather than a short file, so a path that exists is a whole dataset and nothing partial survives a failure.

`downloadBytes` holds the **entire file** in memory. The catalog spans five orders of magnitude, from `cdn_ip_v1` at ~10 KB to `resproxy_ip_90d_v1` at 1.79 GB, and a 1.79 GB dataset is 1.79 GB of resident memory here, so reach for it at the small end. `client.database().metadata(id, .{})` publishes the size per format without transferring anything, which is how you find out which end you are at.

`downloadUrl` hands back the link rather than the bytes, so you choose how to move the file; the link authorizes the START of a transfer, so one already running is not interrupted when it lapses. The client never follows that redirect for you. `download` and `downloadBytes` do follow it, and that second request carries no API key: the link authorizes itself, and object storage has no business holding your credential.

### Absent is not false

Every field beyond `ip` and `is_vpn` is optional, because your plan decides which of them the API sends. `null` means "not in your plan", not "checked, and no".

```zig
const hosting = result.value.is_hosting orelse false; // when you only want the flag
if (result.value.is_hosting == null) { ... }          // not in your plan
```

## Other Libraries

There are official VPNDetection client libraries available for many languages including PHP, Python, Go, Java, Ruby, and many popular frameworks such as Django, Rails, and Laravel. See our GitHub at https://github.com/vpndetection-io for more.

## About VPNDetection

VPN Detection API: Accurate anonymity detection identifying VPNs, residential proxies, hosting servers, Tor nodes, CDNs, relays and more.

[<img src="https://s3.vpndetection.io/vpndetection-public/brand/mark.svg" alt="VPNDetection" width="96"/>](https://vpndetection.io/)

## License

This project is licensed under the [MIT License](LICENSE).
