const std = @import("std");

const bogon = @import("bogon.zig");
const cache_mod = @import("cache.zig");
const database_mod = @import("database.zig");
const errors = @import("errors.zig");
const http = @import("http.zig");
const lookup_mod = @import("lookup.zig");

const Allocator = std.mem.Allocator;
const CallError = errors.CallError;
const Diagnostics = errors.Diagnostics;
const Io = std.Io;
const Lookup = lookup_mod.Lookup;

/// The production API. Override it with `Options.base_url`.
pub const default_base_url = "https://api.vpndetection.io";

pub const CacheOptions = struct {
    /// Maximum number of addresses held.
    max_entries: usize = 10_000,
    /// How long an answer stays fresh.
    ttl: Io.Duration = .fromSeconds(60 * 60),
};

pub const Options = struct {
    /// Omit it entirely to use the free tier, which answers `ip` and `is_vpn`
    /// and allows 1000 requests per day per source address.
    api_key: ?[]const u8 = null,
    base_url: []const u8 = default_base_url,
    /// Null disables caching, so every lookup of a non-bogon address is served.
    cache: ?CacheOptions = .{},
    /// Concurrent in-flight requests during a batch.
    concurrency: usize = 8,
    /// Further attempts a transient failure gets.
    retries: u32 = 2,
};

/// Per-call overrides for one request. Anything left null falls back to the
/// client's setting.
pub const CallOptions = struct {
    retries: ?u32 = null,
    /// Filled in with the status, the wait and the API's own explanation when
    /// the call fails. A Zig error carries no payload, so this is how the
    /// detail behind one is reached.
    diagnostics: ?*Diagnostics = null,
};

/// Per-call overrides for one batch.
///
/// `concurrency` lives here and not on `CallOptions`, so passing it to a
/// single lookup does not compile rather than being accepted and ignored.
pub const BatchOptions = struct {
    retries: ?u32 = null,
    /// In-flight requests for THIS batch only, so one large batch does not need
    /// a second client to widen it.
    concurrency: ?usize = null,
};

/// A client for the VPNDetection API.
///
/// Everything it returns is allocated with the allocator passed to `init` and
/// is owned by the caller: a `Lookup` and a `Batch` each carry a `deinit`, and a
/// `downloadUrl` is a slice to free.
///
/// Safe to share between concurrent tasks. Do NOT copy it after `init`: like
/// `std.http.Client`, it holds intrusive lists that point at themselves.
///
/// The cache is per instance and never global: two clients holding different API
/// keys are on different plans and entitled to different fields, so a shared
/// cache would serve one of them the other's shape.
pub const Client = struct {
    gpa: Allocator,
    io: Io,
    transport: http.Transport,
    cache: ?cache_mod.Cache,
    concurrency: usize,
    retries: u32,

    pub const InitError = Allocator.Error || error{InvalidBaseUrl};

    /// `io` is the same `std.Io` implementation the rest of your program uses;
    /// `std.Io.Threaded` is the usual one, and a batch is only as concurrent as
    /// the implementation you pass here allows.
    pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Client {
        std.debug.assert(options.concurrency > 0);

        const base_url = std.mem.trimEnd(u8, options.base_url, "/");
        const uri = std.Uri.parse(base_url) catch return error.InvalidBaseUrl;
        if (uri.host == null) {
            return error.InvalidBaseUrl;
        }

        const owned_base_url = try gpa.dupe(u8, base_url);
        errdefer gpa.free(owned_base_url);

        // Bearer only. The API also accepts X-Api-Key and ?apikey=; a key
        // belongs in one header, not in a query string a proxy will log.
        const authorization = if (options.api_key) |key|
            try std.fmt.allocPrint(gpa, "Bearer {s}", .{key})
        else
            null;
        errdefer if (authorization) |value| gpa.free(value);

        var cache: ?cache_mod.Cache = null;
        if (options.cache) |settings| {
            std.debug.assert(settings.max_entries > 0);
            std.debug.assert(settings.ttl.nanoseconds > 0);
            cache = .init(gpa, settings.max_entries, settings.ttl);
        }

        return .{
            .gpa = gpa,
            .io = io,
            .transport = .{
                .http = .{ .allocator = gpa, .io = io },
                .base_url = owned_base_url,
                .authorization = authorization,
            },
            .cache = cache,
            .concurrency = options.concurrency,
            .retries = options.retries,
        };
    }

    pub fn deinit(self: *Client) void {
        self.transport.deinit();
        self.gpa.free(self.transport.base_url);
        if (self.transport.authorization) |value| {
            self.gpa.free(value);
        }
        if (self.cache) |*cache| {
            cache.deinit();
        }
        self.* = undefined;
    }

    /// Whether an address is answered locally rather than served. Exposed here
    /// so the check is reachable from the client you already hold; the free
    /// `vpndetection.isBogon` is the same function.
    pub fn isBogon(_: *Client, ip: []const u8) bool {
        return bogon.isBogon(ip);
    }

    /// Classifies one address. The caller owns the result and must `deinit` it.
    ///
    /// A bogon is answered locally and never reaches the network. Everything
    /// else is served, then cached for this client.
    pub fn lookup(self: *Client, ip: []const u8) CallError!Lookup {
        return self.lookupWith(ip, .{});
    }

    /// `lookup`, with this call's own retry budget and somewhere to put the
    /// detail behind a failure.
    pub fn lookupWith(self: *Client, ip: []const u8, options: CallOptions) CallError!Lookup {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        diag.reset();

        if (bogon.isBogon(ip)) {
            return lookup_mod.bogonLookup(self.gpa, ip);
        }
        if (self.cache) |*cache| {
            if (try cache.get(self.io, ip, self.gpa)) |cached| {
                defer self.gpa.free(cached);
                return self.parse(cached, diag);
            }
        }

        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(self.gpa);
        try path.append(self.gpa, '/');
        try http.appendEncoded(self.gpa, &path, ip);

        const body = try http.send(&self.transport, self.gpa, self.io, .{
            .path = path.items,
            .retries = options.retries orelse self.retries,
            .diagnostics = diag,
        });
        defer self.gpa.free(body);

        const result = try self.parse(body, diag);
        if (self.cache) |*cache| {
            cache.put(self.io, ip, body);
        }
        return result;
    }

    /// Classifies many addresses concurrently. The caller owns the batch and
    /// must `deinit` it, which frees every answer inside it.
    ///
    /// The answers are keyed by address rather than positional, so duplicates in
    /// the input collapse to a single request and the caller never has to line
    /// two lists up. Keys are in the order the addresses were first seen. An
    /// address that fails carries its error as its value, so one bad entry
    /// cannot lose the rest of the answers.
    pub fn lookupBatch(
        self: *Client,
        ips: []const []const u8,
        options: BatchOptions,
    ) Allocator.Error!Batch {
        var batch: Batch = .{ .gpa = self.gpa };
        errdefer batch.deinit();
        for (ips) |ip| {
            if (batch.entries.contains(ip)) {
                continue;
            }
            const key = try self.gpa.dupe(u8, ip);
            errdefer self.gpa.free(key);
            try batch.entries.put(self.gpa, key, .{ .failed = .{ .err = error.Network } });
        }

        var work: Work = .{
            .client = self,
            .ips = batch.entries.keys(),
            .entries = batch.entries.values(),
            .next = .init(0),
            .retries = options.retries,
        };
        if (work.ips.len == 0) {
            return batch;
        }

        const limit = @max(1, options.concurrency orelse self.concurrency);
        const workers = @min(limit, work.ips.len);
        const helpers = try self.gpa.alloc(Io.Future(void), workers - 1);
        defer self.gpa.free(helpers);

        // The caller is the last worker, so the batch still completes on an Io
        // that cannot give us a second task. Peak in-flight requests is the
        // number of workers, because each one holds at most one request.
        var spawned: usize = 0;
        while (spawned < helpers.len) : (spawned += 1) {
            helpers[spawned] = self.io.concurrent(runWorker, .{&work}) catch break;
        }
        runWorker(&work);
        for (helpers[0..spawned]) |*helper| {
            _ = helper.await(self.io);
        }
        return batch;
    }

    /// The licensed dataset downloads, for keys carrying the `db.download`
    /// scope.
    pub fn database(self: *Client) database_mod.Database {
        return .{ .client = self };
    }

    fn parse(self: *Client, body: []const u8, diag: *Diagnostics) CallError!Lookup {
        return lookup_mod.parseServed(self.gpa, body) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Malformed => {
                diag.setMessage("the answer was not a lookup response");
                return error.ServerError;
            },
        };
    }
};

/// What a batch answers: one entry per distinct address, in the order the
/// addresses were first seen.
pub const Batch = struct {
    gpa: Allocator,
    entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,

    pub const Entry = union(enum) {
        ok: Lookup,
        failed: Failure,
    };

    /// A failure carries its own diagnostics, so one bad address in a batch
    /// still explains itself.
    pub const Failure = struct {
        err: CallError,
        diagnostics: Diagnostics = .{},
    };

    pub fn deinit(self: *Batch) void {
        for (self.entries.keys()) |key| {
            self.gpa.free(key);
        }
        for (self.entries.values()) |entry| {
            switch (entry) {
                .ok => |answer| answer.deinit(),
                .failed => {},
            }
        }
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn get(self: *const Batch, ip: []const u8) ?Entry {
        return self.entries.get(ip);
    }

    /// The addresses, in the order they were first seen.
    pub fn keys(self: *const Batch) []const []const u8 {
        return self.entries.keys();
    }

    pub fn values(self: *const Batch) []const Entry {
        return self.entries.values();
    }

    pub fn count(self: *const Batch) usize {
        return self.entries.count();
    }
};

const Work = struct {
    client: *Client,
    ips: []const []const u8,
    entries: []Batch.Entry,
    next: std.atomic.Value(usize),
    retries: ?u32,
};

/// Each worker takes the next address until there are none left, so in-flight
/// requests never exceed the worker count and a slow address cannot leave a
/// worker idle. Every entry is written by exactly one worker, at its own index.
fn runWorker(work: *Work) void {
    while (true) {
        const index = work.next.fetchAdd(1, .monotonic);
        if (index >= work.ips.len) {
            return;
        }
        var diagnostics: Diagnostics = .{};
        const answer = work.client.lookupWith(work.ips[index], .{
            .retries = work.retries,
            .diagnostics = &diagnostics,
        });
        work.entries[index] = if (answer) |value|
            .{ .ok = value }
        else |err|
            .{ .failed = .{ .err = err, .diagnostics = diagnostics } };
    }
}
