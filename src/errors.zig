const std = @import("std");

/// Why a request failed.
///
/// `RateLimited` and `QuotaExceeded` both arrive as HTTP 429 and are NOT the
/// same thing. A rate limit is the API protecting itself, carries `Retry-After`,
/// and retrying works. A spent quota carries no such header, and retrying will
/// not help until the window rolls over or the limit is raised. The header is
/// the only thing that distinguishes them.
pub const Error = error{
    BadRequest,
    Unauthorized,
    Forbidden,
    RateLimited,
    QuotaExceeded,
    ServerError,
    /// No response arrived: a refused connection, a timeout, a TLS failure, or
    /// a body that stopped mid-transfer. All are worth another attempt.
    Network,
};

/// What every call in this library can fail with.
pub const CallError = Error || std.mem.Allocator.Error;

/// The authorization server refusing an OAuth request. A set of its own, because
/// a new member of `Error` would break every caller switching on it
/// exhaustively. The code and description are in `Diagnostics.errorCode` and
/// `Diagnostics.errorDescription`, and none of these is worth retrying.
pub const OauthError = error{
    /// The person refused the sign-in (`access_denied`).
    OauthAccessDenied,
    /// The device code expired, or was already exchanged or refused
    /// (`expired_token`). A poll that outlived the code locally leaves no status.
    OauthExpiredToken,
    /// Any other refusal, including a code this version has never seen:
    /// `authorization_pending`, `slow_down`, `invalid_grant`, `invalid_client`.
    OauthRejected,
};

/// What every `OauthApi` call can fail with: an OAuth refusal, or exactly what
/// any other call fails with.
pub const OauthCallError = CallError || OauthError;

/// Whether retrying this exact request could succeed.
pub fn isRetryable(err: CallError) bool {
    return switch (err) {
        error.RateLimited, error.ServerError, error.Network => true,
        error.OutOfMemory,
        error.BadRequest,
        error.Unauthorized,
        error.Forbidden,
        error.QuotaExceeded,
        => false,
    };
}

/// The wire spelling, which is also the name the shared conformance corpus uses.
pub fn kindName(err: CallError) []const u8 {
    return switch (err) {
        error.BadRequest => "bad_request",
        error.Unauthorized => "unauthorized",
        error.Forbidden => "forbidden",
        error.RateLimited => "rate_limited",
        error.QuotaExceeded => "quota_exceeded",
        error.ServerError => "server_error",
        error.Network => "network",
        error.OutOfMemory => "out_of_memory",
    };
}

/// A response status, and the presence of `Retry-After`, are the whole
/// classification.
///
/// `retry_after` is the PRESENCE of the header rather than a parsed delay: a
/// 429 is retryable because the server asked us to wait, and a value we cannot
/// read (the header also permits an HTTP date) must not turn a throttle into a
/// spent quota.
pub fn classify(status: u16, retry_after_present: bool) Error {
    // Present means transient, absent means an allowance is spent. Nothing else
    // in the response separates the two.
    if (status == 429) {
        return if (retry_after_present) error.RateLimited else error.QuotaExceeded;
    }
    if (status == 401) {
        return error.Unauthorized;
    }
    if (status == 403) {
        return error.Forbidden;
    }
    // Any other 4xx is a CLIENT error. Falling through to the server_error
    // default would make it retryable, so a bad dataset id would be retried
    // twice before failing. Classify on the RANGE, not on an enumerated list.
    if (status >= 400 and status < 500) {
        return error.BadRequest;
    }
    return error.ServerError;
}

/// What the API said, alongside the error value itself.
///
/// A Zig error carries no payload, so a call that wants the status, the wait, or
/// the API's own explanation passes one of these in through its options and
/// reads it after the call fails. It holds its message inline, so there is
/// nothing to free and it can be kept on the stack.
pub const Diagnostics = struct {
    status: ?u16 = null,
    /// How long the server asked us to wait. Null when it did not ask, which on
    /// a 429 means an allowance is spent rather than throttled.
    retry_after_s: ?u64 = null,
    message_buf: [max_message_len]u8 = undefined,
    message_len: usize = 0,
    error_code_buf: [max_error_code_len]u8 = undefined,
    error_code_len: ?usize = null,
    error_description_buf: [max_message_len]u8 = undefined,
    error_description_len: ?usize = null,

    /// Long enough for every message the API sends, and short enough that a
    /// batch of a hundred thousand addresses can afford one per entry. A longer
    /// message is truncated rather than allocated.
    pub const max_message_len = 128;
    /// Longer than every code RFC 6749 and RFC 8628 define.
    pub const max_error_code_len = 48;

    /// The API's own explanation, or the transport failure's name. Empty when
    /// the call succeeded or the failure carried no text.
    pub fn message(d: *const Diagnostics) []const u8 {
        return d.message_buf[0..d.message_len];
    }

    /// The OAuth `error` behind an `OauthError`, and null after any other
    /// failure.
    pub fn errorCode(d: *const Diagnostics) ?[]const u8 {
        const len = d.error_code_len orelse return null;
        return d.error_code_buf[0..len];
    }

    /// The `error_description` the server sent with an `OauthError`, and null
    /// when it sent none, or none as a string.
    pub fn errorDescription(d: *const Diagnostics) ?[]const u8 {
        const len = d.error_description_len orelse return null;
        return d.error_description_buf[0..len];
    }

    pub fn reset(d: *Diagnostics) void {
        d.status = null;
        d.retry_after_s = null;
        d.message_len = 0;
        d.error_code_len = null;
        d.error_description_len = null;
    }

    /// Records an OAuth refusal: its code, its description, and a message of
    /// `<code>` or `<code>: <description>`.
    pub fn setOauth(d: *Diagnostics, code: []const u8, description: ?[]const u8) void {
        const code_len = @min(code.len, max_error_code_len);
        @memcpy(d.error_code_buf[0..code_len], code[0..code_len]);
        d.error_code_len = code_len;
        d.error_description_len = null;
        var buffer: [max_message_len]u8 = undefined;
        if (description) |text| {
            const len = @min(text.len, max_message_len);
            @memcpy(d.error_description_buf[0..len], text[0..len]);
            d.error_description_len = len;
            d.setMessage(std.fmt.bufPrint(&buffer, "{s}: {s}", .{ code, text }) catch &buffer);
        } else {
            d.setMessage(code);
        }
    }

    pub fn setMessage(d: *Diagnostics, text: []const u8) void {
        const len = @min(text.len, max_message_len);
        @memcpy(d.message_buf[0..len], text[0..len]);
        d.message_len = len;
    }
};

/// An OAuth refusal, when `body` is a JSON object with a STRING `error`: its
/// code and description go to `diag`. Null for any other body, which is then
/// the ordinary failure its status describes. Only a 4xx is ever asked.
pub fn oauthRefusal(gpa: std.mem.Allocator, body: []const u8, diag: *Diagnostics) ?OauthError {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) {
        return null;
    }
    const code = parsed.value.object.get("error") orelse return null;
    if (code != .string) {
        return null;
    }
    const description: ?[]const u8 = if (parsed.value.object.get("error_description")) |given|
        (if (given == .string) given.string else null)
    else
        null;
    diag.setOauth(code.string, description);
    return oauthErrorFor(code.string);
}

pub fn oauthErrorFor(code: []const u8) OauthError {
    if (std.mem.eql(u8, code, "access_denied")) {
        return error.OauthAccessDenied;
    }
    if (std.mem.eql(u8, code, "expired_token")) {
        return error.OauthExpiredToken;
    }
    return error.OauthRejected;
}

/// The two APIs behind this host answer with different envelopes: the lookup
/// endpoint uses `error`, the database endpoints use `rc`. Both are read here so
/// a caller never has to know which one they hit.
pub fn envelopeMessage(gpa: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) {
        return null;
    }
    for ([_][]const u8{ "error", "rc" }) |key| {
        const found = parsed.value.object.get(key) orelse continue;
        if (found == .string and found.string.len > 0) {
            return gpa.dupe(u8, found.string) catch null;
        }
    }
    return null;
}

test "a 4xx that is not enumerated is still a client error" {
    try std.testing.expectEqual(error.BadRequest, classify(404, false));
    try std.testing.expectEqual(error.BadRequest, classify(418, false));
    try std.testing.expect(!isRetryable(classify(404, false)));
    try std.testing.expect(isRetryable(classify(503, false)));
}

test "a 429 is classified by Retry-After, not by its status" {
    try std.testing.expectEqual(error.RateLimited, classify(429, true));
    try std.testing.expectEqual(error.QuotaExceeded, classify(429, false));
    try std.testing.expect(isRetryable(error.RateLimited));
    try std.testing.expect(!isRetryable(error.QuotaExceeded));
}

test "both error envelopes are read" {
    const gpa = std.testing.allocator;
    const from_lookup = envelopeMessage(gpa, "{\"error\":\"not a valid IP address\"}").?;
    defer gpa.free(from_lookup);
    try std.testing.expectEqualStrings("not a valid IP address", from_lookup);

    const from_database = envelopeMessage(gpa, "{\"rc\":\"NOT_FOUND\"}").?;
    defer gpa.free(from_database);
    try std.testing.expectEqualStrings("NOT_FOUND", from_database);

    try std.testing.expect(envelopeMessage(gpa, "not json at all") == null);
}
