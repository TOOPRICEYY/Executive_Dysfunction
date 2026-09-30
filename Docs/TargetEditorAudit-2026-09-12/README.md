# Apps & websites editor review — 12 September 2026

Scope: the native Blocking Group target editor, not a whole-product redesign. Existing hard-edge surfaces and app themes are retained. No live enforcement was toggled.

## Flow and findings

1. **Open a Blocking Group — healthy.** Dashboard opens the editor directly; there is no Activity Group selection step. A fresh iPhone simulator capture was inspected before changes.
2. **Choose apps — previously overemphasized.** The full-width all-caps picker competed with the section title and supplied only an aggregate selection count. Now a compact native picker row explains which selections stay on this device. Mac now uses an application chooser instead of requiring bundle identifiers. Installed-app names/icons resolve once per row; unresolved apps retain their identifiers.
3. **Add websites — previously error-prone.** A raw multiline editor offered no individual removal action or entry-level feedback. Now URLs/domains become removable rows; bulk entry is supported, duplicates are reported, and invalid entries remain for correction. Existing classification metadata and exclusions are preserved. Newly added domains are included under Other.
4. **Adjust advanced filters — previously too prominent.** Twelve category switches and Mac/Windows identifiers were exposed in the routine flow. These now live in a collapsed disclosure. Excluded domains carry a visible explanation. Hiding these controls does not alter any policy.

## Accepted evidence

- [iPhone before](ios-before.png): freshly captured original editor with two domains and keyboard open.
- [iPhone after](ios-after.png): same simulator and two domains after explicit Add, keyboard dismissed by design.
- [Mac light](mac-light.png) and [Mac dark](mac-dark.png): hostless rendering of the real SwiftUI editor at 680 pt width. These confirm the routine two-domain layout fits within 650 pt height. Offscreen snapshots show the unresolved-app fallback, not the eventual installed-app icon.

The iPhone images differ in keyboard state because the revised Add action finishes entry. They demonstrate hierarchy and the edited flow, not a pixel-equivalent comparison. No content clipping was observed in the accepted after states.

## Verification and limits

- 414 hostless Mac tests passed, including compact light/dark layout checks.
- 154 iOS unit tests passed.
- iOS simulator UI coverage exercises URL add, individual removal, duplicate feedback, invalid-entry retention, collapsed advanced filters, and cancellation. Repeated after the final hard-edge button polish.
- Real Screen Time selection requires device authorization and is not available in the simulator. The native Mac app picker still needs a manual interaction check. No accessibility compliance claim is made; controls have descriptive accessibility names and iOS removal/add hit areas are at least 44 pt.
- The editor redesign does not bypass or change save-time unlock policies. Native iOS build is not installed on the physical phone by these checks.
