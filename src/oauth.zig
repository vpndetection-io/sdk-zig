//! Signing a person in on their own machine with the OAuth device flow, so a
//! program can be handed one of their API keys instead of asking them to paste
//! it.

const std = @import("std");

const client_mod = @import("client.zig");
const errors = @import("errors.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = errors.Diagnostics;
const Io = std.Io;
const OauthCallError = errors.OauthCallError;
const Parsed = std.json.Parsed;

const device_code_grant = "urn:ietf:params:oauth:grant-type:device_code";
/// RFC 8628's default, for a device authorization whose interval is below 1.
const default_poll_interval_s = 5;
const slow_down_step_s = 5;

/// Per-call options for an `OauthApi` call.
pub const OauthOptions = struct {
    /// Filled in with the status, the OAuth error code and description, and a
    /// message when the call fails.
    diagnostics: ?*Diagnostics = null,
};

/// What `deviceAuthorization` asks for. A value left null, or empty, is left
/// out of the request rather than sent empty.
pub const DeviceAuthorizationOptions = struct {
    /// The scopes to ask for, space-delimited and sent verbatim, e.g.
    /// `account.read apikeys.read apikeys.reveal`. The server narrows it to what
    /// the client may ask for without saying so; `TokenResponse.scope` is what
    /// was granted.
    scope: ?[]const u8 = null,
    /// The API the tokens are for (RFC 8707).
    resource: ?[]const u8 = null,
    diagnostics: ?*Diagnostics = null,
};

/// The OAuth authorization server behind the API: the device flow, token
/// refresh and revocation.
///
/// Every call takes a client ID, which is issued on request from
/// support@vpndetection.io. None of these requests carries the client's API
/// key, and none needs one, so a client built without a key works the same.
/// Every answer is a `std.json.Parsed` whose arena owns it, so `deinit` is the
/// whole cleanup.
///
/// Reached through `Client.oauth`.
pub const OauthApi = struct {
    client: *client_mod.Client,

    /// The authorization server's discovery document. Nothing here needs it:
    /// every request is built from the client's base URL.
    pub fn metadata(self: OauthApi, options: OauthOptions) OauthCallError!Parsed(OauthMetadata) {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const body = try http.sendOauth(&self.client.transport, self.client.gpa, self.client.io, .{
            .path = "/.well-known/oauth-authorization-server",
            .retries = self.client.retries,
            .diagnostics = diag,
        });
        defer self.client.gpa.free(body);
        return self.decode(OauthMetadata, body, diag);
    }

    /// Starts a device sign-in. Show the person `user_code` and
    /// `verification_uri`, then hand the answer to `pollDeviceToken`.
    ///
    /// It consumes nothing, so it is retried like any read. A refusal, such as
    /// `slow_down` when this address has started too many, is
    /// `error.OauthRejected`.
    pub fn deviceAuthorization(
        self: OauthApi,
        client_id: []const u8,
        options: DeviceAuthorizationOptions,
    ) OauthCallError!Parsed(DeviceAuthorization) {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        var fields: [3]Field = undefined;
        var count: usize = 0;
        fields[count] = .{ .name = "client_id", .value = client_id };
        count += 1;
        for ([_]Field{
            .{ .name = "scope", .value = options.scope orelse "" },
            .{ .name = "resource", .value = options.resource orelse "" },
        }) |optional| {
            if (optional.value.len > 0) {
                fields[count] = optional;
                count += 1;
            }
        }
        const body = try self.post("/oauth/device_authorization", fields[0..count], self.client.retries, diag);
        defer self.client.gpa.free(body);
        return self.decode(DeviceAuthorization, body, diag);
    }

    /// Exchanges an approved device code for tokens, once.
    ///
    /// Never retried: the server consumes the code on approval, so a retry
    /// after a lost answer loses the tokens. While the person has not decided
    /// this is `error.OauthRejected` with code `authorization_pending`, which is
    /// what `pollDeviceToken` waits through.
    pub fn exchangeDeviceCode(
        self: OauthApi,
        client_id: []const u8,
        device_code: []const u8,
        options: OauthOptions,
    ) OauthCallError!Parsed(TokenResponse) {
        return self.exchange(&.{
            .{ .name = "grant_type", .value = device_code_grant },
            .{ .name = "device_code", .value = device_code },
            .{ .name = "client_id", .value = client_id },
        }, options);
    }

    /// Exchanges a refresh token for a new pair, once.
    ///
    /// Never retried: the server consumes the refresh token before it mints
    /// the new one, so keep the `refresh_token` this returns. A refresh names
    /// the key the person picked in `apikey_id` but never hands the key back.
    pub fn exchangeRefreshToken(
        self: OauthApi,
        client_id: []const u8,
        refresh_token: []const u8,
        options: OauthOptions,
    ) OauthCallError!Parsed(TokenResponse) {
        return self.exchange(&.{
            .{ .name = "grant_type", .value = "refresh_token" },
            .{ .name = "refresh_token", .value = refresh_token },
            .{ .name = "client_id", .value = client_id },
        }, options);
    }

    /// Revokes a token. A refresh token ends the whole sign-in and every token
    /// it issued, which is how a machine is signed out; an access token ends
    /// only itself. Revoking twice is revoking once, so it is retried like a
    /// read.
    pub fn revoke(
        self: OauthApi,
        client_id: []const u8,
        token: []const u8,
        options: OauthOptions,
    ) OauthCallError!void {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const fields = [_]Field{
            .{ .name = "token", .value = token },
            .{ .name = "client_id", .value = client_id },
        };
        const body = try self.post("/oauth/revoke", &fields, self.client.retries, diag);
        self.client.gpa.free(body);
    }

    /// Waits for the person to approve a device sign-in, and returns its tokens.
    ///
    /// Before EVERY request, the first included, it sleeps `device.interval`
    /// seconds, or 5 when that is below one, and adds 5 more for the rest of the
    /// call each time the server answers `slow_down`. It stops at the first
    /// answer that is neither `authorization_pending` nor `slow_down`: a refusal
    /// is `error.OauthAccessDenied`, a code that ran out
    /// `error.OauthExpiredToken`, and an ordinary failure ends it too. Running
    /// out of `device.expires_in`, counted from this call, is
    /// `error.OauthExpiredToken` with no status in the diagnostics. Calling it
    /// again with the same device authorization is safe until the code expires.
    ///
    /// There is no cancellation handle: it blocks until one of those outcomes.
    /// Canceling the `Io` task running it ends the wait as `error.Network`.
    pub fn pollDeviceToken(
        self: OauthApi,
        client_id: []const u8,
        device: DeviceAuthorization,
        options: OauthOptions,
    ) OauthCallError!Parsed(TokenResponse) {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const io = self.client.io;

        var interval_s: i64 = if (device.interval >= 1) device.interval else default_poll_interval_s;
        const deadline = Io.Clock.awake.now(io).addDuration(.fromSeconds(@max(device.expires_in, 0)));
        while (true) {
            io.sleep(.fromSeconds(interval_s), .awake) catch |err| {
                diag.reset();
                diag.setMessage(@errorName(err));
                return error.Network;
            };
            if (Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) {
                diag.reset();
                diag.setOauth("expired_token", null);
                return error.OauthExpiredToken;
            }
            const refused = if (self.exchangeDeviceCode(client_id, device.device_code, .{
                .diagnostics = diag,
            })) |token|
                return token
            else |err| switch (err) {
                error.OauthRejected => diag.errorCode() orelse return err,
                else => return err,
            };
            if (std.mem.eql(u8, refused, "slow_down")) {
                interval_s += slow_down_step_s;
            } else if (!std.mem.eql(u8, refused, "authorization_pending")) {
                return error.OauthRejected;
            }
        }
    }

    fn exchange(self: OauthApi, fields: []const Field, options: OauthOptions) OauthCallError!Parsed(TokenResponse) {
        var scratch: Diagnostics = .{};
        const diag = options.diagnostics orelse &scratch;
        const body = try self.post("/oauth/token", fields, 0, diag);
        defer self.client.gpa.free(body);
        const wire = try self.decode(WireTokenResponse, body, diag);
        return .{ .arena = wire.arena, .value = .{
            .access_token = wire.value.access_token,
            .token_type = wire.value.token_type,
            .expires_in = wire.value.expires_in,
            .refresh_token = wire.value.refresh_token,
            .scope = wire.value.scope,
            .apikey_id = wire.value.@"mslm:apikey_id",
            .apikey = wire.value.@"mslm:apikey",
        } };
    }

    fn post(self: OauthApi, path: []const u8, fields: []const Field, retries: u32, diag: *Diagnostics) OauthCallError![]u8 {
        const gpa = self.client.gpa;
        const form = try encodeForm(gpa, fields);
        defer gpa.free(form);
        return http.sendOauth(&self.client.transport, gpa, self.client.io, .{
            .method = .POST,
            .path = path,
            .form = form,
            .retries = retries,
            .diagnostics = diag,
        });
    }

    /// A 2xx body parsed into `T`. One that does not parse, or lacks a required
    /// member, is the ordinary `error.ServerError`, with the status kept.
    fn decode(self: OauthApi, comptime T: type, body: []const u8, diag: *Diagnostics) OauthCallError!Parsed(T) {
        const gpa = self.client.gpa;
        const parsed = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(parsed);
        parsed.* = .init(gpa);
        errdefer parsed.deinit();

        const arena = parsed.allocator();
        // Parsed from a copy the arena owns, so every string in the answer
        // outlives the body the caller frees.
        const owned = try arena.dupe(u8, body);
        const value = std.json.parseFromSliceLeaky(T, arena, owned, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                diag.setMessage("the answer did not match the documented shape");
                return error.ServerError;
            },
        };
        return .{ .arena = parsed, .value = value };
    }
};

/// The authorization server's discovery document (RFC 8414).
pub const OauthMetadata = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    device_authorization_endpoint: ?[]const u8 = null,
    revocation_endpoint: ?[]const u8 = null,
    scopes_supported: ?[]const []const u8 = null,
    response_types_supported: ?[]const []const u8 = null,
    grant_types_supported: ?[]const []const u8 = null,
    code_challenge_methods_supported: ?[]const []const u8 = null,
    token_endpoint_auth_methods_supported: ?[]const []const u8 = null,
    authorization_response_iss_parameter_supported: ?bool = null,
    service_documentation: ?[]const u8 = null,
};

/// A device sign-in that has started and is waiting for the person.
pub const DeviceAuthorization = struct {
    /// What `pollDeviceToken` exchanges. Never show it.
    device_code: []const u8,
    /// What the person types at `verification_uri`.
    user_code: []const u8,
    verification_uri: []const u8,
    /// The same page with the code already filled in.
    verification_uri_complete: ?[]const u8 = null,
    /// Seconds until both codes expire.
    expires_in: i64,
    /// Seconds to wait between polls.
    interval: i64,
};

/// What a successful token exchange hands over.
pub const TokenResponse = struct {
    access_token: []const u8,
    /// Always `Bearer`.
    token_type: []const u8,
    /// Seconds until the access token expires.
    expires_in: i64,
    /// A refresh consumes the token it presents, so keep the one that comes
    /// back.
    refresh_token: ?[]const u8 = null,
    /// What was actually granted, which may be narrower than what was asked
    /// for. Empty, not null, when nothing was.
    scope: ?[]const u8 = null,
    /// The wire's `mslm:apikey_id`: the ID of the API key the person picked,
    /// while this sign-in may still read that key back. Null when no key was
    /// picked, or when their role no longer allows reading keys back.
    apikey_id: ?[]const u8 = null,
    /// The wire's `mslm:apikey`: the API key itself, from the device code grant
    /// only and never from a refresh. Null without `apikey_id`, and also beside
    /// one whose secret cannot be read back, which is the case for a key created
    /// before keys could be shown again in the console.
    apikey: ?[]const u8 = null,
};

/// `TokenResponse` as the wire spells it.
const WireTokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
    refresh_token: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    @"mslm:apikey_id": ?[]const u8 = null,
    @"mslm:apikey": ?[]const u8 = null,
};

const Field = struct { name: []const u8, value: []const u8 };

/// `application/x-www-form-urlencoded`, leaving only the unreserved characters
/// literal: a `+` in a value must arrive as a `+`, so it goes as `%2B`.
fn encodeForm(gpa: Allocator, fields: []const Field) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (fields, 0..) |field, i| {
        if (i > 0) {
            try out.append(gpa, '&');
        }
        try http.appendEncoded(gpa, &out, field.name);
        try out.append(gpa, '=');
        try http.appendEncoded(gpa, &out, field.value);
    }
    return out.toOwnedSlice(gpa);
}

test "a form value keeps its plus, ampersand and equals" {
    const gpa = std.testing.allocator;
    const form = try encodeForm(gpa, &.{
        .{ .name = "device_code", .value = "a+b c&d=é" },
        .{ .name = "client_id", .value = "x" },
    });
    defer gpa.free(form);
    try std.testing.expectEqualStrings("device_code=a%2Bb%20c%26d%3D%C3%A9&client_id=x", form);
}
