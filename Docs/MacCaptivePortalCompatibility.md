# macOS captive-portal compatibility

## Diagnosis

Code inspection and hostless regressions establish these failure paths; the
reported Wi-Fi network has not been available for an end-to-end reproduction:

1. Fortress default-deny refused `captive.apple.com`, because the recovery
   infrastructure list did not include Apple's connectivity probe. It also
   refused the sign-in assistant's redirects to public, previously unknown
   portal hosts (or an unnamed socket).
2. Captive DNS can answer a blocked-site lookup with a portal address. The retry
   guard treats such an address as evidence of a blocked site and drops unnamed
   connections to it. There was no authenticated sign-in-component exception.
3. Non-loopback LAN/gateway answers were accepted into the public retry-address
   set even though local traffic is exempt in the decision layer.
4. The provider returned no remote endpoint on macOS 14, preventing port- and
   address-scoped decisions there. Browser flows also lacked a URL-derived port.

Apple documents `captive.apple.com` on TCP 80/443 for portal connectivity
validation: <https://support.apple.com/en-us/101555>.

## Changes and boundaries

- Allow the **exact** probe hostname on TCP 80/443 under default-deny; not all
  Apple hosts, probe subdomains, arbitrary ports, or UDP. Explicit domain blocks
  and block-list application restrictions still win.
- Allow TCP 80/443 portal navigation by Apple's Captive Network Assistant and
  captiveagent before default-deny or an unnamed correlated-IP drop. This is a
  process-scoped exception, not a global pause or a shared-IP allowlist. Known
  explicitly blocked destinations remain blocked even inside the assistant.
- Trust requires the source application's audit token, the exact protected OS
  executable path and signing identifier, and successful live code validation
  against `anchor apple`. A copied identifier, User-Agent, WebKit process name,
  Safari, or arbitrary `/System` executable cannot grant this exception. Use the
  originating application's token, not the networking broker's process token.
- Only an otherwise-denied authentication flow triggers additional identity
  resolution. The existing bounded PID + PID-version cache is reused. Normal
  allowed domain-only browsing remains on its cheap/default-allow path.
- Reject local-scope DNS answers from prepared, restored and refreshed public
  retry guards. Keep prior public coverage when refreshing on a captive network.
  Missing public answers still do not count as complete readiness.
- Use the legacy endpoint API on macOS 14 and URL ports for browser flows.
- Diagnostics add fixed, privacy-preserving decision reasons:
  `captive_portal_probe_allowed` and `captive_portal_assistant_allowed`. No portal
  credentials, URLs or browsing history are logged.

System domain drops, encrypted-DNS defenses, ordinary browser retry guards,
change policies and the safety latch remain in place. Authentication is not
treated as permission to disable enforcement. Nothing changes Wi-Fi settings,
DNS settings, certificate validation, or the trusted block-page helper.

## Verification

Run the hostless `DesktopEnforcementTests` scheme. Regressions cover the probe,
Fortress public/unnamed redirects, DNS collision versus ordinary browser retry,
explicit blocks, non-web transports, identity spoofing, normal browser/app rules,
URL-only browser flows, and local DNS answers with preservation of public guards.
The signed `HoldfastMac` build compiles the actual provider and Security APIs.
Neither action installs, launches or toggles the live extension.

Verification on 2026-09-21: all **450** hostless desktop tests passed (including
eight new regressions). The signed Debug app/extension build succeeded and
`codesign --verify --deep --strict` passed using the system trust service.
This change has not been installed into `/Applications` or activated live.

### Remaining real-network test (after explicit deployment)

1. With Holdfast enabled, join a Wi-Fi network that requires sign-in. Confirm
   Apple's sign-in assistant appears. Do not disable certificate warnings or
   automate acceptance of the network's terms/credentials.
2. Complete authentication yourself. Check an ordinary allowed site and a known
   blocked site. The former must load; the latter must remain blocked.
3. Repeat with a Fortress rule if used, then reconnect to check another login.
   Where possible test both a local gateway and a public portal redirect.
4. Read the filter status's `diagnostics.decisionReasons` and readiness, without
   publishing portal URLs or credentials. Domain-only traffic can bypass provider
   callbacks, so an absent allowance counter alone does not mean login failed.
5. Confirm no pause/safety-latch transition was introduced by login.

Some portals require a full browser, nonstandard ports, or an explicitly blocked
login provider. Those intentionally do not receive a blanket exception. An
observed failure needs scoped evidence before widening this recovery path.
