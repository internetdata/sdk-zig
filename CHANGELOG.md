# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 2.3.0 are described by their release commits.

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
