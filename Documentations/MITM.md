# MITM Rewrite System — Developer Guide

NaiveFlow can intercept the HTTP traffic of selected domains — terminating TLS
for HTTPS, or reading plain HTTP directly — then inspect, rewrite, and forward
it upstream: a man-in-the-middle on traffic you control. This guide covers
authoring rules and scripts. It assumes familiarity with HTTP, regular
expressions, and JavaScript, and does not cover the settings UI.

> **Prerequisite (HTTPS only).** Intercepting **HTTPS** works only for clients
> that trust NaiveFlow's generated root CA — install and trust it first. Apps
> that pin certificates cannot be intercepted (their handshake to the minted
> leaf fails); this is expected. Plain **HTTP** carries no certificate and needs
> no CA trust.

## DNS scope

Application-owned DoH and DoH3 are routed as ordinary HTTPS and QUIC traffic.
A dedicated MITM DNS handler that decrypts queries, performs replacement DNS
lookups, and synthesizes DoH responses is out of scope, rather than a pending
feature. DNS routing does not automatically enable MITM or require a CA.
General HTTP rewrite and script features remain controlled by explicit MITM
configuration. The core's own DoH upstream resolver is retained separately;
see [DNS configuration](DNSConfiguration.md).

## Contents

- [How it works](#how-it-works)
- [Rule sets](#rule-sets)
- [The import format](#the-import-format)
- [Rule operations](#rule-operations)
- [Subscriptions](#subscriptions)
- [Behavior reference](#behavior-reference)

## How it works

Interception is gated on the host. **HTTPS** is intercepted when the TLS
ClientHello **SNI** matches a rule set's suffixes; **plain HTTP** is intercepted
when the first request's host matches — the domain behind the synthetic
address when the connection was routed by one, otherwise the request's
authority (absolute-form target, or the `Host` header). MITM must be enabled by
the master toggle, and the matching rule set must be enabled.

An intercepted **HTTPS** connection is handled in four steps:

1. Mint a leaf certificate for the requested host (cached, per host) and
   complete the **inner** TLS handshake with the client, negotiating ALPN from
   the client's own offer (intersected with `h2` / `http/1.1`). If the client
   offers both and this `host:port` has answered an earlier probe with
   HTTP/1.1, only `http/1.1` is offered.
2. Read the first request and apply the matching rules. A `rewrite` rule can
   answer on the inner leg (302 / reject — no upstream) or change the
   destination host.
3. **Defer** opening the **outer** leg until the destination is known, then dial
   it — the rewritten host when set, otherwise the original — and run its own TLS
   handshake. An HTTP/1.1 client goes to an HTTP/1.1 upstream; an HTTP/2 client
   is **bridged** to whatever the upstream speaks: HTTP/2 directly, or HTTP/1.1
   with on-the-fly translation.
4. Decrypt each direction, run the matching rules, and re-encrypt to the
   opposite leg.

**Plain HTTP** follows the same pipeline without certificates or handshakes: the
upstream is dialed in cleartext, and the script request URL carries an `http://` scheme.
Cleartext is always treated as HTTP/1.1 — h2c is not intercepted (prior-knowledge
h2c is forwarded untouched; an `Upgrade`-based `101` becomes an opaque tunnel,
see [Behavior reference](#behavior-reference)).

Traffic is processed in two **phases**:

- **Request** (`httpRequest`) — client→server, before the request leaves for
  upstream.
- **Response** (`httpResponse`) — server→client, before the response reaches the
  client.

Both HTTP/1.1 and HTTP/2 are supported. For HTTP/2 the rewriter works on decoded
header lists and whole-body buffers; for HTTP/1.1 it drives a byte-level framing
state machine. The rule model is identical either way.

A rule set's `hostname` suffixes gate **which hosts** are intercepted; each
rule's `url-pattern` gates **which requests** within those hosts it acts on. A
request that matches no rule is forwarded unchanged (its body streamed through
unbuffered), so an intercepted-but-unrewritten request is cheap — but
interception itself (the extra TLS handshakes) is not. Scope `hostname` as
tightly as you can.

> **Performance note.** Scripts share one serial executor and one JavaScript VM.
> JavaScriptCore interrupts a synchronous span after at most 30 seconds of
> execution. A failed invocation forwards the input to the script. On systems
> without the JavaScriptCore execution-limit entry point, script rules pass
> through. Asynchronous HTTP callbacks release the executor while waiting.
> Imported Surge modules can set a per-invocation `timeout` in seconds, capped
> at 180 seconds. Reimport existing modules to pick up this setting.

---

## Rule sets

A rule set is the unit of configuration:

| Field            | Meaning |
| ---------------- | ------- |
| `name`           | Display name. |
| `domainSuffixes` | Hosts to intercept, matched by **suffix**. `example.com` covers `www.example.com`. No wildcards. |
| `enabled`        | Per-set toggle; a disabled set is skipped but keeps its data. |
| `rules`          | Ordered list of rewrite rules. Redirect / reject / host-rewrite are per-rule via the [`rewrite` operation](#rewrite-0--request-only). |
| `parameters` | Legacy metadata retained for round trips; the former script API is removed. See [Parameter lines](#parameter-lines). |

Suffix matching is **most-specific-wins**: with both `example.com` and
`api.example.com` configured, a request to `api.example.com` uses only the
latter. Each connection resolves to exactly one rule set, once, at connection
start — a transparent rewrite to another host does not re-resolve it. Duplicate
suffixes across sets are last-writer-wins.

Rule sets are created three ways: built rule-by-rule in the app, **imported**
from a `.amrs` file, or **subscribed** to a `.amrs` URL (see
[Subscriptions](#subscriptions)). The `.amrs` text format below is the
interchange and authoring format; sets are stored internally as JSON and
exported to the Network Extension as a compact binary. A set holds at most
**10,000 rules** and **256 parameters**.

---

## The import format

A rule set is a sequence of **header lines**, **rule lines**, and (optionally)
**parameter lines**, in any order. Blank lines are ignored; lines beginning with
`#` or `//` are comments. Parsing never hard-fails — a line that is neither a
recognized header nor a valid rule/parameter is dropped silently, so a partially
valid file still imports what it can.

Lines belong to a **section** introduced by a bracketed header. Sections are
optional and a file starts in `[Rule]`. `[Parameter]` begins the parameter
section; an unrecognized bracket header makes following lines ignored until the
next section.

```
# A complete example
name        = My Rule Set
hostname    = example.com, api.example.org

# request: transparently rewrite the whole URL to a new host (dials it + rewrites Host)
0, 0, ^https://example\.com/old, 0, https://upstream.example.com/new
# request: add a header on /api/ paths
0, 1, ^/api/, X-Powered-By, NaiveFlow
```

### Header lines

Shape: `<key> = <value>`. Keys are case-insensitive; the value is trimmed and
otherwise kept verbatim. Header lines are recognized in any section.

| Key          | Meaning |
| ------------ | ------- |
| `name`       | Display name. |
| `hostname`   | Comma-separated domain suffixes. |
| `icon-light` | Base64-encoded image bytes for the icon shown in light appearance. |
| `icon-dark`  | Base64-encoded image bytes for the icon shown in dark appearance. |

Lines with unrecognized keys are dropped. Redirect / reject / host-rewrite are
configured per-rule via the [`rewrite` operation](#rewrite-0--request-only), not
as headers. An icon that is not valid base64 or decodes to more than **256 KB**
is dropped; when the current appearance has no icon, the other variant is used.

### Rule lines

Shape:

```
<phase>, <operation>, <field1> [, <field2> [, <field3>]]
```

- **Phase**: `0` = request, `1` = response.
- **Operation** and its trailing fields:

| ID    | Operation        | Phase        | Fields |
| ----- | ---------------- | ------------ | ------ |
| `0`   | `rewrite`        | request only | `url-pattern`, `sub-mode`, `<sub-mode args>` |
| `1`   | `header-add`     | both         | `url-pattern`, `name`, `value` |
| `2`   | `header-delete`  | both         | `url-pattern`, `name` |
| `3`   | `header-replace` | both         | `url-pattern`, `name`, `value` |
| `4`   | `body-replace`   | both         | `url-pattern`, `search`, `replacement` |
| `5`   | `body-json`      | both         | `url-pattern`, `action`, `<action args>` |
| `100` | `script`         | both         | `url-pattern`, `base64`, optional `surge` / `quantumult-x` |
| `101` | removed Anywhere streaming ABI | unsupported | rejected |

Scripting uses a separate `100`+ id range. `rewrite` (op `0`) is always
request-phase regardless of the phase column; its second field is a numeric
**sub-mode** and the rest depend on it — see
[`rewrite` (0)](#rewrite-0--request-only). A rule whose field count does not
match, or whose `url-pattern` is empty or won't compile as a regex, is dropped.
`body-replace`'s `search` must also compile as a regex; `body-json`'s trailing
fields depend on `action`; `script` base64 must decode to
syntactically valid UTF-8 JavaScript (checked at import).

### Fields and quoting

Fields are separated by `,`. Whitespace around an unquoted field is trimmed. A
field beginning with `"` is read to the matching `"`, and `""` inside a quoted
field is a literal `"`. Quote any field containing a comma or significant
leading/trailing whitespace:

```
0, 1, ^/, X-Note, "value, with a comma"
```

### The `url-pattern`

Every rule leads with a `url-pattern`: an `NSRegularExpression` (default Unicode
semantics) tested against the **whole request URL** — e.g.
`https://api.example.com/login?token=abc`. It is purely a gate (the replace
operations carry their own `search`); it does **not** see the method or HTTP
version. Use `.*` to match every request, or anchor on scheme/host
(`^https://api\.example\.com/`) to scope by origin — but an intercepted
**plain-HTTP** URL has an `http://` scheme, so anchor on `^https?://` (or just
the host) when a set also covers cleartext. The **host** is matched
case-insensitively (lowercased before the test); path and query keep their case.
A URL longer than 8 KB never matches, and if the URL can't be determined the
gate fails closed (the rule is skipped).

For **response**-phase rules the gate is tested against the **originating
request's** URL (response heads carry no path) — specifically its post-rewrite
URL — so a request and its response can share a pattern.

### Parameter lines

Legacy `[Parameter]` metadata remains readable and round-trippable, but its
removed `NaiveFlow.params` script API is unavailable. For retained text scripts,
use the `[Script]` `argument` option, exposed as `$argument`.

## Rule operations

### `rewrite` (0) — request only

Its second field is a numeric **sub-mode**; the rest depend on it. When the
`url-pattern` gate matches, the **first** `rewrite` rule that resolves wins (a
rule that matches but fails to expand its target is skipped, so a later rule can
still win).

| Sub-mode | Name             | Args          | Effect |
| -------- | ---------------- | ------------- | ------ |
| `0`      | transparent      | `<full-url>`  | Replace the whole request URL. The request-target becomes the replacement's path+query (empty path → `/`, fragment dropped); the outer leg dials the replacement **host** and `Host` / `:authority` is rewritten to match. The client still sees the **original** host on the leaf certificate. Scripts receive the request URL through `$request.url`. |
| `1`      | 302 redirect     | `<full-url>`  | Synthesize `302 Found` with `Location: <full-url>` (verbatim). No upstream dial. |
| `2`      | reject 200 text  | `[<content>]` | Synthesize `200 OK`, `text/plain; charset=utf-8`. Empty → a short default line. No upstream dial. |
| `3`      | reject 200 gif   | *(none)*      | Synthesize `200 OK` with a canned 1×1 `image/gif`. No upstream dial. |
| `4`      | reject 200 data  | `[<base64>]`  | Synthesize `200 OK`, `application/octet-stream`, body decoded from `<base64>`. Empty → a default payload. No upstream dial. |

For sub-modes `0` and `1` the URL must be a full absolute URL with a host
(validated at import). The replacement supports **capture references** to the
`url-pattern` match: `$0` is the whole match, `$1`–`$9` (and `${10}`, `${11}`, …)
are groups, `$$` is a literal `$`. A replacement with no reference is used
verbatim. References resolve **per request**, so one pattern with capture groups
can rewrite many URLs; a non-participating group expands to empty, and if the
expanded URL isn't a valid absolute URL the rule is skipped for that request.

A transparent rewrite can change the dial target, so the upstream dial is
**deferred**: the inner handshake completes, the first request is read and
rewritten, and only then is the upstream dialed. Consequences for divergent
targets on one connection:

- **HTTP/1.1** fixes its single upstream leg on the first request. A later
  request whose rewrite resolves a *different* host is reconnected transparently
  **if the leg is idle** (no response in flight); if a response is still in
  flight the connection is torn down and the client retries on a fresh one.
- A **bridged HTTP/2** client with an **HTTP/1.1** upstream dials per stream, so
  each stream generally follows its own resolved host. With an **HTTP/2**
  upstream, the connection is committed on the first request and later streams go
  to that committed upstream regardless of their rewrite.

Either way, avoid splitting one origin's traffic across several transparent
target hosts.

```
0, 0, ^https://a\.example\.com/, 0, https://b.example.com/
0, 0, ^https://old\.example\.com/(.*), 0, https://new.example.com/$1
0, 0, ^https://old\.example\.com/page, 1, https://new.example.com/page
0, 0, .*/ads/, 3
```

### `header-add` (1)

Appends a header (does not replace an existing one of the same name):

```
0, 1, .*, X-Trace-Id, naiveflow
```

### `header-delete` (2)

Removes every header with the given name (case-insensitive):

```
1, 2, .*, Set-Cookie
```

> Unlike `header-add` / `header-replace`, which reject framing and hop-by-hop
> header names at load, `header-delete` is **not** guarded — deleting
> `Content-Length` or `Transfer-Encoding` changes how the body is framed. Don't.

### `header-replace` (3)

Overwrites the value of every header with the given name (case-insensitive), and
normalizes the name's spelling to the rule's. A header that is not present is
left alone — it does **not** add it:

```
1, 3, .*, Cache-Control, no-store
```

### `body-replace` (4)

Regex find-and-replace over the text body in **native code**, no JavaScript. Its
fields are `url-pattern`, a `search` regex, and a `replacement`:

```
1, 4, .*, http://, https://
1, 4, .*, (?i)debug=true, debug=false
1, 4, .*, (\d{4})-(\d{2})-(\d{2}), $3/$2/$1
```

`search` is an `NSRegularExpression` matched against the **whole decompressed body**,
and every match is replaced. `replacement` supports the same capture references
as `rewrite`; an **empty** replacement deletes matches. A rule whose `search` is
empty or won't compile is dropped. Quote a field containing a comma or leading `"`,
doubling inner quotes — so the literal `"price":` is written `"""price"":"`.

The body is decoded as UTF-8, with a Latin-1 fallback that accepts **any** byte
sequence — there is no charset detection. A non-UTF-8 body (UTF-16, GBK, …) is
therefore seen as Latin-1 and round-trips only because nothing matches; a pattern
that *does* match such a body can corrupt it. Use `body-replace` on UTF-8 text.

Like `script`, `body-replace` is a **buffered** transform: the body is
accumulated (auto-decoding `gzip` / `deflate` / `br`, up to **4 MiB**), edited,
and re-emitted with a fresh `Content-Length`. The contract is otherwise
**total** — a `search` that matches nothing, or a `replacement` unrepresentable
in the body's bytes, leaves the body unchanged. **Every** matching `body-replace`
rule fires, in rule order, so replacements compose.

When several body transforms match one message they run in a fixed order:
`body-json` first, then `body-replace`, then a `script` (so the script sees the
fully-edited body).

### `body-json` (5)

Declarative JSON body editing in **native code** — the same edits as the
former native JSON script helpers, without JavaScript. One rule, one
edit; fields are `url-pattern`, an `action` token, and the action's fields:

| `action`                  | Trailing fields           | Effect |
| ------------------------- | ------------------------- | ------ |
| `add`                     | `path`, `value`           | Upsert at `path` (create or overwrite; append at array end when index == length). |
| `replace`                 | `path`, `value`           | Overwrite at `path` only if the member/index already exists. |
| `delete`                  | `path`                    | Remove the member/element at `path`. |
| `replace-recursive`       | `key`, `value`            | Overwrite every property named `key` at any depth. |
| `delete-recursive`        | `key`                     | Remove every property named `key` at any depth. |
| `remove-where-key-exists` | `path`, `key`             | At the array at `path`, drop objects containing `key`. |
| `remove-where-field-in`   | `path`, `field`, `values` | At the array at `path`, drop objects whose `field` ∈ `values`. |

`path` is a JSONPath like `$.data.items[0].id` (leading `$` optional; dotted keys
and `[index]` / `["key"]` brackets; an empty path or `$` addresses the whole
document). `value` / `values` are JSON literals (`true`, `42`, `"text"`,
`{"a":1}`, `["x","y"]`); a string that **isn't** valid JSON is taken literally,
so `value = NaiveFlow` means `"NaiveFlow"`. Action tokens are case-insensitive and
accept the camelCase spelling. A rule whose `path` can't be parsed is dropped.

Like `script`, `body-json` is a **buffered** transform (auto-decoding, 4 MiB
cap). The contract is **total** — a body that isn't JSON, a path that doesn't
resolve, or an unserializable result leaves the body **byte-for-byte** unchanged.
A *successful* edit re-serializes the whole document, so object member order is
not preserved and slashes are not escaped. **Every** matching `body-json` rule
fires in rule order; a matching `script` runs after them.

```
1, 5, ^/api/user, add, $.user.vip, true
1, 5, ^/api/user, delete, $.user.password
1, 5, ^/api/feed, remove-where-field-in, $.items, status, expired
```

A `value` / `values` containing a comma must be one quoted CSV field with inner
quotes doubled:

```
1, 5, ^/api/feed, remove-where-field-in, $.items, status, "[""expired"",""deleted""]"
1, 5, ^/api/profile, add, $.meta, "{""beta"":true,""tier"":2}"
1, 5, ^/api/profile, replace, $.tier, "gold, platinum"
1, 5, .*, replace-recursive, access_token, "***"
```

### `script` (100): Surge / Quantumult X

Only buffered Surge and Quantumult X scripts are supported. Scripts execute at
 top level and complete with `$done(...)`, including asynchronous HTTP callbacks.
Use `$request` / `$response` for context. Surge provides `$httpClient`,
`$persistentStore`, `$notification`; Quantumult X provides `$task.fetch`,
`$prefs`, `$notify`. Common adapters include console logging, timers, UTF-8
encoding/decoding, URL query handling, base64, gzip decoding and binary bodies.
Quantumult X `$done({bodyBytes: ...})` accepts ArrayBuffer or typed-array binary
edits, including gRPC responses. Module URL imports download script dependencies
and preserve the chosen dialect.
The supported subsets still require real-script acceptance
checks; this does not promise full compatibility with either client.

```javascript
const data = JSON.parse($response.body);
data.example = true;
$done({body: JSON.stringify(data)});
```

Anywhere's `process(ctx)`, `Anywhere.*`, `NaiveFlow.*` helpers and operation
`101` (`stream-script`) have been removed. Import/activation rejects legacy
scripts and streaming operations. Stored legacy records remain decodable for
clear diagnostics; they are not automatically converted. Replace their source
with a Surge or Quantumult X script. Runtime loading also refuses unsupported
legacy scripts.

Script dialect is explicit metadata, fixed into the published runtime version.
The default is **Surge**. Choose Quantumult X with `dialect=quantumult-x`:

```ini
[MITM]
hostname = example.com

[Script]
rewrite = type=http-response, pattern=^https://example.com/, script-path=https://example.com/surge.js, dialect=surge
qx-rewrite = type=http-response, pattern=^https://example.com/qx/, script-path=https://example.com/qx.js, dialect=quantumult-x
```

Only `surge` and `quantumult-x` are accepted. Omission defaults to Surge, even if
the source contains QX identifiers. Source contents no longer select a runtime.
For `.amrs` operation 100, an optional final field selects the dialect:
`1, 100, <pattern>, <base64>, quantumult-x`; omission also defaults to Surge.
Stored JSON script operations carry a `dialect` field; older records without it
load as Surge. Exports and immutable runtime versions preserve this choice.

Both adapters use the same JavaScriptCore VM, network routing, DNS, storage and
memory budget. Source syntax/legacy-ABI checks happen when the policy loads;
request execution reads the compiled dialect directly. There is no performance
claim without measurements, and neither adapter implies full client compatibility.

## Subscriptions

A subscription is a `.amrs` file served over **http(s)** from a URL whose path
ends in `.amrs`. NaiveFlow fetches it (HTTP 2xx, UTF-8 body required), parses it
with the format above, and stores it as a rule set.

On **refresh**, the suffixes, rules, parameters, and icons are **replaced**
wholesale by the fetched file. The set's local **name**, **enabled** state, and
subscription URL are preserved, as are parameter overrides that remain valid (see
[Parameter lines](#parameter-lines)). The **10,000-rule** cap applies; a file
that exceeds it is rejected in full. Imported (non-subscribed) sets are edited in
the app rule-by-rule.

---

## Single-rule semantics

At most one buffered script fires per message; the last matching script wins.
All matching static header/rewrite and body JSON/regex operations retain their
existing ordered behavior. The removed Anywhere streaming ABI does not run.

## Worked examples

### Inject a request header on API paths

```
name     = Add Trace
hostname = api.example.com
0, 1, ^/v2/, X-Trace-Id, naiveflow
```

### Redirect an old path, preserving the tail (transparent URL rewrite)

```
name     = Path Migration
hostname = example.com
0, 0, ^https://example\.com/old/(.*), 0, https://example.com/new/$1
```

### Block a host with a 1×1 GIF

```
name     = Block Tracker
hostname = tracker.example.com
0, 0, .*, 3
```

## Behavior reference

MITM still requires a matching hostname scope and trusted CA for TLS. Static
rewrites and native JSON/regex body rules remain available. Script support is a
subset of Surge / Quantumult X; unsupported source is rejected before activation.
Body and concurrency limits apply to both dialects. See the shared memory budget
below for overload behavior.

The temporary certificate profile server binds only to `127.0.0.1`. It accepts
at most four concurrent clients, limits request headers to 16 KiB, and closes
each client after five seconds. Only GET/HEAD requests for
`/NaiveFlowMITMRoot.mobileconfig` are served. Stopping the server closes all
clients; the endpoint expires after 120 seconds.


## Shared transient memory budget (2026-11-12)

MITM body buffering, native body edits, buffered script invocations, script HTTP
responses, HTTP/2 downstream pacing, pre-dial buffers and leg write queues now
compete for one process-local **24 MiB accounting budget**. Existing per-body,
per-stream, concurrency and fetch-byte limits continue to apply.

Body rewrite admission reserves room for the body and one decoded/transformed
copy. Unknown-length bodies reserve their allowed maximum before buffering.
Native JSON/regex work retains its existing workspace estimates. Buffered JS
invocations reserve estimated body-copy space plus context overhead; fetched
response copies retained by JS are charged to that invocation until its actual
lifetime ends. Native fetched responses carry their own lifetime reservation.
HTTP/2 flow-control backlogs and in-flight writer batches stay charged until
consumed, sent, failed or released.

If admission fails, body rewriting is skipped and existing framing forwards the
body. Script/native edit budget failures retain the unmodified message; script
HTTP failures reject the request. Writer or pre-dial overflow closes the affected
connection, and HTTP/2 downstream overflow resets the affected stream. These
paths log their reason. They do not silently change the selected network route.

This is payload/workspace accounting, **not a 24 MiB process footprint cap**.
JavaScript allocations unrelated to the accounted bodies, TLS/system buffers,
headers, allocator overhead and other tunnel modules remain outside this ledger.
Actual peak memory and throughput still require device measurements.
