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

    /// Long enough for every message the API sends, and short enough that a
    /// batch of a hundred thousand addresses can afford one per entry. A longer
    /// message is truncated rather than allocated.
    pub const max_message_len = 128;

    /// The API's own explanation, or the transport failure's name. Empty when
    /// the call succeeded or the failure carried no text.
    pub fn message(d: *const Diagnostics) []const u8 {
        return d.message_buf[0..d.message_len];
    }

    pub fn reset(d: *Diagnostics) void {
        d.status = null;
        d.retry_after_s = null;
        d.message_len = 0;
    }

    pub fn setMessage(d: *Diagnostics, text: []const u8) void {
        const len = @min(text.len, max_message_len);
        @memcpy(d.message_buf[0..len], text[0..len]);
        d.message_len = len;
    }
};

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
