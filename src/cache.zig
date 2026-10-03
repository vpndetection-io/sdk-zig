const std = @import("std");

const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
const CallError = errors.CallError;
const Diagnostics = errors.Diagnostics;
const Io = std.Io;

/// A per-client answer cache: least-recently-used eviction, with a time to live.
///
/// It holds response BODIES rather than parsed answers, and hands out a copy, so
/// a cached answer can never be freed underneath the caller by another thread's
/// eviction. Parsing a small JSON body again is cheaper than the lifetime rules
/// the alternative would need.
///
/// Never global or static: two clients with different API keys are on different
/// plans and entitled to different fields, so a shared cache would serve one of
/// them the other's shape.
///
/// It also holds the addresses being asked about, so callers that miss at the
/// same moment share one request: the first `claim` leads a `Flight`, every
/// later one waits for what the leader `land`s. A miss and its flight are
/// decided under one lock, so a caller never misses both a body just landed and
/// the flight that landed it.
pub const Cache = struct {
    gpa: Allocator,
    max: usize,
    ttl: Io.Duration,
    mutex: Io.Mutex = .init,
    /// Most recently used first.
    order: std.DoublyLinkedList = .{},
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,
    flights: std.StringHashMapUnmanaged(*Flight) = .empty,

    const Entry = struct {
        node: std.DoublyLinkedList.Node = .{},
        key: []u8,
        body: []u8,
        expires: Io.Timestamp,
    };

    pub fn init(gpa: Allocator, max: usize, ttl: Io.Duration) Cache {
        return .{ .gpa = gpa, .max = max, .ttl = ttl };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            self.destroy(entry.*);
        }
        self.entries.deinit(self.gpa);
        std.debug.assert(self.flights.count() == 0);
        self.flights.deinit(self.gpa);
        self.* = undefined;
    }

    /// What a failed request hands each caller that waited for it.
    pub const Failure = struct {
        err: CallError,
        diagnostics: Diagnostics,
    };

    /// One address being asked about. Counted, because a waiter still holds it
    /// after its leader has taken it off the board.
    pub const Flight = struct {
        refs: usize = 1,
        state: union(enum) {
            flying,
            /// A copy of the answer, held only while someone waits for it.
            served: []u8,
            failed: Failure,
            /// The leader stopped without an answer: its task was canceled, or it
            /// could not keep one. A waiter asks again.
            abandoned,
        } = .flying,
        landed: Io.Condition = .init,
    };

    pub const Claim = union(enum) {
        /// A copy of the cached body, owned by the caller.
        hit: []u8,
        /// Nobody is asking about the address: the caller asks, and must `land`
        /// what it gets, whatever it gets.
        lead: *Flight,
        /// Someone already is: the caller `wait`s for it.
        wait: *Flight,
    };

    pub const Outcome = union(enum) {
        served: []const u8,
        failed: Failure,
        abandoned,
    };

    pub const Landing = union(enum) {
        /// A copy of the body, owned by the caller.
        served: []u8,
        failed: Failure,
        abandoned,
    };

    /// A fresh cached body, or the flight to lead or to wait for.
    pub fn claim(self: *Cache, io: Io, key: []const u8, gpa: Allocator) Allocator.Error!Claim {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.live(io, key)) |entry| {
            return .{ .hit = try gpa.dupe(u8, entry.body) };
        }
        if (self.flights.get(key)) |flight| {
            flight.refs += 1;
            return .{ .wait = flight };
        }
        const flight = try self.gpa.create(Flight);
        errdefer self.gpa.destroy(flight);
        flight.* = .{};
        const owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned);
        try self.flights.put(self.gpa, owned, flight);
        return .{ .lead = flight };
    }

    /// Ends a flight the caller leads: a served body is cached, a failure is
    /// cached for no one, and every waiter is woken with a copy of either.
    pub fn land(self: *Cache, io: Io, key: []const u8, flight: *Flight, outcome: Outcome) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.flights.fetchRemove(key)) |removed| {
            std.debug.assert(removed.value == flight);
            self.gpa.free(removed.key);
        }
        const waited = flight.refs > 1;
        flight.state = switch (outcome) {
            .served => |body| blk: {
                self.store(io, key, body);
                if (!waited) break :blk .abandoned;
                // Out of memory, a waiter asks again rather than failing.
                break :blk if (self.gpa.dupe(u8, body)) |copy| .{ .served = copy } else |_| .abandoned;
            },
            .failed => |failure| .{ .failed = failure },
            .abandoned => .abandoned,
        };
        flight.landed.broadcast(io);
        self.release(flight);
    }

    /// Waits for the flight to land and lets go of it. A cancelation lets go of
    /// it too and leaves the request to its leader.
    pub fn wait(self: *Cache, io: Io, flight: *Flight, gpa: Allocator) (Allocator.Error || Io.Cancelable)!Landing {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        defer self.release(flight);

        while (flight.state == .flying) {
            try flight.landed.wait(io, &self.mutex);
        }
        return switch (flight.state) {
            .flying => unreachable,
            .served => |body| .{ .served = try gpa.dupe(u8, body) },
            .failed => |failure| .{ .failed = failure },
            .abandoned => .abandoned,
        };
    }

    /// Lets go of a flight the caller was to wait for without waiting.
    pub fn leave(self: *Cache, io: Io, flight: *Flight) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.release(flight);
    }

    fn release(self: *Cache, flight: *Flight) void {
        flight.refs -= 1;
        if (flight.refs > 0) {
            return;
        }
        if (flight.state == .served) {
            self.gpa.free(flight.state.served);
        }
        self.gpa.destroy(flight);
    }

    /// The entry under `key` while it is fresh. One past its time to live is
    /// dropped. The caller holds the lock.
    fn live(self: *Cache, io: Io, key: []const u8) ?*Entry {
        const entry = self.entries.get(key) orelse return null;
        if (Io.Clock.awake.now(io).nanoseconds >= entry.expires.nanoseconds) {
            _ = self.entries.remove(entry.key);
            self.order.remove(&entry.node);
            self.destroy(entry);
            return null;
        }
        self.order.remove(&entry.node);
        self.order.prepend(&entry.node);
        return entry;
    }

    /// A copy of the cached body, owned by the CALLER, or null on a miss. An
    /// entry past its time to live is dropped rather than returned.
    pub fn get(self: *Cache, io: Io, key: []const u8, gpa: Allocator) Allocator.Error!?[]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const entry = self.live(io, key) orelse return null;
        return try gpa.dupe(u8, entry.body);
    }

    /// Copies `body` in under `key`, evicting the least recently used entry when
    /// the cache is full. A failure to allocate leaves the cache untouched: a
    /// missing cache entry is a cost, not an error, so it is never propagated.
    pub fn put(self: *Cache, io: Io, key: []const u8, body: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.store(io, key, body);
    }

    /// `put`, for a caller that holds the lock.
    fn store(self: *Cache, io: Io, key: []const u8, body: []const u8) void {
        const expires = Io.Clock.awake.now(io).addDuration(self.ttl);
        if (self.entries.get(key)) |existing| {
            const fresh = self.gpa.dupe(u8, body) catch return;
            self.gpa.free(existing.body);
            existing.body = fresh;
            existing.expires = expires;
            self.order.remove(&existing.node);
            self.order.prepend(&existing.node);
            return;
        }

        const entry = self.gpa.create(Entry) catch return;
        entry.* = .{ .key = undefined, .body = undefined, .expires = expires };
        entry.key = self.gpa.dupe(u8, key) catch {
            self.gpa.destroy(entry);
            return;
        };
        entry.body = self.gpa.dupe(u8, body) catch {
            self.gpa.free(entry.key);
            self.gpa.destroy(entry);
            return;
        };
        self.entries.put(self.gpa, entry.key, entry) catch {
            self.destroy(entry);
            return;
        };
        self.order.prepend(&entry.node);
        if (self.entries.count() > self.max) {
            self.evictOldest();
        }
    }

    fn evictOldest(self: *Cache) void {
        const node = self.order.pop() orelse return;
        const entry: *Entry = @alignCast(@fieldParentPtr("node", node));
        _ = self.entries.remove(entry.key);
        self.destroy(entry);
    }

    fn destroy(self: *Cache, entry: *Entry) void {
        self.gpa.free(entry.key);
        self.gpa.free(entry.body);
        self.gpa.destroy(entry);
    }
};

test "an entry survives until its ttl and is then a miss" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cache: Cache = .init(gpa, 10, .fromMilliseconds(40));
    defer cache.deinit();

    cache.put(io, "1.1.1.1", "{\"ip\":\"1.1.1.1\"}");
    const hit = (try cache.get(io, "1.1.1.1", gpa)).?;
    defer gpa.free(hit);
    try std.testing.expectEqualStrings("{\"ip\":\"1.1.1.1\"}", hit);

    try io.sleep(.fromMilliseconds(60), .awake);
    try std.testing.expect(try cache.get(io, "1.1.1.1", gpa) == null);
}

test "the least recently used entry is the one evicted" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cache: Cache = .init(gpa, 2, .fromSeconds(60));
    defer cache.deinit();

    cache.put(io, "a", "1");
    cache.put(io, "b", "2");
    // Touching "a" makes "b" the oldest, so "b" is what the third insert costs.
    const touched = (try cache.get(io, "a", gpa)).?;
    gpa.free(touched);
    cache.put(io, "c", "3");

    try std.testing.expect(try cache.get(io, "b", gpa) == null);
    for ([_][]const u8{ "a", "c" }) |key| {
        const kept = (try cache.get(io, key, gpa)).?;
        gpa.free(kept);
    }
}
