# Security hardening and enhancements — 2026-09-29

Source of findings: the "Holdfast — App Analysis" review of the same date.
Everything below was written without a Swift compiler or Xcode available, so
**nothing here has been built or run yet.** The Swift was syntax-checked with a
tree-sitter parser (no new parse errors versus the previous files); type
checking, the unit suites and live behavior still need Xcode and this Mac.

## What changed

| Area | Before | After | Files |
| --- | --- | --- | --- |
| Pause ledger (Mac) | Read from a user-editable plist and published with no cap; one edited `expiresAt` paused a rule for years. | App clamps each published pause to the group's session maximum. The filter remembers when it first saw a pause session and caps it from there, so republishing cannot slide it forward. | `DesktopBlockProfile.clampedPause`, `DesktopPauseBound.swift`, provider loader |
| Lock state (Mac) | Unlock progress, retreat unlocks, session exits, pauses and backoff in plists. | Stored in the data-protection Keychain (`KeychainProtectedLedger`), migrated once from the old plists. Falls back to the plist, with a fault log, if that Keychain is unavailable. | `ProtectedLedger.swift`, `KeyValueLedger.swift`, `MacAppModel` |
| Policy HMAC key | Legacy login keychain, where the access group is ignored and the key can be revealed. | Data-protection Keychain; an existing key is moved (same bytes) on first read. | `DesktopPolicyKeyStore` |
| Emergency disable | Silent. | Kept instant and passage-gated (by decision), but each use is recorded in bypass history (source "Emergency disable") and in the tamper journal, with whether a filter warning was live. | `BypassHistory.swift`, `MacAppModel.disableDesktopBlocking` |
| Clock | Rule windows and lockdown sessions trusted the wall clock. | The filter anchors wall time to `mach_continuous_time` per boot and keeps a high-water mark across boots. On disagreement beyond 2 minutes it enforces the union of both instants. Unlock waits in the app use the earlier of the two times. | `ClockTamperGuard.swift`, `activeRules`, `activeSessions` |
| Weakening from iCloud | The Mac republished whatever arrived. | A locked group weakened without this Mac's unlock keeps its previous form for its unlock delay (passage-only groups are not held). Held changes are listed in the Mac status area. Retreat groups past their planned end, and not-yet-started Retreat groups, are exempt. | `RemoteWeakeningHold.swift`, `MacAppModel.publishDesktopPolicy`, `MacContentView` |
| System Settings toggle | Unobserved. | `NEFilterConfigurationDidChange` is watched. An off switch while Holdfast intends to enforce is journaled, shown as a warning, and re-armed after 15 minutes (never immediately, in case it was an outage fix). | `ExternalFilterToggle.swift`, controller extension |
| Tamper journal | None. | `TamperJournal` in app and filter; the filter's events travel in the status file; the Mac mirrors the journal to iCloud KVS (`holdfast.tamper-journal.v1`). | `TamperJournal.swift` |
| VPN / proxy apps | Only exact signing identifiers. | Identifiers ending in `.*` match a vendor family (covers tunnel helpers). New "VPN and proxy apps" preset. | `matchesApplication`, `HoldfastPresets.swift` |
| Block-page CA | Unconstrained, 10 years, key on disk. | Name-constrained to blocked domains, `pathlen:0`, 825 days, key deleted after signing, re-minted per run. Verified with OpenSSL: in-scope leaf verifies, out-of-scope leaf fails with "permitted subtree violation". | `Scripts/setup-block-page.sh`, `Docs/MacBlockPage.md` |
| Retreat boundaries (Mac) | Started/ended only when the app recompiled. | Retreat groups carry `activeFrom`/`activeUntil`; Retreats starting within 14 days are published ahead. Shortening an interval counts as weakening. | `RetreatSchedule.swift`, `DesktopEnforcementRule` |
| Presets | None. | Work hours, Evenings off, Deep-work retreat, Hard block (Mac dashboard and iOS "+" menu). | `HoldfastPresets.swift` |
| Reflection | Passage only. | Temporary access asks one question (≥ 4 words) before the passage; the answer is saved with the bypass and shown in history. | `ReflectionPrompt.swift`, pause sheets |
| Controller refactor | 4,700-line controller with loose queue state. | First extraction: the single-flight, latest-wins preference queue is a pure `GenerationalMutationQueue`, with the old property names kept as views so call sites are unchanged. | `GenerationalMutationQueue.swift` |

New tests: `DesktopPauseBoundTests`, `ClockTamperGuardTests`,
`ExternalFilterToggleGateTests`, `TamperJournalTests`,
`RemoteWeakeningHoldTests` (+ `RetreatIntervalTests`), `HoldfastPresetsTests`,
`GenerationalMutationQueueTests`, and an emergency-disable case in
`BypassHistoryTests`. Desktop-only tests are excluded from the iOS test target.

## Before merging

1. `xcodegen generate`, then build `HoldfastMac`, `Holdfast` and both test
   schemes. Expect a handful of type errors to fix; none were checkable here.
2. Run `DesktopEnforcementTests` and `HoldfastTests`.
3. After installing, confirm the ledger is using the data-protection Keychain:
   `log show --predicate 'category == "protected-ledger"' --last 10m` should
   show no `ledger_fallback_to_defaults`.

## Manual verification (live)

- **Pause forgery:** grant a 10-minute pause, then set its `expiresAt` far in
  the future with `defaults write` against the old plist key. Expect no effect
  (the ledger no longer reads the plist) and, if forced through the fallback
  path, a pause that still ends at the session maximum.
- **Clock:** during a blocking window, move the clock 8 hours forward. The site
  must stay blocked and the journal should record "System clock changed".
  Restore automatic time and confirm normal behavior after reboot.
- **System Settings:** switch the filter off in System Settings. Expect the
  warning, a journal entry, and re-enable after 15 minutes. Then use
  "Disable Blocking With Passage" and confirm nothing re-arms.
- **Remote weakening:** on the iPhone, remove a domain from a locked
  (delayed, 1 day) group. On the Mac expect the hourglass notice and the domain
  to stay blocked until the stated time.
- **Retreat:** schedule a Retreat to start in 10 minutes, quit Holdfast, and
  confirm the filter starts and ends it on time.
- **Block-page CA:** `sudo Scripts/setup-block-page.sh`, then check
  `/Library/Application Support/ExecutiveDysfunction/blockpage/` has no
  `ca.key`, and that Keychain Access shows only one Holdfast Block Page CA.

## Not done, and why

- **iOS background Retreat boundaries.** iOS needs Device Activity monitors per
  Retreat window within the ~20-monitor budget; that is a separate design.
- **iOS stricter-only ingest.** The same hold is not yet applied when a
  weakening arrives on the iPhone from the Mac.
- **Configuration profile with a removal password** (Tier 4a) needs a live
  probe on this Mac, not code.
- **Clock jumps forward across a reboot** remain undetectable locally; a
  network time check would close it.
- **Further controller extraction.** Next candidates, in order: activation
  evidence and watchdog sequencing, same-boot reset, late-enable quarantine.
- **Windows** is now labelled experimental in the README; the source is kept.
