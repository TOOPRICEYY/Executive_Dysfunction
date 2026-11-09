# Read-only verification incorrectly triggered emergency safety locking

## Live evidence

The signed app's read-only `--report-enforcement-safety-state` reporter confirms
`preference-operation-timeout`, triggered September 19, 2026 at 12:49:23 EDT
(`2026-09-19T16:49:23Z`). The latch is still set and blocking remains disabled.

Unified Logging for that incident shows:

- Operation `bfff6422`, generation 90, policy revision 551, exceeded the shared
  8-second preference deadline during a policy update.
- The final extension-properties query `ebf7ce9d` returned at 12:49:25.085,
  reporting build 87 enabled. Its callback was discarded after the timeout.
- This check precedes `saveToPreferences`; no enabled write was submitted by
  that attempt. The cleanup's final sweep reported zero outstanding enabled saves.
- Nevertheless, the timeout removed the preference, quarantined hypothetical
  late writes, and persisted a same-boot safety lock.

This establishes a false-positive lock from slow pre-save verification, not
evidence that this incident was caused by a provider crash or a connectivity
probe failure. The logs do not establish why macOS's query was slow.

## Change (build 89)

- Separate load, extension verification, and save deadlines. Reads get 30
  seconds per stage; writes and explicit-disable recovery retain 8 seconds.
- A timed-out read without an outstanding enabled write does not remove a
  preference, disable all blocks, persist a safety latch, or start quarantine.
  Retry at most twice, with a new generation fencing each late callback; then
  display a recoverable failure and offer Retry Web Enforcement.
- A newer queued operation supersedes a timed-out read instead of being replaced
  by its retry. Explicit disable and uncertain enabled writes retain emergency
  cleanup behavior.
- Final pre-save verification rejection and enabled-preference load errors no
  longer latch a safety lock when no enabled write is outstanding. Failed proof
  still refuses the write; it is not treated as authorization to enable.
- Persist the interrupted-activation marker only immediately before a real
  enabled save, not before queued reads or no-op configuration checks.
- Log timeout stage, selected recovery action, retry count, deadline, and
  outstanding-write count. Expose persisted cause/time through the signed
  reporter and the recorded cause in the safety-lock UI.

## Verification and live recovery

The HoldfastMac hostless suite passed **435 tests, zero failures**, including
timeout, activation authorization, late-save quarantine, same-boot reset, and
network-outage regressions. Result: `Test-HoldfastMac-2026.09.20_11-47-40--0400.xcresult`;
build log: `/tmp/holdfast-safety-read-timeout-final.log`. `git diff --check` passed.
Build 89 was copied to `/Applications/Holdfast.app` and its deep/strict code
signature verified. The app was not relaunched and no live Network Extension
configuration was changed.

The existing persisted lock is intentionally not auto-cleared: older records do
not carry the operation-stage evidence needed for a safe general migration.
After reopening the updated app, use **Reset Enforcement Without Restart** once.
This proves preference removal and ordinary connectivity while blocking remains
off. **Enable Web Enforcement** remains a separate explicit action. Live
reenablement and slow-OS-query behavior remain manual verification steps.
