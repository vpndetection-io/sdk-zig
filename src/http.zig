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
    /// Set when the call ends because its task was canceled, for a caller that
    /// must tell that from a failure: the request it leads for others is then
    /// abandoned rather than failed.
    canceled: ?*bool = null,
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
            if (remaining == 0 or !errors.isRetryable(err)) {
                if (request.canceled) |canceled| {
                    canceled.* = wasCanceled(io);
                }
                return err;
            }
            if (!backOff(io, diag, &delay)) {
                if (request.canceled) |canceled| {
                    canceled.* = true;
                }
                return err;
            }
            remaining -= 1;
        }
    }
}

/// Whether the task has a cancelation outstanding, which `bounded` re-arms when
/// it cancels an attempt. It stays armed for the caller's next cancelation point.
fn wasCanceled(io: Io) bool {
    io.checkCancel() catch {
        io.recancel();
        return true;
    };
    return false;
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

/// The longest `Retry-After` waited out as given, in whole seconds: 2^31 - 1 ms,
/// the bound every SDK shares. `Io.sleep` takes any wait, so 2147484 held a call
/// for 24.8 days and 9223372036854775807 for good (4.3.2, measured 2026-09-26);
/// one past it is read like a value that will not parse, still a throttle, and
/// waited out on the caller's own backoff.
pub const max_retry_after_s: u64 = 2_147_483;

/// Waits before another attempt: whatever the server asked for, up to
/// `max_retry_after_s`, over the caller's own doubling backoff. False when the
/// wait was canceled, which ends the retries rather than being ignored.
pub fn backOff(io: Io, diag: *const Diagnostics, delay: *Io.Duration) bool {
    const asked: ?u64 = if (diag.retry_after_s) |seconds|
        (if (seconds <= max_retry_after_s) seconds else null)
    else
        null;
    const wait: Io.Duration = if (asked) |seconds| .fromSeconds(@intCast(seconds)) else delay.*;
    io.sleep(wait, .awake) catch return false;
    delay.* = .fromNanoseconds(@min(delay.nanoseconds * 2, retry_max_delay.nanoseconds));
    return true;
}

/// Repeats `attemptFn`, one request AND the read of its answer, the way `send`
/// repeats a request alone: an answer the call cannot read is the server's
/// fault like any 5xx, so it is retried too, carrying the status it came with.
/// Read after the retries were spent, as through 4.5.2, it failed after
/// exactly one request. `attemptFn` sends with no retries of its own; a wait
/// canceled between attempts ends the call and sets `canceled`.
pub fn retrying(
    comptime T: type,
    io: Io,
    retries: u32,
    diag: *const Diagnostics,
    canceled: ?*bool,
    context: anytype,
    comptime attemptFn: fn (@TypeOf(context)) CallError!T,
) CallError!T {
    var delay = retry_base_delay;
    var remaining = retries;
    while (true) {
        if (attemptFn(context)) |value| {
            return value;
        } else |err| {
            if (remaining == 0 or !errors.isRetryable(err)) {
                return err;
            }
            if (!backOff(io, diag, &delay)) {
                if (canceled) |flag| {
                    flag.* = true;
                }
                return err;
            }
            remaining -= 1;
        }
    }
}

/// A GET whose answer is parsed into `T`, owned by the caller: each attempt is
/// the request and the parse together, under `retrying`. Parsed from a copy
/// the arena owns, so every string in the answer outlives the body.
pub fn getParsed(
    comptime T: type,
    transport: *Transport,
    gpa: Allocator,
    io: Io,
    request: Request,
) CallError!std.json.Parsed(T) {
    const Attempt = struct {
        transport: *Transport,
        gpa: Allocator,
        io: Io,
        request: Request,

        fn run(self: @This()) CallError!std.json.Parsed(T) {
            var single = self.request;
            single.retries = 0;
            const body = try send(self.transport, self.gpa, self.io, single);
            defer self.gpa.free(body);

            const parsed = try self.gpa.create(std.heap.ArenaAllocator);
            errdefer self.gpa.destroy(parsed);
            parsed.* = .init(self.gpa);
            errdefer parsed.deinit();

            const arena = parsed.allocator();
            const owned = try arena.dupe(u8, body);
            const value = std.json.parseFromSliceLeaky(T, arena, owned, .{
                .ignore_unknown_fields = true,
            }) catch {
                self.request.diagnostics.setMessage("the answer did not match the documented shape");
                return error.ServerError;
            };
            return .{ .arena = parsed, .value = value };
        }
    };
    const once: Attempt = .{ .transport = transport, .gpa = gpa, .io = io, .request = request };
    return retrying(std.json.Parsed(T), io, request.retries, request.diagnostics, null, once, Attempt.run);
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
        return readJson(&response, gpa, self.http.io, diag);
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
        return readJson(&response, gpa, self.http.io, diag);
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
        const retry_after = readRetryAfter(response.head, self.http.io);
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
    fn readJson(response: *std.http.Client.Response, gpa: Allocator, io: Io, diag: *Diagnostics) CallError![]u8 {
        const status = @intFromEnum(response.head.status);
        diag.status = status;
        const retry_after = readRetryAfter(response.head, io);
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
        const retry_after = readRetryAfter(response.head, self.http.io);
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
        return self.openWith(url, try self.authorizationHeader(diag), .default, diag);
    }

    /// The `Authorization` a request carries. `std.http.Client` writes a header
    /// value out as given, so a control character left inside the key would
    /// reach the wire, and a CR LF would start a header of its own. Refused
    /// here, before anything is sent, because `Client.init`'s error set has no
    /// member for it.
    fn authorizationHeader(self: *const Transport, diag: *Diagnostics) CallError!std.http.Client.Request.Headers.Value {
        const value = self.authorization orelse return .omit;
        for (value) |c| {
            if (c < 0x20 or c == 0x7f) {
                diag.setMessage("the API key holds a control character");
                return error.BadRequest;
            }
        }
        return .{ .override = value };
    }

    /// A POST with a JSON body, opened but not yet sent: the caller hands the
    /// body to `sendBodyComplete`, which writes head and body together.
    fn openPost(self: *Transport, url: []const u8, diag: *Diagnostics) CallError!std.http.Client.Request {
        const uri = std.Uri.parse(url) catch |err| return fail(diag, err);
        const authorization = try self.authorizationHeader(diag);
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
        const retry_after = readRetryAfter(self.response.head, transport.http.io);
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
fn readRetryAfter(head: std.http.Client.Response.Head, io: Io) struct { present: bool, seconds: ?u64 } {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            continue;
        }
        const value = std.mem.trim(u8, header.value, " \t");
        return .{ .present = true, .seconds = retryAfterSeconds(value, Io.Clock.real.now(io).toSeconds()) };
    }
    return .{ .present = false, .seconds = null };
}

/// The wait a `Retry-After` value asks for at `now_s`, seconds since the epoch:
/// a count of seconds written as digits and nothing else, or how far away an
/// HTTP date is, nothing for one already past. Null for anything else. A sign,
/// a fraction, a digit separator or an exponent is not a count, though
/// `std.fmt.parseInt` would take a sign or an underscore and hold the call that
/// long. A count too long for the i64 `Io.Duration.fromSeconds` takes is null
/// too, rather than a panic in `backOff`.
pub fn retryAfterSeconds(value: []const u8, now_s: i64) ?u64 {
    if (value.len > 0 and allDigits(value)) {
        return std.fmt.parseInt(u63, value, 10) catch null;
    }
    const at = httpDate(value, now_s) orelse return null;
    return @intCast(@max(0, at - now_s));
}

const short_days = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const long_days = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// An HTTP date in one of RFC 9110's three forms, which are always GMT, as
/// seconds since the epoch: `Sun, 06 Nov 1994 08:49:37 GMT`,
/// `Sunday, 06-Nov-94 08:49:37 GMT` and `Sun Nov  6 08:49:37 1994`. Null for
/// any other form, any other zone, and a day or a time that does not exist.
/// `now_s` places the second form's two-digit year.
pub fn httpDate(value: []const u8, now_s: i64) ?i64 {
    // IMF-fixdate.
    if (value.len == 29 and std.mem.eql(u8, value[3..5], ", ") and value[7] == ' ' and
        value[11] == ' ' and value[16] == ' ' and std.mem.eql(u8, value[25..], " GMT"))
    {
        if (!oneOf(value[0..3], &short_days)) {
            return null;
        }
        return epochSeconds(number(value[12..16]), month(value[8..11]), number(value[5..7]), value[17..25]);
    }
    // asctime, whose day of the month is padded with a space.
    if (value.len == 24 and value[3] == ' ' and value[7] == ' ' and value[10] == ' ' and value[19] == ' ') {
        if (!oneOf(value[0..3], &short_days)) {
            return null;
        }
        const day: ?i64 = if (value[8] == ' ') number(value[9..10]) else number(value[8..10]);
        return epochSeconds(number(value[20..24]), month(value[4..7]), day, value[11..19]);
    }
    // RFC 850, whose year has two digits.
    const comma = std.mem.indexOf(u8, value, ", ") orelse return null;
    const rest = value[comma + 2 ..];
    if (!oneOf(value[0..comma], &long_days) or rest.len != 22 or rest[2] != '-' or rest[6] != '-' or
        rest[9] != ' ' or !std.mem.eql(u8, rest[18..], " GMT"))
    {
        return null;
    }
    const year = number(rest[7..9]) orelse return null;
    return epochSeconds(century(year, now_s), month(rest[3..6]), number(rest[0..2]), rest[10..18]);
}

/// RFC 9110 has a two-digit year that would be more than 50 years ahead read
/// as the most recent past year with those digits.
fn century(two_digits: i64, now_s: i64) i64 {
    const this_year = civilYear(@divFloor(now_s, std.time.s_per_day));
    const year = this_year - @mod(this_year, 100) + two_digits;
    return if (year > this_year + 50) year - 100 else year;
}

fn epochSeconds(year: ?i64, month_number: ?i64, day: ?i64, time: []const u8) ?i64 {
    const y = year orelse return null;
    const m = month_number orelse return null;
    const d = day orelse return null;
    if (time.len != 8 or time[2] != ':' or time[5] != ':') {
        return null;
    }
    const hour = number(time[0..2]) orelse return null;
    const minute = number(time[3..5]) orelse return null;
    // 60 is the leap second RFC 9110 allows.
    const second = number(time[6..8]) orelse return null;
    if (d < 1 or d > daysIn(y, m) or hour > 23 or minute > 59 or second > 60) {
        return null;
    }
    return daysFromCivil(y, m, d) * std.time.s_per_day + hour * 3600 + minute * 60 + second;
}

fn daysIn(year: i64, month_number: i64) i64 {
    return switch (month_number) {
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Days since 1970-01-01 in the proleptic Gregorian calendar.
fn daysFromCivil(year: i64, month_number: i64, day: i64) i64 {
    const y = if (month_number <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const day_of_year = @divFloor(153 * @mod(month_number + 9, 12) + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// The year holding `days` since 1970-01-01.
fn civilYear(days: i64) i64 {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const day_of_era = z - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) -
        @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const shifted_month = @divFloor(5 * day_of_year + 2, 153);
    return year_of_era + era * 400 + @as(i64, if (shifted_month >= 10) 1 else 0);
}

fn month(name: []const u8) ?i64 {
    for (months, 1..) |candidate, n| {
        if (std.mem.eql(u8, name, candidate)) {
            return @as(i64, @intCast(n));
        }
    }
    return null;
}

fn oneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) {
            return true;
        }
    }
    return false;
}

/// Digits alone as a number, never a sign or a separator.
fn number(text: []const u8) ?i64 {
    if (text.len == 0 or !allDigits(text)) {
        return null;
    }
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn allDigits(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isDigit(c)) {
            return false;
        }
    }
    return true;
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

test "a Retry-After count is digits and nothing else" {
    const now: i64 = 1_760_000_000;
    try std.testing.expectEqual(@as(?u64, 0), retryAfterSeconds("0", now));
    try std.testing.expectEqual(@as(?u64, 120), retryAfterSeconds("120", now));
    try std.testing.expectEqual(@as(?u64, 7), retryAfterSeconds("007", now));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u63)), retryAfterSeconds("9223372036854775807", now));
    for ([_][]const u8{ "", "+1", "-1", "1_0", "1.5", "1e3", "0x10", " 1", "1 ", "soon", "9223372036854775808" }) |value| {
        std.testing.expectEqual(@as(?u64, null), retryAfterSeconds(value, now)) catch |err| {
            std.debug.print("Retry-After \"{s}\" was read as a count\n", .{value});
            return err;
        };
    }
}

test "an HTTP date is read in RFC 9110's three forms, as GMT" {
    // 1994-11-06T08:49:37Z, the example all three forms spell.
    const at: i64 = 784111777;
    try std.testing.expectEqual(@as(?i64, at), httpDate("Sun, 06 Nov 1994 08:49:37 GMT", 0));
    try std.testing.expectEqual(@as(?i64, at), httpDate("Sunday, 06-Nov-94 08:49:37 GMT", at));
    try std.testing.expectEqual(@as(?i64, at), httpDate("Sun Nov  6 08:49:37 1994", 0));
    try std.testing.expectEqual(@as(?i64, 951782400), httpDate("Tue, 29 Feb 2000 00:00:00 GMT", 0));
    try std.testing.expectEqual(@as(?i64, 0), httpDate("Thu, 01 Jan 1970 00:00:00 GMT", 0));
    // RFC 850's year is read as the nearest past one within 50 years ahead.
    const in_2026: i64 = 1_760_000_000;
    try std.testing.expectEqual(@as(?i64, 4_102_444_800), httpDate("Friday, 01-Jan-00 00:00:00 GMT", 4_102_444_800));
    try std.testing.expectEqual(httpDate("Sat, 01 Jan 2050 00:00:00 GMT", 0), httpDate("Saturday, 01-Jan-50 00:00:00 GMT", in_2026));
    try std.testing.expectEqual(httpDate("Mon, 01 Jan 1977 00:00:00 GMT", 0), httpDate("Monday, 01-Jan-77 00:00:00 GMT", in_2026));

    const refused = [_][]const u8{
        "Sun, 06 Nov 1994 08:49:37 UTC",
        "Sun, 06 Nov 1994 08:49:37 +0000",
        "Sun, 06 Nov 1994 08:49:37 EST",
        "Sun, 31 Nov 1994 08:49:37 GMT",
        "Sun, 29 Feb 2100 08:49:37 GMT",
        "Sun, 06 Nov 1994 24:00:00 GMT",
        "Sun, 06 Nov 1994 08:60:00 GMT",
        "Sun, 06 Nov 1994 08:49:61 GMT",
        "Sun, 00 Nov 1994 08:49:37 GMT",
        "Xyz, 06 Nov 1994 08:49:37 GMT",
        "Sun, 06 Nob 1994 08:49:37 GMT",
        "Sun, +6 Nov 1994 08:49:37 GMT",
        "Sun, 06 Nov 1994 8:49:37 GMT",
        "Sun, 6 Nov 1994 08:49:37 GMT",
        "Sunday, 06-Nov-94 08:49:37 UTC",
        "Sun, 06-Nov-94 08:49:37 GMT",
        "Sun Nov 31 08:49:37 1994",
        "Sun Nov  6 08:49:37 1994 GMT",
        "1994-11-06T08:49:37Z",
        "tomorrow",
        "",
    };
    for (refused) |value| {
        std.testing.expectEqual(@as(?i64, null), httpDate(value, 0)) catch |err| {
            std.debug.print("\"{s}\" was read as a date\n", .{value});
            return err;
        };
    }
}

test "a Retry-After date asks for the wait until it, and nothing once it is past" {
    const at: i64 = 784111777;
    try std.testing.expectEqual(@as(?u64, 3), retryAfterSeconds("Sun, 06 Nov 1994 08:49:37 GMT", at - 3));
    try std.testing.expectEqual(@as(?u64, 0), retryAfterSeconds("Sun, 06 Nov 1994 08:49:37 GMT", at + 60));
    try std.testing.expectEqual(@as(?u64, null), retryAfterSeconds("Sun, 31 Nov 1994 08:49:37 GMT", at));
}
