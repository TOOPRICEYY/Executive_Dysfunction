# The block page

A blocked site shows a page saying “Holdfast has returned this
time to you.” instead of the browser's generic "can't connect" error.

## Why it is built this way

A content filter can only allow or drop a flow. It cannot inject bytes, and the
framework's own remediation page —
`remediateVerdictWithRemediationURLMapKey:remediationButtonTextMapKey:` — is
declared `API_AVAILABLE(ios(9.0)) API_UNAVAILABLE(macos)`, as is
`NEFilterBrowserFlow`. There is no supported way for the filter itself to answer
a blocked request on macOS.

So the page has to come from somewhere the browser will connect to *and trust*:

1. Explicitly blocked domains resolve to `127.0.0.1` via a marked block in
   `/etc/hosts`, but only while the filter reports a fresh, active heartbeat.
2. A root-run server answers there on ports 80 and 443.
3. On 443 it presents a leaf certificate for the requested domain, signed by a
   CA that this Mac trusts.

The server removes its mappings as soon as the filter reports inactive, when
the status heartbeat is more than 12 seconds old, and when the daemon exits.
This prevents a stopped or crashed provider from leaving ordinary browsing
redirected to loopback. The filter is unchanged and still drops real
connections to those domains.
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
this machine. Since 2026-09-29 that CA is deliberately narrow:

- **Name-constrained.** X.509 `nameConstraints` (critical) permit only the
  blocked domains and their subdomains, and exclude every IP address. macOS
  rejects any certificate it signs for another name, so it cannot be used to
  impersonate your bank, email or anything else.
- **Leaf-only and short-lived.** `pathlen:0`, `keyCertSign` only, valid for 825
  days.
- **No key left behind.** The CA key is deleted as soon as the leaf is signed.
  Each run mints a fresh CA for the current block list, trusts it, then removes
  the previous one.

Before this change the CA was unconstrained, valid for ten years, and its key
stayed on disk: anyone who could read the key could intercept any TLS on this
Mac. Re-run the script once to replace an old CA.

This is inherent to showing a real page in the tab for an HTTPS site: answering
as `x.com` means holding a certificate a browser accepts for `x.com`.
`--uninstall` removes the trust setting, the leaf, and the hosts entries.

## Install

    sudo Scripts/setup-block-page.sh

It generates a fresh name-constrained CA on every run, mints a leaf whose
SANs cover the currently explicitly blocked domains (each plus its `www.`
form), installs a `KeepAlive` LaunchDaemon for the server, and records the names
that certificate can answer. The daemon writes its marked `/etc/hosts` block
only while the provider's current policy is active and its heartbeat is fresh.
A backup is kept at `/etc/hosts.Holdfast.bak` before the daemon is
first allowed to edit the file.

**Re-run it whenever the block list changes.** The certificate SANs and
configured-domain allowlist are snapshots of the explicit domains that were
blocked at install time. A newly blocked domain is still refused by the filter,
but shows the browser's generic connection error until the installer refreshes
the certificate. Wiring this to run automatically needs the root helper described in
`MacAdministratorHardening.md` (Tier 1); until that exists it is manual.

Fortress/app-wide blocking does not enumerate every hostname, so it continues
to use the generic browser error. The custom page is intentionally limited to
the explicit block list; `/etc/hosts` has no safe wildcard mechanism.

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
`BLOCKPAGE_HOSTS`, `BLOCKPAGE_HTTPS_PORT` and `BLOCKPAGE_HTTP_PORT`. These make
it possible to exercise the real server with throwaway state, a temporary hosts
file, and high ports without touching the system trust store, `/etc/hosts`, or
ports 80 and 443.

## Verified

- Renderer tests cover the exact sentence, hostname escaping, active rule
  details, lockdown time, and light/dark responsive markup.
- Host-policy tests cover active, inactive, stale, and missing status; configured
  domain intersection; clean removal; and refusal to edit malformed markers.
- The shipped build-39 server returned HTTP `403`, the exact sentence, and the
  requested `coinbase.com` host on a high loopback port. It shut down cleanly,
  and the real `/etc/hosts` hash was unchanged.
- The host-only desktop suite passes 160 tests without loading or restarting the
  live Network Extension.
- The full privileged build-39 installation was verified on ports 80/443: the
  System trust store accepted the local certificate, the root LaunchDaemon
  stayed healthy, and `https://twitter.com` returned trusted HTTP `403` with the
  exact sentence and requested hostname.
- A watchdog-bounded 15-second run passed four rounds of ordinary DNS, HTTPS,
  VPN-tunnel HTTPS, and raw TCP. Three rounds rendered the verified page, all
  four cached-public-IP retries failed before HTTP with provider reason
  `correlated_blocked_endpoint`, and the provider recorded zero unidentified
  drops or fail-open trips.
- At disable, the explicit inactive status removed the managed hosts block;
  Twitter immediately resolved to its public address again and ordinary HTTPS
  returned HTTP `200`.

Not yet verified: visual rendering in the user's Chrome profile. The connected
browser-control extension was unavailable during the guarded run; the trusted
TLS and complete HTML response were verified with the system HTTP client.
