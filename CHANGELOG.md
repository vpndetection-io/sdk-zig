# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 4.3.2 are described by their release commits.

## 4.5.2 - 2026-10-10

### Fixes

- Re-pin the spec to 2026.10.09: rotating a key needs apikeys.reveal ([`9aa7c28`](https://github.com/vpndetection-io/sdk-zig/commit/9aa7c2836a97e112d20efe266468c0cdc356f7ef))

## 4.5.1 - 2026-10-04

### Fixes

- Re-pin the spec to 2026.10.03: metadata needs no license ([`f8524e2`](https://github.com/vpndetection-io/sdk-zig/commit/f8524e20ef9e3103731a84b4c4772c232b24086a))

## 4.5.0 - 2026-10-03

### Features

- Add the authorization code sign-in, with PKCE ([`37758e4`](https://github.com/vpndetection-io/sdk-zig/commit/37758e4f990a59690485d04986f1f100b6f83fdc))

## 4.4.2 - 2026-10-03

### Fixes

- Share one request per address across lookups and batches ([`c40ee03`](https://github.com/vpndetection-io/sdk-zig/commit/c40ee0394c5a0a054340450b80566859400311e4))

## 4.4.1 - 2026-09-30

### Fixes

- Judge an IPv4-mapped address as the IPv4 address it carries ([`9525491`](https://github.com/vpndetection-io/sdk-zig/commit/9525491a07d8fc42fff554379327d6130d74ae2b))
- Recognize 26 more reserved ranges as bogons, as the API does ([`4dc1fd8`](https://github.com/vpndetection-io/sdk-zig/commit/4dc1fd8eb449c05e825c9ff047d4f19565ad166f))

## 4.4.0 - 2026-09-27

### Features

- Re-pin the spec to 2026.09.26, adding client_id_metadata_document_supported ([`a755063`](https://github.com/vpndetection-io/sdk-zig/commit/a755063e66c86355db59cdb62ed1ba30d9bcaf11))

## 4.3.3 - 2026-09-26

### Fixes

- Refuse an impossible timeout before a bogon, a cached answer or a wait ([`4a586b4`](https://github.com/vpndetection-io/sdk-zig/commit/4a586b4c2e26254d89242e645b7a7b9bfe1975df))
- End the poll's sleep at its deadline, and saturate slow_down ([`be73793`](https://github.com/vpndetection-io/sdk-zig/commit/be73793386a35e3e742738fd227c8e78bd088e63))
- Wait out a Retry-After past 2^31 - 1 ms on the client's own backoff ([`7d3a3e1`](https://github.com/vpndetection-io/sdk-zig/commit/7d3a3e17e805b417ced4e326195b2ff72defaa63))

## 4.3.2 - 2026-09-22

### Fixes

- Re-pin the spec to 2026.09.21 ([`bc79636`](https://github.com/vpndetection-io/sdk-zig/commit/bc79636aecea9f3b0585342812e07a08d5b26483))
