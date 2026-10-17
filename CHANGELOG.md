# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 4.3.2 are described by their release commits.

## 4.6.0 - 2026-10-17

### Features

- Re-pin the spec to 2026.10.16: dynamic client registration ([`e4a4843`](https://github.com/vpndetection-io/sdk-zig/commit/e4a48439851b671df91ac2aa244f82d63c07c875))
- Build and test on Zig 0.17.0 as well ([`c08f4b2`](https://github.com/vpndetection-io/sdk-zig/commit/c08f4b21d674c5c47a4fd52d0078e327bc1bd691))

## 4.5.5 - 2026-10-16

### Fixes

- Re-pin the spec to 2026.10.15: descriptions in US spelling ([`29c3527`](https://github.com/vpndetection-io/sdk-zig/commit/29c3527f3f63046ffbcde35e963d508162a14605))

## 4.5.4 - 2026-10-15

### Fixes

- Retry an unreadable answer to OAuth discovery and device authorization ([`c421a29`](https://github.com/vpndetection-io/sdk-zig/commit/c421a2955b6b697eb56e6d4c8a8dd85fd9d944de))

## 4.5.3 - 2026-10-11

### Fixes

- Read Retry-After as digits or an RFC 9110 date in GMT ([`e72d9d3`](https://github.com/vpndetection-io/sdk-zig/commit/e72d9d39370dea46d93c5e5b5ec86762d911aa63))
- Refuse a key holding a control character, and retry an unreadable 2xx ([`7cf56c9`](https://github.com/vpndetection-io/sdk-zig/commit/7cf56c972444e70c5589f218ecf85b04fc2a16e1))
- Clear the integration runner's package cache before each fetch ([`18c4a70`](https://github.com/vpndetection-io/sdk-zig/commit/18c4a70eb38b06c3fb8764fe992b5ee63fa8a3e0))

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
