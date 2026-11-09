# Guarded macOS filter connectivity smoke test

Run from Terminal:

```sh
./Scripts/mac-filter-smoke-test.zsh
```

The default enabled window is 15 seconds. An optional integer argument from 5
through 30 changes it. The app independently refuses any smoke-test request
whose deadline is stale, less than three seconds away, or more than 30 seconds
away.

Safety does not depend on the process being tested:

1. The runner first establishes the persisted disabled state.
2. A separate `nohup` watchdog is armed and acknowledges readiness before the
   runner launches the app's bounded enable mode.
3. Near the end of the observation window the runner requests an ordinary
   disabled launch.
4. The app owns an internal absolute-deadline disable.
5. At the same absolute deadline the watchdog terminates the tested app and
   launches a fresh process with `--disable-web-filter-now`. This forced mode
   disables the Network Extension even if macOS's `defaults` command or user
   preferences daemon is unavailable.
6. Any premature runner exit also performs the same disable sequence.

If either the runner or watchdog actually observes loss of its DNS or
pre-resolved HTTPS control path, its recovery launch also passes
`--mark-filter-startup-unsafe`. That marker exposes the app's safe reset UI and
keeps normal enable unavailable. A routine deadline disable with healthy
connectivity does not set the marker.

An outage creates `Diagnostics/SmokeTests/UNSAFE-REBOOT-REQUIRED.tsv`, and a
subsequent run still refuses to enable on that boot by default. Restarting the
Mac is no longer the only way to retire this harness latch: the in-app safe
enforcement reset can do so without enabling filtering. The app's reset keeps
`desktop-enforcement.blocking-disabled` equal to `1`, drains old Network
Extension operations, proves the filter preference absent, proves DNS and
HTTPS healthy, and proves preference absence again before writing a receipt.

The runner accepts that receipt only when all of these checks pass:

- its boot-session value exactly matches the current known boot session;
- its completion timestamp is strictly newer than the latch's `detected_at`;
- its reset-attempt identifier is present;
- the app-owned activation safety latch is clear;
- persisted blocking-disabled intent is true before, during, and after checks;
- the same receipt remains visible throughout validation;
- two new runner-owned rounds each pass DNS and pre-resolved HTTPS.

The scripts do not invoke `defaults`. They run the deployed, signed app binary
with `--report-enforcement-safety-state`, which exits before constructing the UI
model or any Network Extension object and returns blocking state, app-latch
state, and the complete receipt in one JSON snapshot. Every reporter invocation
has a three-second inherited `SIGALRM` deadline. A timeout, process failure,
invalid JSON, or missing required value is an unhealthy observation; it cannot
stall either the runner or the independent watchdog.
The runner refuses build 44 or older before passing this flag, because those
builds do not have the early-exit reporter and must never interpret it as an
ordinary app launch.

For a guarded deployment upgrade, set
`EXECUTIVE_DYSFUNCTION_ALLOW_EXTENSION_UPGRADE=1`. The preflight then accepts
an older enabled/active instance of the same extension bundle as the replacement
source. It never accepts a newer, disabled, inactive, or different extension,
and the run cannot pass until a fresh provider session reports the exact build
embedded in the deployed app.

The accepted latch and receipt audit are archived into the new smoke-test report
before the normal preflight begins. Missing, stale, malformed, or mismatched
evidence leaves the latch intact. If the reset cannot prove recovery, filtering
must remain disabled and the Mac must be restarted before another live test.
Runner and watchdog latch writers use the same bounded `lockf` lock as receipt
retirement. Retirement compares the complete locked latch against the immutable
report snapshot and renames it while still holding that lock, so a same-second
writer cannot have its newer latch mistaken for the one that was validated.

Each run writes an immutable directory under `Diagnostics/SmokeTests/<UUID>`
containing parallel probes per round: DNS, a pre-resolved allowed Apple TCP
endpoint, two ordinary HTTPS origins, interface-bound HTTPS through `en0` and
`utun9`, the currently blocked policy domain, and a direct cached-IP retry for
that blocked domain. Candidate domains are captured from the last active status
and authenticated policy before the disabled baseline, resolved while safely
disabled, and narrowed to the provider's actually active domain after its fresh
heartbeat. This keeps both tests meaningful even though build 39 correctly
clears `blockedDomains` when the provider stops.

When the optional block-page service is installed, the named probe passes only
for trusted HTTP `403` containing “Holdfast has returned this time
to you.”; without it, failing before HTTP remains valid blocking. The cached-IP
probe always targets the saved public address and does not follow redirects, so
any HTTP response is an enforcement failure and `http=000` is an unambiguous
pre-origin block.

The report also contains timing data, pre/periodic/post filter status snapshots,
network state, watchdog events, app/provider Unified Logging, the deployed build
number, and a post-disable connectivity check. `summary.txt` applies a strict
PASS/FAIL audit to provider readiness, ordinary connectivity, both named and
cached-IP blocking, fail-open state, unidentified-drop count, and recovery after
disable. Full raw evidence remains alongside it for diagnosis.

The bounded macOS Network Extension lifecycle log makes grade, default-drop,
provider startup, and tunnel conflicts visible. The app-authored status and logs
are privacy-safe and do not record destinations beyond the fixed test endpoints;
macOS's system log can contain private-redacted system metadata.
