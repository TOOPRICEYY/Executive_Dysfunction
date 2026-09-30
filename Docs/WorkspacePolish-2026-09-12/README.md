# Holdfast workspace refinement — build 85

September 12, 2026. Native macOS and iOS implementation, following a screenshot-led product-design audit of the existing app. The hard-edge visual language is retained; typography, hierarchy, wording, responsiveness, and action sequencing have been refined. No network enforcement or change-policy rules were relaxed in this pass.

## Flow findings and outcomes

1. **Dashboard → find a group — improved and regression tested.** Disabled Mac groups were hidden behind “other blocking,” and large panels consumed space without helping navigation. All baseline groups now appear directly, search is available for larger collections, and narrow panels stack. Target summaries distinguish apps, websites, and Screen Time selections. iOS explains missing Screen Time access and offers a direct route to settings. See `mac-dashboard-before.png`, `mac-dashboard-after.png`, and `ios-dashboard-after.png`. The Mac before calendar was empty; the after fixture deliberately exercises populated calendar layout, so that portion is not a like-for-like data comparison.

2. **Blocking Group → schedule/change policy — improved and regression tested.** Plain-language policy and enforcement choices replace technical wording. Schedule painting explains that colored time allows access and reports weekly allowance hours. The Mac week uses available width for all seven days; very narrow views retain scrolling. Long names and compact layouts were rendered. See `ios-schedule-after.png` and `mac-dashboard-narrow.png`. Existing authorization checks remain authoritative.

3. **Retreat → review → start/edit/history — sequencing bugs fixed.** iOS now presents an actual review screen before explicit activation. Returning from review does not start a retreat. Opening an existing retreat from the dashboard no longer incorrectly marks it as new. Active/scheduled retreats offer Save changes, not another start action. Dates, selected groups, and the policy governing both changes and early ending are explained. History separates active, planned/draft, and completed records. The Mac policy selector now has sufficient space in a narrow window. See `ios-retreat-review.png` and `mac-retreat-narrow.png`.

4. **Settings → protection/appearance/diagnostics — clearer and tested.** iOS puts protection settings before appearance. Shared controls use quieter typography, distinguish disabled/destructive states, and improve light-theme accent readability. The inert Mac preview action was removed. Clearing the diagnostic trace requires confirmation. Generic errors are no longer mislabeled as iCloud problems, and temporary-access sheet errors can surface on that sheet. See `ios-settings-after.png`.

5. **Unlock/temporary access → enforcement — preserved, not live-tested.** Shared presentation improvements apply without weakening passage requirements, temporary-access eligibility, or retreat change policies. Unit coverage exercised existing policy and outage logic; live network enforcement, Screen Time permissions, and destructive recovery actions were deliberately not activated.

## Changed implementation areas

- Shared presentation: `Sources/CloudShared/HoldfastPresentation.swift` and both native design systems.
- Workspace/navigation: `IOSWorkspaceViews.swift`, `MacWorkspaceViews.swift`, and `MacContentView.swift`.
- Editors: `IOSArchitectureEditors.swift`, `MacBlockingGroupEditor.swift`, and the save-status wording in `AppModel.swift`.
- Calendars: `IOSBlockStatusTimeline.swift` and `MacBlockStatusTimeline.swift`.
- Error presentation: `TemporaryAccessRequestView.swift`.
- Tests/project: `CloudPreferencesTests.swift`, new `MacWorkspaceLayoutTests.swift`, `Tests/UI/HoldfastWorkspaceUITests.swift`, and build 85/test-source declarations in `project.yml` with regenerated Xcode project.

The repository contained extensive pre-existing changes. This list describes this pass rather than attributing every dirty file to it.

## Verification

- macOS: **418 tests passed**, including shared policy/enforcement regressions and native light/dark/narrow rendering tests.
- iOS simulator: **156 unit tests and all 10 UI tests passed**, including explicit retreat review/back behavior.
- Final affected iOS schedule/tab checks rerun successfully after a simulator Busy launch failure was cleared by restarting only that simulator.
- `git diff --check` passed.
- Mac snapshots use offscreen SwiftUI hosts with fixture data, not the live app model. Forced light/dark rendering does not establish a complete real-user theme-toggle test.
- The retreat UI test creates a disabled simulator-only group; it does not start a retreat or enable live filtering.

Result bundles are in Xcode DerivedData: `Test-HoldfastMac-2026.09.12_09-30-10--0400.xcresult`, `Test-Holdfast-2026.09.12_09-22-22--0400.xcresult`, and `Test-Holdfast-2026.09.12_09-29-03--0400.xcresult`.

## Remaining manual coverage

Build 85 was installed at `/Applications/Holdfast.app`; its version and deep/strict code signature were verified. The app was not relaunched, no live filter settings were changed, and no commit or external deployment was made.

Install the iOS build on a physical iPhone to verify real Screen Time authorization, token presentation, unlock, and temporary-access behavior. Test existing locked retreat editing/ending with real policies. VoiceOver, maximum Dynamic Type, all localization lengths, and all device sizes are not fully audited. No full accessibility-compliance claim is made. Live Mac extension approval/network recovery and the browser block page were outside this presentation pass. Reopening the installed Mac application is left to the user so this work does not interrupt live enforcement.
