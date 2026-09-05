//! The Zig-specific API surface, as distinct from the shared conformance corpus
//! in conformance.zig.

const std = @import("std");
const vpndetection = @import("vpndetection");

const support = @import("support.zig");

const Harness = support.Harness;
const Io = std.Io;
const Route = support.Route;

const many = 12;

fn routeMany(harness: *Harness) !std.ArrayList([]const u8) {
    var ips: std.ArrayList([]const u8) = .empty;
    for (1..many + 1) |i| {
        const ip = try harness.stub.printed("9.9.9.{d}", .{i});
        try harness.stub.routeLookup(ip);
        try ips.append(harness.stub.arena.allocator(), ip);
    }
    return ips;
}

// Peak in-flight is the only measurement that tells a real limit from an option
// that was accepted and ignored.
test "batch concurrency is configurable per call" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    harness.stub.delay = .fromMilliseconds(20);
    const ips = try routeMany(harness);

    var client = try harness.client(.{ .cache = null });
    defer client.deinit();
    var batch = try client.lookupBatch(ips.items, .{ .concurrency = 3 });
    defer batch.deinit();

    try std.testing.expectEqual(many, harness.stub.callCount());
    try std.testing.expect(harness.stub.peak() <= 3);
    try std.testing.expect(harness.stub.peak() > 1);
}

test "a per call concurrency overrides the client default" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    harness.stub.delay = .fromMilliseconds(20);
    const ips = try routeMany(harness);

    var client = try harness.client(.{ .cache = null, .concurrency = 2 });
    defer client.deinit();
    var batch = try client.lookupBatch(ips.items, .{ .concurrency = 6 });
    defer batch.deinit();

    const peak = harness.stub.peak();
    try std.testing.expect(peak > 2);
    try std.testing.expect(peak <= 6);
}

test "without an override the client concurrency still applies" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    harness.stub.delay = .fromMilliseconds(20);
    const ips = try routeMany(harness);

    var client = try harness.client(.{ .cache = null, .concurrency = 2 });
    defer client.deinit();
    var batch = try client.lookupBatch(ips.items, .{});
    defer batch.deinit();

    try std.testing.expect(harness.stub.peak() <= 2);
}

test "retries are configurable per call" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/9.9.9.9", .{ .status = 500, .body = "{\"error\":\"lookup failed\"}" });

    var client = try harness.client(.{ .cache = null, .retries = 0 });
    defer client.deinit();
    try std.testing.expectError(
        error.ServerError,
        client.lookupWith("9.9.9.9", .{ .retries = 2 }),
    );

    // One initial attempt plus two retries, rather than the client's zero.
    try std.testing.expectEqual(3, harness.stub.callCount());
}

// A 429 with no Retry-After is a spent allowance, and retrying it is hammering
// a quota that will not recover until its window rolls over.
test "a spent quota is never retried" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/9.9.9.9", .{
        .status = 429,
        .body = "{\"error\":\"request allowance exceeded\"}",
    });

    var client = try harness.client(.{ .cache = null, .retries = 5 });
    defer client.deinit();
    try std.testing.expectError(error.QuotaExceeded, client.lookup("9.9.9.9"));
    try std.testing.expectEqual(1, harness.stub.callCount());
}

test "a rate limit is retried after the server supplied wait" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/9.9.9.9", .{
        .status = 429,
        .body = "{\"error\":\"rate limit exceeded\"}",
        .headers = &.{.{ .name = "Retry-After", .value = "1" }},
    });

    var client = try harness.client(.{ .cache = null, .retries = 1 });
    defer client.deinit();
    const started = Io.Clock.awake.now(harness.io());
    try std.testing.expectError(error.RateLimited, client.lookup("9.9.9.9"));

    try std.testing.expectEqual(2, harness.stub.callCount());
    // The header, not the backoff schedule, decides the wait.
    const waited = started.untilNow(harness.io(), .awake);
    try std.testing.expect(waited.toMilliseconds() >= 1000);
}

test "the API key reaches the wire as a bearer token" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    var keyed = try harness.client(.{ .api_key = "sk-test-1234" });
    defer keyed.deinit();
    (try keyed.lookup("1.1.1.1")).deinit();
    try std.testing.expectEqualStrings("Bearer sk-test-1234", harness.stub.authorizationFor("/1.1.1.1").?);

    var keyless = try harness.client(.{});
    defer keyless.deinit();
    (try keyless.lookup("1.1.1.1")).deinit();
    try std.testing.expectEqualStrings("", harness.stub.seen()[1].authorization);

    // std.http.Client sends its own user agent unless the header is overridden,
    // and the version in ours comes from the manifest through build options.
    try std.testing.expect(std.mem.startsWith(u8, harness.stub.lastUserAgent(), "vpndetection-zig/"));
}

test "isBogon is on the client and agrees with the standalone function" {
    const gpa = std.testing.allocator;
    const data = try support.corpus.load(gpa);
    defer data.deinit();
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    var client = try harness.client(.{});
    defer client.deinit();

    for (data.value.isBogon) |case| {
        try std.testing.expectEqual(case.expect, client.isBogon(case.ip));
        try std.testing.expectEqual(vpndetection.isBogon(case.ip), client.isBogon(case.ip));
    }
}

// The single most important semantic in the library, asserted natively rather
// than through the corpus's JSON view: a plan that omits a field leaves it
// null, and a plan that includes it answers false.
test "absent and false are different values" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/1.1.1.1", .ok("{\"ip\":\"1.1.1.1\",\"is_vpn\":false}"));
    try harness.stub.route("/8.8.4.4", .ok("{\"ip\":\"8.8.4.4\",\"is_vpn\":false,\"is_hosting\":false}"));

    var client = try harness.client(.{});
    defer client.deinit();

    const free_tier = try client.lookup("1.1.1.1");
    defer free_tier.deinit();
    try std.testing.expectEqual(@as(?bool, null), free_tier.value.is_hosting);
    try std.testing.expectEqual(false, free_tier.value.is_hosting orelse false);

    const served = try client.lookup("8.8.4.4");
    defer served.deinit();
    try std.testing.expectEqual(@as(?bool, false), served.value.is_hosting);
}

test "an ipv6 address survives the path template" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route(
        "/2606:4700:4700::1111",
        .ok("{\"ip\":\"2606:4700:4700::1111\",\"is_vpn\":false}"),
    );

    var client = try harness.client(.{});
    defer client.deinit();
    const result = try client.lookup("2606:4700:4700::1111");
    defer result.deinit();
    try std.testing.expectEqualStrings("2606:4700:4700::1111", result.value.ip);
}

test "an unusable base url is refused before any request" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    for ([_][]const u8{ "not a url", "/relative", "" }) |base_url| {
        try std.testing.expectError(
            error.InvalidBaseUrl,
            vpndetection.Client.init(gpa, threaded.io(), .{ .base_url = base_url }),
        );
    }
}

// The download endpoint answers 302 to object storage, and the dataset behind
// it runs to gigabytes. The origin here PROMISES 8 GiB, so a client that
// follows the redirect is caught by the request count rather than by the wait.
test "downloadUrl returns the redirect rather than following it" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();

    var url_buffer: [64]u8 = undefined;
    const location = try harness.stub.printed(
        "{s}/huge.mmdb",
        .{harness.stub.baseUrl(&url_buffer)},
    );
    try harness.stub.route("/api/v1/database/download", .{
        .status = 302,
        .headers = &.{.{ .name = "Location", .value = location }},
    });
    try harness.stub.route("/huge.mmdb", .{ .promised_length = 8 * 1024 * 1024 * 1024 });

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const url = try client.database().downloadUrl("vpn_ip_extended_v1", .mmdb, .{});
    defer gpa.free(url);

    try std.testing.expectEqualStrings(location, url);
    try std.testing.expect(harness.stub.calledOnly("/api/v1/database/download"));
}

// Which digests a dataset publishes is the API's choice, so the whole set comes
// back. They nest under `checksums`, and reading a top-level `sha256` is how
// the Node SDK shipped this broken in 1.0.x.
test "checksums returns the whole digest set from under its key" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v1/database/checksum", .ok(
        \\{"id":"vpn_ip_extended_v1","format":"mmdb",
        \\ "checksums":{"md5":"m","sha1":"s1","sha256":"s256","sha512":"s512"}}
    ));

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const digests = try client.database().checksums("vpn_ip_extended_v1", .mmdb, .{});
    defer digests.deinit();

    try std.testing.expectEqualStrings("m", digests.value.md5.?);
    try std.testing.expectEqualStrings("s1", digests.value.sha1.?);
    try std.testing.expectEqualStrings("s256", digests.value.sha256.?);
    try std.testing.expectEqualStrings("s512", digests.value.sha512.?);
}

// A license is held against a FAMILY, and the downloadable ids hang off its
// versions. The spec used to claim `{id, formats}` here while the service
// answered a family, so `list` handed back structs whose every field was empty
// and `list` into `download` was broken in every SDK.
test "the database list unwraps a family and its versions" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v1/database/list", .ok(
        \\{"datasets":[{"base":"vpn_ip_extended","name":"VPN IP Extended",
        \\ "license_type":"standard","in_term":true,"standing":"licensed",
        \\ "versions":[{"id":"vpn_ip_extended_v1","version":1,
        \\   "formats":[{"format":"mmdb","bytes":1234}],"sampleFormats":["csvgz"]}]}]}
    ));

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const datasets = try client.database().list(.{});
    defer datasets.deinit();

    try std.testing.expectEqual(1, datasets.value.len);
    const family = datasets.value[0];
    try std.testing.expectEqualStrings("vpn_ip_extended", family.base);
    try std.testing.expectEqualStrings("licensed", family.standing);
    try std.testing.expectEqual(1, family.versions.len);
    try std.testing.expectEqualStrings("vpn_ip_extended_v1", family.versions[0].id);
    try std.testing.expectEqual(1, family.versions[0].version);
    try std.testing.expectEqualStrings("mmdb", family.versions[0].formats[0].format);
    try std.testing.expectEqual(1234, family.versions[0].formats[0].bytes.?);
    try std.testing.expectEqualStrings("csvgz", family.versions[0].sampleFormats.?[0]);
}

// A 404 from a bad dataset id is a CLIENT error. Letting it fall through to the
// retryable server_error default is the mistake both the Node and Go SDKs
// shipped with.
test "an unknown dataset is not retried" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v1/database/metadata", .{
        .status = 404,
        .body = "{\"rc\":\"NOT_FOUND\"}",
    });

    var client = try harness.client(.{ .api_key = "key", .retries = 3 });
    defer client.deinit();
    var diagnostics: vpndetection.Diagnostics = .{};
    try std.testing.expectError(
        error.BadRequest,
        client.database().metadata("no_such_dataset", .{ .diagnostics = &diagnostics }),
    );

    try std.testing.expectEqualStrings("NOT_FOUND", diagnostics.message());
    try std.testing.expectEqual(1, harness.stub.callCount());
}

// The corpus's dedup case runs with the cache on, where a repeated address
// costs nothing either way. With the cache off, deduping is the only thing
// standing between one address and two requests.
test "a batch dedupes even with the cache disabled" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");
    try harness.stub.routeLookup("8.8.8.8");

    var client = try harness.client(.{ .cache = null });
    defer client.deinit();
    const input = [_][]const u8{ "1.1.1.1", "8.8.8.8", "1.1.1.1", "8.8.8.8", "1.1.1.1" };
    var batch = try client.lookupBatch(&input, .{});
    defer batch.deinit();

    try std.testing.expectEqual(2, batch.count());
    try std.testing.expectEqual(2, harness.stub.callCount());
}

test "a batch keeps its own copy of the addresses it was given" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.routeLookup("1.1.1.1");

    var client = try harness.client(.{});
    defer client.deinit();

    const ip = try gpa.dupe(u8, "1.1.1.1");
    const input = [_][]const u8{ip};
    var batch = try client.lookupBatch(&input, .{});
    defer batch.deinit();
    gpa.free(ip);

    try std.testing.expectEqualStrings("1.1.1.1", batch.keys()[0]);
    try std.testing.expect(batch.get("1.1.1.1") != null);
}

/// A stub dataset: gzip's magic so a test can tell real bytes from a truncated
/// or re-encoded copy, and enough of them that a single-chunk transfer is not
/// what makes the test pass.
fn payload(harness: *Harness) ![]const u8 {
    const bytes = try harness.stub.arena.allocator().alloc(u8, 40_000);
    bytes[0] = 0x1f;
    bytes[1] = 0x8b;
    for (bytes[2..], 2..) |*byte, i| {
        byte.* = @truncate(i *% 31);
    }
    return bytes;
}

const storage_path = "/storage/cdn_ip_v1.csv.gz";

/// Points the download endpoint at the stub's own storage route, so the whole
/// two-request dance happens against one origin that records both.
///
/// The header slice comes from the stub's arena rather than from a literal: a
/// `&.{...}` here would die with this function while the stub still holds it.
fn routeDownload(harness: *Harness, file: support.Route) !void {
    const arena = harness.stub.arena.allocator();
    var url_buffer: [64]u8 = undefined;
    const location = try harness.stub.printed("{s}" ++ storage_path, .{harness.stub.baseUrl(&url_buffer)});
    const headers = try arena.dupe(Route.Header, &.{.{ .name = "Location", .value = location }});
    try harness.stub.route("/api/v1/database/download", .{ .status = 302, .headers = headers });
    try harness.stub.route(storage_path, file);
}

test "download streams a dataset to disk and sends no key to object storage" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const body = try payload(harness);
    try routeDownload(harness, .ok(body));

    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "sk-test-1234" });
    defer client.deinit();
    const written = try client.database().download("cdn_ip_v1", .csvgz, scratch.path("data.csv.gz"), .{});

    try std.testing.expectEqual(body.len, written);
    var read_buffer: [64_000]u8 = undefined;
    try std.testing.expectEqualSlices(u8, body, try scratch.read("data.csv.gz", &read_buffer));
    try std.testing.expect(!scratch.exists("data.csv.gz.part"));

    // The presigned link authorizes itself. Handing object storage the API key
    // as well would give a third party a credential it can spend.
    try std.testing.expectEqualStrings(
        "Bearer sk-test-1234",
        harness.stub.authorizationFor("/api/v1/database/download").?,
    );
    try std.testing.expectEqualStrings("", harness.stub.authorizationFor(storage_path).?);
}

test "downloadBytes agrees with the streamed copy byte for byte" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    const body = try payload(harness);
    try routeDownload(harness, .ok(body));

    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "key" });
    defer client.deinit();
    const written = try client.database().download("cdn_ip_v1", .csvgz, scratch.path("data.csv.gz"), .{});

    const bytes = try client.database().downloadBytes("cdn_ip_v1", .csvgz, .{});
    defer gpa.free(bytes);

    try std.testing.expectEqual(written, bytes.len);
    var read_buffer: [64_000]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try scratch.read("data.csv.gz", &read_buffer), bytes);
}

// Silence here is how a truncated dataset gets renamed into place and read for
// weeks as a complete one.
test "a transfer that stops short fails and leaves nothing behind" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    // Announces 40,000 bytes, writes 16, then closes.
    try routeDownload(harness, .{ .body = "0123456789abcdef", .promised_length = 40_000 });

    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "key", .retries = 0 });
    defer client.deinit();
    var diagnostics: vpndetection.Diagnostics = .{};
    try std.testing.expectError(error.Network, client.database().download(
        "cdn_ip_v1",
        .csvgz,
        scratch.path("data.csv.gz"),
        .{ .diagnostics = &diagnostics },
    ));

    try std.testing.expect(!scratch.exists("data.csv.gz"));
    try std.testing.expect(!scratch.exists("data.csv.gz.part"));
    try std.testing.expect(diagnostics.message().len > 0);

    // The in-memory variant reads the same body through the same check.
    try std.testing.expectError(
        error.Network,
        client.database().downloadBytes("cdn_ip_v1", .csvgz, .{}),
    );
}

// A licence refusal is the API saying no, not a wobble: retrying it spends
// quota to be told the same thing again.
test "a dataset the organization does not license is refused once" {
    const gpa = std.testing.allocator;
    const harness = try Harness.start(gpa);
    defer harness.deinit();
    try harness.stub.route("/api/v1/database/download", .{
        .status = 403,
        .body = "{\"rc\":\"NOT_LICENSED\"}",
    });

    var scratch = support.Scratch.start();
    defer scratch.deinit();

    var client = try harness.client(.{ .api_key = "key", .retries = 3 });
    defer client.deinit();
    var diagnostics: vpndetection.Diagnostics = .{};
    try std.testing.expectError(error.Forbidden, client.database().download(
        "hosting_ip_v1",
        .csvgz,
        scratch.path("data.csv.gz"),
        .{ .diagnostics = &diagnostics },
    ));

    try std.testing.expect(!vpndetection.isRetryable(error.Forbidden));
    try std.testing.expectEqual(1, harness.stub.callCount());
    try std.testing.expectEqual(@as(?u16, 403), diagnostics.status);
    // The API says WHICH refusal this is. Falling back to the status would mean
    // the envelope went unread.
    try std.testing.expectEqualStrings("NOT_LICENSED", diagnostics.message());
    // Nothing may be created for a download that never started.
    try std.testing.expect(!scratch.exists("data.csv.gz.part"));
}
