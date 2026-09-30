# macOS enforcement recovery

Recoverable diagnostic errors do not authorize a global pause:

- Missing provider reports and slow rule application warn after 30 seconds.
- The startup watchdog warns after 30 seconds and continues checking for late readiness without rewriting preferences.
- Unidentified-drop pressure raises a diagnostic warning, not a five-minute allow-all window. Named, intentional drops do not count toward the warning.
- Incomplete blocked-domain DNS preparation retries, then offers recovery without persisting a user-disabled state. It does not enable incomplete retry guards.

The enforcement banner offers **Disable All Web Blocks With Passage…** when a recovery warning or delivery error is present. It uses the same locally generated passage and policy-bound validation as the ordinary disable action; no network request or waiting period is needed. Successful confirmation removes the filter preference and leaves blocking disabled until explicitly enabled again.

Warnings are deduplicated by cause and clear when the corresponding condition recovers. Diagnostic snapshots include `dropPressureWarningActive` and the `drop_pressure_warnings` counter; legacy fail-open fields do not claim that a bypass occurred.

Uncertain system-level preference writes, invalid activation authority, and the bounded connectivity smoke-test cleanup retain their safety-removal behavior. This change deliberately does not remove those protections against a provider-less Network Extension intercepting all traffic.

Regression coverage: `MacFilterStartupWatchdogTests`, `WebFilterFailOpenGovernorTests`, `WebFilterDiagnosticsTests`, and `DesktopRemovalAuthorizationTests`. Live validation should use the bounded connectivity smoke test, not an unguarded enforcement toggle.
