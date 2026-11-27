# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 4.3.2 are described by their release commits.

## 4.20.0 - 2026-11-27

### Fixes

- Read a keyless answer without the AS's type ([`f3554c9`](https://github.com/vpndetection-io/sdk-zig/commit/f3554c9f1cd83a92e039b7fdff84cf8c0aa6696a))

## 4.19.2 - 2026-11-26

### Fixes

- Refuse a user agent on the entitlement call ([`3def0f5`](https://github.com/vpndetection-io/sdk-zig/commit/3def0f59ab41bbba2eae33057a01892c7c28e187))

## 4.19.1 - 2026-11-25

### Fixes

- README: one paid plan, Data; the entitlement example names it ([`07e0200`](https://github.com/vpndetection-io/sdk-zig/commit/07e02005776071fe10ad5db53f30f72fc25d7a5d))
- Docs: the entitlement plan's example key is the Data plan's ([`0f9d72b`](https://github.com/vpndetection-io/sdk-zig/commit/0f9d72bc9262e0c70f607180992b10d019eac79a))
- Spec 2026.11.25: doc comments name a paid plan, the entitlement example the Data plan ([`763d10e`](https://github.com/vpndetection-io/sdk-zig/commit/763d10e370a97689f9ab6447b7746f1db0a1f3dd))

## 4.19.0 - 2026-11-24

### Features

- Send a visitor's user agent with a lookup, myIp or a batch ([`1709626`](https://github.com/vpndetection-io/sdk-zig/commit/170962603b039ed4c29ae6ec628b224b95e8cc77))

### Fixes

- Refuse a malformed first or last day on six more details ([`e6e828a`](https://github.com/vpndetection-io/sdk-zig/commit/e6e828a1ee5fa8232d2577a50ef4307b2614b166))

## 4.18.0 - 2026-11-22

### Features

- Read is_bot on every answer, and bot, whose bot it is, on a paid plan's ([`3548d17`](https://github.com/vpndetection-io/sdk-zig/commit/3548d17fcf33659baa44102fe3060df1ffbe2007))

### Fixes

- Require the AS's country and RPKI status, as the API always sends them ([`329da9e`](https://github.com/vpndetection-io/sdk-zig/commit/329da9e4973d0555a614ac652c156b8e83300895))
- Refuse a database summary or checksum digest sent as null or left out ([`0c26c70`](https://github.com/vpndetection-io/sdk-zig/commit/0c26c70cbf66fd7509ef2f6a73196363eef30b0b))

## 4.17.1 - 2026-11-21

### Fixes

- Re-pin the spec: an AS always carries its country and RPKI status ([`fc9fc02`](https://github.com/vpndetection-io/sdk-zig/commit/fc9fc021f55541f3a60c385b1f073ad5b3aca428))

## 4.17.0 - 2026-11-20

### Features

- Read the network, service, company and abuse members of a paid answer ([`abfe424`](https://github.com/vpndetection-io/sdk-zig/commit/abfe42415750c0b61945e67dab5942969453f632))

### Fixes

- Cache a spent trial's or a reached cap's answer for a minute at most ([`49c120f`](https://github.com/vpndetection-io/sdk-zig/commit/49c120fe80529232bcae2c34b27a790bfe1d55a5))
- Describe the free plan's usage as its trial, with no period ([`09eaf6d`](https://github.com/vpndetection-io/sdk-zig/commit/09eaf6d077601aded51f4e4f333383d4384d7913))

## 4.16.1 - 2026-11-19

### Fixes

- Re-pin the spec to 2026.11.18: a key over plain HTTP is refused ([`0559b50`](https://github.com/vpndetection-io/sdk-zig/commit/0559b5075c48b832aa34497610aa26f08169ead2))

## 4.16.0 - 2026-11-18

### Features

- Read cap_reached past a paid plan's overage cap, and re-pin the spec ([`8e53c6d`](https://github.com/vpndetection-io/sdk-zig/commit/8e53c6db58d2f5cdb8a2f785ca5a5cbe3bdbeec5))

## 4.15.0 - 2026-11-17

### Features

- Read the plan's name, and pin vocabulary values handed back as served ([`e9cf935`](https://github.com/vpndetection-io/sdk-zig/commit/e9cf935b68f2100c3d44e6dfd4a3a16f149cc701))

## 4.14.0 - 2026-11-14

### Features

- Re-pin the spec to 2026.11.14: is_bogon on every answer, and provider_name beside each provider ([`efc3347`](https://github.com/vpndetection-io/sdk-zig/commit/efc334797343575ac3925fbddbcf2d6011bd864b))

### Fixes

- Re-pin the spec to 2026.11.12: plainer words on the 401 and the batch rate limit ([`2932897`](https://github.com/vpndetection-io/sdk-zig/commit/29328979deec70d3ed32a9fece03b356cef72ff3))
- Say that a batch request of one address is answered as its lookup ([`f4a3bfb`](https://github.com/vpndetection-io/sdk-zig/commit/f4a3bfb790c296fbce0e7bff3cf652edc9a4bb6b))

## 4.13.1 - 2026-11-11

### Fixes

- Say the free plan's daily trial and Unlimited, the free plan, and re-pin the spec ([`ab87964`](https://github.com/vpndetection-io/sdk-zig/commit/ab8796460547c0c92de7fb34c5a13559902a4db2))

## 4.13.0 - 2026-11-11

### Features

- Add trial_expired for a trial key's answers, and re-pin the spec ([`3fd5eca`](https://github.com/vpndetection-io/sdk-zig/commit/3fd5ecaf9bfe15858e0d857d2bfecfd7cbc8b343))

## 4.12.2 - 2026-11-11

### Fixes

- Name the Unlimited tier and its terms, and re-pin the spec ([`a71af5b`](https://github.com/vpndetection-io/sdk-zig/commit/a71af5b7d053b11fd59c14426a7c55985c8236c8))

## 4.12.1 - 2026-11-11

### Fixes

- Re-pin the spec's 2026.11.11 rebuild: plainer words on lookups without a key ([`50ce776`](https://github.com/vpndetection-io/sdk-zig/commit/50ce7764380ad15e5559531b0b3e80dec62e0413))

## 4.12.0 - 2026-11-11

### Features

- Re-pin the spec to 2026.11.11: a lookup without a key answers more ([`d0998de`](https://github.com/vpndetection-io/sdk-zig/commit/d0998ded7868fa0ee68b894a9f3fe468052c40cb))

## 4.11.0 - 2026-11-07

### Features

- Download the build a database.updated webhook names ([`39ebae0`](https://github.com/vpndetection-io/sdk-zig/commit/39ebae0ea7162d140d16f29e89219bb9595d4055))

### Fixes

- Re-pin the spec to 2026.11.05: the download's build parameter ([`a8ee889`](https://github.com/vpndetection-io/sdk-zig/commit/a8ee8892f37a1d8f6cb99904fe40efe92abc7a65))

## 4.10.3 - 2026-11-05

### Fixes

- End a device poll once its wait runs to the deadline ([`1e69ee4`](https://github.com/vpndetection-io/sdk-zig/commit/1e69ee47b3ba6a6df09dfddf33765611ceb9ccf1))

## 4.10.2 - 2026-10-28

### Fixes

- Read a date-time whose T or Z is lowercase ([`08bdc44`](https://github.com/vpndetection-io/sdk-zig/commit/08bdc44f69756243c27ad3be7e7c6c3fcf70c71b))

## 4.10.1 - 2026-10-26

### Fixes

- Re-pin the spec to 2026.10.25: Retry-After on myip's 429 ([`b1ff514`](https://github.com/vpndetection-io/sdk-zig/commit/b1ff514005009f35d7a71cb4bbc85ddf051a729f))

## 4.10.0 - 2026-10-24

### Features

- Add oauth().register, for RFC 7591 dynamic client registration ([`3ae80da`](https://github.com/vpndetection-io/sdk-zig/commit/3ae80da3f1478413520d8250543c1f46791fc179))

### Fixes

- Refuse a numeric string, a malformed date or a missing required member ([`28d8d91`](https://github.com/vpndetection-io/sdk-zig/commit/28d8d917de149f3f2de28623b1831342a918cfec))

## 4.9.0 - 2026-10-20

### Features

- Read open on databases and downloads ([`cd4377e`](https://github.com/vpndetection-io/sdk-zig/commit/cd4377e02a52d734dbff80051b3caae7040c8447))
- Add location and asn to lookup results, a bogon's included ([`0a9ca38`](https://github.com/vpndetection-io/sdk-zig/commit/0a9ca3886f465a1e96e1d5e3e32a5726b291f486))

## 4.8.0 - 2026-10-19

### Features

- Re-pin the spec to 2026.10.19: num_ports and num_proxies in the pubproxy detail ([`df7a5b2`](https://github.com/vpndetection-io/sdk-zig/commit/df7a5b206eaa970f09b940ab76be34e3f50bcd16))

## 4.7.0 - 2026-10-18

### Features

- Re-pin the spec to 2026.10.18: is_pubproxy and the pubproxy detail ([`8e2a96c`](https://github.com/vpndetection-io/sdk-zig/commit/8e2a96c21b18316f3dac66781a6612ccb96ebae8))

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
