# Windows enforcement component

Target: Windows 11 x64/ARM64 with Secure Boot. The service is a normal,
visible LocalSystem service and the process guard is a signed kernel driver.
It is resistant to standard-user changes, but a local administrator retains an
explicit recovery/uninstall path.

## Enforcement layers

1. `HoldfastService` runs as LocalSystem, watches the ACL-protected
   `%ProgramData%\Holdfast\policy.bin`, and sends only monotonic
   policy revisions to the driver. Its accepted revision is retained under
   `HKLM\SOFTWARE\Holdfast`; equal-revision active snapshots remain
   writable so schedule transitions and crash recovery can be reconciled.
2. `HoldfastGuard.sys` registers a process-creation callback and
   denies configured executable paths before their first instruction executes.
   The driver device ACL permits policy writes only from SYSTEM or an
   administrator, and rejects policy rollback.
3. The service installs persistent Windows Filtering Platform filters at the
   IPv4 and IPv6 ALE authorization layers for each configured executable. This
   blocks outbound connections even if the process-creation layer is temporarily
   unavailable. Updates happen in one WFP transaction, and the provider and
   filters remain visible to normal Windows Firewall auditing tools.
4. Domain-aware website filtering still requires a signed WFP callout plus
   forced DNS. Do not implement it by editing `hosts`: that is easy to bypass
   and mishandles encrypted DNS. The current code must not be described as
   enforcing Windows domain/category rules yet.
5. For managed/business deployments, prefer signed App Control for Business
   policies for publisher-based rules. AppLocker is a compatible fallback, but
   Microsoft describes it as defense-in-depth rather than a security boundary.

## Diagnostics and the intermittent all-traffic symptom

The service writes privacy-safe operational records to
`%ProgramData%\Holdfast\enforcement.log`, rotating at 1 MiB to
`enforcement.previous.log`. Records contain revisions, rule/filter counts,
component success flags, the WFP transaction stage, and Windows error codes;
they never contain application paths or destinations.

An equal policy revision can represent a different active schedule snapshot.
The previous service refreshed the process driver but skipped WFP replacement
whenever the revision was unchanged. Persistent ALE filters from an earlier
active window therefore survived indefinitely. If the configured application
was a VPN, proxy, browser broker, or shared networking process, that looked like
all internet traffic being blocked. Every accepted snapshot now atomically
reconciles the owned WFP filters, including equal-revision snapshots.

## Required production work

- Generate the binary policy only after validating the same authenticated JSON
  envelope used by macOS. Protect its machine key with DPAPI-NG or TPM-backed
  CNG storage; never ship a hard-coded key.
- Build with the WDK, pass Driver Verifier/HVCI tests, obtain Microsoft driver
  signing, and ship through an MSI/MSIX installer that sets service failure
  recovery and restrictive service/ProgramData ACLs.
- Implement the WFP DNS/connection layer and test VPN, IPv6, QUIC, encrypted
  DNS, sleep/resume, clock changes, Safe Mode, upgrade, and recovery behavior.
- Provide a separately documented administrator recovery tool. Never hide the
  service, driver, filter, or removal state from the device owner.
