# Text Configuration — Developer Guide

RuleProxy can drive nodes, proxy groups, rules, host overrides and global
settings from one Surge-style text profile. This guide documents exactly what
this build parses, what it applies, and what it only stores, so a profile that
imports cleanly is never mistaken for a profile that is fully honored.

Nothing here is a claim of full Surge compatibility: the syntax follows Surge so
existing profiles import, but every feature is listed with its real status.

## Contents

- [Pipeline](#pipeline)
- [Where the files live](#where-the-files-live)
- [Sections](#sections)
- [`[General]` fields](#general-fields)
  - [Adding a setting](#adding-a-setting)
- [`[Proxy]`](#proxy)
- [`[Proxy Group]`](#proxy-group)
- [`[Rule]`](#rule)
- [`[Host]`](#host)
- [`[MITM]` and `[Script]`](#mitm-and-script)
- [Diagnostics](#diagnostics)
- [Reload scopes](#reload-scopes)
- [Activation lifecycle](#activation-lifecycle)
- [Exporting the current setup](#exporting-the-current-setup)
- [Editing inside the app](#editing-inside-the-app)
- [Limits](#limits)
- [Known gaps](#known-gaps)

## Pipeline

```
text → ConfigurationDocument     (lossless: comments, blank lines, order, raw text)
     → ParsedConfiguration      (typed sections and rules)
     → ConfigurationValidator   (capability gates, references, FINAL, cycles)
     → ConfigurationCompiler    (ProxyConfiguration / ProxyGroup / rule sets / settings)
     → ConfigurationActivation  (snapshot + manifest)
     → ConfigurationInstaller   (writes the app's existing stores)
     → RoutingExportOperation   (routing.bin + darwin notification to the tunnel)
```

Entry point for editors and importers is `TextConfigurationPipeline.process(text:)`.
`ConfigurationImport.read(from:)` turns a picked file into text (UTF-8 only, 1 MB
cap, BOM and CRLF normalized) so a file and a pasted document travel the same
path. `TextConfigurationPipeline.Result.route(host:ip:port:)` previews the
decision through the same `OrderedRouteMatcher` the tunnel will use, so an editor
never invents its own matching rules.

The document model round-trips: `ConfigurationDocument.text` returns the original
bytes, including comments and unknown sections. Editing helpers on
`ConfigurationDocument` (`line`, `entries`, `section`) never reorder rules.

## Where the files live

Everything is inside the App Group container (`AWCore.Identifier.appGroupSuite`),
under `configurations/`:

| File | Written by | Meaning |
| --- | --- | --- |
| `draft.txt` | host app | what the editor shows; survives a relaunch even with errors |
| `manifest.json` | host app | active snapshot, rollback target, last failure, `appliedAt` |
| `snapshots/<uuid>.json` | host app | frozen text + summary + diagnostics per activation (20 kept) |
| `installation.json` | host app | which nodes/groups/rule sets the text configuration owns |
| `engine-confirmation.json` | extension | the snapshot the engine is actually running + engine version |

`installation.json` is what makes re-activation idempotent: nodes are matched by
name against the ids listed there, so re-activating updates in place, and a node
the user added by hand is never overwritten or deleted.

`engine-confirmation.json` is written by the Network Extension, not the host.
`ConfigurationSnapshotStore.isActiveSnapshotConfirmed()` compares it with the
manifest, which is how "activated" stays distinguishable from "running".

## Sections

| Section | Parsed | Applied by this build | Notes |
| --- | --- | --- | --- |
| `[General]` | yes | every key in the settings catalog | see the field table below |
| `[Proxy]` | yes | yes | link form and field form |
| `[Proxy Group]` | yes | `select` only | other kinds are reported |
| `[Rule]` | yes | four rule types | see [`[Rule]`](#rule) |
| `[Host]` | yes | yes | exact hosts only; wildcards reported |
| `[MITM]` | yes | `enable` only | host list is not consumed yet |
| `[Script]` | yes | no | parsed, validated, reported as not installed |
| anything else | preserved | no | reported as `unknownSection` |

An unknown section or key is never silently dropped: it stays in the document and
produces a diagnostic.


## `[General]` fields

`key = value` lines. Status meanings: **applied** changes engine behavior,
**reported** is recognized so a real Surge profile imports, but produces a
`notApplied` warning because this build cannot honor it yet.

Every key below is declared once, in `ConfigurationSettings.catalog`
(`Shared/Configuration/ConfigurationSettings.swift`). That one table is what the
parser, the validator, the compiler, the installer, the exporter and the reload
planner all read, so a key cannot be half-wired: it is either applied end to end
or not declared at all. `ConfigurationSettingsBindings.all` says where the value
lives (`AWCore`), and `ConfigurationSettingsTests` fails if the two tables drift
apart.

| Key | Values | Reload scope | Status |
| --- | --- | --- | --- |
| `proxy-mode` | `rule`, `global`, `direct` | data-plane restart | applied |
| `quic-policy` | `automatic`, `blocked`, `unblocked` | live | applied |
| `block-udp` | boolean | live | applied |
| `block-webrtc` | boolean | live | applied |
| `prevent-dns-leak` | boolean | live | applied |
| `hide-vpn-icon` | boolean | live | applied |
| `bypass-country` | ISO country code | live | applied through routing export |
| `include-all-networks` | boolean | reconnect | applied |
| `exclude-local-network` | boolean | reconnect | applied |
| `include-apns` | boolean | reconnect | applied |
| `include-cellular-services` | boolean | reconnect | applied |
| `exclude-device-communication` | boolean | reconnect | applied |
| `always-on` | boolean | reconnect | applied |
| `tun-included-routes` | comma list | live | applied |
| `tun-excluded-routes` | comma list | live | applied |
| `dns-mode` | `default`, `plain`, `doh` | data-plane restart | applied |
| `dns-server` | IPv4, optional port | data-plane restart | applied; also sets `dns-mode = plain` |
| `encrypted-dns-server` | `https://` URL | data-plane restart | applied; also sets `dns-mode = doh` |
| `proxy-dns-mode` | `default`, `plain`, `doh` | data-plane restart | applied |
| `proxy-dns-server` | IPv4, optional port | data-plane restart | applied |
| `proxy-encrypted-dns-server` | `https://` URL | data-plane restart | applied |
| `subscription-dns-mode` | `default`, `plain`, `doh` | live | applied |
| `subscription-dns-server` | IPv4, optional port | live | applied |
| `subscription-encrypted-dns-server` | `https://` URL | live | applied |
| `fallback-dns-mode` | `default`, `plain` | data-plane restart | applied |
| `fallback-dns-server` | IPv4, optional port | data-plane restart | applied |
| `ech-dns-mode` | `default`, `plain`, `doh` | data-plane restart | applied |
| `ech-dns-server` | IPv4, optional port | data-plane restart | applied |
| `ech-encrypted-dns-server` | `https://` URL | data-plane restart | applied |
| `synthetic-address-excluded-suffix` | comma list | data-plane restart | applied |
| `mitm` | boolean | live | applied; `[MITM] enable` wins when both appear |
| `allow-insecure` | boolean | data-plane restart | applied |
| `trusted-certificate` | comma list of SHA-256 fingerprints | live | applied |
| `trusted-ssid` | comma list | live | applied |
| `always-trust-cellular` | boolean | live | applied |
| `always-untrust-cellular` | boolean | live | applied |
| `reflection` | boolean | live | applied |
| `experimental` | boolean | live | applied |
| `loglevel` | `debug`, `info`, `warn`, `error` | live | reported; recorded in the snapshot, nothing to apply it to yet |
| `dns-server-fallback` | IPv4, optional port | data-plane restart | reported; use `fallback-dns-server` |
| `dns-fallback-system` | boolean | data-plane restart | reported |
| `dns-direct-system` | boolean | data-plane restart | reported; use `dns-mode` |
| `hijack-dns` | comma list | data-plane restart | reported |
| `dns-exclude-route` | comma list | data-plane restart | reported; use `synthetic-address-excluded-suffix` |
| `test-url` | text | live | reported; latency testing is configured in the app |
| `proxy-test-url` | text | live | reported |
| `test-timeout` | text | live | reported |
| `internet-test-url` | text | live | reported |
| `auto-quic-block` | boolean | live | reported; use `quic-policy = automatic` |
| `allow-hotspot-access` | boolean | live | reported |
| `skip-proxy` | comma list | live | reported; use `tun-excluded-routes` |
| `always-real-ip` | comma list | live | reported; use `synthetic-address-excluded-suffix` |

Value spellings follow Surge where they exist: booleans accept `true/false`,
`yes/no`, `on/off` and `1/0`; enumerations are case-insensitive; lists are
comma-separated and trimmed. A value a key rejects is an error that names what
the key accepts, so the text view can be fixed without leaving it.

`dns-server` takes a single address; a comma list is rejected with
`invalidValue` rather than silently using the first entry.

Anything else in `[General]` is preserved in the document and reported as
`unknownGeneralKey`; it is never silently dropped.

### Adding a setting

Two entries in one file, and the key is parsed, validated, compiled, applied,
exported and classified for reload:

```swift
// Shared/Configuration/ConfigurationSettings.swift — the catalog
ConfigurationSettingKey(
    name: "proxy-mode",
    kind: .enumeration(["rule", "global", "direct"]),
    scope: .stackRestart,
    applies: true,
    summary: "rule routes by [Rule], global sends everything through PROXY."
),

// …and the binding, in the same file
bind("proxy-mode", read: {
    .text(AWCore.getProxyMode().rawValue)
}, write: { value in
    if let mode = ProxyMode(rawValue: text(value) ?? "") { AWCore.setProxyMode(mode) }
}),
```

No change is needed in the parser, the validator's key lists, the compiler, the
installer or the exporter. Then the table above is extended and the test suite
asserts the two tables still agree.

Declaring a key with `applies: false` first is a legitimate step: it makes a
Surge profile import and gets the validator to report it, and the binding is
added when the engine can honor it. The tests stop the flag from being flipped
without a binding.


## `[Proxy]`

Two forms are accepted, both keyed by the node name:

```ini
[Proxy]
# link form
Tokyo = trojan://password@example.com:443?sni=example.com#Tokyo
# field form: type, server, port, then options
Frankfurt = vless, de.example.com, 443, uuid=…, tls=true, ws=true, ws-path=/ray
Local = direct
```

The link form goes through `ProxyConfiguration.parse(url:)`. The field form is
converted to a one-entry Clash document and parsed by `ClashProxyParser`, so both
forms end up as exactly the same outbound configuration.

| Type token | Mapped to | Notes |
| --- | --- | --- |
| `vless` | vless | `uuid`, `flow`, `encryption`, `network`, `tls`, `sni`, reality options |
| `trojan` | trojan | `password`, `sni`/`peer`, `ws` |
| `anytls` | anytls | `password`, padding options |
| `hysteria`, `hysteria2` | hysteria2 | `password`, `up`/`down`, obfs options |
| `ss`, `shadowsocks` | ss | `cipher`/`method`, `password` |
| `socks5` | socks5 | `username`, `password` |
| `http`, `rfc` | http | `username`, `password`, `tls` |
| `sudoku` | sudoku | parameters passed through |
| `direct` | direct | no server needed |

Option names are translated (`id` → `uuid`, `sni`/`peer` → `servername`,
`ws` → `network`, `ws-path` → `path`, `ws-headers` → `host`, `cipher`/`method` →
`cipher`, `aead` → `aead-method`, `public-key`/`short-id` → `reality-opts`).
Options this build cannot express (`skip-cert-verify`, `udp`, `udp-relay`, `tfo`,
`mptcp`, `ecn`, `test-url`, `ip-version`, `underlying-proxy`, `block-quic`,
`no-error-alert`, `fast-open`) are dropped **with a `notApplied` warning** — never
silently.

An unknown type is an error (`unknownProxyType`), not a skipped node.

Node and group names must not be policy tokens. `DIRECT`, `REJECT`,
`REJECT-TINYGIF` and `PROXY` are read as policies, not names, so
`DOMAIN-SUFFIX, a.com, DIRECT` always means the built-in action even when a node
is called `DIRECT`. Such a node is declared but unreachable; the validator warns
(`reservedPolicyName`) and the exporter renames it (`DIRECT_`) so an exported
document keeps meaning the same thing after it is read back.

## `[Proxy Group]`

```ini
[Proxy Group]
PROXY = select, Tokyo, Frankfurt, DIRECT
Auto = url-test, Tokyo, Frankfurt, url=http://cp.cloudflare.com, interval=300
```

Kinds `select`, `url-test`, `fallback`, `load-balance`, `smart` and `random` are
recognized. Only `select` is expressible today; the others produce a warning and
are treated as a manual selection group. A group is flattened to its dialable
members, and routing resolves a group policy to its **first** member, because this
build has one selected node per route.

Unknown members are errors (`unresolvedPolicy`). Cycles are detected
(`groupCycle`) and validation continues instead of recursing.


## `[Rule]`

Rules are evaluated in document order, first match wins. Compiled into the engine
today:

| Type | Value | Action |
| --- | --- | --- |
| `DOMAIN-SUFFIX` | `example.com` | policy |
| `DOMAIN-KEYWORD` | `example` | policy |
| `IP-CIDR` | `10.0.0.0/8` | policy |

Policy is `DIRECT`, `REJECT`, `REJECT-TINYGIF`, `PROXY`, or a node/group name.
`no-resolve` is parsed and kept per rule.

Parsed, previewable in the editor, but **not compiled** into the binary payload
yet: `DOMAIN`, `DOMAIN-WILDCARD`, `DOMAIN-REGEX`, `URL-REGEX`, `GEOIP`, `GEOSITE`,
`IP-ASN`, `GEOASN`, `RULE-SET`, `PROCESS-NAME`, `SRC-IP`, `SRC-PORT`, `DST-PORT`,
`PROTOCOL`, `USER-AGENT`, and `AND`/`OR`/`NOT` expressions. Each one produces an
`unsupportedRuleType` diagnostic saying it was not compiled; the editor preview
(`route(host:)`) can still evaluate it once geo lookups are injected.

`FINAL` is parsed and validated (exactly one, and last — otherwise
`duplicateFinal` / `finalNotLast`) and becomes `CompiledConfiguration.finalAction`
for the ordered matcher. The current binary payload has no FINAL entry, so the
tunnel keeps its own default until the ordered payload lands.

Because the engine assigns one policy per rule set, rules are grouped into
`Config · <POLICY>` rule sets. Editing a policy therefore creates or updates the
matching rule set instead of rewriting rule order.

## `[Host]`

```ini
[Host]
example.com = 10.0.0.1
```

Exact hosts only. The override table feeds `DNSHosts`, which the local resolver
consults before any upstream. Wildcard entries are reported and skipped rather
than stored (`invalidValue`); duplicate or invalid addresses are errors.

`[Host]` is owned by the text configuration: activation replaces the whole table,
and `ConfigurationInstaller.uninstall()` clears it.

## `[MITM]` and `[Script]`

```ini
[MITM]
enable = true
hostname = example.com, *.example.org

[Script]
http-request = script-path=https://example.com/a.js, requires-body=true
```

`[MITM] enable` is applied. `hostname`, `tcp-connection`, `skip-server-cert-verify`,
`ca-passphrase`, `auto-quic-block`, `use-default-ca` and `client-source-address` are
parsed and validated but not consumed yet, so each one produces a `notApplied`
warning — the document says what it wants, and the app says what it does.

`[Script]` declarations are parsed and validated (a script without `script-path` is
an error, request/response phases require a pattern) but scripts are not installed
by this build; every script produces a `notApplied` warning. The script runtime
work is tracked separately from the text configuration milestone.

## Diagnostics

`ConfigurationDiagnostic` carries severity, a stable `code`, an optional line and
section, and a message. `TextConfigurationPipeline.Result.diagnosticsByLine`
groups them for an editor gutter.

| Code | Severity | Meaning |
| --- | --- | --- |
| `duplicateSection` | error | the same section appears twice |
| `duplicateName` | info | duplicate node/group/member name |
| `duplicateFinal` | error | more than one `FINAL` |
| `finalNotLast` | error | `FINAL` is not the last rule |
| `groupCycle` | error | proxy groups reference each other in a cycle |
| `invalidSectionHeader` | error | `[...]` cannot be parsed |
| `invalidValue` | error | value has the wrong shape |
| `malformedRule` | error | rule line cannot be split into type/value/policy |
| `ruleValueTooLong` | error | rule value exceeds the 65 535-byte payload field |
| `missingEquals` | error | key line has no `=` |
| `missingRulePolicy` | error | rule has no policy |
| `missingValue` | error | key has no value |
| `notApplied` | warning | recognized, but this build does nothing with it |
| `unknownDirective` | warning | unsupported `#!`-style directive |
| `unknownGeneralKey` | warning | unrecognized `[General]` key |
| `unknownPolicy` | error | policy name is not a node, group, or built-in |
| `unknownProxyType` | error | proxy type has no outbound |
| `unknownSection` | info | section preserved but has no effect |
| `unsupportedRuleType` | info / warning | rule or group kind not compiled |
| `unsupportedRuleOption` | warning | rule option not compiled |
| `unresolvedPolicy` | error | referenced node/group/member does not exist |
| `reservedPolicyName` | warning | node/group named after a policy token (`DIRECT`, `REJECT`, `PROXY`), so rules pointing at it use the built-in action |
| `unusedProxy` | info | declared node that no rule or group references |

Errors block activation; warnings and info do not.


## Reload scopes

`ConfigurationReloadPlan` diffs the settings the document asks for against what
the engine is running, and classifies each change by what has to happen:

| Scope | Fields | What the app does |
| --- | --- | --- |
| `live` | `quic-policy`, `block-udp`, `block-webrtc`, `prevent-dns-leak`, `mitm`, `hide-vpn-icon`, `tun-included-routes`, `tun-excluded-routes`, `bypass-country`, `loglevel` | nothing: `ConfigurationCoordinator` announces the change, `RuntimeCoordinator` turns the announcement into `TunnelStack+Runtime.reloadSettings()` and the other reload steps |
| `stackRestart` | `proxy-mode`, `dns-mode`, `dns-server`, `encrypted-dns-server` | extension rebuilds its data plane in place |
| `reconnect` | `include-all-networks`, `exclude-local-network`, `include-apns`, `include-cellular-services` | host reconnects so the packet-tunnel preferences are rewritten |

Rule, node, group and `[Host]` changes are not part of the plan: they travel
through `routing.bin`, `ActiveConfiguration` and `DNSHosts`, all of which the
extension picks up from a darwin notification without a disconnect.

`Outcome.requiresReconnect` tells the editor whether to offer a reconnect prompt
after activation.

## Announcements

The host never posts a notification by name. `ConfigurationCoordinator` decides
which announcements an activation owes — `settings` whenever any `[General]`
value changed, `mitm` when the changed keys belong to interception — and
`ConfigurationInstaller` posts exactly that list.

The extension half is `RuntimeCoordinator`. It turns each announcement back into
an ordered plan of reload steps (`reloadHostMappings`, `reloadSettings`,
`reloadRouting`, `reloadMITM`, `reloadActiveConfiguration`, `revalidateQUIC`)
and skips the steps that only make sense while the tunnel is running — only the
host-cache invalidation runs in every phase, so a stale `[Host]` override cannot
survive a start. A test holds the two tables against each other: a notification
the host can post that no event recognizes fails instead of waking the tunnel for
nothing.

## Activation lifecycle

1. `ConfigurationActivation.saveDraft` stores the editor text (errors allowed).
2. `ConfigurationActivation.activate(text:)` compiles, refuses to continue while
   errors remain, freezes a snapshot, and points the manifest at it.
3. `ConfigurationInstaller.install(_:)` reconciles nodes, groups and rule sets,
   replaces `[Host]`, applies settings, keeps one node selected, and writes
   `installation.json`.
4. `StoreMutationReaction` / `RoutingExportScheduler` rebuilds `routing.bin` and
   posts `routingChanged`, so the tunnel reloads rules live.
5. The extension installs the payload and writes `engine-confirmation.json`.
6. `isActiveSnapshotConfirmed()` compares steps 2 and 5. Anything else means the
   editor should show "activated, not yet confirmed".

If step 3 fails, the installer records the reason, rolls the manifest back to the
previous snapshot, and installs that snapshot again, so the engine is never left
pointing at a document whose nodes are missing.

## Exporting the current setup

`ConfigurationExporter` is the other direction: it renders what the app already
holds as a text document, so switching to the text configuration starts from the
user's existing nodes, groups, rules, host overrides and settings instead of an
empty editor.

```swift
let result = ConfigurationExporter.exportCurrentConfiguration(container: appContainer)
// result.text    — the document
// result.notes   — everything the stores held that the document cannot express
// result.counts  — nodes / groups / rules / hosts written
```

What it will and will not do:

- Only what the engine can act on is written. Chains, chain groups, module rule
  sets, rule sets with no assigned policy, group members that are not exported,
  and nodes without a share link are listed in `notes` instead of being turned
  into something they are not. An unassigned rule set is *matched but decides
  nothing* in the engine, which no text rule can say.
- Names that cannot survive `Name = value` parsing or comma lists (`=`, `,`,
  `#`) are sanitized, and duplicates are numbered, because a duplicate name is an
  error on the way back in. Names that collide with a policy token
  (`DIRECT`, `REJECT`, `REJECT-TINYGIF`, `PROXY`) are suffixed too, since such a
  node could never be referenced by a rule; both kinds of rename are listed in
  `notes`.
- `[Host]` comes from the DNS override table. `[MITM]` comes from the enabled MITM
  rule sets' host list and is left out entirely when MITM is enabled but lists no
  host, since `enable = true` with an empty `hostname` is an error.
- The generated `FINAL` uses `PROXY`, which is the engine's terminal action (the
  selected node); `Options.finalPolicy` overrides it.

The output is Surge-style INI — the section names and rule tokens that
`SurgeConfigurationParser` reads, so an exported document is a document this app
imports back. No section is generated that the parser keeps but the engine does
not act on (`[Script]`, `[URL Rewrite]`, `[Header Rewrite]`), and none for data
the stores do not hold. Export is *this app's* format only: it is not aimed at
another client's dialect, and no other client's proprietary sections exist in
the stores to write.

`ConfigurationExporterTests` round-trips every fixture through
`TextConfigurationPipeline.process(text:)` and asserts zero errors, so an export
that drifts away from the parser fails a test rather than a user's activation.

## Editing inside the app

Two pieces, split on purpose:

- `RuleProxy/Views/Pages/Profile/ProfileView.swift` — a renderer. It draws the
  editor, the counts, the diagnostics, the reload notice, the actions and the
  applied-document list, and nothing else.
- `Shared/ViewModels/ProfileEditorModel.swift` — the session state machine
  (buffer, preview, draft, dirty flag, apply, import, revert, discard, status and
  error). It talks to the pipeline through the small `ProfileEditing` protocol, so
  it can be exercised without SwiftUI, an App Group container or a tunnel;
  `ConfigurationDocumentOperations` is the implementation used in the app.
- `ConfigurationDocumentOperations` (`Shared/Operations/`) remains the two-way
  bridge. Both directions run on the same pipeline as every other importer —
  there is no second code path.

The naming is deliberate: in this project `Configuration…` means a *proxy node*
(`ProxyConfiguration`, `ConfigurationStore`), while the *profile* is the single
text document that describes the whole setup. Keeping the new session layer under
`Profile…` leaves room for the profile to become the source of truth.

| Direction | Entry point | What is written |
| --- | --- | --- |
| stores → text | `exportCurrent()` (`ConfigurationExporter`) | the editor buffer only |
| text → stores | `apply(_:)` (`ConfigurationInstaller.activate(text:)`) | stores, snapshot, `routing.bin` |

How the screen behaves:

- The buffer *is* the document. Every edit recompiles it after a 250 ms pause
  (`TextConfigurationPipeline.process`), refreshes the counts and the diagnostic
  list, and saves `draft.txt`. Editing never installs anything. The debounce lives
  in `ProfileEditorModel` (`previewDelay`), not in the view, so a second surface
  (deep link, tvOS, tests) behaves identically.
- "Apply to App" stays disabled while the compile has errors, so a broken
  document cannot replace a working one. A refused apply keeps the buffer and the
  baseline untouched and only sets `errorMessage`. On success the footer shows
  `ConfigurationInstaller.Outcome.summary`, the applied-document list picks up the
  new snapshot, and the buffer becomes the new baseline (so "unsaved" clears).
- The "Last Apply" section lists the changes from `ConfigurationReloadPlan` with
  their scope (`Applies immediately` / `Restarts the tunnel data plane` /
  `Requires reconnect`) plus the matching one-line instruction. This is the
  information the installer already computed but the page used to drop.
- Unsaved changes are visible twice: an "Unsaved" marker in the section header and
  a footer line comparing the buffer with the applied document. "Discard Changes"
  appears only while the buffer differs and restores the applied text.
- "Load from Current Setup" renders the live stores, so editing starts from what
  the app already runs instead of the starter template. Export notes (chains,
  chain groups, module rule sets, unassigned rule sets) are shown under the
  result rather than being dropped.
- "Import File" only loads a picked file (UTF-8, 1 MB cap) into the buffer;
  applying stays a separate, explicit press. A file that cannot be read leaves the
  buffer exactly as it was. "Export File" shares the buffer text through the
  system share sheet.
- Rows in "Applied Documents" put that snapshot's text back in the editor for
  review; applying it again is still an explicit press.
- Applying is an ordinary store mutation, so `StoreMutationReaction` →
  `RoutingExportScheduler` rewrites `routing.bin` and the tunnel reloads by the
  scope in `ConfigurationReloadPlan`; a changed node still needs a reconnect.

What this is deliberately not:

- No auto-apply while typing, and no file watcher. Applying stays an explicit
  press; the profile is written into the stores through the same installer every
  other path uses, so nothing can change the running configuration invisibly.
- `draft.txt` is not an open-in-place document. `LSSupportsOpeningDocumentsInPlace`
  stays `NO`, so the file cannot be edited from the Files app behind the app's
  back; the editor is the only writer.
- There is still no structured (form-based) editor for individual nodes, groups
  or rules — those are edited in their own screens, and the document is generated
  from them on demand.

### Where this is heading

The profile is meant to become the place configuration is *written*, with the
per-feature pages shrinking to what text cannot express. That direction is only
taken one capability at a time, and each step needs the same two things:

1. **The profile can express it completely.** A page is only retired after the
   parser, compiler, installer and exporter round-trip its capability with no
   silent loss; otherwise deleting the page would delete the feature.
2. **It survives `Load from Current Setup` → `Apply`.** Export notes must be
   empty for that data, or the edit would disappear on the next profile write.

So the remaining gaps listed under "Known gaps" (ordered rules and `FINAL` in the
payload, `[Proxy Group]` types, `[MITM] hostname`, `[Script]`) are prerequisites,
not follow-up work: they are the features whose pages still have no textual
equivalent. What stays on a page even afterwards is state that is not
configuration of the tunnel — latency results, the current node selection,
appearance, certificate trust and install flows — because those describe the
session and the device, not the profile.

## Limits

| Limit | Value | Source |
| --- | --- | --- |
| Rules per rule set | 200 000 | `CustomRoutingRuleSet.maxRuleCount` |
| Rule value in the payload | 65 535 UTF-8 bytes | `RoutingBinaryFormat` (`valueLen` is `UInt16`) |
| Rule set name in the payload | 64 characters | `RoutingExportOperation` (`prefix(64)`) |
| Snapshots kept | 20 (+ active and rollback target) | `ConfigurationSnapshotStore.retainedSnapshotCount` |
| Editor edit payload | ~6 000 characters per call | `ConfigurationDocumentEditing` helpers |

The routing payload writer (`RoutingBinaryWriter.encode`) skips a rule whose value
is longer than its `UInt16` length field, and truncates a rule-set name to 64
characters. Validation therefore rejects an over-long value up front
(`ruleValueTooLong`) instead of letting the rule vanish between activation and the
tunnel; a long name only loses its tail in logs and match attribution.

## Known gaps

These are deliberate, documented gaps, not silent failures:

- **Ordered payload.** `OrderedRouteMatcher` and `CompiledConfiguration.orderedRules`
  exist and are used by previews, but `RoutingBinaryFormat` still carries the
  tiered, one-policy-per-rule-set model. Until the payload carries rule order,
  FINAL, GeoIP/GeoSite and the extra rule types, the tunnel keeps using
  `TieredRouteMatcher`; the editor reports those rules as not compiled.
- **Geo databases.** Explicit external V2Ray GeoIP/GeoSite and CIDR/domain text
  sources are downloaded and validated on apply, pinned into runtime versions,
  and indexed at compilation/decode. Refresh is manual; performance and runtime
  acceptance are unverified. See [Geo databases](GeoDatabases.md).
- **Scripts.** `[Script]` is parsed and validated only.
- **MITM host list.** Only `[MITM] enable` is applied; the certificate and host
  fields are stored and reported.
- **`loglevel`.** Recorded, not applied.
- **macOS.** No macOS target exists yet; this document covers iOS, iPadOS and
  tvOS builds.

