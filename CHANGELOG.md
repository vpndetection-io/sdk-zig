# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 4.3.2 are described by their release commits.

## 4.3.3 - 2026-09-26

### Fixes

- Refuse an impossible timeout before a bogon, a cached answer or a wait ([`4a586b4`](https://github.com/vpndetection-io/sdk-zig/commit/4a586b4c2e26254d89242e645b7a7b9bfe1975df))
- End the poll's sleep at its deadline, and saturate slow_down ([`be73793`](https://github.com/vpndetection-io/sdk-zig/commit/be73793386a35e3e742738fd227c8e78bd088e63))
- Wait out a Retry-After past 2^31 - 1 ms on the client's own backoff ([`7d3a3e1`](https://github.com/vpndetection-io/sdk-zig/commit/7d3a3e17e805b417ced4e326195b2ff72defaa63))

## 4.3.2 - 2026-09-22

### Fixes

- Re-pin the spec to 2026.09.21 ([`bc79636`](https://github.com/vpndetection-io/sdk-zig/commit/bc79636aecea9f3b0585342812e07a08d5b26483))
