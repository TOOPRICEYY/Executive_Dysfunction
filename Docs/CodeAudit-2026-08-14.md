# Holdfast code audit — 2026-08-14

Scope: Swift application/shared code, macOS Network Extension and block-page
daemon, iOS Device Activity integration, build scripts, and a source review of
the Windows service/WFP/driver implementation. The live macOS filter was not
enabled, disabled, restarted, or upgraded during automated verification.

## Confirmed findings and disposition

| Severity | Finding | Disposition |
| --- | --- | --- |
| High | iOS could request more Device Activity monitors than the system capacity. More importantly, a temporary allowance whose expiry monitor was not admitted could remain open past its expiry. | Fixed. Capacity is allocated deterministically, expiry monitors take priority, and any allowance that cannot be monitored is cancelled and its shield is reconciled immediately. |
| High | Duplicate rule identifiers could reach `Dictionary(uniqueKeysWithValues:)` in restriction checks and terminate the process. | Fixed. Proposed policy duplicates are rejected before authorization checks; imported duplicates use deterministic newest-wins projection where additive display/sync behavior is appropriate. |
| High | Malformed allowance minutes could construct an invalid Swift range while compiling an allow-list schedule. | Fixed fail-closed. Invalid weekdays/minutes are ignored and the remaining allowed intervals are merged safely. |
| Medium | Several cloud/editor projections assumed unique Activity Group or Blocking Group identifiers and could crash on corrupt or conflicting sync data. | Fixed with deterministic conflict resolution and explicit duplicate-policy rejection. |
| Medium | The block-page daemon force-cast the imported PKCS#12 identity. An unexpected Security-framework payload could terminate the daemon. | Fixed by checking the Core Foundation runtime type before the API-guaranteed conversion; HTTPS is withheld and an error is logged on mismatch. |
| Medium | Shared static `JSONEncoder`/`JSONDecoder` instances in the temporary-pause store could be used concurrently by multiple store instances. | Fixed by creating operation-local coders. File serialization and atomic replacement remain intact. |
| Medium | Swift 6 sendability warnings identified policy persistence and Network Extension completion closures crossing dispatch queues without an explicit concurrency contract. | Fixed with a sendable persistence contract, locked store conformance, and a narrowly scoped sendable completion wrapper. |
| Medium | Block-status lane assignment scanned all lanes for every event, degrading toward quadratic behavior with many groups. | Fixed with active/free binary min-heaps (`O(events log events)`). Events remain visually stacked instead of widening the calendar. |
| Medium | Allow-list compilation allocated and scanned a 7 × 1,440 Boolean grid per group. | Fixed with sorted/merged intervals and interval complementation. |
| Low | The calendar captured the current calendar/time zone once and the “now” marker did not advance. | Fixed. Day/time-zone notifications rebuild the snapshot and a minute timeline advances the marker. |
| Low | Domain suffix reduction performed pairwise comparisons and admitted malformed ASCII labels. | Fixed with a suffix-membership walk and hostname/label validation. |
| Low | Duplicate synced event IDs could collide in SwiftUI `ForEach`; legends also copied the complete rule collection. | Fixed with collision-resistant event identity and index iteration. |
| Low | Deprecated/unbounded C-string decoding remained in boot/address parsing, and the HTTP header renderer contained a logically unnecessary force unwrap. | Fixed with bounded UTF-8 decoding and optional-safe header rendering. |
| Build performance | The block-page embedding phase ran on every macOS build because it declared no inputs/outputs. | Fixed by declaring the executable input and embedded output. |

## Residual risks and validation limits

- The Windows service/driver sources were reviewed, but the Windows SDK, WDK,
  Driver Verifier, and a Windows test host are not available on this Mac. No
  unverified kernel changes were made.
- Windows process-driver policy replacement and persistent WFP replacement are
  separate transactions. If one succeeds and the other fails, old and new
  restrictions can temporarily coexist. This is fail-closed, but can appear as
  broad connectivity loss when a VPN, proxy, browser broker, or shared network
  process is targeted. A production Windows validation plan should include
  explicit rollback/reconciliation fault injection around both steps.
- Address Sanitizer and Thread Sanitizer test runners aborted inside Xcode's
  test bootstrap before executing a test on this macOS/Xcode installation.
  The ordinary host-only suite and Xcode static analyzer completed successfully.
- A physical-device iOS test is still required for Device Activity capacity
  behavior and shield restoration. Simulator/generic builds cannot exercise
  Screen Time enforcement.
- A guarded live macOS Network Extension smoke test remains manual. It should
  use the existing watchdog harness so enforcement is automatically disabled
  after its short test window. It was intentionally not run during this audit
  because the live machine has previously lost all connectivity.

## Verification

- Host-only macOS safety/regression suite: **327 passed, 0 failed, 0 skipped**.
- Complete unsigned macOS app + Network Extension build: passed.
- Complete unsigned generic iOS app + embedded extensions build: passed.
- Xcode static analyzer for the macOS app + Network Extension: passed.
- `git diff --check`: passed.
- Shell syntax checks: passed (the smoke script emits a sandbox-only `nice(5)`
  warning while parsing).
- JavaScript syntax checks for icon generation and path tracing: passed.
- Signed build 67 app and embedded extension: signature and designated
  requirement verification passed; deployed executable hash matches the build.
- Post-deploy ordinary connectivity: Apple success endpoint returned HTTP 200.
- Post-deploy safety state: activation latch clear, `blockingDisabled=false`.
- `/Applications/Holdfast.app` now contains build 67. The deliberately
  undisturbed running process and active Network Extension remain build 66
  until a controlled app relaunch/extension upgrade.

## Files changed by this audit

- `Sources/CloudShared/CloudPreferences.swift`
- `Sources/CloudShared/BlockStatusCalendarLayout.swift`
- `Sources/Shared/ActivityMonitorCapacityPlan.swift`
- `Sources/Shared/RuleScheduler.swift`
- `Sources/App/AppModel.swift`
- `Sources/App/IOSBlockStatusTimeline.swift`
- `Sources/MacApp/MacBlockStatusTimeline.swift`
- `Sources/MacApp/MacActivityGroupEditor.swift`
- `Sources/MacApp/MacEnforcementController.swift`
- `Sources/DesktopShared/DesktopEnforcementPolicy.swift`
- `Sources/DesktopShared/DesktopRemovalAuthorization.swift`
- `Sources/DesktopShared/MacFilterInterceptionPlan.swift`
- `Sources/DesktopShared/MacFilterPreparedRetryGuards.swift`
- `Sources/MacWebFilterExtension/MacWebFilterProvider.swift`
- `Sources/BlockPageServer/main.swift`
- `Sources/BlockPageShared/BlockPageHTTP.swift`
- `Sources/BlockPageShared/BlockPageTemporaryPause.swift`
- `Tests/ActivityMonitorCapacityPlanTests.swift`
- `Tests/BlockStatusCalendarLayoutTests.swift`
- `Tests/CloudPreferencesTests.swift`
- `Tests/DesktopEnforcementPolicyTests.swift`
- `Tests/WebFilterOutageRegressionTests.swift`
- `project.yml` and generated `Holdfast.xcodeproj`
