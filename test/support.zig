//! A stub origin that answers from a table and records what it was asked for, so
//! "never touched the network" and "kept at most N in flight" are asserted
//! rather than assumed.
//!
//! Hand-rolled on `std.Io.net` rather than on `std.http.Server` because two of
//! the things that have to be proved here are outside what a conforming server
//! offers: the PEAK number of concurrent connections, and an origin that
//! PROMISES a multi-gigabyte body so a followed redirect is caught by the
//! request count rather than by waiting for the transfer.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const corpus = @import("corpus.zig");

const vpndetection = @import("vpndetection");

/// A response the stub is prepared to give for one path.
pub const Route = struct {
    status: u16 = 200,
    body: []const u8 = "",
    headers: []const Header = &.{},
    /// Sent as `Content-Length` while the body stays empty, so a client that
    /// follows a redirect it should not is told the file is enormous without the
    /// test having to produce one.
    promised_length: ?u64 = null,

    pub const Header = struct { name: []const u8, value: []const u8 };

    pub fn ok(body: []const u8) Route {
        return .{ .body = body };
    }
};

/// One request the stub answered, as much of it as a test is allowed to keep.
pub const Call = struct {
    path: []const u8,
    /// Empty when the request carried no `Authorization` header at all.
    authorization: []const u8,
};

pub const Stub = struct {
    gpa: Allocator,
    io: Io,
    /// Owns every string a test hands to the stub or the stub records, so
    /// tearing one down is a single free.
    arena: std.heap.ArenaAllocator,
    server: Io.net.Server,
    port: u16,
    accepting: Io.Future(void) = undefined,
    connections: Io.Group = .init,
    mutex: Io.Mutex = .init,
    routes: std.StringArrayHashMapUnmanaged(Route) = .empty,
    calls: std.ArrayList(Call) = .empty,
    /// The last `User-Agent` header seen.
    user_agent: []const u8 = "",
    in_flight: usize = 0,
    peak_in_flight: usize = 0,
    delay: Io.Duration = .zero,

    /// Binds an ephemeral port on the loopback and starts serving.
    pub fn start(gpa: Allocator, io: Io) !*Stub {
        const self = try gpa.create(Stub);
        errdefer gpa.destroy(self);
        var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const server = try address.listen(io, .{});
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .server = server,
            .port = server.socket.address.getPort(),
        };
        // `concurrent` rather than `async`: an `async` task is allowed to run
        // inline when the pool is full, and an accept loop that runs inline
        // never returns.
        self.accepting = try io.concurrent(acceptLoop, .{self});
        return self;
    }

    pub fn deinit(self: *Stub) void {
        // Cancelling is what makes the blocked accept return: it is a
        // cancelation point, so the loop ends there rather than on the next
        // connection that happens to arrive.
        self.accepting.cancel(self.io);
        self.connections.await(self.io) catch {};
        self.server.deinit(self.io);

        self.routes.deinit(self.gpa);
        self.calls.deinit(self.gpa);
        self.arena.deinit();
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    pub fn baseUrl(self: *Stub, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}", .{self.port}) catch unreachable;
    }

    pub fn route(self: *Stub, path: []const u8, value: Route) !void {
        const gop = try self.routes.getOrPut(self.gpa, try self.own(path));
        gop.value_ptr.* = value;
    }

    /// A successful free-tier lookup for one address, which is what most cases
    /// want the stub to answer.
    pub fn routeLookup(self: *Stub, ip: []const u8) !void {
        const body = try std.fmt.allocPrint(
            self.arena.allocator(),
            "{{\"ip\":\"{s}\",\"is_vpn\":false}}",
            .{ip},
        );
        try self.route(try self.printed("/{s}", .{ip}), .ok(body));
    }

    pub fn own(self: *Stub, text: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, text);
    }

    pub fn printed(self: *Stub, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), format, args);
    }

    pub fn callCount(self: *Stub) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.calls.items.len;
    }

    /// Every request, in order. The caller holds no lock, so this is only sound
    /// once the client under test has finished.
    pub fn seen(self: *Stub) []const Call {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.calls.items;
    }

    pub fn peak(self: *Stub) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.peak_in_flight;
    }

    /// What the request for `path` carried in its `Authorization` header, empty
    /// when it carried none, and null when `path` was never asked for. Recorded
    /// per request rather than as "the last one seen", because the interesting
    /// question is which of two requests carried the key.
    pub fn authorizationFor(self: *Stub, path: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.calls.items) |call| {
            if (std.mem.eql(u8, call.path, path)) {
                return call.authorization;
            }
        }
        return null;
    }

    pub fn lastUserAgent(self: *Stub) []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.user_agent;
    }

    pub fn calledOnly(self: *Stub, path: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.calls.items.len == 1 and std.mem.eql(u8, self.calls.items[0].path, path);
    }
};

fn acceptLoop(self: *Stub) void {
    while (true) {
        const stream = self.server.accept(self.io) catch return;
        self.connections.concurrent(self.io, serve, .{ self, stream }) catch {
            serve(self, stream);
        };
    }
}

fn serve(self: *Stub, stream: Io.net.Stream) void {
    defer stream.close(self.io);

    var read_buffer: [8192]u8 = undefined;
    var reader = stream.reader(self.io, &read_buffer);
    var head_buffer: [8192]u8 = undefined;
    const head = readHead(&reader.interface, &head_buffer) catch return;
    const target = requestTarget(head) orelse return;

    var decoded_buffer: [256]u8 = undefined;
    const path = percentDecode(target, &decoded_buffer);

    const found = record(self, path, head);
    if (self.delay.nanoseconds > 0) {
        self.io.sleep(self.delay, .awake) catch {};
    }
    // Leave the in-flight window BEFORE writing, so what is measured is the
    // deliberate delay and nothing else. A client stops counting a request the
    // moment it reads the answer, so decrementing after the write measures a
    // window wider than the client's own: on a loaded runner the next request
    // arrives and increments before this thread is scheduled again, and a
    // correctly-bounded batch reads as one OVER its limit.
    release(self);

    // An unrouted address gets what the real API gives one, so a test that
    // forgets a route fails as a bad request rather than as a hang.
    const answer = found orelse Route{
        .status = 400,
        .body = "{\"error\":\"not a valid IP address\"}",
    };
    writeResponse(self.io, stream, answer) catch {};
}

fn release(self: *Stub) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.in_flight -= 1;
}

fn record(self: *Stub, path: []const u8, head: []const u8) ?Route {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    self.in_flight += 1;
    self.peak_in_flight = @max(self.peak_in_flight, self.in_flight);
    const owned = self.arena.allocator().dupe(u8, path) catch return null;
    self.calls.append(self.gpa, .{
        .path = owned,
        .authorization = ownedHeader(self, head, "authorization"),
    }) catch {};
    self.user_agent = ownedHeader(self, head, "user-agent");
    return self.routes.get(path);
}

fn ownedHeader(self: *Stub, head: []const u8, name: []const u8) []const u8 {
    const value = headerValue(head, name) orelse return "";
    return self.arena.allocator().dupe(u8, value) catch "";
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
    const target = parts.next() orelse return null;
    const query = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..query];
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

fn percentDecode(text: []const u8, out: []u8) []const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len and len < out.len) : (len += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 ..][0..2], 16)) |byte| {
                out[len] = byte;
                i += 3;
                continue;
            } else |_| {}
        }
        out[len] = text[i];
        i += 1;
    }
    return out[0..len];
}

fn writeResponse(io: Io, stream: Io.net.Stream, answer: Route) !void {
    var write_buffer: [8192]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    const out = &writer.interface;
    const length = answer.promised_length orelse answer.body.len;
    try out.print("HTTP/1.1 {d} X\r\nContent-Type: application/json\r\n", .{answer.status});
    try out.print("Content-Length: {d}\r\nConnection: close\r\n", .{length});
    for (answer.headers) |header| {
        try out.print("{s}: {s}\r\n", .{ header.name, header.value });
    }
    try out.writeAll("\r\n");
    try out.writeAll(answer.body);
    try out.flush();
    // A promised body that is never written would leave the client waiting for
    // the rest of it, so the connection is closed instead: whoever followed the
    // redirect gets an error, and the request is on the record either way.
    try stream.shutdown(io, .both);
}

/// A stub origin, an `Io` to reach it with, and a client pointed at it: the four
/// lines every test would otherwise repeat.
pub const Harness = struct {
    gpa: Allocator,
    threaded: Io.Threaded,
    stub: *Stub,
    url_buffer: [64]u8 = undefined,

    /// The thread budget is set here rather than left to the CPU count, because
    /// the peak-in-flight measurements need requests to genuinely overlap and a
    /// two-core runner would otherwise serialize them.
    pub fn start(gpa: Allocator) !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .threaded = .init(gpa, .{ .async_limit = .limited(32) }),
            .stub = undefined,
        };
        self.stub = try Stub.start(gpa, self.threaded.io());
        return self;
    }

    pub fn deinit(self: *Harness) void {
        self.stub.deinit();
        self.threaded.deinit();
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    pub fn io(self: *Harness) Io {
        return self.threaded.io();
    }

    pub fn client(self: *Harness, options: vpndetection.Options) !vpndetection.Client {
        var pointed = options;
        pointed.base_url = self.stub.baseUrl(&self.url_buffer);
        return vpndetection.Client.init(self.gpa, self.io(), pointed);
    }
};

/// A scratch directory for a test that needs a real PATH rather than a
/// directory handle, which `Database.download` does.
///
/// Do not copy one after `start`: `path` hands back a slice of its own buffer.
pub const Scratch = struct {
    tmp: std.testing.TmpDir,
    buffer: [128]u8 = undefined,

    pub fn start() Scratch {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    pub fn deinit(self: *Scratch) void {
        self.tmp.cleanup();
    }

    /// `std.testing` puts its temporary directories under `.zig-cache/tmp` and
    /// hands back a handle rather than a path, so the path is spelled the same
    /// way it builds it.
    pub fn path(self: *Scratch, name: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.buffer, ".zig-cache/tmp/{s}/{s}", .{
            &self.tmp.sub_path,
            name,
        }) catch unreachable;
    }

    pub fn exists(self: *Scratch, name: []const u8) bool {
        self.tmp.dir.access(std.testing.io, name, .{}) catch return false;
        return true;
    }

    pub fn read(self: *Scratch, name: []const u8, buffer: []u8) ![]u8 {
        return self.tmp.dir.readFile(std.testing.io, name, buffer);
    }
};
