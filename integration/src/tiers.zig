//! Which plan tiers a run can observe, and the secret each one needs.
//!
//! A tier is observable only when its secret holds something NON-EMPTY. CI
//! interpolates a secret that does not exist to an empty string rather than
//! leaving the variable unset, and a client built with an empty key presents no
//! credential at all, so an empty secret would quietly run as a second
//! unauthenticated rung and make every comparison against it vacuously true.

const std = @import("std");

/// Ascending, one rung per plan tier.
///
/// The plan comes from the ORG rather than from the key, so each rung needs its
/// own organization and therefore its own secret.
///
/// Field COUNTS are deliberately absent. Pinning "starter answers seven fields"
/// turns a pricing change into a red SDK build; the relation between the tiers
/// is what a client actually has to keep.
pub const Tier = enum {
    unauth,
    free,
    starter,
    scale,
    max,

    pub const ladder = [_]Tier{ .unauth, .free, .starter, .scale, .max };

    pub fn secret(self: Tier) ?[]const u8 {
        return switch (self) {
            .unauth => null,
            .free => "VPNDETECTION_STAGING_KEY_FREE",
            .starter => "VPNDETECTION_STAGING_KEY_STARTER",
            .scale => "VPNDETECTION_STAGING_KEY_SCALE",
            .max => "VPNDETECTION_STAGING_KEY_MAX",
        };
    }

    /// What this rung promises against whichever observable rung sits below it.
    /// A paid tier serves strictly more; a free key and no key at all are one
    /// entitlement reached two ways.
    pub fn widens(self: Tier) bool {
        return switch (self) {
            .unauth, .free => false,
            .starter, .scale, .max => true,
        };
    }

    /// The key, trimmed. Empty when this rung has no secret or the secret is
    /// not set, which are the same thing to everything downstream.
    pub fn key(self: Tier) []const u8 {
        const name = self.secret() orelse return "";
        const value = std.testing.environ.getPosix(name) orelse return "";
        return std.mem.trim(u8, value, " \t\r\n");
    }

    /// Why this rung cannot be exercised, or null when it can.
    pub fn skipReason(self: Tier) ?[]const u8 {
        const name = self.secret() orelse return null;
        if (self.key().len > 0) {
            return null;
        }
        return name;
    }

    /// Skips the calling test, naming the secret, rather than failing a run that
    /// was never given the credential.
    pub fn require(self: Tier) !void {
        if (self.skipReason()) |name| {
            std.debug.print("SKIP: {s} is not set, so the {t} tier cannot be exercised\n", .{ name, self });
            return error.SkipZigTest;
        }
    }
};

/// The rungs this run can actually observe, in order. The unauthenticated one
/// is always among them.
pub fn observable(buffer: *[Tier.ladder.len]Tier) []const Tier {
    var count: usize = 0;
    for (Tier.ladder) |tier| {
        if (tier.skipReason() == null) {
            buffer[count] = tier;
            count += 1;
        }
    }
    return buffer[0..count];
}

/// The ladder needs two rungs to say anything, so this only fires when no tier
/// secret at all is configured.
pub fn requireLadder(buffer: *[Tier.ladder.len]Tier) ![]const Tier {
    const open = observable(buffer);
    if (open.len < 2) {
        std.debug.print("SKIP: no tier secret is set, so there is no ladder to compare\n", .{});
        return error.SkipZigTest;
    }
    return open;
}
