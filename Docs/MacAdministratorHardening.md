# Hardening against the administrator

The device owner is the adversary here, and they hold root. Nothing local makes
this app stronger than the person holding the recovery key. The realistic goal
is different and still worth engineering for:

- **Cost.** Convert a two-second impulse into a deliberate, effortful act.
- **Latency.** Put a delay between the decision to stop and the stopping, long
  enough for the impulse to pass.
- **Visibility.** Whatever cannot be prevented must be undeniable and
  reportable.

Measured on this machine (macOS 26.3.1): SIP enabled, Authenticated Root
enabled, FileVault on, **no MDM enrollment**, `gp` in `admin`. Filter is at
build 19, `activated enabled`.

## What actually defends the filter today

An ad-hoc-signed binary calling `NEFilterManager.loadFromPreferences` gets **no
callback at all** — `nesessionmanager` never answers, and the process hangs
until killed (verified: exit 137 after a 12s watchdog). The content-filter
configuration is therefore not merely write-protected, it is unreadable without
`com.apple.developer.networking.networkextension`. An attacker must produce a
binary signed by a team ID holding that entitlement.

That is a real barrier against arbitrary tooling. It is a weak one against
*this* owner, who has the signing team and the source tree on disk.

## Attack paths, ordered by cost

| # | Path | Cost | Status |
|---|------|------|--------|
| 1 | The app's own **Remove** button | ~2 s | **Closed in build 20** (Tier 0) |
| 2 | Set the clock outside a rule's active window | ~10 s | **Open.** |
| 3 | VPN / SOCKS proxy (FortiClient is already installed here) | ~10 s, no admin | **Open.** |
| 4 | System Settings → Network → Filters → disable | seconds + admin auth | Apple-gated |
| 5 | Delete `/Applications/ExecutiveDysfunctionMac.app` | seconds | Needs probe |
| 6 | Forge the policy HMAC (key is in the *user's* Keychain) | minutes | Partially open |
| 7 | Rebuild the app from source with removal ungated | ~30 min | Inherent |
| 8 | Recovery / disable SIP / safe mode | reboot | Above the ceiling |

Paths 1–3 are cheaper than the thing they defeat and two of the three are our
own doing. Every network-layer refinement is downstream of these: a perfect
ClientHello parser is worth nothing behind a button that turns it off.

## Tier 0 — close our own doors — **done, build 20**

`DesktopRemovalAuthorization.swift` holds the gate; it does no I/O and takes its
clock readings as parameters, so all of it is under test.

Removal is now a scheduled event rather than a button:

1. `beginRemoval()` records a request and **tears nothing down**. Enforcement
   runs untouched for the whole delay. Re-requesting while one is pending is a
   no-op, so the wait cannot be restarted to dodge an expiring window, and the
   passage cannot be re-rolled for a shorter one.
2. `completeRemoval(passage:)` is the only path that may disable the filter, and
   it returns false unchanged unless the delay has elapsed *and* the passage
   matches. `disableNetworkFilter()` additionally asserts on any other caller.
3. Terms come from the strictest locked rule in force: longest `unlockDelayDays`,
   longest `passageWordCount`, **shortest** `editWindowHours` (a shorter window
   is the stricter setting). Any locked rule earns a floor of one day even if it
   was configured with a zero-day delay.
4. Miss the confirmation window and the request expires; starting again serves
   the full wait.
5. The countdown shows in the banner, not only in the sheet — a delay the user
   can start and forget is one they cannot reconsider. Cancel stays available at
   every point, which is what makes the gate tolerable enough to leave on.

**The wait does not trust the wall clock.** Elapsed time is the *lesser* of
wall-clock and `mach_continuous_time` elapsed, anchored to `kern.bootsessionuuid`
(`kern.boottime` would not do — it is expressed in wall time and moves whenever
the clock is set). Setting the clock a year forward leaves the gate shut;
setting it backward cannot help either. Across a reboot the monotonic anchor is
meaningless and wall time carries the wait — a narrower gap than stranding every
pending removal at every restart. `ProcessInfo.systemUptime` was rejected because
it stops during sleep, which would stall a multi-day wait on a laptop.

Residual: this raises the cost of the *in-app* path only. Deleting the app,
disabling the filter in System Settings, and rebuilding from source are
unaffected — those are Tier 1 and Tier 4.

## Tier 1 — survive app deletion and logout

A root LaunchDaemon (`KeepAlive`), installed via `SMAppService`, whose only job
is to re-arm:

- restore the app bundle from a root-owned copy under
  `/Library/Application Support/ExecutiveDysfunction/` if it vanishes;
- re-submit the system-extension activation;
- re-enable `NEFilterManager.isEnabled` if flipped off.

The point is not that root cannot remove the daemon. It is that removal now
requires `sudo` and a password — an intentional act, at a keyboard, with a
prompt naming what is being disabled. Daemon and app should each validate the
other's signature (`SecStaticCodeCheckValidity`, team + bundle ID) so swapping
either for a stub fails rather than silently succeeding.

**Caution:** `drop_all_feature_content_filter` means a configured-but-silent
filter takes the whole machine offline. A resurrection daemon raises the stakes
on every crash. It must ship with a bounded restart counter that gives up and
tears the filter configuration down rather than looping.

## Tier 2 — stop trusting the local clock

`activeRules(at: Date())` reads the wall clock, which the owner sets. Rules here
are schedule-based (the YouTube rule runs 00:01–11:00), so a clock change is a
complete bypass at zero cost.

Fix, cheap and local: persist a monotonic high-water mark of observed time. If
the wall clock jumps backwards past it, or forward by more than the elapsed
uptime, treat that as tamper and **fail closed** — enforce the rule — rather
than fail open. Clock tampering should make the app stricter, not looser.

## Tier 3 — the proxy and tunnel gap

This is the largest genuine hole and it needs no administrator at all. A
blocklist fundamentally cannot survive a proxy: the filter sees a TLS connection
to the proxy, not to the destination.

Only allowlist (Fortress) mode can close it, and only if it also denies the
*tunnel*:

- Under Fortress, the tunnel endpoint is itself not on the allowlist, so it is
  refused — this already works in principle and should be tested against the
  installed FortiClient.
- Extend `blocksApplication` with a tunnel-class denylist (known VPN and proxy
  signing identifiers, plus `ssh -D`) so blocklist mode degrades less badly.
- Treat the appearance of a second active `NEVPNManager` configuration as a
  tamper signal worth journaling and, optionally, escalating on.

Honest limit: a full-tunnel VPN established *before* the rule activates, on a
long-lived connection, stays outside all of this.

## Tier 4 — the actual ceiling

Only two things genuinely resist an administrator, and both are configuration,
not code:

**(a) Configuration profile with a removal password.** A manually installed
profile carrying `com.apple.system-extension-policy` with
`NonRemovableSystemExtensions`, plus a profile removal password held by an
accountability partner. `profiles remove` then requires a secret the owner does
not have. This is the highest-leverage unimplemented item and needs no Apple
Business account. **Untested — worth probing next.**

**(b) Supervision.** Enrollment via Apple Business Manager or a DEP reseller
makes the enrollment itself non-removable; undoing it requires an erase. This is
the only true lock, and it is a large step.

Recovery mode and SIP-disable sit above both. That is the ceiling, and the
design should state it rather than pretend otherwise.

## Tier 5 — visibility as the fallback

Everything above eventually loses to physical access. What does not lose is the
record. A root-owned append-only tamper journal, mirrored through the existing
CloudShared iCloud key-value path to the iPhone app, should record: filter
disabled, removal requested, clock jump detected, policy rejected, filter gone
stale, extension deactivated.

The failure mode this project has already hit twice — enforcement quietly doing
nothing, indistinguishable from enforcement working — is the same failure mode
as a bypass nobody notices. Journaling is the cheapest item on this page and
plausibly the most effective, because a bypass an accountability partner can see
is one most people do not take.

## Open probes

These are asserted nowhere in this document because they have not been measured:

1. Does deleting the containing app cause `sysextd` to garbage-collect the
   extension, and how quickly?
2. Does disabling a content filter in System Settings require admin
   authentication, or only a toggle?
3. Do content filters load in safe mode?
4. Does a profile removal password actually block `profiles remove -p` for a
   manually installed profile?
5. Does the filter still see flows when FortiClient's full tunnel is up?

Probe 4 gates Tier 4(a), and Tier 4(a) is the only item here that changes the
answer to "can the administrator thwart this".
