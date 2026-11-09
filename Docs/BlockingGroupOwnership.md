# Blocking Groups own their configuration

Build 83 removes Activity Groups from Mac and iOS navigation and editing.
Each Blocking Group owns its domains, category selection, application targets,
allowance schedule, usage budget, and modification policy. Retreats combine
Blocking Groups and preserve their versioned configurations.

The schema-3 migration copies legacy linked contents into `targets` and folds
their effective modification protections into the Blocking Group. It preserves
the compiled domain sets, windows, and protections. Shared contents become
independent value copies; future edits no longer propagate to sibling groups.
Unused legacy collections are imported once as disabled Blocking Groups.
Missing legacy references are kept unresolved until their data arrives.

Legacy Activity Group records/IDs remain compatibility data, not user-managed
objects. They support older retreat configurations and per-device Screen Time
token imports. Opaque Apple tokens are never uploaded to iCloud. Locally
available selections are captured under a Blocking Group-specific storage key;
rejected edits restore the previous local selection. Update all devices before
editing with the new model: older apps do not understand owned targets.

The change also corrects false unlock warnings caused by re-serializing an
unchanged selection. Admission, rejection messages, and pending-sync IDs now
share the same comparison. Real weakening changes still require unlocking.

Verification: shared migration tests cover policy equivalence, independent
copies, idempotence, missing references, unused imports, and no resurrection
after deletion. iOS UI tests cover direct domain entry and navigation without
an Activity Groups tab. Live Screen Time enforcement requires a physical device.
