# Temporary allowance passage backoff

Build 88 adds an optional per-Blocking-Group **Passage backoff** setting beneath Allow temporary access on iOS and macOS.

Build 90 separates **Temporary access policy** from **Change protection**, with
independent passage lengths. Existing lengths are preserved when opening the
editor. Equivalent and strictly stronger changes, including enabling backoff,
do not need an unlock; weaker or mixed changes still do. A non-blocking warning
appears when permanent changes are equally easy or easier than temporary access,
including when backoff could eventually overtake the edit passage.

- When enabled, accepted allowance requests add cross-session friction of base × 1, × 2, × 3, × 4, and so on. Existing contiguous-session doubling is a minimum: enabling backoff never shortens a passage. Opening or failing/cancelling a passage does not count.
- Reset interval: 1–365 days, initially 7. The fixed interval begins with the first successful grant, not the most recent grant. A day means 24 elapsed hours. The first grant after expiry begins a new interval.
- Counts persist locally across app restarts, allowance expiry, and early cancellation. Each group/device has its own counter; allowance permission is not shared between devices.
- Disabling the option retains the existing session-only exponential behavior. Existing saved policies decode with this new option off. Removing backoff and shortening its reset interval need the saved change policy; enabling it or increasing the interval is stricter.
- Passage generation is bounded at 38,400 words, the existing worst-case session-policy bound, to prevent overflow or unbounded allocation.
- A stale passage sheet cannot grant a backoff allowance after the required length has changed. Current policy and duration limits are checked again on confirmation.
- Explicit allowance/backoff settings now survive compilation for groups whose edit-lock policy is None or App default. A locked inherited policy that denies temporary access still vetoes it.

## Browser access and compatibility

Build 90 also routes allowances with a custom access passage different from the
edit passage through the native app, so an older browser helper cannot grant
them using the wrong length. Both native apps preserve the old shared length
when opening an existing group, then save access and edit lengths independently.

Backoff-enabled groups must request allowances in the native app. The browser helper does not share the app's device-local counter and cannot issue a cheaper, independent passage. Newly published Mac policies turn off the legacy browser opt-in bit as well as marking native-only access, so even older helpers/providers cannot use that path after accepting the updated policy. Native temporary allowances remain available.

The updated helper explains this on the block page. Existing helper installations need `Scripts/update-block-page-helper.sh` to pick up the new wording; an updated provider is needed for browser-origin allowance status reporting. The app bundle contains both updates, but replacing the application alone does not restart these running components. Live provider/helper activation is a separate manual verification step.

## Suspension status

The top of the group editor and its dashboard row show **Temporarily allowed until [time]**. The label disappears at expiry. The schedule preview remains the saved schedule, not a claim that it is currently enforcing. iOS dashboard counts exclude temporarily allowed rules and also surface retreat-only allowances. Mac status merges local allowances with fresh provider-reported browser allowances; a stale provider heartbeat is not used as current UI evidence.

## Verification and boundaries

Automated coverage includes linear growth, exact reset boundaries, restart persistence, rule isolation, clock rollback, caps, legacy decoding, cloud/native bridging, restrictive inheritance, change-policy weakening, expiration/cancellation retention, rejected grant accounting, browser challenge rejection, legacy browser-opt-in compatibility, and native status rendering. macOS tests are hostless; simulator tests do not establish real Screen Time enforcement.

No live blocking preferences were changed during testing. Physical iPhone allowance grants, active Mac extension/helper upgrades, and the whole real-browser/native allowance cycle remain manual checks.

UI regression notes: the new toggle was initially at the edge of the visible scroll area, so the test now scrolls it fully into view and waits for its accessibility value. A simulator Busy launch failure was resolved by restarting only the simulator. The final backoff-toggle and dashboard-tab rerun passed, with screenshots inspected. The existing 11 UI tests also passed in the broader run.

Final verification: **431 macOS tests and 165 iOS unit tests passed**. Build 88 installed at `/Applications/Holdfast.app`; deep/strict code signature and version verified. No app relaunch, live filter toggle, root helper restart, commit, or external deployment was performed. Screenshots are in `Docs/AllowanceBackoff-2026-09-20/`.
