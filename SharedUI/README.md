# Holdfast — one shared interface

All **new** application screens live here, not in a Windows-specific UI.
React + TypeScript produces one offline HTML/CSS/JS bundle consumed by WebView2
on Windows and the same WebKit wrapper on macOS/iOS. No web server, Node runtime,
remote website, analytics or CDN is needed in the packaged app.

## Current implementation, not a parity claim

- Shared status, group editor (targets, weekly windows, separate change/access
  policies, backoff controls, compact expandable schedule), retreat summaries,
  device-local bypass history and appearance controls.
- Responsive desktop/phone layout; system/light/dark theme and shared accents.
- Versioned asynchronous bridge with validation, timeout/error states, revision
  preservation, no automatic mutation retry and explicit capability gates.
- A clearly labeled, **in-memory-only** fixture available with `?preview=1` when
  there is no native host. A missing host never silently falls back to demo data.
- Windows now has a trusted service-owned workspace: durable groups, weekly
  application-network schedules, independently checked change policies,
  passage unlocks, timed exceptions/backoff, intent/reflection history, and
  explicit enforcement control. The renderer cannot write policy files or
  authorize itself. Actual WFP acknowledgements drive displayed status.
- Apple app targets now bundle the same interface and connect it to the existing
  MacAppModel/AppModel. Native-only budgets, categories, other-platform targets,
  inherited policy fields, and opaque Screen Time tokens survive ordinary edits.
  iOS selections are staged by a native-only token until a policy-checked save.
- Apple retreat creation, lockdown configuration, diagnostics and advanced
  settings still open existing native views. Those advanced screens have **not**
  all been migrated into React. The native fallback remains available.
- Windows website/category filtering, usage budgets, retreats, all-device
  lockdown and Apple sync remain **unsupported**. No local-only lockdown is
  substituted for the user's all-device commitment.

Verification on 2026-10-02: both complete Apple targets compile (Mac unsigned,
iOS simulator), including packaged assets; 531 hostless native tests passed.
TypeScript/build and 11 contract/presentation tests passed; 15 browser tests pass
across desktop Chromium, phone Chromium and phone WebKit, including rejected
passages and preservation of unsaved editor drafts after an acknowledged unlock.
The Windows ARM64 installed UI connects as the normal user. Bounded live VM tests
exercise save, stale-write rejection, selected-app filtering, unaffected control
traffic, exception grant, history, replay rejection, unlock, deletion and global
disable. The initial live test exposed a lost pipe-reply race, now fixed with a
bounded receipt handshake rather than unbounded FlushFileBuffers.

The Mac installation and live enforcement were not replaced or toggled. Apple
native pickers/authorization still need signed on-device acceptance testing.
Windows x64 requires native runtime testing; this remains a development build,
not complete platform parity or a production installer.

## SwiftUI parity layer (2026-10-03)

The dashboard and editor now follow the original SwiftUI layout instead of a
generic web layout:

- Now-headline and next line ("Next: Social Feeds starts at 18:00"), group rows
  sorted now/next/later with state bars, live headline, lockdown/allowance
  badges, RETREAT chip and lock chips (NO LOCK / PASSAGE / N-DAY LOCK / DAILY
  CONFIRM).
- Enforcement banner (WEB FILTER ON/OFF, sync, groups on, retreats running) with
  a FILTER CONTROLS disclosure; sidebar enforcement status; preset start grid and
  START FROM PRESET menu; schedule lanes with the 7-day strip and BLOCKING /
  PAUSED / LATER TODAY / DONE FOR TODAY / FREE TODAY / OFF labels.
- Editor: lock card (Locked / Unlocking / Unlocked until…), painted 30-minute
  schedule grid (with an exact-times fallback so nothing is rounded unless you
  paint), live temporary-access section, change protection, access policy.
- Phone: inline title with a + menu, compact hero with Lockdown, "New blocking
  group" row, slim "No retreat running · Plan one" row, collapsible bypasses,
  iCloud footer and a bottom tab bar.

All of it is driven by **optional, host-evaluated** contract fields, so older
hosts (including the current Windows service) keep working with fallbacks:
`group.now`, `group.unlock`, `group.lockdownUntil`, `snapshot.summary`,
`snapshot.retreatGroups`, `snapshot.schedule.days`, `snapshot.presets`,
`enforcement.headline`, the `presets` capability and the `installPreset`
command. The renderer still never infers enforcement from a schedule: the
summary headline is only shown while enforcement is confirmed, and lane
intervals come from the host's own calendar evaluation.

## Ownership / maintenance rule

| Area | Single owner |
| --- | --- |
| Screens, forms, labels, accessibility, themes, responsive layout | `SharedUI/src` |
| UI/device protocol | `SharedUI/src/contract.ts` |
| Window lifecycle, trusted local content, message transport, native pickers | Thin platform hosts |
| Authorization, persisted commitments, passages, authoritative status, enforcement | Native policy/service boundary — never the renderer |

An adapter translates native models into this presentation contract. It must not
implement another copy of these screens. Conversely the interface must not infer
"blocking" from a calendar, write trusted policy files, grant itself an edit
unlock or trust its own passage validation. Schedule segments here are drawing
geometry, not a scheduler. Existing Swift presentation code is transitional and
is retired flow-by-flow, not maintained indefinitely alongside this UI.

`saveGroup` carries the revision captured **when the editor opened**, even after
a status refresh. Hosts must reject stale writes and check the existing saved
policy before accepting weakening. `requestTemporaryAccess`, retreat ending and
unlock commands are requests, not grants. The host must complete authoritative
confirmation before success. No mutation capabilities should be advertised until
all those checks are implemented. Unsupported features remain visibly disabled.

The contract is a view model, not a replacement cloud-document format. Preserve
unknown/native-only fields in adapters; never round-trip a reduced UI projection
as a full configuration. Do not replace iCloud with an invented incompatible
Windows file and call it synced. Usage budgets, website categories, full
retreat/version editing and advanced platform settings still require additional
shared views before the native fallback can be retired.

## Build / test / preview

Use Node 22.18+ (native TypeScript stripping for unit tests) and npm:

```sh
cd SharedUI
npm ci
npm run build
npm test
npx playwright install chromium webkit
npm run test:browser
npm run dev
# Open http://127.0.0.1:4173/?preview=1 explicitly for sample data.
```

Only `dist/` goes into native packages. `package-lock.json` pins the dependency
graph. Build output includes third-party licenses. No production app downloads
JavaScript at runtime. The bundle blocks remote resources through CSP, does not
use `innerHTML`, and has no service worker or background network calls.

### Windows

After building the shared bundle, from the repository root on macOS:

```sh
/bin/zsh Platform/Windows/scripts/Build-SharedUI-UTM.zsh 'Holdfast Windows ARM64 Test' ARM64
```

Or in a full Windows source checkout with the prebuilt `SharedUI/dist`:

```powershell
.\Platform\Windows\scripts\Build.ps1 -Architecture ARM64 -SharedUI
# Elevated installation:
.\Platform\Windows\scripts\Install.ps1 -PackageDirectory .\Platform\Windows\package-ARM64
# Open Holdfast from the Start menu as the normal user.
```

WebView2 Evergreen Runtime is required. The SDK and JSON dependency are version-
and SHA-256-pinned. UI build is opt-in; the installer detects and installs the
UI/assets when present and creates a Start menu shortcut. The service starts
with Windows, initially disabled for a new workspace; upgrades preserve saved
intent. This is a developer package, not a finished GUI installer.

`HoldfastUI.exe --smoke-test` checks actual render + native snapshot acknowledgement
and writes `ui-smoke.json` beside the executable, then exits. Run in the logged-in
user's interactive session with permission to write that test report. A UTM
guest-agent process runs as SYSTEM in session 0, which is not a valid GUI test
session (the first such attempt timed out). An interactive limited-user scheduled
task passed; the temporary task was removed. Add `-RequireWorkspace` to the
script below to reject a rendered-but-disconnected screen.

For a repeatable guest-agent check, run `scripts/Test-SharedUI.ps1
-PackageDirectory <package-path>` elevated inside the test VM. It launches the
UI in the logged-in user's **limited** session using a uniquely named temporary
task, validates its report, checks that service state is unchanged, and removes
the task in `finally`. It does not enable or disable any filter.

`scripts/Test-Workspace.ps1 -Client <build>/ui/Release/HoldfastWorkspaceProbe.exe`
runs the bounded native integration checks. It refuses an occupied workspace,
uses only a disposable copy of curl, launches an independent recovery watchdog,
records detailed curl exit codes, restores the empty workspace and stops the
service in `finally`. The probe is a test binary, not an installed app feature.

### Apple

```sh
swift build --package-path Platform/AppleSharedUI --scratch-path .build/SharedUIApple
.build/SharedUIApple/debug/HoldfastSharedUIPreview "$PWD/SharedUI/dist"
```

The preview has no model/enforcer/iCloud connection and uses an ephemeral WebKit
store. The real Xcode targets include this same wrapper and the adapters in
`Sources/PresentationShared/SharedInterface*.swift`. Build `SharedUI/dist` before
Xcode; a build phase copies that exact bundle into both apps. The project change
is additive and preserves existing project edits. On Mac, `--native-ui` opens
the prior UI; advanced native controls remain reachable from the shared screen.

## Native boundary safeguards

- Bundle-only origin; reject external/frame navigation, popup windows and media
  permission requests. No general shell/filesystem access is exposed.
- Check message origin, main frame (WebKit), protocol, correlation ID and size.
- Structured JSON responses, not string-concatenated user code. Discard Apple
  replies after navigation/unmount. Renderer rejects incompatible snapshots.
- Production native adapters must authorize **every** mutation independently of
  UI state; hiding a button or disabling devtools is not an authorization check.

References: [Microsoft's WebView2 security guidance](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/security),
[local content hosting](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/working-with-local-content),
[Apple's local-file WebKit API](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)).
