# Bypass history and intention

The Status/Dashboard panel counts successful temporary-access grants per Blocking Group. Extending an existing pause counts as another grant. It does not count blocked visits, edit unlocks, failed requests, or measured browsing time.

Each request offers **Conscious intervention** and **e-dulgance**. Neither is preselected. These are reflection labels only: they never change passage requirements, backoff, duration limits, or lockdown precedence. Old records without a label appear as **Unspecified**.

Click a group or “View all bypasses & configure…” to open the detailed view (a separate window on macOS, a sheet on iOS). Filter by calendar period/custom dates, group, app/block-page source, or intention. Sort groups by count, recency, or name; optionally hide zero-count groups. Preferences persist locally. Authorized minutes are not usage measurements and may overlap.

## Recording and coverage

- History is device-local, not iCloud-synced. Recording starts with this version; resettable backoff counters are not converted into invented historical events.
- The app keeps the newest 10,000 records. Deleted groups retain their historical names; current groups use their current names.
- Stable request IDs prevent repeated imports from inflating counts. Expiration and pause cleanup do not remove history. Corrupt app history is preserved and reported instead of silently overwritten.
- Browser grants require the updated macOS block-page helper and filter provider. The root-owned helper journal retains its latest 1,000 grants for import, including grants while the app is closed. An older helper can only supply active pauses observed by the updated provider, with unspecified intention.
- As with existing rule/status metadata, the provider's bounded browser-event mirror is readable by other local users via the filter status file. It includes group names, intention, and grant timestamps, but no passages, challenge tokens, browsing URLs, or visit history. The root request journal remains private (0600).
- Recording is observational: report filters never alter enforcement. No extra network requests are needed. Unchanged imports and unrelated defaults notifications do not re-decode or rewrite the app ledger.

## Deployment

Build the app and provider with the existing macOS scheme. The app bundles the matching BlockPageServer. Installing the app alone does not replace an already-running privileged helper. Once the updated app is in Applications, the existing administrator command updates that helper without recreating certificates:

```sh
sudo /bin/bash Scripts/update-block-page-helper.sh
```

Reload an old block page before submitting a request: the new helper requires the intention field. Updating or restarting live enforcement is separate from the unit/simulator test workflow.

## Verification — build 92

- macOS: 475 hostless tests passed, including history retention/deduplication, malformed optional metadata, browser-journal persistence, and light/dark layout captures. Full app, helper, and provider built.
- iOS: 182 unit tests passed. The simulator UI test opens history, selects both intentions, verifies the selected value, and verifies persistence after closing/reopening the view.
- Browser typing-guard script passed explicit-choice, typing, deletion, paste/drop, synthetic input, and altered-submission checks.
- Screenshots reviewed for the dashboard, report, and intention controls. iOS uses inline expandable choices to avoid the observed modal-menu selection failure.
- No live enforcement was enabled, disabled, or restarted. Applications still contained build 91 at handoff. Physical-device grants and a live browser grant/import remain to be checked after installing build 92 and updating the privileged helper/provider.
