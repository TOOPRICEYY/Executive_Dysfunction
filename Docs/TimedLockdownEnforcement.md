# Timed enforcement lockdowns (build 94)

## Semantics

A lockdown holds only the selected Blocking Groups continuously, including
outside their normal blocking windows, during allowance windows, while their
saved schedule is disabled, and during existing temporary pauses. It does not
rewrite the saved schedule. Multiple lockdowns are additive: ending one cannot
release another. Normal scheduling resumes after the final applicable session.

Targets are snapshotted at the start. Editing/deleting a group or ending its
retreat cannot erase that commitment; current targets are enforced additively.
Lockdowns always apply to all updated Apple devices on the same iCloud account.
The session, portable target snapshot, original deadline and early-exit policy
sync; opaque iOS app/category tokens remain device-local. Existing unexpired
local sessions are shared on first reconciliation after updating.
Normal platform authorization and emergency recovery remain available.

## Cross-device synchronization

`CloudLockdown.swift` stores each immutable session under a separate iCloud KVS
key and writes authorized cancellation as a separate tombstone. This is not
part of the whole preferences document: concurrent starts are additive and old
clients cannot erase sessions by saving their preferences. A persisted local
replica doubles as an offline outbox. Missing cloud data never cancels a local
session, and a late session arrival cannot override its cancellation tombstone.
Expired sessions are pruned; cancellation tombstones last through the original
deadline plus one day. Quota failure leaves local intent intact and reports a
pending sync rather than claiming delivery. Ordinary sync never restarts an
unchanged Mac policy.

Both apps reconcile on launch/foreground and external KVS notifications. KVS
does not guarantee immediate delivery or wake a terminated app to enforce a new
session. Open Holdfast on each device after starting/ending a lockdown. Controls
and status explain delivery delay, missing local targets, missing authorization
and iOS monitoring failure. This is not a remote enforcement acknowledgement.
Every participating app must be updated; on Mac the provider must also be updated
to read the new signed cancellation authorization. Earlier versions remain local.

The Mac signs cancellation authority for specific session IDs through their
original deadline, so a sleeping provider can still receive it; this cannot
authorize weakening a rule or ending an unrelated session. iOS preserves and
checks a Mac-origin session's saved delay/checkpoints before publishing an early
exit. In-progress exit requests remain local; the completed cancellation syncs.

## macOS

The browser-pause path previously deleted rules before `activeRules` could
apply the lockdown override. Both pause validation and effective-rule filtering
now protect held groups. Native/browser pause controls and reported pause status
are suppressed for those groups. Session snapshots persist in the signed policy.
Unauthorised updates cannot remove selected IDs or postpone a running session.
Failed publication rolls back the UI's start/end mutation.

Expiry uses the exact date in the provider's runtime decisions. The calendar,
dashboard group rows, and group editor show the override and deadline. Web
enforcement must still be enabled and healthy; creating a session does not
silently clear a safety latch or grant extension permission.

Early exit checks the saved passage and its configured wait/checkpoints on both platforms.
The former misleading "Rest of today" fixed-duration choice is now "12 hours".

## iOS / iPadOS

Timed enforcement is distinct from app-wide *change protection*. Open
Dashboard → Start lockdown, select groups and duration, then Start lockdown.
The app saves device-local target snapshots, registers one independent
Device Activity expiry monitor per session, and applies independent Managed
Settings stores. Normal allowance/window callbacks cannot clear these stores.
Overlapping sessions use different store names. Rebuilds preserve registered
session monitors and reserve their capacity before normal schedules.

Screen Time receives an outward-rounded 15-minute envelope. Exact intended
times remain in the model/calendar; opening/foregrounding Holdfast reconciles
the exact state. iOS callbacks may be delayed until device use. The setup and
dashboard explain this approximation, as accepted by the user. A registration
failure does not apply new lockdown shields. A missing monitor during recovery
is reported; unmonitored lockdown shields are cleared rather than left forever.
The diagnostics report includes exact/padded end, monitor registration, and
snapshot-shield counts. Sessions created on iOS require the saved 80-word passage;
imported sessions keep the originating device's exit policy.
Admission also budgets snapshot/current-target stores against Apple's
[50 named Managed Settings stores per process](https://developer.apple.com/videos/play/wwdc2022/110336/).

## Windows limitation

This repository has a partial executable-blocking service/driver, not a complete
Windows app/filter stack. Its signed-JSON-to-binary policy producer and domain
filtering WFP/DNS implementation are absent. It cannot yet enforce these timed
website/group lockdowns. Completing that requires the Windows implementation,
WDK/signing/install infrastructure and real-device verification; no claim of
Windows lockdown support is made by this change.

## Verification and manual checks

Automated tests cover paused/disabled/unscheduled rules, target preservation,
overlap/expiry, carry-forward protection, calendar clipping/merging across
midnight, iOS snapshot encoding, monitor identity, coarse timing and UI entry.

Before release, on a physical iPhone/iPad with Screen Time authorization:

1. Select a group currently inside an allowance window; start a one-hour lockdown.
2. Verify its selected apps/sites shield immediately, unrelated sites still work,
   and existing temporary access does not release it.
3. Background, reopen, modify the saved schedule and repeat. Start an overlapping
   session; ending one must not release the other.
4. Check exact expiry by reopening Holdfast; separately check coarse background
   expiry on device use. Inspect diagnostics if callbacks are late.
5. Repeat with denied authorization and exhausted monitor capacity; the app
   must explain failure, not show a newly active lockdown.

On Mac, verify the same selected-site/unrelated-site matrix, existing browser
connections and retry behavior, normal pause restoration after expiry, and
status/calendar details. No live enforcement was toggled by automated tests.

For cross-device release verification (physical devices, still required):

1. Update Mac app/provider and iPhone app; use the same iCloud account and enable
   each device's normal enforcement authorization. Start on Mac, open iPhone,
   verify the same group IDs/deadline and selected-target blocking outside windows.
2. Repeat from iPhone to Mac, including app-only groups whose local targets have
   been configured independently. Missing targets must show a warning.
3. Start different sessions offline on each device, reconnect and reopen both;
   both sessions must remain. End one through its saved policy; only it ends.
4. Keep one device offline while cancelling, then reconnect with its stale
   session. It must consume the cancellation, never resurrect the session.
5. Test a Mac-origin delayed/repeated-confirmation policy from iOS. The initial
   passage must begin the wait, not bypass it. Check unchanged normal browsing.

Automated transport tests use isolated defaults and an in-memory cloud; they
exercise offline/concurrent delivery, tombstones, restart, quota recovery, legacy
preferences writes and idempotence without writing to the user's iCloud account.

Build 94 verification on 2026-09-29: 492 hostless Mac tests and 196 iOS simulator
unit tests passed, plus the lockdown setup UI test (all-device wording and no
start without Screen Time). Logs: `/tmp/holdfast-lockdown-sync-mac.log`,
`/tmp/holdfast-lockdown-sync-ios.log`, `/tmp/holdfast-lockdown-sync-ios-final.log`.
Not deployed by this change; physical cross-device delivery remains unverified.
