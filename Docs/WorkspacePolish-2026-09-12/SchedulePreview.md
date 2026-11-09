# Top-of-editor blocking schedule — builds 86–87

Build 87 refinement: the default view is now one compact row of seven labeled mini-bars. A Details/Less disclosure expands to the full day-by-day timeline, time axis, legend, and usage-limit explanation. Expansion is local view state only and does not edit the schedule. The UI regression checks compact height, expansion/collapse, and the unsaved schedule round-trip.

Build 87 verification: 423 Mac tests and targeted iOS 4 unit + 2 UI tests passed. Compact screenshots are `schedule-preview-condensed-iphone.png` and `schedule-preview-condensed-mac.png`. Installed at `/Applications/Holdfast.app`, signature/version verified, with no relaunch or live enforcement change.

Both native Blocking Group editors now show a compact weekly summary immediately below the heading and before editable fields or unlock controls. Seven horizontal daily bars show local 00–24 time, accent-colored blocking, and muted allowance gaps. The preview follows unsaved schedule changes and explicitly labels disabled groups; usage-budget restrictions are noted separately. This is a schedule preview, not live enforcement status.

The shared presentation model handles exact minutes, overlapping spans, overnight/week-boundary windows, equal-bound full-day windows, and both allowance/block painting modes. Mac previews use the editor's existing draft painter cells; iOS uses the draft time-window plan. Enforcement behavior and authorization policies are unchanged.

Implementation: `BlockingSchedulePreview.swift`, `BlockingSchedulePreviewView.swift`, `MacBlockingGroupEditor.swift`, and `IOSArchitectureEditors.swift`. The SwiftUI component belongs to application/test targets only, not the network extension.

Tests cover range projection, empty/full-day cases, invalid windows, light/dark compact rendering, top-of-editor visibility, and immediate refresh after editing allowances. The Mac regression suite passed 423 tests. Real-device Screen Time enforcement is outside this read-only UI change.

Visual evidence: `schedule-preview-iphone.png`, `schedule-preview-mac-light.png`, and `schedule-preview-mac-dark.png`.

Final targeted iOS verification passed all four projection unit tests and both UI tests (visibility and unsaved schedule round-trip). Build 86 was installed in `/Applications/Holdfast.app` and its code signature/version verified. The app was not relaunched and live filtering was untouched.
