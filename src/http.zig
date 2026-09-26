const std = @import("std");

const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
const CallError = errors.CallError;
const Diagnostics = errors.Diagnostics;
const Io = std.Io;

pub const retry_base_delay: Io.Duration = .fromMilliseconds(250);
const retry_max_delay: Io.Duration = .fromSeconds(30);

/// The longest timeout a call takes: `std.math.maxInt(i64)` nanoseconds, about
/// 292 years. Near the top of `Io.Duration`'s i96 the deadline `bounded` adds
/// to the clock overflows, which panics rather than failing the call.
pub const max_timeout: Io.Duration = .fromNanoseconds(std.math.maxInt(i64));

/// Whether an attempt could ever finish inside `timeout`.
pub fn validTimeout(timeout: Io.Duration) bool {
    return timeout.nanoseconds > 0 and timeout.nanoseconds <= max_timeout.nanoseconds;
}

/// One request, and what to do if it fails.
pub const Request = struct {
    /// Whether the answer is the body or the `Location` of a redirect.
    kind: enum { json, location } = .json,
    method: std.http.Method = .GET,
    path: []const u8,
    query: []const Transport.Param = &.{},
    /// The JSON body of a POST; empty for a GET.
    body: []const u8 = "",
    retries: u32,
    /// How long ONE attempt may take, from the connection to the last byte of
    /// the answer. A retry starts a fresh one.
    timeout: Io.Duration,
    diagnostics: *Diagnostics,
};

/// Retries a transient failure, waiting whatever the server asked for over the
/// caller's own backoff. A 429 WITHOUT `Retry-After` is a spent allowance rather
/// than a throttle and is not retried at all.
pub fn send(transport: *Transport, gpa: Allocator, io: Io, request: Request) CallError![]u8 {
    const diag = request.diagnostics;
    // Zero or below, every attempt would time out before it started, so the
    // call would fail only after the whole backoff; near the top of
    // `Io.Duration` the deadline itself overflows and panics. Neither is sent.
    if (!validTimeout(request.timeout)) {
        return refuseTimeout(diag, request.timeout);
    }
    var delay = retry_base_delay;
    var remaining = request.retries;
    while (true) {
        diag.reset();
        if (bounded(io, request.timeout, diag, attempt, .{ transport, gpa, request })) |body| {
            return body;
        } else |err| {
            if (remaining == 0 or !errors.isRetryable(err) or !backOff(io, diag, &delay)) {
                return err;
            }
            remaining -= 1;
        }
    }
}

/// Refuses a timeout `validTimeout` rejects. `send` and `sendOauth` run it on
/// every request; a call that can answer without one - a bogon, a cached
/// answer, the poll's first wait - runs it first, or the bad value would pass
/// whenever no request happened to be needed.
pub fn checkTimeout(diag: *Diagnostics, timeout: Io.Duration) errors.Error!void {
    if (!validTimeout(timeout)) {
        return refuseTimeout(diag, timeout);
    }
}

/// A timeout `validTimeout` rejects is the caller's mistake, refused the way
/// the API refuses a bad argument: `error.BadRequest`, never retried.
pub fn refuseTimeout(diag: *Diagnostics, timeout: Io.Duration) errors.Error {
    diag.reset();
    var text: [Diagnostics.max_message_len]u8 = undefined;
    diag.setMessage(std.fmt.bufPrint(&text, "timeout must be positive and at most {d} ns, got {d} ns", .{
        max_timeout.nanoseconds,
        timeout.nanoseconds,
    }) catch "timeout must be positive and at most 292 years");
    return error.BadRequest;
}

fn attempt(transport: *Transport, gpa: Allocator, request: Request) CallError![]u8 {
    const diag = request.diagnostics;
    return switch (request.kind) {
        .json => if (request.method == .POST)
            transport.postJson(gpa, request.path, request.body, diag)
        else
            transport.getJson(gpa, request.path, request.query, diag),
        .location => transport.getLocation(gpa, request.path, request.query, diag),
    };
}

/// Runs one attempt against a deadline this library owns, since
/// `std.http.Client` takes none. The attempt is a task of its own: when the
/// deadline passes first it is canceled, which interrupts the read or connect it
/// is blocked in, and then waited for, so nothing it allocated or opened outlives
/// the call. A timeout is `error.Network`, retryable, with the bound in the
/// diagnostics. Canceling the task that waits cancels the attempt at once and
/// stays armed, so a retry's backoff ends the call. An `Io` that cannot start a
/// concurrent task runs the attempt inline and unbounded: it could not cancel it.
pub fn bounded(
    io: Io,
    timeout: Io.Duration,
    diag: *Diagnostics,
    comptime function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Task = struct {
        fn run(finished: *Io.Event, task_io: Io, task_args: @TypeOf(args)) Result {
            defer finished.set(task_io);
            return @call(.auto, function, task_args);
        }
    };

    var finished: Io.Event = .unset;
    var task = io.concurrent(Task.run, .{ &finished, io, args }) catch
        return @call(.auto, function, args);
    // A duration rather than a deadline goes to the wait, because an `Io` may
    // convert a deadline on a clock other than the one it was read from.
    const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = timeout, .clock = .awake });
    const canceled = while (true) {
        const left = deadline.durationFromNow(io);
        if (left.raw.nanoseconds <= 0) {
            break false;
        }
        finished.waitTimeout(io, .{ .duration = left }) catch |err| switch (err) {
            // A spurious wakeup reads as a timeout too, so the clock decides.
            error.Timeout => continue,
            error.Canceled => break true,
        };
        return task.await(io);
    };

    const outcome = task.cancel(io);
    if (canceled) {
        io.recancel();
        return outcome;
    }
    // An attempt that finished while it was being canceled is kept, whatever
    // it came to. Only the failure the cancelation caused is renamed.
    if (outcome) |_| {} else |err| if (err == error.Network) {
        var text: [Diagnostics.max_message_len]u8 = undefined;
        diag.setMessage(std.fmt.bufPrint(&text, "the request timed out after {d} ms", .{
            timeout.toMilliseconds(),
        }) catch "the request timed out");
    }
    return outcome;
}

/// Waits before another attempt: whatever the server asked for, over the
/// caller's own doubling backoff. False when the wait was canceled, which ends
/// the retries rather than being ignored.
pub fn backOff(io: Io, diag: *const Diagnostics, delay: *Io.Duration) bool {
    const wait: Io.Duration = if (diag.retry_after_s) |seconds|
        .fromSeconds(@intCast(seconds))
    else
        delay.*;
    io.sleep(wait, .awake) catch return false;
    delay.* = .fromNanoseconds(@min(delay.nanoseconds * 2, retry_max_delay.nanoseconds));
    return true;
}

/// One OAuth request: a GET, or a POST of a form body that is already encoded.
pub const OauthRequest = struct {
    method: std.http.Method = .GET,
    path: []const u8,
    form: []const u8 = "",
    retries: u32,
    timeout: Io.Duration,
    diagnostics: *Diagnostics,
};

/// `send` for the OAuth endpoints. Never carries the API key, and never retries
/// an OAuth refusal, whatever `retries` allows.
pub fn sendOauth(
    transport: *Transport,
    gpa: Allocator,
    io: Io,
    request: OauthRequest,
) errors.OauthCallError![]u8 {
    const diag = request.diagnostics;
    // Zero or below, every attempt would time out before it started, so the
    // call would fail only after the whole backoff; near the top of
    // `Io.Duration` the deadline itself overflows and panics. Neither is sent.
    if (!validTimeout(request.timeout)) {
        return refuseTimeout(diag, request.timeout);
    }
    var delay = retry_base_delay;
    var remaining = request.retries;
    while (true) {
        diag.reset();
        const args = .{ transport, gpa, request, diag };
        if (bounded(io, request.timeout, diag, Transport.oauthAttempt, args)) |body| {
            return body;
        } else |err| switch (err) {
            error.OauthAccessDenied, error.OauthExpiredToken, error.OauthRejected => return err,
            else => |ordinary| {
                if (remaining == 0 or !errors.isRetryable(ordinary) or !backOff(io, diag, &delay)) {
                    return ordinary;
                }
                remaining -= 1;
            },
        }
    }
}

/// Every request the library makes: the GET operations, the batch POST and the
/// OAuth requests.
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
        return readJson(&response, gpa, diag);
    }

    /// The body of a 2xx JSON response to a POST carrying `body`, owned by
    /// `gpa`. The one request with a body: the batch.
    pub fn postJson(
        self: *Transport,
        gpa: Allocator,
        path: []const u8,
        body: []const u8,
        diag: *Diagnostics,
    ) CallError![]u8 {
        const url = try self.buildUrl(gpa, path, &.{});
        defer gpa.free(url);
        // `sendBodyComplete` takes the bytes as mutable, so the body is copied.
        const payload = try gpa.dupe(u8, body);
        defer gpa.free(payload);

        var request = try self.openPost(url, diag);
        defer request.deinit();
        request.sendBodyComplete(payload) catch |err| return fail(diag, err);
        var response = request.receiveHead(&.{}) catch |err| return fail(diag, err);
        return readJson(&response, gpa, diag);
    }

    /// The body of a 2xx answer to an OAuth request, owned by `gpa`.
    ///
    /// No `Authorization` at all, whatever the client holds: these endpoints
    /// have no use for the key, and on the token endpoint the header would read
    /// as client authentication, which these public clients do not have.
    fn oauthAttempt(
        self: *Transport,
        gpa: Allocator,
        oauth: OauthRequest,
        diag: *Diagnostics,
    ) errors.OauthCallError![]u8 {
        const url = try self.buildUrl(gpa, oauth.path, &.{});
        defer gpa.free(url);
        const uri = std.Uri.parse(url) catch |err| return fail(diag, err);
        var request = self.http.request(oauth.method, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = .omit,
                .user_agent = .{ .override = user_agent },
                .content_type = if (oauth.method == .POST)
                    .{ .override = "application/x-www-form-urlencoded" }
                else
                    .default,
            },
        }) catch |err| return fail(diag, err);
        defer request.deinit();
        if (oauth.method == .POST) {
            // `sendBodyComplete` takes the bytes as mutable, so the body is copied.
            const payload = try gpa.dupe(u8, oauth.form);
            defer gpa.free(payload);
            request.sendBodyComplete(payload) catch |err| return fail(diag, err);
        } else {
            request.sendBodiless() catch |err| return fail(diag, err);
        }
        var response = request.receiveHead(&.{}) catch |err| return fail(diag, err);

        const status = @intFromEnum(response.head.status);
        diag.status = status;
        const retry_after = readRetryAfter(response.head);
        diag.retry_after_s = retry_after.seconds;
        const body = try readBody(&response, gpa, diag);
        if (status >= 200 and status < 300) {
            return body;
        }
        defer gpa.free(body);
        // Only a 4xx can be a refusal. Every 5xx is the server failing, whatever
        // its body says.
        if (status >= 400 and status < 500) {
            if (errors.oauthRefusal(gpa, body, diag)) |refusal| {
                return refusal;
            }
        }
        if (errors.envelopeMessage(gpa, body)) |message| {
            defer gpa.free(message);
            diag.setMessage(message);
        }
        return errors.classify(status, retry_after.present);
    }

    /// A 2xx body, or the failure a non-2xx describes.
    fn readJson(response: *std.http.Client.Response, gpa: Allocator, diag: *Diagnostics) CallError![]u8 {
        const status = @intFromEnum(response.head.status);
        diag.status = status;
        const retry_after = readRetryAfter(response.head);
        diag.retry_after_s = retry_after.seconds;

        const body = try readBody(response, gpa, diag);
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
        const authorization: std.http.Client.Request.Headers.Value =
            if (self.authorization) |value| .{ .override = value } else .omit;
        return self.openWith(url, authorization, .default, diag);
    }

    /// A POST with a JSON body, opened but not yet sent: the caller hands the
    /// body to `sendBodyComplete`, which writes head and body together.
    fn openPost(self: *Transport, url: []const u8, diag: *Diagnostics) CallError!std.http.Client.Request {
        const uri = std.Uri.parse(url) catch |err| return fail(diag, err);
        const authorization: std.http.Client.Request.Headers.Value =
            if (self.authorization) |value| .{ .override = value } else .omit;
        var request = self.http.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = authorization,
                .user_agent = .{ .override = user_agent },
                .content_type = .{ .override = "application/json" },
            },
        }) catch |err| return fail(diag, err);
        errdefer request.deinit();
        return request;
    }

    /// Which content encodings the answer may arrive in. A dataset transfer
    /// pins `identity` so the bytes on the wire ARE the published file; the
    /// JSON endpoints take whatever compresses best.
    pub const Encodings = enum { default, identity_only };

    fn openWith(
        self: *Transport,
        url: []const u8,
        authorization: std.http.Client.Request.Headers.Value,
        encodings: Encodings,
        diag: *Diagnostics,
    ) CallError!std.http.Client.Request {
        const uri = std.Uri.parse(url) catch |err| return fail(diag, err);
        var request = self.http.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = authorization,
                .user_agent = .{ .override = user_agent },
                // Asked for by name, because the header std would generate from
                // the field below lists everything BUT identity and so emits a
                // malformed one when identity is all that is left.
                .accept_encoding = switch (encodings) {
                    .default => .default,
                    .identity_only => .{ .override = "identity" },
                },
            },
        }) catch |err| return fail(diag, err);
        errdefer request.deinit();
        // Not decoration: `receiveHead` refuses a content encoding that is not
        // set here, so an origin that compresses anyway is caught rather than
        // writing bytes that do not match the digest the API publishes.
        if (encodings == .identity_only) {
            request.accept_encoding = @splat(false);
            request.accept_encoding[@intFromEnum(std.http.ContentEncoding.identity)] = true;
        }
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

/// A dataset file arriving from object storage, and everything the origin said
/// about it.
///
/// Held by the caller and NEVER copied after `begin`: `std.http.Client.Response`
/// points back at the `Request` beside it, so a copy leaves that pointer aimed
/// at the original.
///
/// This is the one request the library makes that carries **no Authorization
/// header**. The link the download endpoint answers with is presigned: it
/// authorizes itself through its query string, and object storage is a third
/// party with no business seeing an API key.
pub const Transfer = struct {
    request: std.http.Client.Request = undefined,
    response: std.http.Client.Response = undefined,
    /// `Content-Length`, when the origin declared one. Null on a chunked body,
    /// which is the only shape where a transfer cannot be length-checked.
    declared: ?u64 = null,
    body_buffer: [body_buffer_len]u8 = undefined,

    /// Big enough that a gigabyte moves in reasonable chunks, small enough to
    /// sit in a caller's frame.
    pub const body_buffer_len = 16 * 1024;

    /// Opens `url` and reads its head, leaving the body ready for `reader`.
    /// The caller must `deinit` whether or not this succeeds past the open.
    pub fn begin(
        self: *Transfer,
        transport: *Transport,
        gpa: Allocator,
        url: []const u8,
        diag: *Diagnostics,
    ) CallError!void {
        self.* = .{};
        self.request = try transport.openWith(url, .omit, .identity_only, diag);
        errdefer self.request.deinit();

        self.response = self.request.receiveHead(&.{}) catch |err| return Transport.fail(diag, err);
        const status = @intFromEnum(self.response.head.status);
        diag.status = status;
        const retry_after = readRetryAfter(self.response.head);
        diag.retry_after_s = retry_after.seconds;
        if (status < 200 or status >= 300) {
            const body = try readBody(&self.response, gpa, diag);
            defer gpa.free(body);
            if (errors.envelopeMessage(gpa, body)) |message| {
                defer gpa.free(message);
                diag.setMessage(message);
            }
            return errors.classify(status, retry_after.present);
        }
        self.declared = self.response.head.content_length;
    }

    pub fn deinit(self: *Transfer) void {
        self.request.deinit();
        self.* = undefined;
    }

    /// The file's bytes. Not decompressed: see `identity_only`.
    pub fn reader(self: *Transfer) *Io.Reader {
        return self.response.reader(&self.body_buffer);
    }

    /// A transfer that stopped short is a FAILURE, not a short file. Silence
    /// here is how a truncated dataset gets written to disk, renamed into place
    /// and read for weeks as a complete one.
    pub fn verify(self: *Transfer, received: u64, diag: *Diagnostics) errors.Error!void {
        const declared = self.declared orelse return;
        if (received == declared) {
            return;
        }
        var buffer: [Diagnostics.max_message_len]u8 = undefined;
        diag.setMessage(std.fmt.bufPrint(
            &buffer,
            "the transfer stopped at {d} of {d} bytes",
            .{ received, declared },
        ) catch "the transfer stopped short of the declared length");
        return error.Network;
    }

    /// Turns a body read that gave up into the retryable failure it is.
    pub fn readFailure(self: *Transfer, diag: *Diagnostics) errors.Error {
        return Transport.fail(diag, self.response.bodyErr() orelse error.ReadFailed);
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
        // No wider than the i64 `Io.Duration.fromSeconds` takes: a longer wait
        // is read like one that will not parse, rather than panicking in
        // `backOff`.
        const seconds: ?u64 = std.fmt.parseInt(u63, value, 10) catch null;
        return .{ .present = true, .seconds = seconds };
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
