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
- [Scripts](#script-100-surge--quantumult-x)
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

Import rewrite rules through a Surge module or Quantumult X rewrite snippet.
The importers support a subset of the two formats, including URL redirects,
selected rejects and header rewrites, and Surge `http-response-jq` deletion.
Module imports resolve script and response resources before activation.
The app shows the resulting rules in the module preview.

A rule set limits interception to its configured hostname suffixes. The
most specific suffix wins. Both the master MITM switch and the selected
rule set must be enabled.

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

## Single-rule semantics

At most one buffered script fires per message; the last matching script wins.
Imported header, URL, and supported JSON rewrites run in rule order.

## Behavior reference

MITM requires a matching hostname scope and trusted CA for TLS. Script support
covers a subset of the Surge and Quantumult X APIs.
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
