const std = @import("std");

/// Mirrors `components.schemas.Entitlement` in spec/openapi.yaml.
///
/// What an API key is entitled to, and what it has spent. Everything here
/// describes the key that asked: there is no way to enquire about another
/// organization, because the credential IS the question.
pub const Entitlement = struct {
    /// The organization the key belongs to.
    org_id: []const u8,
    apikey: EntitlementApikey,
    plan: EntitlementPlan,
    usage: EntitlementUsage,
};

/// The credential itself. The key is never echoed back - only its id, which is
/// what the console shows and what you can act on.
pub const EntitlementApikey = struct {
    id: []const u8,
    /// Null for a key with no end date, which is the normal case.
    expires: ?[]const u8,
    /// The source addresses this key may be used from. EMPTY means
    /// unrestricted, never "deny all".
    allowed_cidrs: []const []const u8,
};

/// The plan behind the key, and the field tier it buys.
///
/// `tier` stays a string rather than a Zig enum, for the same reason
/// `Database.license_type` does: a tier added to the API after this release
/// would otherwise fail the whole response to parse.
pub const EntitlementPlan = struct {
    /// The plan the organization is on, e.g. `max`.
    key: []const u8,
    /// The field tier, which decides how much of a lookup answer comes back:
    /// `free`, `starter`, `scale` or `max`.
    tier: []const u8,
};

/// Consumption against the plan's allowance, in the current window.
pub const EntitlementUsage = struct {
    /// Requests counted in the current window. The same number a lookup is
    /// gated on, and it can lag by a few seconds.
    requests: i64,
    /// What the plan includes. Zero on a plan that includes none.
    quota: i64,
    /// Where we stop serving. Null means NEVER, which is the normal state of an
    /// uncapped paid plan and is not the same as zero. Above the quota and
    /// below this, requests are served and billed as overage.
    hard_limit: ?i64,
    /// When the current allowance period began.
    window_start: []const u8,
    /// When the allowance next resets.
    window_end: []const u8,
};
