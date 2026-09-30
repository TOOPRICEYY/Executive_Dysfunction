# Approval-free Mac web enforcement

This Mac edition deliberately excludes the Endpoint Security target and its
manually approved `com.apple.developer.endpoint-security.client` entitlement.
It uses capabilities that an Apple Developer Program Account Holder or Admin
can enable directly for explicit App IDs:

- `com.apple.developer.system-extension.install` on the containing app.
- `com.apple.developer.networking.networkextension` with
  `content-filter-provider-systemextension` on the app and filter extension.
- The existing App Group, Keychain sharing, and iCloud key-value capabilities.

The current signing team remains `7GXNZJMGPD`. The containing app uses the
explicit identifier `com.GabrielPrice.ExecutiveDysfunction`, and its filter uses
`com.GabrielPrice.ExecutiveDysfunction.WebFilter`. Register both identifiers,
enable Network Extensions in Certificates, Identifiers & Profiles, regenerate
both profiles, and then use manual signing for Developer ID distribution as
Apple documents.

The Debug configuration uses `content-filter-provider`, matching Apple
Development profiles. Release uses `content-filter-provider-systemextension`,
which Apple requires for a Developer ID packaged system extension. The two
configurations intentionally use separate entitlement files.

## Hardened layers

The system extension registers **only** `NEFilterDataProvider`. See "Why there
is no packet provider" below; this is a correctness requirement, not a
simplification.

1. With no active website rule the filter is a pass-through: every flow is
   allowed without inspection, so a scheduling or policy bug cannot cost
   connectivity.
2. Network Extension URL and socket hostname metadata is checked first.
3. Flows on web ports with no name yet are streamed through a bounded parser.
   Incomplete suffixes are passed while the prefix is retained; the suffix that
   completes a blocked HTTP Host or TLS SNI is withheld and dropped.
4. A ClientHello is judged on the server name it actually reveals. The ECH
   extension being present is *not* concealment: Chrome sends it on every
   connection as GREASE, beside a readable SNI, so refusing on its presence
   blocks all Chrome browsing. Only a hello offering no readable name is
   refused.
5. Unnamed QUIC on UDP 80/443 is refused so clients fall back to inspectable
   TCP. Named QUIC flows are decided normally.
6. DoT/DoQ ports and common public DoH provider hostnames are blocked while
   website enforcement is active.
7. A flow this filter cannot identify is released under a block-list rule,
   because a block list has no name to match against and must not turn a parser
   limitation into an outage. Fortress fails closed for every unidentified flow,
   which is what a default-deny allow-list means.
8. A circuit breaker suspends all filtering if unidentified drops exceed 200 in
    60 seconds, so no filter bug can become a total outage.
9. Loopback, link-local, RFC1918/ULA, and RFC6598 destinations are always reachable, and
   the controlling app and its extension are never blocked.
10. Policies use an HMAC-authenticated atomic file, monotonic revisions, and a
   target-private Keychain baseline so deletion, corruption, or rollback of the
   shared candidate does not weaken a running or restarted filter.
11. Locked rules accept only same-or-stronger changes unless the authenticated
    passage/delay workflow has opened its edit window.
12. The containing app re-submits the activation request at every launch, so an
    extension left at an older version, or a content filter switched off in
    System Settings, is repaired without the user pressing anything.

## Why there is no packet provider

Every recorded crash of this extension was the same one: `SIGSEGV` at
`KERN_INVALID_ADDRESS` inside `-[NEFilterPacketInterpose createChannel]`, on the
`com.apple.network.connections` queue, across builds 4 and 5.

The packet provider is therefore removed from `NEProviderClasses` entirely, and
a unit test asserts it stays removed. `NetworkPacketInspector` is retained
because the Windows enforcement tree still uses that parsing, but nothing on
macOS instantiates a packet provider.

The cost is the loss of IP-fragment and GRE/ESP/IP-in-IP tunnel blocking, which
only the packet layer could see. That is an accepted trade: those paths are
rarely used bypasses, and no bypass justifies a design that can take the
machine offline.

### Correction: drop-all is not the outage mechanism on this machine

This document previously asserted that a crashed or restarting filter blacks out
the Mac, because macOS drops all traffic while a configured content filter is not
answering. **That claim is contradicted by measurement and must not be relied on
again.** It was inference from an Apple-documented mechanism, never verified
here, and it sent two separate investigations in the wrong direction.

What was actually measured:

- `plutil -p /Library/Preferences/com.apple.networkextension.necp.plist` reports
  `drop_all_level => "Unknown"`, not an active drop-all level.
- `nesessionmanager` logs, repeatedly:
  `applyIPDefaultDrop: IP Drop-All disabled due to disableDefaultDropAfterBoot`.
- Neither `~/Library/Logs/DiagnosticReports` nor
  `/Library/Logs/DiagnosticReports` contains any crash for this extension.

So on this machine IP drop-all is switched off, and a filter that stops
answering does *not* take the network down. The outages had a different cause
entirely — see "The intermittent total outage" below.

Two consequences follow. First, several comments in the source justified their
caution with the drop-all mechanism ("saving restarts the provider, and macOS
drops all traffic while a configured filter is not answering"). The *conclusions*
still hold — needless configuration saves are still worth avoiding, and a
timer-driven `isEnabled` cycle is still forbidden — but the stated reason is
weaker than it appears. Second, and more important: a mechanism that has only
been read about is not evidence. Everything in "Measured behaviour" was checked
against a live machine; this claim never was, and it survived for months because
it explained the symptom plausibly.

## The intermittent total outage

The build-28 launch incident was measured from the provider's own counters:
6,551 new flows, 144 selected for inspection, zero outbound callbacks, 113
zero-byte completions, and 31 still held. The initial data verdict requested
**16,640 outbound bytes**. Network Extension treats that value as the amount it
must collect before calling the provider, not as an upper bound. Browsers wait
for the server after writing a much smaller ClientHello, while the filter waited
for bytes the browser would never write. Every inspected web connection
deadlocked; ordinary browsing therefore looked completely offline.

The provider now requests one initial byte and streams classification:

1. Retain a bounded prefix (at most 64 KiB).
2. On an incomplete TLS or HTTP parse, pass only the bytes just inspected so the
   client can continue writing, then request at most 512 more bytes.
3. Withhold the final callback that identifies a blocked hostname and drop the
   flow. The server can receive an incomplete ClientHello/request, but never the
   completing bytes that make the blocked request usable.
4. Release invalid callback sequences and unclassified completion under a block
   list instead of turning parser uncertainty into a machine-wide deny.

This also handles ClientHellos split across arbitrarily many callbacks; the old
eight-callback escape hatch was both a Coinbase retry bypass and an unreliable
outage guard. Exact offset checks reject empty, replayed, overlapping, or gapped
callbacks safely. Known blocked hostnames are dropped at new-flow time, before
any streaming state is created.

### Build 29: allowed verdicts starved behind source identity resolution

A second enabled trial produced a different signature. Over 58 seconds the
provider received 1,327 flows. At its heartbeat it had explicitly allowed 765
of 766 decisions, dropped one unnamed QUIC flow, started zero inspections, and
never tripped fail-open. Policy decisions therefore did not explain the loss of
connectivity.

The provider was synchronously resolving every flow's audit token through
Security.framework before returning its verdict. The active policy contained
zero `macApplicationIdentifiers`, so none of that work could affect a decision.
Unified Logging showed sustained code-signing/Security activity while allowed
flows accumulated. The evidence points to Network Extension callback starvation:
traffic was allowed logically but waited behind unnecessary identity work.

Build 30 gates source identity resolution on
`hasActiveMacApplicationRestrictions`. Domain-only policies now skip the
Security round trip entirely; application blocking still resolves and caches
identity when an active application rule needs it. Fixed-cardinality counters
report requested versus skipped identity resolutions without recording an
identity or path.

An older completion bug is still guarded: `handleOutboundDataComplete` once
mapped the new-flow `.inspect` result to `.drop()`. Completion now uses
`decisionAtOutboundCompletion`, which releases an unclassified block-list flow
and fails closed only for Fortress or a positively known blocked name.

Two other boundaries remain explicit:

- `100.64.0.0/10` (RFC 6598 shared space) is local scope because the live VPN's
  resolver is `100.64.0.2`; blocking it removes system-wide name resolution.
- DNS port 53 never enters the TCP web streamer. DNS messages require their own
  whole-message path.

## Unidentified bypass handling and the safety valve

The enforcement contract intentionally denies two deterministic bypasses while
a web restriction is active: unnamed QUIC on UDP 80/443 and a complete TLS
ClientHello that signals ECH but exposes no readable SNI. Chrome ECH GREASE with
a visible SNI is classified by that SNI. Missing-SNI or malformed TLS that does
not signal ECH is released under a block list and refused under Fortress.

| Situation | Block list | Fortress |
| --- | --- | --- |
| Known blocked hostname or parsed blocked SNI/Host | drop | drop |
| Unnamed QUIC on UDP 80/443 | drop | drop |
| Complete ECH-only ClientHello | drop | drop |
| Missing-SNI or malformed TLS | allow | drop |
| Outbound stream ends unclassified | allow | drop |

### Fail-open safety valve

`WebFilterFailOpenGovernor` is a last-resort circuit breaker: past 200
unidentified drops within 60 seconds, the filter stops filtering for 300 seconds
and logs at `fault`. It then re-arms, so a persistent fault trips repeatedly
rather than disabling enforcement for good.

Only **unidentified** drops count. A drop where a rule named the destination is
intentional and is never counted — otherwise reloading a blocked page enough
times would switch enforcement off, and the valve would be the easiest bypass in
the product.

This exists because no correctness argument about the decision tree has survived
contact with a live machine. Every outage in this project's history was some
branch behaving exactly as written, on traffic that branch was never meant to
see. The valve is the one rule that cannot be reasoned wrong: a filter dropping
traffic at a rate no block list can explain is broken, and a broken filter must
get out of the way.

## Performance constraints on the flow path

`ResilientDesktopPolicyLoader.current()` runs on the flow path. It must not
decode the vendor configuration per flow, and must not touch the Keychain or the
App Group file synchronously. Both were doing exactly that; the JSON blob was
re-decoded for the life of the filter because an accepted revision always
satisfied `>= cached`. File and Keychain refreshes now happen on a background
queue and the flow path reads a cached snapshot.

## Measured behaviour

Verified against a live rule on macOS 26.3.1:

- `peekOutboundBytes` does not wait for the full requested amount. A 1024-byte
  peek was satisfied by a ~300-byte ClientHello and by a 39-byte HTTP request,
  both delivered immediately. Peeking is safe; requesting *more data* from a
  client that is waiting on the server is what deadlocks.
- Successive outbound callbacks contain offset chunks rather than an
  accumulated prefix. For example, a ClientHello deliberately written as 20
  then 57 bytes arrives at offsets 0 and 20. The provider therefore retains a
  bounded per-flow prefix, validates overlaps/gaps, and parses only the
  reassembled bytes; treating the offset-20 chunk as a new payload recreates
  the hostname-bypass bug.
- Refusing a flow at `handleNewFlow` makes the client wait out its own connect
  timeout, about 12 seconds. Refusing it on the first write instead fails in
  about 30 milliseconds. Blocked web flows are therefore held for one write.
- Dropping DNS questions works but is not used. The stub resolver retries every
  configured server first, so the user waits about 15 seconds for a generic
  timeout instead of ~30ms for a refused connection, and the outcome is the
  same because the connection is refused by name anyway.
- Changing the browser or system DNS server does not bypass enforcement.
  Resolving a blocked domain through an unrelated DoH provider still failed,
  because matching happens on the connection, not on the lookup.
- Connecting to a raw IP with SNI for a blocked domain is refused, while the
  same IP with a different SNI connects normally.

## Why inspection must accumulate a whole ClientHello

A browser does not put the server name near the front of its ClientHello, and
a peek sized by intuition rather than measurement produces an intermittent
bypass that is easily mistaken for the browser re-routing itself.

Chrome 150 was measured on this machine. Its post-quantum key share makes the
ClientHello 1735-1831 bytes, delivered in a single write, and Chrome shuffles
its extension order on every connection. Across eight connections to one host
the server name appeared at offsets:

    1691, 1426, 1722, 1760, 1419, 429, 1748, 1798

Seven of eight sat beyond a 1024-byte peek. With a short window the filter
found the name on roughly one attempt in eight and released the flow on the
rest, so a blocked site failed once and then loaded on retry. Nothing was
re-routing: Chrome was simply retrying until the name fell outside the window.

The original conclusion from that measurement was wrong: requesting the whole
record on the first verdict treats the request as a threshold and deadlocks a
smaller client write. The correct implementation starts with one byte, retains
the prefix, passes each incomplete suffix, and asks for at most 512 additional
bytes. It can therefore reach an SNI at any measured offset without waiting for
one impossible 16,640-byte callback or imposing a continuation-count bypass.

The completing suffix is not passed until classification. A blocked SNI is
dropped while those bytes are still withheld; an allowed SNI releases the flow.

## GREASE ECH is not concealment

Refusing any ClientHello carrying the `encrypted_client_hello` extension
blocked every page in Chrome. Chrome sends that extension on *every*
connection as GREASE, precisely so that real ECH cannot be distinguished from
ordinary traffic; it was observed here as a 250-byte 0xFE0D extension sitting
beside a plainly readable SNI.

Enforcement therefore decides on the visible name whenever there is one, and
treats only a hello with no readable name as concealed. The residual gap is a
domain reachable solely behind a public ECH outer name, which is a narrower
limit than refusing an entire browser.

## Policy delivery must never wedge

The filter once enforced a single stale snapshot indefinitely: `coinbase.com`
blocked correctly, while every domain added afterwards passed straight through.
The shared file and the vendor configuration both held the current revision, so
the policy was arriving and being discarded.

Two faults combined:

1. The stronger-only evaluator was applied to the vendor configuration. That
   channel is written only by the signed containing app into system-owned
   Network Extension preferences, which already needs the administrator rights
   required to remove the filter, so the check bought nothing there. It did do
   harm: once the retained baseline named a rule the user had since deleted,
   `proposedByID[old.id]` was permanently nil and *every* later policy was
   rejected -- including ones that only added domains.
2. `ingestedVendorRevision` was latched before validation, so a revision
   rejected for any reason was never reconsidered.

The vendor configuration is now applied on its monotonic revision alone, and the
revision is latched only on acceptance. Tamper resistance stays where the threat
is: the shared file is user-writable, so `scheduleRefresh` keeps the HMAC,
monotonic and stronger-only checks. Rollback is still refused on both paths.

The failure mode to avoid repeating is silence. A rejected policy produced no
symptom other than rules that quietly did nothing, which is indistinguishable
from a filter that is simply not working.

### A running provider never sees a configuration change

`NEFilterDataProvider` reads `filterConfiguration.vendorConfiguration` as it
stood when `startFilter` ran. A later `saveToPreferences` updates the stored
configuration and does **not** reach the running provider.

This produced a second silent wedge: the app published revision 203 while the
filter enforced 199 for sixteen minutes, then jumped to the current revision the
instant the app relaunched. Two mistakes hid it:

1. `updatePolicy` delivered only when `status == .active`, and `status` latches.
   One failed save — a filter restart racing an activation is enough — left it
   on `.failed`, after which every policy was dropped. Delivery must never be
   gated on a status enum.
2. `reassert()` looked like the repair, and appeared to work because every
   deploy also bumped `CURRENT_PROJECT_VERSION`. An activation request for an
   already-installed version is a no-op that does not restart the provider. The
   version change was doing the work, not the activation.

Delivery is a plain re-save, capped at three attempts and throttled to one every
thirty seconds.

An earlier version escalated to cycling `NEFilterManager.isEnabled` off and on,
on a timer, whenever the filter looked behind. Because the app also republished
on every iCloud notification, "behind" was near-permanent, and the machine took
a recurring outage. **Do not reintroduce any automatic, repeating action that
writes Network Extension configuration.**

### Saves must tolerate a losing race

Two `saveToPreferences` failures are transient and were previously fatal to a
policy update:

- `NEConfigurationErrorDomain` code 10, "permission denied". Observed at
  17:39:34.474, in the same millisecond that `sysextd` logged
  `starting uninstall of ...WebFilter version 26 for upgrade`. This is not a
  permissions problem; it is a save landing while the extension is being
  replaced. It left the extension stuck at `activated_disabled`.
- `NEFilterErrorDomain` code 3, "configuration is stale". This is a save racing
  a filter restart, with an in-process snapshot the system has since
  invalidated.

Both are answered by re-reading preferences and saving once more. The retry is
bounded at two attempts, two seconds apart, and is scheduled from the failure
itself rather than from a timer — after the cap the chain ends and the failure
stays visible in `deliveryError`.

Retrying is safe here for a specific reason worth keeping in mind: a *failed*
save does not restart the provider, so a retry costs nothing until it succeeds,
at which point retrying stops. That is what distinguishes this from the
`isEnabled` cycle, which paid its cost on every iteration whether or not it
helped.

Note also that the shared-file channel cannot rescue this. The file lives in the
signed-in user's App Group container and the extension runs as root, so the two
do not resolve the same path. The vendor configuration is the only channel that
reaches the filter.

### The filter states what it is enforcing

A content filter has no `sendProviderMessage`, and the extension runs as root,
so its App Group container and Keychain items are unreadable by the signed-in
user's app. The filter therefore writes a small world-readable report to
`/Library/Application Support/ExecutiveDysfunction/filter-status.json`: the
revision it is using, how many rules and domains are active right now, and a
timestamp. It heartbeats every 30 seconds so a stopped filter is
distinguishable from a filter enforcing an old policy.

The app polls that file and compares it with the revision it last published,
then says which of the two is wrong: enforcing, idle, behind, stale, or not
reporting. `behind` is the state that previously had no symptom at all beyond
rules that quietly did nothing.

Writes are throttled and dispatched to a utility queue; the flow path never
touches the file system.

### Redacted diagnostics and incident correlation

Build 28 extends the same status file with an optional diagnostics object. It is
backward-compatible with older provider status and contains only fixed-cardinality
control-flow data:

- provider session UUID, extension version/build, start time and heartbeat
  sequence;
- current and previous provider-session snapshots, so a restart does not erase
  the immediately preceding evidence;
- counts by verdict stage and stable decision reason, including unnamed QUIC,
  incomplete/ECH/missing-SNI/malformed TLS, terminal unclassified releases,
  invalid stream sequences and continuation-cap releases;
- current/peak held inspections and maximum inspected prefix size;
- fail-open state, expiry, trip/re-arm counts and unidentified-drop window;
- the latest sixteen unusual events, storing only minute-bucketed time, reason, revision,
  TCP/UDP, broad port class, byte count and continuation count.

The diagnostics schema cannot carry hostnames, IP addresses, URLs, SNI values,
application identifiers, executable paths, rule identifiers or payload bytes.
Flow and anomaly times are rounded down to one-minute buckets before they enter
the world-readable file; exact correlation remains available in Unified Logging.
The top-level `blockedDomains` field predates these diagnostics and exists for
the local block-page confirmation path.

The heartbeat is now a real `DispatchSourceTimer` owned by the provider. The old
implementation wrote only when a flow happened to call `currentPolicy()`, so an
idle but healthy provider could look stale after 120 seconds and provoke policy
repair. Status writes and heartbeat sequence assignment are serialized, and a
generation guard prevents queued work from an old/stopped provider from writing
after shutdown.

Routine traffic is aggregated into the status snapshot every thirty seconds.
The matching `diagnostic_summary` is persistent at provider start and policy
revision changes, and debug-level for unchanged heartbeats to avoid thousands
of idle notice records per day. Individual routine destinations are never logged. Invalid
stream state, inspection-table resets, continuation limits, fail-open transitions,
provider start/stop, policy acceptance/rejection, system-extension activation,
and Network Extension preference load/save results have structured events.
App preference operations carry an opaque operation ID and include trigger,
revision, retry number, stored revision, configuration-changed flag, duration,
and public NSError domain/code. The ID is never added to `vendorConfiguration`,
because changing configuration merely for diagnostics could itself restart the
provider.

Useful read-only collection commands:

```sh
cat '/Library/Application Support/ExecutiveDysfunction/filter-status.json'

/usr/bin/log show --last 2h --style compact \
  --predicate 'subsystem == "com.GabrielPrice.ExecutiveDysfunction.WebFilter"'

/usr/bin/log show --last 2h --style compact \
  --predicate 'subsystem == "com.GabrielPrice.ExecutiveDysfunction" OR process == "nesessionmanager" OR process == "sysextd"'
```

The first predicate explains data-plane decisions. The second correlates app
activation/save attempts with macOS provider lifecycle and IP Drop-All windows.

### Baselines are shared per user

`AcceptedDesktopPolicyStore` keys its Keychain item by service and account only,
so every process running as that user shares one baseline. A test that built its
own loader silently inherited a revision left by another process and rejected
its own fixtures as rollbacks. The loader now takes an `AcceptedPolicyPersisting`
so tests can pass an in-memory baseline and stay hermetic.

### Tests must never touch NetworkExtension

`DesktopEnforcementTests` was hosted in `Holdfast`, so every
`xcodebuild test` launched the real app, which constructs `MacAppModel` ->
`MacEnforcementController` -> `configureNetworkFilter()` ->
`NEFilterManager.saveToPreferences`. Running the unit tests therefore rewrote the
live filter configuration and restarted the content filter on the developer's own
machine; one run logged `NEFilterErrorDomain Code=3 "configuration is stale"`.
Debugging an outage with a test suite that causes outages does not converge.

The decision layer is pure Foundation/Security/CryptoKit, so `Sources/DesktopShared`
is now compiled straight into a **hostless** test bundle with no `TEST_HOST` and
no dependency on the app. Run it with:

    xcodebuild test -scheme DesktopEnforcementTests -destination 'platform=macOS'

`MacEnforcementController` additionally refuses to configure the filter or submit
an activation request when an XCTest bundle is loaded, as a second line of
defence if the target is ever re-hosted.

## Remaining boundary

Local installation still requires the ordinary macOS System Settings approval
for a system extension/content filter. An administrator can remove the app or
filter through the visible Recovery / Remove path.

What still gets through:

- A VPN or full tunnel that carries traffic past the filter.
- A non-TLS custom protocol that reaches the site with no readable name
  anywhere.
- TLS to a raw IP with no SNI.
- A client that deliberately produces enough unidentified QUIC/ECH drops to
  trip the last-resort fail-open governor during its cooldown.
- Traffic on a connection that was already established before the rule became
  active.
- Anything the device owner does with administrator or recovery access.

For resistance to an administrator, arbitrary tunnels, or app deletion, deploy
the filter with Automated Device Enrollment/MDM and force DNS or a full-tunnel
secure web gateway. No local consumer app can make itself stronger than the
device owner.
