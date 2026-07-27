# The block page

A blocked site shows a page saying why, instead of the browser's generic
"can't connect" error.

## Why it is built this way

A content filter can only allow or drop a flow. It cannot inject bytes, and the
framework's own remediation page —
`remediateVerdictWithRemediationURLMapKey:remediationButtonTextMapKey:` — is
declared `API_AVAILABLE(ios(9.0)) API_UNAVAILABLE(macos)`, as is
`NEFilterBrowserFlow`. There is no supported way for the filter itself to answer
a blocked request on macOS.

So the page has to come from somewhere the browser will connect to *and trust*:

1. Blocked domains resolve to `127.0.0.1` via `/etc/hosts`.
2. A root-run server answers there on ports 80 and 443.
3. On 443 it presents a leaf certificate for the requested domain, signed by a
   CA that this Mac trusts.

The filter is unchanged and still drops real connections to those domains.
Loopback is allowed at step 3 of `WebFilterFlowDecider`, before any hostname
check, so the redirect reaches the page rather than being dropped.

### Why not a transparent proxy

`NETransparentProxyProvider` is macOS-only and can redirect flows, which is the
textbook way to do this. It was rejected deliberately: to decide anything it
must intercept *every* port-443 flow and pump every byte through userspace,
which is the same shape as the `NEFilterPacketProvider` whose crash took this
machine offline. Redirecting only blocked names means unblocked traffic never
touches this code at all, and a bug here costs the block page rather than the
network.

The tradeoff is that the redirect is weaker than interception. A browser
resolving over DoH ignores `/etc/hosts` and will not see the page — it gets the
old failed connection, because the filter still refuses it. Failing back to
"blocked without explanation" is the right direction to fail.

## What it trusts — read this before installing

`Scripts/setup-block-page.sh` creates a root CA and marks it trusted for SSL on
this machine. **That CA can impersonate any site to this Mac.** Its private key
lives at `/Library/Application Support/ExecutiveDysfunction/blockpage/ca.key`,
root-owned and `0600`. Anyone who can read that key can intercept your TLS.

This is inherent to showing a real page in the tab for an HTTPS site: answering
as `x.com` means holding a certificate a browser accepts for `x.com`.
`--uninstall` removes the key, the trust setting, and the hosts entries.

## Install

    sudo Scripts/setup-block-page.sh

It generates the CA on first run and reuses it afterwards, mints a leaf whose
SANs cover the currently blocked domains (each plus its `www.` form), installs a
`KeepAlive` LaunchDaemon for the server, and writes a marked block into
`/etc/hosts`. A backup is kept at `/etc/hosts.ExecutiveDysfunction.bak` the
first time it edits.

**Re-run it whenever the block list changes.** The certificate SANs and the
hosts entries are both snapshots of the domains that were blocked at the time.
A newly blocked domain keeps failing to connect until then. Wiring this to run
automatically needs the root helper described in
`MacAdministratorHardening.md` (Tier 1); until that exists it is manual.

Verify:

    curl -sS https://<a-blocked-domain> | head -5

Remove:

    sudo Scripts/setup-block-page.sh --uninstall

## Server

`Sources/BlockPageServer` is a small tool, built as its own target and copied
into the app bundle at `Contents/MacOS/BlockPageServer` by a post-build script,
so a refresh always installs the server matching the installed app.

It binds loopback only, via `requiredLocalEndpoint` — note that this carries the
port, and passing `on:` to `NWListener` as well makes it reject the parameters
outright and fail to listen. It reads `filter-status.json` for the live rule
counts and lockdown-session end time, so the page shows the real remaining time
rather than a static message.

Paths and ports are overridable through `BLOCKPAGE_DIR`, `BLOCKPAGE_STATUS`,
`BLOCKPAGE_HTTPS_PORT` and `BLOCKPAGE_HTTP_PORT`, which is how the certificate
and TLS path were verified against a throwaway CA on port 9443 without touching
the system trust store, `/etc/hosts`, or port 443.

## Verified

- A leaf minted for `DNS:x.com,DNS:www.x.com,DNS:coinbase.com` completes a TLS
  handshake as `x.com` and validates against the CA (`curl --cacert`), returning
  `403` with the page.
- The page names the requested host from the `Host` header, and rendered
  `Lockdown session — 6d 6h remaining` from a status file.
- Plaintext HTTP on port 80 returns the same page.

Not yet verified: the full privileged install (trust store, `/etc/hosts`, port
443, daemon) and how a real browser renders it.
