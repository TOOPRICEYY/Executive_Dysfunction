# Design QA

## Comparison target

- Option 1 source visual truth: `/Users/gp/.codex/generated_images/019f9efa-c043-7be1-af52-bc50d4591a7d/exec-6308bdea-7d5f-452b-94cd-297d409e7fc9.png`
- Option 2 source visual truth: `/Users/gp/.codex/generated_images/019f9efa-c043-7be1-af52-bc50d4591a7d/exec-cc28d3c3-86a4-43cf-9663-4a2f27ff9ef7.png`
- SwiftUI retreat implementation: `Diagnostics/ui/retreat-composer-light.jpg`
- SwiftUI allowance painter implementation: `Diagnostics/ui/allowance-painter-light.jpg`
- Additional implementation states: `Diagnostics/ui/retreat-review-dark.jpg`, `Diagnostics/ui/settings-highlight-blue.jpg`, `Diagnostics/ui/settings-highlight-blue-dark.jpg`, `Diagnostics/ui/dashboard-highlight-blue.jpg`, `Diagnostics/ui/allowance-painter-compact.png`, `Diagnostics/ui/allowance-painter-compact-saved.png`, `Diagnostics/ui/allowance-painter-regular.png`, `Diagnostics/ui/retreat-lock-padded.png`, `Diagnostics/ui/allowance-painter-drag.png`, `Diagnostics/ui/allowance-painter-hour-labels-30-minute-selection.png`, and `Diagnostics/ui/allowance-painter-hour-labels-30-minute-evening.png`

## Viewport and normalization

- Source images: 1487 x 1058 pixels.
- Native app captures: 1305 x 768 pixels from the isolated `--ui-preview` build.
- Responsive allowance captures: 899 x 768 pixels in compact mode and 1299 x 768 pixels in regular three-column mode.
- Final interaction captures: 898 x 768 pixels for Retreat Lock padding and 901 x 768 pixels for the allowance gesture state.
- Final 30-minute captures: 901 x 768 pixels for both the top-of-day selection state and scrolled evening state.
- Native macOS viewport: 1305 x 768 points as reported by the captured app window; browser CSS size and `deviceScaleFactor` are not applicable.
- Full-view comparisons normalize each source and implementation panel into a 1305 x 728 pixel content area without stretching, then place the two panels side by side.
- Focused comparisons use equal-size paired crops: 1180 x 510 for the retreat header/composer and 1180 x 700 for the painter/grid/controls.

## State

- Option 1: light mode, Retreats selected, populated retreat draft, three selected Activity Groups, lock and date controls visible.
- Option 2: light mode, Allowance Schedules selected, Social Feeds selected, two-hour paint grid visible, blue allowance cells and editing controls visible.
- Additional states: dark retreat review; Settings in light and dark mode; Electric Blue and Theme Default highlight selections.

## Full-view comparison evidence

- `Diagnostics/ui/qa/option1-comparison.png`
- `Diagnostics/ui/qa/option2-comparison.png`
- `Diagnostics/ui/qa/allowance-responsive-comparison.png`
- `Diagnostics/ui/qa/retreat-lock-padding-comparison.png`
- `Diagnostics/ui/qa/allowance-gesture-comparison.png`
- `Diagnostics/ui/qa/allowance-30-minute-comparison.png`
- `Diagnostics/ui/qa/allowance-30-minute-evening-comparison.png`

The final implementation retains the selected source architecture: a fixed left rail, severe rectangular divisions, oversized terminal-style headings, wide whitespace, Activity Group rows, and a three-part retreat composition. The painter retains the Option 2 group rail, central weekly time grid, right-side paint controls, and blue allowed-time blocks at regular widths. Below 1040 points of workspace width, the two inspector rails become two compact toolbars above the grid; this preserves every core action and gives the seven-day schedule the full content width instead of crushing the center region. The native app is intentionally vertically compressed relative to the taller source canvases so persistent actions remain visible.

## Focused comparison evidence

- `Diagnostics/ui/qa/option1-focus-comparison.png`
- `Diagnostics/ui/qa/option2-focus-comparison.png`

Focused comparisons were required because the full-view contact sheets make the terminal typography, field borders, row rhythm, painter cell borders, and side controls too small to assess precisely.

## Required fidelity surfaces

- Fonts and typography: passed. All new SwiftUI surfaces use the system monospaced family with black display weights, tight tracking, uppercase labels, and a stronger final display scale. This intentionally follows the requested terminal-script refinement rather than copying the condensed display face literally.
- Spacing and layout rhythm: passed. Fixed 252-point navigation, hard one-pixel rules, large section gaps, 42-point content margins, and square controls are consistent. Retreat Lock has a uniform 24-point content inset on every edge. The allowance editor changes from three columns to compact stacked toolbars when its own workspace drops below 1040 points. Its time grid now uses two visible 24-point half-hour rows per labeled hour, retaining clear targets without duplicating time labels.
- Colors and visual tokens: passed. Warm off-white/black surfaces, signal yellow in light mode, phosphor green in dark mode, and the source's electric blue are preserved. Settings can replace every highlight with one persisted token, including navigation, primary actions, schedule cells, focus rings, and status emphasis.
- Image quality and asset fidelity: passed. The selected screens do not depend on photographic or illustrative raster assets. Native SF Symbols are used for standard navigation icons; no placeholder emoji, CSS art, handcrafted SVG, or screenshot-as-UI substitution was introduced.
- Copy and content: passed for the requested UI phase. `Website Group` is not used; the interface consistently says `Activity Group`. Retreat-only draft/review language is confined to Retreats. Development-only copy was removed from the review screen.

## Primary interactions tested

- Navigate Baseline, Activity Groups, Allowance Schedules, Retreats, History, and Settings.
- Switch light and dark modes.
- Select Theme Default and Electric Blue highlights and observe immediate propagation.
- Confirm the custom highlight reaches the sidebar selection, primary buttons, Activity Group bars, painter cells, save button, and dark-mode states.
- Select an Activity Group, apply the allowance quick action, and save the painted schedule in the isolated preview.
- Narrow and zoom the same allowance window; verify automatic compact/regular transitions, all seven day columns, persistent Save access, and intentional grid scrolling. In compact mode, switch to News, apply Allow Evenings, save, and confirm the persistent action changes to `SCHEDULE SAVED`.
- Drag across five schedule cells and confirm one continuous painted run. Right-click the middle painted cell and confirm only that cell is removed. Confirm no paint/unpaint mode controls remain and the interaction instructions appear in the helper below the grid.
- Paint the unlabeled 12:30 AM row across five weekdays and remove its middle cell with right-click, confirming independent half-hour targeting beneath hourly labels. Scroll through the complete 24-hour grid and verify the 6:00–10:00 PM quick action occupies eight half-hour rows with the helper still present at the bottom.
- Enter Retreat Review and return to editing.
- Confirm preview mode performs no enforcement or iCloud writes.

Native app QA has no browser console. Accessibility state was inspected after each interaction and produced no application error dialog.

## Findings

- No actionable P0, P1, or P2 visual findings remain.
- P3: the macOS title-bar toolbar and native date/menu controls retain a small amount of platform softness outside the brutal content canvas. This preserves standard Mac behavior and does not weaken the primary visual system.
- Expected functional scope: `START RETREAT` remains disabled and clearly labeled as the next activation step. This UI-first change does not add retreat persistence or enforcement semantics.

## Comparison history

1. Initial painter capture at the former 1080-point minimum clipped persistent columns. Fixed by increasing the native minimum width to 1240 points and recapturing at 1305 x 768. Post-fix evidence: `Diagnostics/ui/qa/option2-comparison.png`.
2. Initial display hierarchy was materially smaller than the selected source. Increased dashboard, Activity Group, Retreat, History, and painter display sizes, then recaptured. Post-fix evidence: both focused comparison images.
3. The initial review screen exposed implementation-phase wording. Replaced it with product-facing copy and made the not-yet-wired activation action explicitly disabled. Post-fix evidence: `Diagnostics/ui/retreat-review-dark.jpg`.
4. The initial palette had separate yellow/green and blue highlight tokens. Unified them behind the new Settings value and verified Electric Blue across the dashboard and painter. Post-fix evidence: `Diagnostics/ui/settings-highlight-blue.jpg` and `Diagnostics/ui/dashboard-highlight-blue.jpg`.
5. The three-column allowance editor compressed its center grid when the workspace became narrow, hiding day columns behind the controls. Added a width-driven compact mode with Activity Group and paint-action toolbars above the independently scrolling grid. Post-fix evidence: `Diagnostics/ui/qa/allowance-responsive-comparison.png`; compact and regular transitions were exercised in the same isolated native app session.
6. Retreat Lock content touched the panel's left edge because the section applied only vertical padding. Replaced it with a uniform 24-point inset and recaptured the same light Retreat state. Post-fix evidence: `Diagnostics/ui/qa/retreat-lock-padding-comparison.png`.
7. The allowance editor exposed paint/unpaint mode controls and individual cells did not support continuous pointer painting. Replaced the cell buttons with a native drag-tracking layer, made primary drag paint and secondary click/drag remove, and moved the only interaction instructions below the grid. Live QA then exposed AppKit's lower-left event origin mapping top-of-grid clicks into evening rows; the mapping was inverted explicitly and regression-tested. Post-fix evidence: `Diagnostics/ui/qa/allowance-gesture-comparison.png`.
8. The original painter stored two-hour cells, preventing half-hour allowance boundaries. Changed the codec and pointer geometry to 48 half-hour cells per day, retained visible half-hour grid lines, and labeled only whole hours to avoid visual noise. Verified a 12:30 AM drag/removal state plus the eight-cell 6:00–10:00 PM preset. Post-fix evidence: `Diagnostics/ui/qa/allowance-30-minute-comparison.png` and `Diagnostics/ui/qa/allowance-30-minute-evening-comparison.png`.

## Implementation checklist

- [x] Option 1 primary dashboard and sidebar.
- [x] Option 1 retreat create/edit and review UI.
- [x] Option 2 painted weekly allowance editor.
- [x] Brutal hard-edge light and dark modes.
- [x] Persisted Settings highlight selector controlling all highlight states.
- [x] Responsive compact allowance editor with persistent core actions.
- [x] Drag-to-paint and right-click/right-drag removal without mode controls.
- [x] Half-hour selection resolution with whole-hour labels and visible half-hour boundaries.
- [x] Uniform Retreat Lock panel padding.
- [x] Isolated preview safeguards for enforcement and policy writes.
- [x] Native Mac build and desktop regression suite.

final result: passed
