//! A loopback origin that FORWARDS to the staging API and records derived facts
//! about every request the library makes.
//!
//! The library builds its own `std.http.Client` and offers no seam to wrap, so
//! this is how a Zig suite gets what the Go and Swift ones get from a recording
//! transport: whether the key reached the wire, how many requests one call took,
//! and the untouched body of an answer the typed model cannot show.
//!
//! **Only derived facts leave here.** A failing expectation prints its operands
//! and these logs are public, so what is remembered about a key is a BOOLEAN;
//! the header itself is never stored and never printed.
//!
//! The presigned dataset transfer does not pass through here: the `Location` a
//! 302 carries is absolute, so the library goes straight to object storage. That
//! request is asserted in the library's own suite, against a stub that can see
//! both halves at once.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// What a test is allowed to remember about one request.
pub const Fact = struct {
    /// Path only. A query string carries the dataset id and the format, and on
    /// some endpoints an API key, so it is dropped before anything is stored.
    path: []const u8,
    /// Whether the request carried the tier's key. Without this a rung is
    /// indistinguishable from an unauthenticated one, and every containment
    /// check against it is vacuously true.
    carried_key: bool,
    status: u16,
};

pub const Proxy = struct {
    gpa: Allocator,
    io: Io,
    /// The upstream origin, e.g. `https://api-staging.vpndetection.io`.
    upstream: []const u8,
    /// Compared against what arrives, never stored or printed.
    key: []const u8,
    /// Owns every string the proxy records, so tearing one down is one free.
    arena: std.heap.ArenaAllocator,
    server: Io.net.Server,
    port: u16,
    accepting: Io.Future(void) = undefined,
    connections: Io.Group = .init,
    mutex: Io.Mutex = .init,
    facts: std.ArrayList(Fact) = .empty,
    bodies: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    /// No answer from these endpoints is big. The dataset itself never passes
    /// through, so anything at this size means the proxy was pointed at
    /// something it has no business buffering.
    pub const max_body_bytes = 4 * 1024 * 1024;

    pub fn start(gpa: Allocator, io: Io, upstream: []const u8, key: []const u8) !*Proxy {
        const self = try gpa.create(Proxy);
        errdefer gpa.destroy(self);
        var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const server = try address.listen(io, .{});
        self.* = .{
            .gpa = gpa,
            .io = io,
            .upstream = upstream,
            .key = key,
            .arena = .init(gpa),
            .server = server,
            .port = server.socket.address.getPort(),
        };
        // `concurrent` rather than `async`: an `async` task may run inline when
        // the pool is full, and an accept loop that runs inline never returns.
        self.accepting = try io.concurrent(acceptLoop, .{self});
        return self;
    }

    pub fn deinit(self: *Proxy) void {
        // Cancelling is what makes the blocked accept return: it is a
        // cancelation point, so the loop ends there rather than on the next
        // connection that happens to arrive.
        self.accepting.cancel(self.io);
        self.connections.await(self.io) catch {};
        self.server.deinit(self.io);

        self.facts.deinit(self.gpa);
        self.bodies.deinit(self.gpa);
        self.arena.deinit();
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    /// What to give the client as its base URL.
    pub fn baseUrl(self: *Proxy, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}", .{self.port}) catch unreachable;
    }

    /// Every request so far, in order. Sound to read once the call under test
    /// has returned.
    pub fn seen(self: *Proxy) []const Fact {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.facts.items;
    }

    pub fn carriedKey(self: *Proxy) bool {
        for (self.seen()) |fact| {
            if (fact.carried_key) {
                return true;
            }
        }
        return false;
    }

    /// The untouched answer to `path`, which is the only way to see a field the
    /// typed model has no home for.
    pub fn body(self: *Proxy, path: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.bodies.get(path);
    }
};

fn acceptLoop(self: *Proxy) void {
    while (true) {
        const stream = self.server.accept(self.io) catch return;
        self.connections.concurrent(self.io, serve, .{ self, stream }) catch {
            serve(self, stream);
        };
    }
}

/// One request in, one forwarded, one answer back.
fn serve(self: *Proxy, stream: Io.net.Stream) void {
    defer stream.close(self.io);

    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(self.io, &read_buffer);
    var head_buffer: [16 * 1024]u8 = undefined;
    const head = readHead(&reader.interface, &head_buffer) catch return;
    const target = requestTarget(head) orelse return;
    const authorization = headerValue(head, "authorization") orelse "";

    const answer = forward(self, target, authorization) catch |err| {
        // A proxy that cannot reach staging must not look like an API answer:
        // 502 with the cause is what a test sees.
        var message: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&message, "{{\"rc\":\"PROXY_{s}\"}}", .{@errorName(err)}) catch
            "{\"rc\":\"PROXY_FAILED\"}";
        record(self, target, authorization, 502, null);
        writeResponse(self.io, stream, .{ .status = 502, .body = body }) catch {};
        return;
    };
    record(self, target, authorization, answer.status, answer.body);
    writeResponse(self.io, stream, answer) catch {};
}

const Answer = struct {
    status: u16,
    body: []const u8 = "",
    content_type: ?[]const u8 = null,
    location: ?[]const u8 = null,
    retry_after: ?[]const u8 = null,
};

/// Issues the same GET upstream, carrying the credential through untouched.
///
/// Redirects are NOT followed: the 302 the download endpoint answers with is
/// the thing under test, and it has to reach the library.
fn forward(self: *Proxy, target: []const u8, authorization: []const u8) !Answer {
    const arena = self.arena.allocator();
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.upstream, target });

    var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
    defer client.deinit();

    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = if (authorization.len > 0) .{ .override = authorization } else .omit,
            .user_agent = .{ .override = "vpndetection-zig-integration" },
        },
    });
    defer request.deinit();
    try request.sendBodiless();
    var response = try request.receiveHead(&.{});

    var answer: Answer = .{ .status = @intFromEnum(response.head.status) };
    answer.content_type = try own(arena, response.head.content_type);
    answer.location = try own(arena, response.head.location);
    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            answer.retry_after = try arena.dupe(u8, header.value);
        }
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const decompress_buffer = try arena.alloc(u8, response.head.content_encoding.minBufferCapacity());
    const body = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    answer.body = try body.allocRemaining(arena, .limited(Proxy.max_body_bytes));
    return answer;
}

fn own(arena: Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try arena.dupe(u8, text) else null;
}

fn record(self: *Proxy, target: []const u8, authorization: []const u8, status: u16, body: ?[]const u8) void {
    const arena = self.arena.allocator();
    const query = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = arena.dupe(u8, target[0..query]) catch return;
    // A boolean, computed here and never stored: the header itself is a
    // credential and these logs are public.
    const carried = self.key.len > 0 and std.mem.indexOf(u8, authorization, self.key) != null;

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.facts.append(self.gpa, .{ .path = path, .carried_key = carried, .status = status }) catch {};
    if (body) |bytes| {
        self.bodies.put(self.gpa, path, bytes) catch {};
    }
}

fn writeResponse(io: Io, stream: Io.net.Stream, answer: Answer) !void {
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    const out = &writer.interface;
    try out.print("HTTP/1.1 {d} X\r\nContent-Length: {d}\r\nConnection: close\r\n", .{
        answer.status,
        answer.body.len,
    });
    if (answer.content_type) |value| {
        try out.print("Content-Type: {s}\r\n", .{value});
    }
    if (answer.location) |value| {
        try out.print("Location: {s}\r\n", .{value});
    }
    if (answer.retry_after) |value| {
        try out.print("Retry-After: {s}\r\n", .{value});
    }
    try out.writeAll("\r\n");
    try out.writeAll(answer.body);
    try out.flush();
    try stream.shutdown(io, .both);
}

fn readHead(reader: *Io.Reader, out: []u8) ![]const u8 {
    var len: usize = 0;
    while (true) {
        const line = try reader.takeDelimiterInclusive('\n');
        if (len + line.len > out.len) {
            return error.HeadTooLong;
        }
        @memcpy(out[len..][0..line.len], line);
        len += line.len;
        if (line.len <= 2) {
            return out[0..len];
        }
    }
}

fn requestTarget(head: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return null;
    var parts = std.mem.tokenizeScalar(u8, head[0..line_end], ' ');
    _ = parts.next() orelse return null;
    return parts.next();
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}
