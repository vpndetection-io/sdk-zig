const std = @import("std");

const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
const CallError = errors.CallError;
const Diagnostics = errors.Diagnostics;
const Io = std.Io;

const retry_base_delay: Io.Duration = .fromMilliseconds(250);
const retry_max_delay: Io.Duration = .fromSeconds(30);

/// One request, and what to do if it fails.
pub const Request = struct {
    /// Whether the answer is the body or the `Location` of a redirect.
    kind: enum { json, location } = .json,
    path: []const u8,
    query: []const Transport.Param = &.{},
    retries: u32,
    diagnostics: *Diagnostics,
};

/// Retries a transient failure, waiting whatever the server asked for over the
/// caller's own backoff. A 429 WITHOUT `Retry-After` is a spent allowance rather
/// than a throttle and is not retried at all.
pub fn send(transport: *Transport, gpa: Allocator, io: Io, request: Request) CallError![]u8 {
    const diag = request.diagnostics;
    var delay = retry_base_delay;
    var remaining = request.retries;
    while (true) {
        diag.reset();
        const attempt = switch (request.kind) {
            .json => transport.getJson(gpa, request.path, request.query, diag),
            .location => transport.getLocation(gpa, request.path, request.query, diag),
        };
        if (attempt) |body| {
            return body;
        } else |err| {
            if (remaining == 0 or !errors.isRetryable(err)) {
                return err;
            }
            const wait: Io.Duration = if (diag.retry_after_s) |seconds|
                .fromSeconds(@intCast(seconds))
            else
                delay;
            io.sleep(wait, .awake) catch return err;
            delay = .fromNanoseconds(@min(delay.nanoseconds * 2, retry_max_delay.nanoseconds));
            remaining -= 1;
        }
    }
}

/// Every request the library makes: six GET operations with no request bodies,
/// which is the whole API.
pub const Transport = struct {
    http: std.http.Client,
    /// Without a trailing slash.
    base_url: []const u8,
    /// `Authorization: Bearer <key>`, built once and owned, so a caller is free
    /// to drop the key it passed in.
    authorization: ?[]const u8,

    /// A response body may not exceed this. The largest thing the API answers
    /// with is a metadata document; anything at this size is a server fault
    /// rather than an answer worth buffering.
    pub const max_body_bytes = 16 * 1024 * 1024;

    pub const Param = struct { name: []const u8, value: []const u8 };

    pub fn deinit(self: *Transport) void {
        self.http.deinit();
    }

    /// The body of a 2xx JSON response, owned by `gpa`.
    pub fn getJson(
        self: *Transport,
        gpa: Allocator,
        path: []const u8,
        query: []const Param,
        diag: *Diagnostics,
    ) CallError![]u8 {
        const url = try self.buildUrl(gpa, path, query);
        defer gpa.free(url);

        var request = try self.open(url, diag);
        defer request.deinit();
        var response = request.receiveHead(&.{}) catch |err| return fail(diag, err);

        const status = @intFromEnum(response.head.status);
        diag.status = status;
        const retry_after = readRetryAfter(response.head);
        diag.retry_after_s = retry_after.seconds;

        const body = try readBody(&response, gpa, diag);
        if (status < 200 or status >= 300) {
            defer gpa.free(body);
            if (errors.envelopeMessage(gpa, body)) |message| {
                defer gpa.free(message);
                diag.setMessage(message);
            }
            return errors.classify(status, retry_after.present);
        }
        return body;
    }

    /// The `Location` of a redirect this client must NOT follow, owned by `gpa`.
    ///
    /// The download endpoint answers 302 to object storage, and the dataset
    /// behind it routinely runs to gigabytes, so following it would transfer the
    /// whole file to hand back a link. Every request is made with
    /// `redirect_behavior = .unhandled`, which is not `std.http.Client`'s
    /// default: left alone it follows up to three.
    pub fn getLocation(
        self: *Transport,
        gpa: Allocator,
        path: []const u8,
        query: []const Param,
        diag: *Diagnostics,
    ) CallError![]u8 {
        const url = try self.buildUrl(gpa, path, query);
        defer gpa.free(url);

        var request = try self.open(url, diag);
        defer request.deinit();
        var response = request.receiveHead(&.{}) catch |err| return fail(diag, err);

        const status = @intFromEnum(response.head.status);
        diag.status = status;
        const retry_after = readRetryAfter(response.head);
        diag.retry_after_s = retry_after.seconds;

        if (status >= 300 and status < 400) {
            const location = response.head.location orelse {
                diag.setMessage("the redirect carried no Location header");
                return error.ServerError;
            };
            return try gpa.dupe(u8, location);
        }
        if (status >= 200 and status < 300) {
            diag.setMessage("expected a redirect to object storage");
            return error.ServerError;
        }
        const body = try readBody(&response, gpa, diag);
        defer gpa.free(body);
        if (errors.envelopeMessage(gpa, body)) |message| {
            defer gpa.free(message);
            diag.setMessage(message);
        }
        return errors.classify(status, retry_after.present);
    }

    fn open(self: *Transport, url: []const u8, diag: *Diagnostics) CallError!std.http.Client.Request {
        const uri = std.Uri.parse(url) catch |err| return fail(diag, err);
        var request = self.http.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = if (self.authorization) |value| .{ .override = value } else .omit,
                .user_agent = .{ .override = user_agent },
            },
        }) catch |err| return fail(diag, err);
        errdefer request.deinit();
        request.sendBodiless() catch |err| return fail(diag, err);
        return request;
    }

    fn buildUrl(
        self: *Transport,
        gpa: Allocator,
        path: []const u8,
        query: []const Param,
    ) Allocator.Error![]u8 {
        var url: std.ArrayList(u8) = .empty;
        errdefer url.deinit(gpa);
        try url.appendSlice(gpa, self.base_url);
        try url.appendSlice(gpa, path);
        for (query, 0..) |param, i| {
            try url.append(gpa, if (i == 0) '?' else '&');
            try url.appendSlice(gpa, param.name);
            try url.append(gpa, '=');
            try appendEncoded(gpa, &url, param.value);
        }
        return url.toOwnedSlice(gpa);
    }

    /// A transport failure is worth another attempt whatever its cause, so every
    /// one of them is `error.Network` and the specific cause goes to the
    /// diagnostics rather than into the error set.
    fn fail(diag: *Diagnostics, err: anyerror) errors.Error {
        diag.setMessage(@errorName(err));
        return error.Network;
    }
};

/// The library's own user agent, so a request from it is identifiable in a log.
pub const user_agent = "vpndetection-zig/" ++ @import("build_options").version;

fn readBody(
    response: *std.http.Client.Response,
    gpa: Allocator,
    diag: *Diagnostics,
) CallError![]u8 {
    var decompress_buffer: []u8 = &.{};
    defer gpa.free(decompress_buffer);
    switch (response.head.content_encoding) {
        .identity => {},
        .compress => {
            diag.setMessage("unsupported content encoding");
            return error.ServerError;
        },
        else => |encoding| {
            decompress_buffer = try gpa.alloc(u8, encoding.minBufferCapacity());
        },
    }
    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return reader.allocRemaining(gpa, .limited(Transport.max_body_bytes)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // A body that stops mid-transfer is a transport failure, and one that
        // never stops is a server fault; neither is the API saying no.
        error.ReadFailed => Transport.fail(diag, response.bodyErr() orelse error.ReadFailed),
        error.StreamTooLong => blk: {
            diag.setMessage("the response body was too large to buffer");
            break :blk error.ServerError;
        },
    };
}

/// `Retry-After` is seconds or an HTTP date. Its PRESENCE is what makes a 429 a
/// throttle rather than a spent allowance, so the two are read separately: a
/// value that will not parse still counts as the server asking us to wait, and
/// the retry then falls back to the client's own backoff.
fn readRetryAfter(head: std.http.Client.Response.Head) struct { present: bool, seconds: ?u64 } {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            continue;
        }
        const value = std.mem.trim(u8, header.value, " \t");
        return .{ .present = true, .seconds = std.fmt.parseInt(u64, value, 10) catch null };
    }
    return .{ .present = false, .seconds = null };
}

/// Percent-encodes everything outside the unreserved set. An IPv6 literal
/// contains colons, which are legal in a path segment but are worth encoding
/// anyway so an intermediary cannot read one as an authority.
pub fn appendEncoded(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try out.append(gpa, c),
            else => try out.print(gpa, "%{X:0>2}", .{c}),
        }
    }
}

test "an address is percent encoded into the path" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendEncoded(gpa, &out, "2606:4700:4700::1111");
    try std.testing.expectEqualStrings("2606%3A4700%3A4700%3A%3A1111", out.items);
}
