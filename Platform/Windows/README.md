# Windows development build — ARM64 and x64

## Shared UI direction (2026-10-02)

New UI development uses the repository's **single `SharedUI` React/TypeScript
bundle**, not separate Windows/Apple screens. `ui/HoldfastUI.cpp` is a thin
WebView2 host connected to a trusted workspace service; the shared WebKit wrapper is
in `Platform/AppleSharedUI`. See `../../SharedUI/README.md` for exact scope,
tests and migration requirements. Group editing, schedules, passage-protected
changes, temporary access/backoff, intent/reflection history and global control
are connected. The existing installed Apple apps remain unchanged.
Build with `scripts/Build.ps1 -SharedUI` after building `SharedUI/dist`, or use
`scripts/Build-SharedUI-UTM.zsh` from macOS. This opt-in developer package does
not install anything until `Install.ps1` is explicitly run. The installer copies
the optional UI/assets and creates a Start menu shortcut.

## CloudKit development connection (not settings sync yet)

The Apple developer account now has `iCloud.com.GabrielPrice.Holdfast`, linked
to the existing Apple app identifier. A development-only web API token is
restricted to `https://holdfast.invalid`; it does not provide private-database
access without the user's Apple sign-in. No production token or schema has
been deployed, and existing Apple key-value-store data has not been migrated.
The development schema contains `HoldfastConnectionTest` with a `nonce: String`
field. This must exist before the web API can write the canary; an empty schema
returns a per-record `NOT_FOUND` even when the HTTP request itself succeeds.

With `BUILD_TESTING=ON` and shared UI enabled, CMake also builds the standalone
`HoldfastCloudKitSignIn.exe` harness. It is deliberately **not installed** with
the app. Place the approved development configuration beside that executable as
`cloudkit-development.json`; never commit session credentials. The local Mac
configuration is in ignored `.build/CloudKit/development.json`.

- Run `HoldfastCloudKitSignIn.exe --probe` as the ordinary interactive Windows
  user to check Apple authentication without opening a sign-in window.
- Run without arguments to sign in through an isolated WebView2 window. It has
  no native message bridge, host objects, downloads or enforcement connection.
  Top-level navigation permits only the enumerated Apple HTTPS hosts, including
  the observed completion host `cdn.apple-cloudkit.com`. Exact app callbacks
  are consumed from navigation, frame, popup and external-protocol events;
  external OS protocol launches are cancelled.
- The callback is validated with Apple before its session is saved using
  user-scoped Windows DPAPI. A different account cannot silently replace the
  established account. HTTP redirects cannot forward credentials to another
  host; TLS validation remains enabled. Password autofill/saving is disabled.
- Redacted results are written to
  `%LOCALAPPDATA%\Holdfast\CloudKitDevelopment\connection-status.json`.
  `settingsSyncEnabled` remains `false`: authentication success is **not** a
  claim that groups or lockdowns have synced.
  Rejected navigation reports only its host, never a callback or query token.
- After authentication, `HoldfastCloudKitRoundTrip.exe` creates one random
  `HoldfastConnectionTest` development record, reads it back and deletes that
  exact record. It does not touch app settings. Its redacted result is
  `roundtrip-status.json` beside the connection status. If an operation has an
  uncertain result, it does not blindly retry; the generated test record name
  is retained for targeted cleanup. This live probe is not part of `ctest`.
  `--inspect-record holdfast-connection-test-<UUID>` performs a read-only lookup
  of that exact generated ID, writing `record-inspection-status.json` instead.
  Errors report the stage, HTTP status and bounded server error code, never
  raw server response text or credentials.

The sign-in URL/callback boundary tests run locally on Windows without a login;
they cover host spoofing, insecure schemes, nonstandard ports, URL credentials,
callback lookalikes, duplicate/malformed/oversized tokens and encoded tokens.

Verified on October 2, 2026 in the ARM64 Windows UTM guest: Apple sign-in,
user-scoped credential persistence, and a private-database create/read/delete
round trip. The test record was deleted and the enforcement workspace remained
unchanged. This verifies the connection, not cross-device settings sync.

Still required: shared settings schema and migration, conflict-safe/offline
replication, native policy-checked Windows projection and signed Apple
integration before enabling any actual settings sync. The
test harness never reads or writes group records and never changes enforcement.

## Enforcement foundation status

**Not yet a complete Windows edition of Holdfast.** Current work provides a
portable policy core, application-network service, administrator control tool,
installer/recovery scripts, connected shared UI and bounded UTM connectivity
tests. Website/category filtering, usage limits, retreats and Apple cross-device
sync remain unsupported. All-device lockdown is not falsely implemented as a
local-only Windows mode.

Status (2026-10-02): **ARM64 development service built, installed and tested in
UTM; the connected installation is running idle with zero active filters.** Both ARM64 and x64 packages compile
with MSVC 19.44/Windows SDK 10.0.26100. The x64 package is cross-built, not
runtime-verified on native x64 Windows. Verified in the ARM64 VM:

- 40 native C++ policy checks; six PowerShell syntax checks and six architecture
  regression checks. The same core checks pass under macOS ASan/UBSan.
- 32 atomic policy replacements with monotonic revisions and service acknowledgement.
- Selected-process IPv4 blocking while an ordinary HTTPS control stays connected.
- Natural 15-second expiry, service-crash release, and malformed-policy rejection
  without early clearing or extending the accepted deadline. All cleanup checks pass.
- Wrong-architecture installation rejection, uninstall/reinstall, idle startup
  acknowledgement, and explicit stopped/zero-filter final status.
- Guest transport success and intentional-failure propagation.
- Connected normal-user UI acknowledgement plus 28 workspace authorization,
  persistence, schedule and backoff checks. Full live workspace save/block/pause/
  history/unlock/delete/disable test passed with independent watchdog cleanup.

Connected packages and the final detailed native test report are retained under
`.build/WindowsArtifacts/2026-10-02-connected/` in the repository. An earlier
Microsoft homepage probe timed out/returned partial content even while idle;
the workspace test now uses a small HEAD request and records curl exit codes.

IPv6 internet connectivity was unavailable and is **not verified**. The independent
watchdog is implemented but forced test-runner death/hung-service recovery still
needs a separate fault-injection run. These are unsigned development packages,
not a production installer or a feature-complete Windows app. A dedicated
`Holdfast Windows ARM64 Test` VM has been created in UTM (8 GiB RAM, 4 cores,
64 GiB disk, no shared host directory); Windows 11 Pro and guest tools are
installed using the owner's downloaded ARM64 ISO. Shared networking failed to
provide an IPv4 lease; the VM now uses Emulated VLAN and downloads work. The
signed Microsoft build-tools bootstrapper was signature-verified and installed
with owner approval. The existing x64 ISO is not used.

One source tree supports ARM64 and x64, but **separate native packages** are
required. ARM64 VM testing does not verify x64 runtime behavior. Installation
checks PE machine types and refuses a native-architecture mismatch.

## Enforcement and recovery boundaries

- `HoldfastCtl` publishes protocol-v2 binary snapshots into the ACL-protected
  `%ProgramData%\Holdfast\policy.bin`. Changes require an elevated administrator.
  Trust is based on local ACLs, **not** the Apple JSON/HMAC/cloud format.
- Validation checks exact file size, UTF-16 paths, revision, timestamps,
  duplicates and a lease of at most 24 hours. Relative/UNC/device paths,
  traversal, wildcards, alternate streams, Windows system executables, and known
  networking/recovery processes are rejected. The service checks canonical
  resolved target paths. This is conservative, not exhaustive VPN detection.
- Explicit per-application IPv4/IPv6 ALE filters are replaced in a transaction
  in a **dynamic WFP session**. Service death or shutdown releases them. No
  catch-all, DNS, IP-wide or proxy settings are changed. Unchanged snapshots do
  not rebuild filters. Periodic health checks detect lost filters.
- Expiry is evaluated every second even without a file rewrite. Invalid input
  retains prior intent only until its original deadline. This prioritizes
  recovery, not tamper-proof enforcement when the service is stopped.
- `HoldfastService --recover` removes only filters owned by Holdfast's provider,
  including legacy persistent filters. It never resets the Windows firewall.
- The kernel guard is an **unbuilt, unsigned prototype**, excluded from CMake
  packaging/installation. Source now checks v2 deadlines, but requires its own
  WDK project, verification and signing before use. No driver is deployed here.

Microsoft documents [dynamic-session cleanup](https://learn.microsoft.com/en-us/windows/win32/fwp/object-management)
and [kernel-driver signing requirements](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/kernel-mode-code-signing-policy--windows-vista-and-later-).
Do not disable Secure Boot or driver-signing enforcement for this package.

The previous prototype's persistent filters could outlive a schedule snapshot
or a failed service. Blocking a networking broker/VPN could look like loss of
all internet. Bounded leases, protected targets, dynamic-session cleanup and
equal-revision reconciliation address those failure modes. The bounded ARM64
tests above verify the core IPv4 expiry/crash paths, not every network setup.

Runtime testing also found and fixed a zero-mask WFP enumeration request
(`FWP_E_NEVER_MATCH`), a control-tool reader handle preventing atomic replacement,
service reader handles missing delete-sharing, cleanup skipping service shutdown
when policy publication fails, and .NET reporting X64 on an ARM64 OS. Installers
now wait for an idle acknowledgement and release service handles on uninstall.

## Build and deploy in UTM

Create a dedicated Windows 11 ARM64 VM on Apple Silicon (starting configuration:
8 GiB memory, 4 cores, 64 GiB disk). Install UTM guest tools, Visual Studio C++
tools for the desired architecture, the Windows SDK, and CMake from official
sources. Keep Secure Boot and endpoint protection enabled. The owner must
approve Windows/build-tool license/account steps. No personal iCloud credentials
or live Mac policies are needed for the test VM.

`scripts/Prepare-BuildTools.ps1` downloads and verifies Microsoft's signed
bootstrapper without installing it. After license approval, pass
`-Install -AcceptLicense` to install ARM64/x64 compilers, SDK and CMake. The
build script discovers Visual Studio's bundled CMake without changing PATH.

In Windows PowerShell:

```powershell
.\scripts\Build.ps1 -Architecture ARM64
# Separate x64 package: .\scripts\Build.ps1 -Architecture x64
# Elevated terminal, after successful native tests:
.\scripts\Install.ps1 -PackageDirectory .\package-ARM64
& "$env:ProgramFiles\Holdfast\HoldfastCtl.exe" --status
```

The installer protects ProgramData/Program Files ownership and ACLs, refuses
reparse-point targets and incompatible legacy guards, and starts the visible
automatic-start service. New workspaces start **disabled/idle**; upgrades preserve
saved enforcement intent and do not clear existing groups or policies. It installs
no driver. The UI runs without administrator rights; installation requires elevation.
Packages are `package-ARM64` and `package-x64`; cross-builds do not claim native
test coverage. Static MSVC runtime linking avoids a separate CRT installation.

From macOS, once the guest and its agent are ready:

```sh
/bin/zsh Platform/Windows/scripts/Deploy-UTM.zsh 'Holdfast Windows ARM64 Test' ARM64
```

The harness copies only Windows sources into a fresh guest directory, builds,
runs native tests, packages and installs idle. It retains build/install logs.
It uses a process-scoped PowerShell execution-policy override for these reviewed
local scripts, not a persistent machine change. Guest-agent transport is
independent of the guest network being tested.
The host harness requires unique guest completion markers and retains explicit
logs: UTM may return success with empty console output before a guest command
has actually finished. Architecture is detected from the machine environment;
Windows PowerShell/.NET Framework reported X64 on this ARM64 guest.

## Bounded connectivity tests

Run only in the dedicated VM, from elevated PowerShell:

```powershell
.\scripts\Test-Connectivity.ps1
Start-Service HoldfastEnforcement
.\scripts\Test-Connectivity.ps1 -CrashTest
Start-Service HoldfastEnforcement
.\scripts\Test-Connectivity.ps1 -MalformedPolicyTest
# With the service running and idle (source checkout only):
.\tests\PolicyPublicationTests.ps1
```

The test refuses an active/error policy, copies Windows curl to a disposable
probe path, validates baseline connectivity, then blocks only that copy for 15
seconds. It checks that ordinary system curl remains connected, checks IPv6
when available, and verifies natural expiry, service-crash cleanup, or expiry
after a malformed policy update. An
independent elevated watchdog clears/stops/recovers at 25 seconds if the test
dies. Results are JSON in `%ProgramData%\Holdfast\test-*.json`. The test leaves
enforcement stopped. Unavailable IPv6 means **unverified**, not passed.

Emergency recovery/uninstall:

```powershell
Stop-Service HoldfastEnforcement
& "$env:ProgramFiles\Holdfast\HoldfastService.exe" --recover
.\scripts\Uninstall.ps1
```

Uninstall removes service registration/owned filters but retains files and
diagnostics for recovery. `enforcement.log` rotates at 1 MiB; logs contain counts,
revisions, stages and error codes, not destinations or executable paths.
`status.json` reports capability (`application-network-only`), phase, revision,
deadline, counts and heartbeat. A stale heartbeat is not proof of enforcement.

## Work still required before production

- Complete the desktop app, scheduling, passage policies, shared lockdowns and
  authenticated sync bridge. Windows does not read Apple's KVS session records.
- Implement and verify domain-aware enforcement without substituting hosts-file
  edits or presenting proxy-only filtering as system-wide protection.
- Test on physical ARM64 and native x64 Windows, including BFE restart,
  clock/sleep/resume, failed upgrades, disk/ACL failures, watchdog fault injection,
  VPNs and IPv6. QUIC/encrypted-DNS/domain cases require the future web filter.
- Build any kernel component with WDK; pass Driver Verifier/HVCI and obtain
  Microsoft signing. Use a signed installer and documented owner recovery.

Portable tests on macOS do not exercise Win32, SCM, WFP, PowerShell or the driver.
