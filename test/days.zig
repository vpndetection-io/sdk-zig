//! The first and last days on the bot, SSH, SMTP, web, DNS resolver and
//! BitTorrent details are `format: date`, read as every other day is: a value
//! not in `YYYY-MM-DD` form, or on no real day, is an answer the call cannot
//! read, a `ServerError` carrying its 200.

const std = @import("std");
const vpndetection = @import("vpndetection");

const support = @import("support.zig");

const Harness = support.Harness;

// Each of the twelve days is a different one, so replacing it changes that
// member alone.
const answer_ok =
    \\{"ip":"1.1.1.1","is_vpn":false,"is_bot":true,"is_ssh":true,"is_smtp":true,"is_web":true,"is_dns_resolver":true,"is_bittorrent":true,
    \\"bot":{"provider":"google","provider_name":"Google","agents":["Googlebot"],"categories":["search_engine"],"verified":true,"identity":"verified","verified_by":"list","confidence":"high","first_seen":"2026-08-01","last_seen":"2026-11-01"},
    \\"ssh":{"port":22,"banner":"SSH-2.0-OpenSSH_9.6","host_key_fp":"SHA256:x","session_ok":true,"first_seen":"2026-08-02","last_seen":"2026-11-02"},
    \\"smtp":{"port":25,"banner":"220 mx","session_ok":true,"first_seen":"2026-08-03","last_seen":"2026-11-03"},
    \\"web":[{"port":443,"tls_ok":true,"session_ok":true,"status_code":200,"server":"nginx","location":"","title":"t","cert_subject_cn":"c","cert_subject_o":"o","cert_issuer_dn":"i","cert_browser_trusted":true,"tls_version":"TLS 1.3","first_seen":"2026-08-04","last_seen":"2026-11-04"}],
    \\"dns_resolver":{"port":53,"recursion_available":true,"rcode":0,"answer_correct":true,"first_seen":"2026-08-05","last_seen":"2026-11-05"},
    \\"bittorrent":{"verified":true,"id_matches_ip":true,"first_seen":"2026-08-06","last_seen":"2026-11-06","last_reachable":"","days_seen":3,"num_ports":1,"peak_num_ports":2,"indexer":false,"clients":["UT"]}}
;

const Member = struct { name: []const u8, day: []const u8 };

const members = [_]Member{
    .{ .name = "bot.first_seen", .day = "2026-08-01" },          .{ .name = "bot.last_seen", .day = "2026-11-01" },
    .{ .name = "ssh.first_seen", .day = "2026-08-02" },          .{ .name = "ssh.last_seen", .day = "2026-11-02" },
    .{ .name = "smtp.first_seen", .day = "2026-08-03" },         .{ .name = "smtp.last_seen", .day = "2026-11-03" },
    .{ .name = "web.first_seen", .day = "2026-08-04" },          .{ .name = "web.last_seen", .day = "2026-11-04" },
    .{ .name = "dns_resolver.first_seen", .day = "2026-08-05" }, .{ .name = "dns_resolver.last_seen", .day = "2026-11-05" },
    .{ .name = "bittorrent.first_seen", .day = "2026-08-06" },   .{ .name = "bittorrent.last_seen", .day = "2026-11-06" },
};

/// What a lookup answered with `day` (JSON text, quotes included) in place of
/// `member`'s: null when it read the answer, else the error.
fn lookUpWith(harness: *Harness, client: *vpndetection.Client, member: Member, day: []const u8, diag: *vpndetection.Diagnostics) !?anyerror {
    const arena = harness.stub.arena.allocator();
    const from = try std.fmt.allocPrint(arena, "\"{s}\"", .{member.day});
    const body = try std.mem.replaceOwned(u8, arena, answer_ok, from, day);
    std.debug.assert(!std.mem.eql(u8, body, answer_ok));
    try harness.stub.route("/1.1.1.1", .{ .body = body });
    const answer = client.lookupWith("1.1.1.1", .{ .diagnostics = diag }) catch |err| return @as(?anyerror, err);
    answer.deinit();
    return null;
}

test "a malformed first or last day on a bot, SSH, SMTP, web, DNS resolver or BitTorrent detail is refused" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    var client = try harness.client(.{ .retries = 0, .cache = null });
    defer client.deinit();

    // The well-formed answer every case below is cut from reads, each day and
    // the empty `last_reachable` with it.
    try harness.stub.route("/1.1.1.1", .{ .body = answer_ok });
    {
        const answer = try client.lookup("1.1.1.1");
        defer answer.deinit();
        try std.testing.expectEqualStrings("2026-08-01", answer.value.bot.?.first_seen.?);
        try std.testing.expectEqualStrings("2026-11-04", answer.value.web.?[0].last_seen);
        try std.testing.expectEqualStrings("2026-11-06", answer.value.bittorrent.?.last_seen.?);
        try std.testing.expectEqualStrings("", answer.value.bittorrent.?.last_reachable.?);
    }

    var failures: usize = 0;
    // The date probe, on the bot's first day.
    for ([_][]const u8{
        "\"x\"",                    "\"tomorrow\"",      "\"monday\"",        "\"2026-02-30\"",       "\"2026-08-01T24:00:00Z\"",
        "\"2026-08-01T10:00:00Z\"", "\"2026-08-01+05\"", "\"2026-08-01\\n\"", "\"2026-08-0\\u0661\"", "\"2026-8-01\"",
    }) |day| {
        var diag: vpndetection.Diagnostics = .{};
        const failed = try lookUpWith(harness, &client, members[0], day, &diag);
        const refused = if (failed) |err| err == error.ServerError else false;
        if (!refused or diag.status != 200) {
            std.debug.print("bot.first_seen = {s}: {s}, status {?d}\n", .{ day, if (failed) |err| @errorName(err) else "read", diag.status });
            failures += 1;
        }
    }
    // Each of the twelve, one malformed value apiece.
    for (members) |member| {
        var diag: vpndetection.Diagnostics = .{};
        const failed = try lookUpWith(harness, &client, member, "\"x\"", &diag);
        const refused = if (failed) |err| err == error.ServerError else false;
        if (!refused or diag.status != 200) {
            std.debug.print("{s} = \"x\": {s}, status {?d}\n", .{ member.name, if (failed) |err| @errorName(err) else "read", diag.status });
            failures += 1;
        }
    }
    try std.testing.expectEqual(0, failures);
}
