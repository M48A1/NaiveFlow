# Text Configuration — Developer Guide

NaiveFlow can drive nodes, proxy groups, rules, host overrides and global
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
     → ConfigurationPublisher   (immutable runtime bundle + snapshot + manifest)
     → RuntimeCoordinator       (DNS / Rule / MITM / Outbound switch together)
```

Entry point for editors and importers is `TextConfigurationPipeline.process(text:)`.
`ConfigurationImport.read(from:)` turns a picked file into text (UTF-8 only, 16 MiB
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
| `runtime-v2/head.json` | host app | current and previous complete runtime versions |
| `runtime-v2/<uuid>.json` | host app | schema-2 immutable bundle and integrity digest |
| `engine-confirmation.json` | extension | the snapshot the engine is actually running + engine version |

A configuration runs only after its text document is applied. Runtime bundles
require a snapshot ID and ordered rules. Earlier bundle schemas are rejected.

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
| `lan-proxy-enabled` | boolean | live | false vetoes local LAN SOCKS5 sharing; true permits the local switch |
| `proxy-mode` | `rule`, `global`, `direct` | data-plane restart | applied |
| `quic-policy` | `automatic`, `blocked`, `unblocked` | live | applied |
| `block-udp` | boolean | live | applied |
| `block-webrtc` | boolean | live | applied |
| `prevent-dns-leak` | boolean | live | applied |
| `hide-vpn-icon` | boolean | live | applied |
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
| `allow-insecure` | boolean | — | removed; configure each node with `skip-cert-verify` |
| `trusted-certificate` | comma list of SHA-256 fingerprints | — | removed; use node `server-cert-fingerprint-sha256` |
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
| `http` | http | `username`, `password`, `tls` |
| `direct` | direct | no server needed |

Option names are translated (`id` → `uuid`, `sni`/`peer` → `servername`,
`ws` → `network`, `ws-path` → `path`, `ws-headers` → `host`, `cipher`/`method` →
`cipher`, `aead` → `aead-method`, `public-key`/`short-id` → `reality-opts`).
TLS nodes accept `skip-cert-verify=true|false` (default `false`) and optional
`server-cert-fingerprint-sha256` (64 hexadecimal characters). A configured
fingerprint must match the leaf certificate, including when `skip-cert-verify`
is true. Without a fingerprint, normal system trust is used unless that node
explicitly disables validation. These exceptions never apply to other nodes,
subscription downloads, or MITM root certificate management.

The node editor exposes **Verify Server Certificate** and **Certificate SHA-256
Fingerprint**. XHTTP download endpoints have their own fields. A malformed
fingerprint prevents saving. Existing JSON without these fields defaults to
system verification. Share links and saved JSON preserve each node's settings.
Legacy global trust values remain stored for reference but have no effect;
re-enter exceptions on the relevant nodes. Global `[General] allow-insecure` and
`trusted-certificate` are recognized as removed settings and block activation.
The separate Trusted Certificates page has been removed.

Options this build cannot express (`udp`, `udp-relay`, `tfo`,
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
rewrite = type=http-response, pattern=^https://example.com/, script-path=https://example.com/a.js, dialect=surge
qx-rewrite = type=http-response, pattern=^https://example.org/, script-path=https://example.org/qx.js, dialect=quantumult-x
```

Request/response scripts are validated and resolved before publishing. The runtime
version fixes the source bytes, argument and dialect. `dialect` accepts `surge`
(default when omitted) or `quantumult-x`; invalid values block activation.
Both dialects share the same runtime services and memory limits. Dialect is never
inferred from source. Existing QX scripts must specify it explicitly.

Exported `[MITM Set]` JSON retains each script’s dialect. See [MITM](MITM.md) for supported operations.

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

Every publication switches one complete runtime version. Changes to connection-level
Network Extension preferences reconnect the provider; other changes rebuild the data
plane in place. The host announces only `configurationVersionChanged`.

## Activation lifecycle

1. Save the draft and compile the complete document.
2. Resolve scripts, rule sets and Geo resources, then validate their fixed bytes.
3. Capture document settings over clean built-in defaults; omitted settings reset.
4. Publish the immutable schema-2 bundle and atomically advance its head.
5. The extension validates and installs DNS, Rule, MITM and Outbound together.
6. Confirm the exact version with a receipt, or restore the previous text version.

The first publication has no previous version. Startup requires an applied text
configuration. See [ConfigurationArchitecture.md](ConfigurationArchitecture.md).

## Exporting the current setup

`ConfigurationDocumentOperations.exportCurrent()` returns the applied text document,
or the starter template when no document has been applied. It reads no manual
configuration stores.

## Editing inside the app

`ProfileView` renders `ProfileEditorModel`, which owns the draft, preview, apply,
import, history and rollback actions. Editing saves a draft; Apply publishes a
complete version. Importing a file loads text for review. iCloud Drive exchanges
text files between devices. MITM certificate installation is available from this
page; interception rules and settings belong to the document.

## Limits

| Limit | Value |
| --- | --- |
| Text document | 16 MiB |
| Ordered runtime rules | 100 000 |
| Script source | 1 MB |
| Runtime bundle | 64 MiB |
| Retained runtime versions | 20, subject to 256 MiB total |

## Known gaps

External Geo resources refresh on explicit Apply. Unsupported rule metadata and
settings fail validation. See [ConfigurationArchitecture.md](ConfigurationArchitecture.md)
for supported native capabilities and [MITM.md](MITM.md) for script behavior.

### 代理组第三方图标

`[Proxy Group]` 支持 `icon-url`，用于 iPhone 与 macOS 策略页的组图标。例如：

```ini
[Proxy Group]
Streaming = select, Relay, DIRECT, icon-url=https://example.com/icons/streaming.png
```

填写 HTTPS 图片直链，支持 PNG、JPEG 等系统可解码的图片；不支持 SVG。URL 中包含逗号或 `#` 时加双引号。图标随组保存、同步与导出；手动组可在编辑器中修改地址，文本配置组通过编辑配置修改。图片由应用界面按需加载，失败时使用默认文件夹图标，不参与分流和节点测速。图标元数据随当前格式的完整运行版本发布。

图标加载限制：单个文件不超过 2 MiB，原图宽高各不超过 4096 像素；应用只保留最长边 128 像素的缩略图，解码缓存预算为 1 MiB，最多同时下载 4 个图标。超限使用默认图标。此限制针对图片资源，不代表应用或 VPN 进程的内存总量上限。
