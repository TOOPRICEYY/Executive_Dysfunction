# SwiftUI visual alignment — 2026-10-02

## Reference and scope

The existing SwiftUI Mac dashboard (`Sources/MacApp/MacContentView.swift` and its shared presentation components) is the visual authority. This revision adapts the existing React interface rather than introducing another platform-specific UI. It restores the sidebar, hierarchy, compact rows, two-column dashboard, hard-edged controls, theme palette, schedule section and bottom bypass section. Native policy/enforcement behavior is not changed.

## Captures and normalization

- Reference: `qa/swiftui-parity/native-dashboard.png`.
- Implementation: `qa/swiftui-parity/shared-dashboard.jpg`.
- Additional checks: `qa/swiftui-parity/shared-light.jpg`, `phone-dashboard.jpg`, `phone-editor.jpg`.
- Original native capture: 2640 × 1680 pixels at 2× density. Removed the 104-pixel macOS titlebar and downsampled the remaining content to 1320 × 788. Browser viewport: 1320 × 788 CSS pixels at 1× screenshot density.
- Phone viewport: 390 × 844 CSS pixels. Both page and open editor measured 390-pixel scroll width: no horizontal overflow. Both navigation regions have equal content/client widths after the clipping fix.
- Native reference runs with `--ui-preview`; browser uses explicit `?preview=1`. Neither writes real policies, cloud data or enforcement settings. The `reference=swiftui` fixture reproduces the reference's three groups for comparison.
- Source and final implementation were inspected together at equal content dimensions. The native window frame is intentionally excluded from comparison.

## Required fidelity surfaces

- Typography: system sans-serif body, compact weighted rows, uppercase large page heading, monospaced enforcement title and utility labels. Browser/native font rasterization and icon glyphs differ slightly.
- Spacing/layout: 252-pixel sidebar, 28-pixel main inset, equal dashboard columns with a 20-pixel gutter, compact 88-pixel group rows, persistent bottom preferences. Phone widths stack the columns and use horizontal navigation.
- Color: native warm light and near-black dark palette, all seven highlight choices, full-accent selected navigation. Apple appearance changes use the original native preference keys; iOS icon synchronization is retained.
- Geometry: square bordered panels, buttons and fields; no replacement decorative artwork. Phosphor outline icons replace platform-only SF Symbols and include their license in the bundle.
- Content structure: groups and active retreats above schedules; bypass history remains at the bottom. Temporary suspension remains visible in group rows and editors.

## Iterations

1. Replaced large shared card-grid navigation with the original dashboard structure.
2. Corrected status-band specificity so panel backgrounds cannot erase enforcement colors.
3. Removed redundant row copy and zero-app labels; preserved host ordering within status ranks.
4. Matched panel typography, row density and status-band alignment against the normalized source.
5. Fixed clipped phone navigation by reducing narrow-screen spacing; remeasured after reload.

## Functional verification

- Shared TypeScript/bundle build succeeds; 13 unit tests pass, including authoritative status headlines and native appearance validation.
- Signed macOS build succeeds; iOS simulator build succeeds.
- Browser: sample group rename/save updates the dashboard, bypass detail opens and time range changes, light/dark and blue/violet accent changes apply, editor opens/closes at phone width, suspended status remains visible. No browser console errors recorded.
- UI testing used computer-use browser controls, not a separate Playwright CLI run. The browser test selectors were updated but that standalone suite was not executed this turn.

## Intentional limits

This is visual alignment, not a claim of pixel-identical native control rendering or complete feature parity. Preview headings explicitly identify sample data. Unsupported commands remain disabled. Platform-only advanced controls and presets stay in the existing native panels. The shared schedule is explicitly labeled as saved weekly windows, not an exact live-enforcement timeline. Live filtering, cloud synchronization, Windows WebView rendering and installed-app runtime behavior were not exercised by this design-only change. No installation was performed.

final result: passed
