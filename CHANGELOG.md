# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 2.3.0 are described by their release commits.

## 2.8.0 - 2026-10-18

### Features

- Add oauth().register, for RFC 7591 dynamic client registration ([`8899a69`](https://github.com/internetdata/sdk-zig/commit/8899a699c917b9cc1d0443dbde5009f3a07051bc))

## 2.7.1 - 2026-10-17

### Fixes

- Refuse a numeric string where a number is due ([`8b6ee98`](https://github.com/internetdata/sdk-zig/commit/8b6ee981ad77157f50ad7b697f22f5e08b89eb7a))

## 2.7.0 - 2026-10-17

### Features

- Re-pin the spec to 2026.10.16: dynamic client registration ([`25b6935`](https://github.com/internetdata/sdk-zig/commit/25b69358c7bca776f02f99c8c7105a65adff12dc))

## 2.6.5 - 2026-10-16

### Fixes

- Re-pin the spec to 2026.10.15: three descriptions in US spelling ([`40be0b1`](https://github.com/internetdata/sdk-zig/commit/40be0b18778c08274dc5e156aab5dbe2e1f838bd))

## 2.6.4 - 2026-10-15

### Fixes

- Retry an unreadable answer to OAuth discovery and device authorization ([`7cc1db2`](https://github.com/internetdata/sdk-zig/commit/7cc1db2ea49bc06ab4e886d4e25fcdbc77884a05))

## 2.6.3 - 2026-10-13

### Fixes

- Re-pin the spec to 2026.10.13: Open databases come with a license ([`88700b2`](https://github.com/internetdata/sdk-zig/commit/88700b2571ae0c3090ef2000673b98d89c371a03))

## 2.6.2 - 2026-10-11

### Fixes

- Read Retry-After as digits or an RFC 9110 date in GMT ([`d06c9bc`](https://github.com/internetdata/sdk-zig/commit/d06c9bcd68083270f087d02d9fb5e28b60ccac2d))
- Refuse a key holding a control character, and retry an unreadable 2xx ([`3a3d61e`](https://github.com/internetdata/sdk-zig/commit/3a3d61e882965820c8ada585b07b8bd9037537b0))

## 2.6.1 - 2026-10-10

### Fixes

- Re-pin the spec to 2026.10.09: rotating a key needs apikeys.reveal ([`b1d81da`](https://github.com/internetdata/sdk-zig/commit/b1d81da13e5f4a6e51d9212a9e691fcfcf1ba494))

## 2.6.0 - 2026-10-09

### Features

- Re-pin the spec to 2026.10.08, adding the Open databases' open flag ([`c6e667b`](https://github.com/internetdata/sdk-zig/commit/c6e667b2b55ede9b7207abded38a5fac9cf2f911))

## 2.5.2 - 2026-10-04

### Fixes

- Re-pin the spec to 2026.10.03: metadata needs no license ([`6dcedbb`](https://github.com/internetdata/sdk-zig/commit/6dcedbbdb5752821c94a617537661936f5842907))

## 2.5.1 - 2026-10-03

### Fixes

- End the device poll's sleep at its deadline, and refuse a bad timeout first ([`013ec28`](https://github.com/internetdata/sdk-zig/commit/013ec280514c797d909a565f6a6ce18445e6b18e))
- Wait out a Retry-After past 2^31 - 1 ms on the client's own backoff ([`78d5ebe`](https://github.com/internetdata/sdk-zig/commit/78d5ebe1f7c42837aa830315496e9920fcda60b9))

## 2.5.0 - 2026-09-30

### Features

- Add the authorization code sign-in, with PKCE ([`8cd535d`](https://github.com/internetdata/sdk-zig/commit/8cd535d523373f4629679f7c4885674b96938b72))

## 2.4.0 - 2026-09-27

### Features

- Re-pin the spec to 2026.09.26, adding its evaluation-sample fields ([`bd0bddc`](https://github.com/internetdata/sdk-zig/commit/bd0bddc2355361534aa6569b3ef403536f25a480))

## 2.3.0 - 2026-09-21

### Features

- Add client.oauth(), the device-flow sign-in, on the 2026.09.21 spec ([`b3f74ce`](https://github.com/internetdata/sdk-zig/commit/b3f74cea47ded6c50aa49b696381f42225348e2f))
