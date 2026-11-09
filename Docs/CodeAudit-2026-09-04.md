# Holdfast audit — 2026-09-04

Scope: macOS app/recovery/filter/diagnostics, shared rules and calendar layout,
iOS monitoring and workspace UI, block-page host-file handling, local deployment,
and a source inspection of the Windows service and driver. Existing unrelated
workspace changes were preserved. Live macOS enforcement was not toggled.

## Fixed findings

| Area | Confirmed problem | Change |
| --- | --- | --- |
| iOS temporary access | An expiry monitor rejected by Screen Time was still followed by suspension, leaving no callback to restore protection. | Only successfully registered pauses authorize suspension. Failed registrations cancel the stored pause, restore any applicable usage shield, and return an error. Granting access no longer reports success after registration revoked it. |
| iOS callbacks | An old allowance-end callback could cancel a pause that had since been extended; an obsolete start callback could clear shields without an active pause. | Callbacks check the current stored allowance before changing shields. Usage restoration also respects whether the usage limit is still enabled. |
| iOS daily limits | The orphan-shield sweep inferred live rule IDs from time windows, so a valid usage-only rule was treated as obsolete. | Compute active usage-rule identities independently from window identities. |
| Retreat calendar | Editing just a Retreat's dates did not invalidate the calendar snapshot on either platform. | Observe the complete calendar input, including enforcement intervals. |
| Calendar/DST | Retreat edges used elapsed hours since midnight, which moved them by an hour on daylight-saving transition days. | Place edges by local clock components; regression coverage includes spring-forward and fall-back. |
| iOS schedule diagnostics | Next-transition calculations added elapsed minutes to midnight and missed repeated fall-back hours. | Resolve clock times through Calendar, including both repeated times and the clock-change instant. |
| Imported data | A reversed Retreat date interval could trap while constructing the dashboard. | Reject invalid/empty calendar intervals before constructing DateInterval. Disabled rules also no longer contribute events or hours. |
| Mac recovery UI | An approval-related delivery error hid Open System Settings behind the recovery-action branch. | Keep the approval action available alongside passage-confirmed recovery. |
| Mac performance | Diagnostic writes performed cross-process file locking and fsync on the caller, including UI/provider paths. | Use a serial utility queue with a 256-write bound. Under sustained disk stalls, new trace writes are dropped rather than blocking enforcement or accumulating unbounded memory. Export and clear wait for queued writes. A sudden process exit may lose the last queued events. |
| Report performance | Building a report decoded the entire trace before taking the newest 400 records. | Decode newest-first and stop at the requested number of valid events; preserve chronological output and tolerate a truncated tail. |
| Diagnostic accuracy | Reports called stale telemetry proof of a wedged filter, instructed a mandatory restart, ignored active Retreat-only configurations, and omitted recovery warnings. | Explain idle suspension, point to same-boot reset/passage recovery, include active Retreats and current warning state. |
| Block-page daemon | Nested/interleaved old/new host-file markers could invalidate removal indices, crash the daemon, or remove unrelated lines. | Refuse overlapping managed ranges before any editing. |
| iOS UI | The painter's time-label padding shifted cells away from weekday headers; fixed widths clipped the last column on the tested phone. | Include padding within the label width and size weekday columns to the viewport. Keep the schedule title compact. |
| iOS readability | Bright accent colors used as text on the light canvas made native controls difficult to read. | Use darker control-ink variants while retaining bright fills and logo colors. |
| Deployment | The one-click command validated the app only after overwriting the installed copy. | Verify the built bundle before installation as well as afterward. |
| Windows driver | Policy IOCTL dispatch acquired a push lock without disabling normal kernel APC delivery, and accepted zero revisions/unterminated paths. | Balance KeEnterCriticalRegion/KeLeaveCriticalRegion around both exit paths and reject malformed input before taking the lock. Source verification only; WDK/Driver Verifier validation remains required. |

Windows locking reference: [Microsoft ExAcquirePushLockExclusive requirements](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-exacquirepushlockexclusive).

## Verification

- macOS regression suite: final 397 tests passed, including bounded logging tests.
- iOS unit suite: 140 passed; 10 TimeWindow tests and 28 Lockdown tests passed afterward, including two added DST cases and an allowance callback regression for DeviceActivity's whole-second boundary precision and a newer extension of the same pause.
- iOS UI suite: all 8 tests passed. Captured tabs, editors, rejection feedback,
  scrolling, schedule painting, and diagnostics. The changed painter receives a
  further focused screenshot check, which passed. [Before](Audit-2026-09-04/allowance-before.png) / [after](Audit-2026-09-04/allowance-after.png): all seven columns fit, headers align, the title is complete, and control text is darker.
- `git diff --check` and deployment-script syntax check passed.
- Signed Debug build 76 built successfully and was installed at `/Applications/Holdfast.app`. Both the source bundle and installed bundle passed `codesign --verify --deep --strict`. No app relaunch or live filter enable/disable was performed.

## Remaining limits and follow-up

- Real Network Extension error/recovery behavior still needs the bounded live
  connectivity harness. Unit tests do not prove OS callback timing or browser
  behavior, and this audit did not change the running filter's state.
- iOS Screen Time registration, allowance expiry, and usage shields require a
  physical iPhone. Simulator tests cover logic and UI, not Screen Time behavior.
- Background Retreat boundaries need a separate lifecycle implementation/review:
  the iOS app compiles the currently active rules at sync time and the monitor
  extension does not independently activate a future Retreat or remove its
  rules at the Retreat boundary. Reopening/syncing currently reconciles them.
  macOS similarly depends on its containing app publishing changes. This audit
  does not claim unattended Retreat start/end guarantees.
- The Windows driver changes have not been built or installed on Windows.
  Domain filtering is still unimplemented there; WFP application rules alone do
  not provide website enforcement. The source findings are not evidence for the
  cause of any historical Windows outage.
- Runtime Dock/Finder accent synchronization on macOS remains intentionally
  disabled in MacDynamicAppIcon; the compiled icon is used. Restoring dynamic
  icons needs a correctly masked asset path and visual verification.
- The existing deployment command still copies onto the installed bundle. A
  transactional installer with rollback and notarized distribution remains a
  separate packaging improvement.
- Visual verification used the iPhone simulator in light mode. Dense real-world
  Mac calendars, Dynamic Type, VoiceOver, and dark-mode screens were not fully
  audited and no accessibility-compliance claim is made.
