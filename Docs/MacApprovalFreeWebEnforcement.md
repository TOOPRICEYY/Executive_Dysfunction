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
3. Flows on web ports with no name yet are peeked, and HTTP Host or TLS
   ClientHello SNI is parsed locally. A fragmented ClientHello remains held
   only until its declared records are complete; arbitrary non-TLS payloads
   are released so ordinary browsing is not held indefinitely.
4. A ClientHello is judged on the server name it actually reveals. The ECH
   extension being present is *not* concealment: Chrome sends it on every
   connection as GREASE, beside a readable SNI, so refusing on its presence
   blocks all Chrome browsing. Only a hello offering no readable name is
   refused.
5. Unnamed QUIC on UDP 80/443 is refused so the client retries over TCP, where
   the ClientHello is readable. Named QUIC flows are decided normally.
6. DoT/DoQ ports and common public DoH provider hostnames are blocked while
   website enforcement is active.
7. TLS ClientHellos that conceal or omit the server name are refused while any
   website rule is active. Fortress rules additionally fail closed for every
   unidentified flow; block-list rules still release non-TLS unidentified
   traffic because they have no domain identity to match.
8. Loopback, link-local and RFC1918/ULA destinations are always reachable, and
   the controlling app and its extension are never blocked.
9. Policies use an HMAC-authenticated atomic file, monotonic revisions, and a
   target-private Keychain baseline so deletion, corruption, or rollback of the
   shared candidate does not weaken a running or restarted filter.
10. Locked rules accept only same-or-stronger changes unless the authenticated
    passage/delay workflow has opened its edit window.
11. The containing app re-submits the activation request at every launch, so an
    extension left at an older version, or a content filter switched off in
    System Settings, is repaired without the user pressing anything.

## Why there is no packet provider

Every recorded crash of this extension was the same one: `SIGSEGV` at
`KERN_INVALID_ADDRESS` inside `-[NEFilterPacketInterpose createChannel]`, on the
`com.apple.network.connections` queue, across builds 4 and 5.

That crash is what produced the reports of the Mac losing all network access.
macOS records `drop_all_feature_content_filter` in
`/Library/Preferences/com.apple.networkextension.necp.plist`: while a content
filter is configured but not answering, the system drops traffic. So any crash
in this extension presents to the user as a total, machine-wide outage rather
than as a filter that stopped filtering.

The packet provider is therefore removed from `NEProviderClasses` entirely, and
a unit test asserts it stays removed. `NetworkPacketInspector` is retained
because the Windows enforcement tree still uses that parsing, but nothing on
macOS instantiates a packet provider.

The cost is the loss of IP-fragment and GRE/ESP/IP-in-IP tunnel blocking, which
only the packet layer could see. That is an accepted trade: those paths are
rarely used bypasses, and no bypass justifies a design that can take the
machine offline.

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

## Why the peek window must hold a whole ClientHello

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

Two consequences are load-bearing:

1. `plaintextPeekBytes` covers a full TLS record. `peekOutboundBytes` is an
   upper bound rather than a threshold, so a large request does not hold small
   writes; this was verified directly.
2. Asking for a larger prefix *after* a short first look does not work. The
   framework did not deliver the additional bytes, the flow finished, and
   `handleOutboundDataComplete` released it. The whole record must be requested
   on the first verdict.

A TLS ClientHello whose name cannot be read is refused rather than released, so
a future client with an even larger hello fails closed instead of leaking.

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

Delivery now escalates: save, and if the filter still reports a lower revision
after three polls, cycle `NEFilterManager.isEnabled` off and on to restart the
provider. Verified converging on a same-version relaunch, the case that was
broken. The cycle leaves traffic briefly unfiltered, so it is throttled to once
a minute and only follows failed cheaper attempts; disabling is the safe
direction, since the outage risk comes from a filter that is configured but not
answering rather than one cleanly absent.

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

### Baselines are shared per user

`AcceptedDesktopPolicyStore` keys its Keychain item by service and account only,
so every process running as that user shares one baseline. A test that built its
own loader silently inherited a revision left by another process and rejected
its own fixtures as rollbacks. The loader now takes an `AcceptedPolicyPersisting`
so tests can pass an in-memory baseline and stay hermetic.

## Remaining boundary

Local installation still requires the ordinary macOS System Settings approval
for a system extension/content filter. An administrator can remove the app or
filter through the visible Recovery / Remove path.

What still gets through:

- A VPN or full tunnel that carries traffic past the filter.
- A non-TLS custom protocol that reaches the site with no readable name
  anywhere. TLS to a raw IP without SNI is refused while a website rule runs.
- Traffic on a connection that was already established before the rule became
  active.
- Anything the device owner does with administrator or recovery access.

For resistance to an administrator, arbitrary tunnels, or app deletion, deploy
the filter with Automated Device Enrollment/MDM and force DNS or a full-tunnel
secure web gateway. No local consumer app can make itself stronger than the
device owner.
