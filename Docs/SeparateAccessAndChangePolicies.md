# Separate access and change policies — build 90

## Why enabling backoff was rejected

The old mode replaced contiguous-session doubling (1×, 2×, 4×, 8×) with a
cross-session linear sequence (1×, 2×, 3×, 4×). A third ongoing-session request
could become cheaper. The restriction gate therefore treated a mode switch as
incomparable and demanded an unlock.

Backoff now adds friction instead: required words are the greater of the linear
history requirement and the existing session requirement. This also protects a
session already underway when backoff is enabled and one spanning a periodic
reset. Turning it on or lengthening the reset period is now stricter; removing
it or shortening the reset period still needs authorization.

## Independent settings

Blocking Group editors on macOS and iOS now have separate **Temporary access
policy** and **Change protection** sections. An optional persisted
`temporaryAccessPassageWordCount` decouples access from edit passages; old files
retain their existing length, and the editor freezes that length before changes.
Temporary access controls passage length, duration cap, and backoff. Change
protection controls permanent edits, disabling/deleting the group, waits, and
edit windows. Inherited restrictions remain enforced.

An advisory warning appears when permanent editing has no confirmation or an
equal/shorter immediate passage than temporary access. With backoff, it also
warns when future escalation could exceed the edit passage. Actual wait-based
protections are not misleadingly classified as easier merely from word count.
Warnings never prevent saving.

Equivalent local metadata/serialization changes no longer demand an iOS unlock.
A separate portable-target comparison prevents this from authorizing removal of
Mac/Windows app targets that the iOS rule projection does not contain. Mixed
stronger/weaker changes continue to require the saved authorization policy.

Custom access passages and backoff must be completed in the native Mac app;
published policies turn off legacy browser grants when the old helper would use
the wrong passage. No root helper was updated or restarted by this task.

## Verification

- 442 Mac hostless tests passed, including new strengthening, no-op, independent
  passage, active-session migration, reset boundary, warning, and legacy-helper
  compatibility regressions.
- 169 iOS unit tests passed.
- Targeted iOS UI test passed for separate sections, the backoff toggle, and the
  policy warning. Simulator screenshots were inspected.
- `git diff --check` passed.
- Build 90 installed at `/Applications/Holdfast.app`; deep/strict signature and
  bundle version verified. Reopen to use the update. iOS was built/tested in the
  simulator, not installed on a physical phone.

Live enforcement is not exercised by these tests. Physical iPhone installation
and actual native exception grants remain manual checks. No live filter toggle,
safety reset, or reactivation was performed.
