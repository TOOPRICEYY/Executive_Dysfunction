# Holdfast

An iPhone Screen Time controller with native macOS enforcement and an experimental Windows application-network service, built with Apple's `FamilyControls`, `ManagedSettings`, `DeviceActivity`, Network Extension, and on-device `FoundationModels` frameworks, plus Windows Filtering Platform components.

The shared React/TypeScript interface and its native adapters are documented in
[SharedUI/README.md](SharedUI/README.md). Build `SharedUI` with `npm ci && npm run build`
before building the Apple targets or the Windows `-SharedUI` package. Core group
and passage flows are connected; advanced Apple editors remain native during
migration. Windows website filtering and cross-device sync are not yet available.

## What this prototype supports

- User-selected apps, websites, and Apple activity categories through `FamilyActivityPicker`.
- Multiple recurring weekly blocking windows.
- Daily usage thresholds for selected apps, categories, and web domains.
- A normal block-list mode and a **Fortress allow-list mode** that shields every app and website except selected exceptions. The controlling app is automatically exempt from Apple's `.all` shield policy.
- Explicit domain blocking and optional on-device AI classification of domains the user types or pastes. Domain names never leave the device.
- An anti-uninstall option using `ManagedSettingsStore.application.denyAppRemoval`.
- **Per-rule lockdown severity**: every rule independently chooses App Default, No Edit Lock, Passage Only, Delayed Unlock, or Repeated Confirmations. Delays can range from 0 to 365 days, and unlocking one rule never unlocks another. Repeat-confirmation rules create a checkpoint every 24 hours; each requires a newly generated passage and missing its configurable window cancels only that rule's request.
- Optional **passage-gated extra time per rule**. A rule can permit one-hour suspension increments with a configurable session maximum. The first hour uses that rule's passage length, the second requires twice as many words, the third four times as many, and so on. The accumulated expiry and escalation counter live in the shared app group, survive relaunch, and reset only after the allowance session expires. A temporary allowance uses one Device Activity monitor slot so the extension can restore scheduled and usage-limit shields at expiry.
- Locked rules can still be opened and drafted. At Save, the app compares the draft with the persisted rule and accepts it without an unlock only when at least one protection is stricter and no dimension is weaker: broader blocked scope/time, a lower usage limit, enabling the rule, fewer Fortress exceptions, or stronger lockdown. Neutral, mixed, and incomparable changes require that rule's normal unlock flow.
- Passage entry includes an on-demand word-level diff after tapping **Check Passage**: matching words are green, incorrect or extra words are red, and omitted expected words are faded red with strikethrough. The result is a snapshot and does not update while typing. It follows the same case-insensitive and whitespace-collapsed rules as final confirmation.
- An **app-wide settings lockdown** remains available for global controls such as anti-uninstall and as the inherited configuration for rules using App Default. The final passage/checkpoint opens a configurable editing window before lockdown re-arms. While any lockdown is enabled, Managed Settings requires automatic date and time so countdowns cannot be bypassed by manually moving the clock. Adding or tightening protections is always allowed. This is deliberate friction enforced in-app, not a cryptographic guarantee.
- A Device Activity monitor extension and custom shield configuration/action extensions.
- A native **approval-free macOS web-enforcement companion**. It edits names, enabled state, schedules, usage limits, explicit domains, website-category choices, enforcement mode, desktop application identities, and per-rule lockdown severity through iCloud key-value storage. Its single Network Extension system extension filters flows on socket hostname, HTTP Host, and TLS SNI, refuses Encrypted Client Hello and unnamed QUIC so a readable name is always required, and blocks common encrypted-DNS endpoints and dedicated DoT/DoQ ports. It registers no packet provider: hosting one crashed the extension, and macOS drops all traffic while a content filter is not answering, so that crash appeared as a machine-wide outage. It retains its last accepted policy in its private Keychain namespace and rejects rollback. The app shows the revision the filter reports it is actually enforcing and warns when that is behind what was published, because a policy the filter never accepted is otherwise invisible: the rules simply stop having any effect. The manually approved Endpoint Security target is not included in the generated Mac project.
- An **experimental Windows application-network service** under `Platform/Windows`, built for ARM64 and x64 and tested in an ARM64 UTM VM. A LocalSystem service accepts bounded, administrator-published policies and atomically maintains dynamic IPv4/IPv6 WFP application filters. The Windows desktop UI, website filter, Apple sync and production signing are still missing. The separate kernel process guard remains unbuilt and is not deployed.

- **Tamper resistance on macOS (2026-09-29).** Lock and pause state lives in the data-protection Keychain instead of editable plists; published pauses are capped at the group's session maximum by both the app and the filter; the filter checks the wall clock against the continuous clock and enforces the union of both times when they disagree; locked groups weakened from another device (or by an Activity Group edit) keep their stricter form for their own unlock delay; switching the filter off in System Settings is journaled and re-armed after 15 minutes; Retreats start and end in the filter on their planned times; and a tamper journal is mirrored to iCloud. The passage-gated **Disable Blocking** remains the instant emergency fallback and is now recorded in bypass history. See `Docs/SecurityHardening-2026-09-29.md`.
- **Presets and reflection.** "Start from preset" adds Work hours, Evenings off, Deep-work retreat or Hard block, with ready-made Activity Groups (including VPN and proxy apps). Temporary access asks a short reflection question whose answer is saved with the bypass.

## Hard platform limits

1. **Restrictions do not survive deletion of the controlling app as an independent configuration.** The consumer-safe design is to prevent deletion while protection is enabled. If Screen Time authorization is revoked, or if the app is removed after anti-uninstall is disabled, the app can no longer guarantee enforcement.
2. `denyAppRemoval` prevents removal of all applications, not only this application.
3. Outside the EU-only `approvedWithDataAccess` mode introduced in iOS 26.4, Apple exposes selected apps, categories, and visited sites as opaque tokens. This app therefore classifies only domains the user explicitly enters. It cannot silently inspect or export browsing history.
4. Fortress mode can make individual application and web-domain tokens exceptions to an `.all` policy. Apple's API does not support making an opaque *category token* an exception to `.all`, so category selections are used by block-list rules, not allow-list exceptions.
5. Device Activity thresholds are callbacks from iOS, not a real-time foreground-app feed. Enforcement accuracy is ultimately controlled by the operating system.
6. Screen Time APIs require a physical-device test for reliable validation. Simulator testing is useful for UI and pure logic only.
7. iOS caps concurrent Device Activity schedules at roughly 20 per app. This project consolidates every time block to one daily monitor regardless of selected weekdays, and combines every rule's usage threshold into one shared daily monitor. The Rules screen shows the current monitor budget, and capacity errors identify unscheduled time blocks.
8. `ManagedSettings` and `DeviceActivity` are unavailable on macOS, so the Mac does not use the consumer Screen Time API. The Mac edition requires the standard Network Extensions and System Extension capabilities and matching profiles, but not the manually approved Endpoint Security entitlement. Opaque iPhone `FamilyActivitySelection` tokens never enter iCloud and are preserved when a Mac edit is applied.
9. Desktop enforcement is resistant to a standard-user account, not to the device owner with administrator/recovery access. Both desktop designs retain an explicit, visible administrator removal path. They do not hide services or attempt to survive an authorized OS recovery or reinstallation.
10. macOS enforcement matches on the connection, not on DNS, so changing the system or browser DNS server does not bypass it. Inspection covers Network Extension hostname/URL metadata, HTTP Host, and TLS ClientHello SNI; fragmented ClientHellos remain held until classifiable, while Encrypted Client Hello, TLS without SNI, and unnamed QUIC are refused so a TLS retry cannot escape without a readable name. Dedicated DoT/DoQ ports and common public DoH hostnames are blocked while a web rule is active. Block-list rules release unidentified non-TLS traffic, because an outage is a worse failure than a missed flow; Fortress mode fails closed for all unidentified traffic, while always permitting loopback, link-local and private-range destinations. VPNs and full tunnels, non-TLS protocols carrying no readable name, and previously established connections remain fundamental limits without MDM or a forced secure gateway.
11. Windows application-network enforcement has bounded IPv4 runtime coverage in an ARM64 VM; executable-launch enforcement remains an unbuilt prototype. Windows domain/category filtering is not implemented and needs a separate design covering DoH, QUIC, VPNs, IPv6, and sleep/resume.

## Configure and run

1. The project uses `com.GabrielPrice.ExecutiveDysfunction` and the `group.com.GabrielPrice.ExecutiveDysfunction` App Group. Register these explicit identifiers in the Apple Developer account. Keep the iOS and macOS app targets on the same cross-platform bundle identifier.
2. In Apple Developer Certificates, Identifiers & Profiles, enable the App Group for the main app and every extension that uses it.
3. Add the Family Controls capability to the iOS app and all three extensions. Development signing can use the development entitlement; App Store distribution requires Apple approval for **Family Controls (Distribution)** for every affected bundle identifier.
4. Enable iCloud **Key-value storage** for the shared iOS/macOS app identifier. Both app targets use `$(TeamIdentifierPrefix)com.GabrielPrice.ExecutiveDysfunction` for `com.apple.developer.ubiquity-kvstore-identifier`.
5. Generate the Xcode project:

   ```sh
   xcodegen generate
   ```

### One-click local macOS deployment

Double-click [Deploy Holdfast.command](<Deploy Holdfast.command>) in Finder, or
run `./Deploy\ Holdfast.command` from Terminal. It regenerates the Xcode
project, builds a signed Debug app, installs it at `/Applications/Holdfast.app`,
and verifies its signature. It does not launch Holdfast or change web
enforcement state.

6. For macOS enforcement, enable the standard **Network Extensions** capability for the containing Mac app ID and `com.GabrielPrice.ExecutiveDysfunction.WebFilter`, then regenerate their profiles. Debug uses the development-profile value `content-filter-provider`; Release keeps `content-filter-provider-systemextension` for Developer ID distribution. Sign both targets with the same team and notarize Developer ID releases. No Endpoint Security capability request is used by this edition. An unsigned build can compile the code but cannot activate the filter.

### Compatibility identifiers retained after the Holdfast rename

Holdfast intentionally retains the original Apple bundle IDs, App Group, Keychain access groups, Network Extension identifier, launch-daemon label, and `/Library/Application Support/ExecutiveDysfunction` support directory. These identifiers are installation and security boundaries rather than displayed branding. Changing them in place would orphan existing preferences, credentials, the installed system extension, and recovery state; new installations and upgrades therefore continue to use them while presenting Holdfast everywhere users see the product.
7. Open `Holdfast.xcodeproj` and run the `Holdfast` scheme only on a physical iPhone. Run `HoldfastMac` on a Mac signed into the same iCloud account; its installed name is **Holdfast Preferences**. The iOS target explicitly opts out of “Designed for iPhone/iPad on Mac” because Screen Time authorization cannot communicate with its iOS helper there. The signing team is stored in `project.yml`, so `xcodegen generate` preserves it.
8. Grant Screen Time access on the iPhone before creating rules. On Mac, click **Install Web Enforcement**, approve the system extension/content filter locally in System Settings, and restart if macOS requests it. **Recovery / Remove** is the deliberate administrator recovery path.

If bundle IDs or the Apple team change, update the constants in `Sources/DesktopShared/DesktopEnforcementPolicy.swift` as well as `project.yml` and the entitlement files. The shared Keychain access-group prefix is intentionally explicit; the current signing team remains `7GXNZJMGPD`.

## Windows build and deployment

The Windows development package includes a portable policy core, bounded application-network service, administrator control tool, and UTM build/recovery test scripts. ARM64 and x64 packages compile separately. ARM64 VM tests pass for native policy validation, atomic updates, selected-process IPv4 blocking, timed expiry, crash recovery, malformed updates, and uninstall/reinstall. Native x64 runtime and IPv6 remain unverified. No domain filtering, desktop UI, Apple sync or signed kernel driver is included yet. See `Platform/Windows/README.md` for exact capabilities, commands and outstanding production work.

Do not treat the Windows development service as a production blocker. Additional network/fault testing, feature work and signing are required; any future kernel driver also requires WDK, Driver Verifier and HVCI verification.

The project targets iOS 17.4 and macOS 14. It conditionally enables Apple Foundation Models classification on iOS 26 or newer. A heuristic on-device fallback is used when Apple Intelligence is unavailable.
