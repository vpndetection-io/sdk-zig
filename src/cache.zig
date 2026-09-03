const std = @import("std");

const Allocator = std.mem.Allocator;
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
pub const Cache = struct {
    gpa: Allocator,
    max: usize,
    ttl: Io.Duration,
    mutex: Io.Mutex = .init,
    /// Most recently used first.
    order: std.DoublyLinkedList = .{},
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,

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
        self.* = undefined;
    }

    /// A copy of the cached body, owned by the CALLER, or null on a miss. An
    /// entry past its time to live is dropped rather than returned.
    pub fn get(self: *Cache, io: Io, key: []const u8, gpa: Allocator) Allocator.Error!?[]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const entry = self.entries.get(key) orelse return null;
        if (Io.Clock.awake.now(io).nanoseconds >= entry.expires.nanoseconds) {
            _ = self.entries.remove(entry.key);
            self.order.remove(&entry.node);
            self.destroy(entry);
            return null;
        }
        self.order.remove(&entry.node);
        self.order.prepend(&entry.node);
        return try gpa.dupe(u8, entry.body);
    }

    /// Copies `body` in under `key`, evicting the least recently used entry when
    /// the cache is full. A failure to allocate leaves the cache untouched: a
    /// missing cache entry is a cost, not an error, so it is never propagated.
    pub fn put(self: *Cache, io: Io, key: []const u8, body: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

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
