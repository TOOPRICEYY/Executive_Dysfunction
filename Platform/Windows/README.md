# Windows enforcement component

Target: Windows 11 x64/ARM64 with Secure Boot. The service is a normal,
visible LocalSystem service and the process guard is a signed kernel driver.
It is resistant to standard-user changes, but a local administrator retains an
explicit recovery/uninstall path.

## Enforcement layers

1. `ExecutiveDysfunctionService` runs as LocalSystem, watches the ACL-protected
   `%ProgramData%\ExecutiveDysfunction\policy.bin`, and sends only monotonic
   policy revisions to the driver. Its accepted revision is retained under
   `HKLM\SOFTWARE\ExecutiveDysfunction`; equal-revision driver writes are
   idempotent so a crash between driver, WFP, and registry commits is retryable.
2. `ExecutiveDysfunctionGuard.sys` registers a process-creation callback and
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
