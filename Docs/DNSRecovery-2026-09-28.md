# Retry-guard DNS recovery

## Confirmed incident

At 16:38:26 on September 28, build 91 deliberately stopped the provider for a
policy update. The DNS preflight tried three four-second batches, failed to get
complete public-IP coverage, and left the preference disabled. The app then
mistook the expected absence of a heartbeat for possible idle suspension.
This was not a persistent safety latch or evidence of a provider crash.

## Implementation

- Keep the bounded foreground attempts and exact-build/generation authorization
  for enabled preference writes. After those attempts, resume the current
  policy's hostname rules and available correlated-IP guards instead of ending
  with all enforcement off.
- Partial prepared snapshots require an explicit recovery flag. Ordinary
  snapshots still require complete coverage. Both paths validate the exact
  policy revision, domain set, schema and lifetime. Partial snapshots cannot be
  rebound as a complete fallback.
- Still-valid cached answers can seed unchanged domains when a policy adds a
  domain. Missing, expired, future or unrelated answers do not certify coverage.
- The provider installs DNS-only, port-53 allow rules for unresolved explicit
  suffixes **before** their existing all-port hostname drop rules. This avoids
  blocking the DNS lookups needed to repair coverage, without granting HTTP,
  HTTPS, encrypted-DNS or wildcard-IP access. The rule budget reserves these
  exceptions under Network Extension's 1,000-rule limit.
- Background refreshes retain installed blocking; they do not clear all rules
  for DNS warm-up. Once a missing suffix resolves, its IP guards are installed
  and its DNS recovery exception is removed. Schedule changes and legacy startup
  warm-up exhaustion also use named blocking instead of leaving a bypass plan.
- Suppress health-driven redelivery during an existing activation/preparation
  transition, so a stale status cannot cancel its recovery.
- Report `isFiltering` separately from complete readiness, preserve actual
  coverage counts, and name the unresolved domains in the UI. A live, correct
  revision with partial coverage satisfies the startup watchdog, but remains
  visibly limited rather than being advertised as fully protected.
- During partial coverage the block-page helper gets no loopback hostname
  mappings, so it cannot poison recovery lookups. Websites still receive the
  Network Extension's hostname blocks rather than the friendly local page.
- Show an explicit preparation message while the app deliberately suspends the
  filter. A generic stale heartbeat no longer guesses that macOS suspended it.

## Security and availability tradeoff

An unresolved domain still has its hostname block, but its unknown cached-IP
retry cannot be protected until a public address is available. This limitation
is explicitly shown. We do not pretend that unknown IPs are protected, allow all
traffic, globally block unnamed traffic, change VPN/DNS settings, or relax the
passage/activation safety policy. This is more protection than the previous
all-or-nothing failure, which left every website unblocked.

There remains a bounded interruption during the existing activation/preflight
sequence. This change prevents a DNS failure from making that interruption
indefinite; it is not a claim of interruption-free hot updates.

## Verification and manual follow-up

Hostless regressions cover partial/zero DNS answers, expiry and revision checks,
cached-answer scope, bounded fallback, named blocks and known-IP retry drops,
DNS-recovery convergence, system-rule capacity, limited status, and stale
session/revision rejection by the startup watchdog. Existing activation and
outage suites remain in the run.

After deployment, test with a rule containing one resolving and one deliberately
nonresolving test domain. Confirm limited protection replaces the stopped state,
the known blocked site stays blocked, and ordinary browsing works. Then restore
the unresolved domain's DNS availability and confirm coverage completes without
a provider restart. Also test changing/pausing rules during a pending batch;
superseded callbacks must not re-enable old policy. Do not modify real VPN/DNS
settings just to simulate failure.

Verified on September 28: **474 hostless tests passed**, the signed macOS app and
extension build succeeded, and deep/strict code-signature verification passed.
The generated Xcode project was refreshed to include the existing shared files.

No live enforcement changes, deployment or reboot were performed. The real
Network Extension/DNS recovery cycle remains a manual post-deployment check.
