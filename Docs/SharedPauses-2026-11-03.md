# Shared temporary pauses

Previously the temporary-access iCloud replica carried spending records, but
neither app applied the remote pause to its enforcement ledger. A successful
rule sync therefore did not imply a pause had transferred.

Both apps now apply the most recently updated contribution for each rule,
including cancellation records. The original expiry is preserved. Imports
require an enabled group that permits temporary access, within its current
maximum, and outside a timed lockdown. Imported minutes are not charged twice.
iOS rebuilds its expiry monitor and retains usage-shield restoration; macOS
republishes its enforcement policy. Imports never republish a grant into iCloud.

Delivery follows iCloud key-value notifications and app activation/refresh.
It is not instantaneous or guaranteed while the iPhone app is suspended. Both
devices need this update. Existing local grants become shared when published;
this does not invent authorizations for pauses absent from the cloud replica.

Manual verification: with both updated apps on the same iCloud account, grant
10 minutes on Mac, open iPhone and confirm the same expiry; cancel on iPhone
and confirm Mac resumes. Repeat in the opposite direction, extend a received
pause, and verify the session maximum is charged once. Verify offline reconnect
does not resurrect an older grant after cancellation. Physical-device iCloud
delivery remains a separate check from unit tests and simulator compilation.
