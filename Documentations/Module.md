# Modules — Developer Guide

A module bundles several **routing rule sets** and **MITM rule sets** into one
unit that is created in the app, **imported** from a Surge `.sgmodule` or
Quantumult X `.snippet` file, or **subscribed** to an HTTP(S) URL. It lets an author ship a complete behavior
for a service (what to proxy, what to block, what to rewrite) as a single
file, and lets a user switch all of it on or off, update it, or delete it in
one place. This guide covers the module model, supported import formats, and how a
module's rule sets take part in routing and MITM. It assumes familiarity with
the [Routing](Routing.md) and [MITM](MITM.md) guides, whose rule formats a
module reuses unchanged.

## Contents

- [How it works](#how-it-works)
- [The module](#the-module)
- [The import format](#the-import-format)
- [Subscriptions](#subscriptions)
- [Limits](#limits)
- [Worked example](#worked-example)
- [Behavior reference](#behavior-reference)

---

## How it works

A module **owns** its rule sets. They are stored inside the module record,
have no subscription URL, icon, or sync identity of their own, and are only
reachable through the module. One module is one sync item: it is written,
synced, and conflict-resolved as a whole, so another device never sees a
module with some of its rule sets missing.

When routing or MITM configuration changes, the app compiles two payloads for
the Network Extension, and a module's rule sets ride in the same payloads as
the standalone ones:

- **Routing.** Each routing rule set in an **enabled** module becomes one
  entry in the `ARB2` payload, exactly like a custom set: its assigned action
  places it in the **User** tier, and a set left on **Default** drops into
  **Neutral**. A disabled module contributes nothing. The entry carries the
  module-qualified name (`Module · Set`) so request logs can attribute a
  match.
- **MITM.** Each MITM rule set in an **enabled** module ships in the `AMR1`
  payload under its module-qualified name. A set is active only when both the
  module switch and the set's own switch are on, and only while MITM itself
  is enabled.

Where a module set and a standalone set tie exactly (an identical routing
pattern in the same tier, or the same MITM host suffix), the **standalone set
wins**: the user's own configuration beats anything distributed. Among
modules, the one higher in the Modules list wins, and within a module the set
listed first.

---

## The module

| Field             | Meaning |
| ----------------- | ------- |
| `name`            | Display name. Kept locally; a subscription refresh never renames the module. |
| `description`     | Optional one-line summary from the file, shown above the module's switch. |
| `enabled`         | Master switch. Off, the module's rule sets leave both payloads but keep their data. |
| `sourceFormat`    | Surge or Quantumult X; determines the parser used on refresh. |
| `subscriptionURL` | Set when the module was subscribed; its rule sets are then read-only. |
| `iconLight` / `iconDark` | Optional icons from the file, at most **64 KB** each. |
| `routingRuleSets` | Ordered list of `{ id, name, rules }`. |
| `mitmRuleSets`    | Ordered list of `{ id, name, enabled, domainSuffixes, rules, parameters, parameterValues }`. |

A rule set's `id` is stable across refreshes (see [Subscriptions](#subscriptions)),
which is what keeps its routing assignment, its switch, and its parameter
values attached. A module created in the app starts empty; add routing and
MITM rule sets from its Module Content page and edit them rule by rule, as
with standalone sets.

---

## The import format

Import Module opens a URL form with a Surge / Quantumult X picker. Importing
fetches the module and every referenced script/resource before committing it;
the URL and format are saved for refresh. Import Module File accepts `.sgmodule`
and `.snippet` files. File imports can reference absolute HTTP(S) script URLs.

Surge HTTP request/response scripts and Quantumult X `script-request-*`,
`script-response-*` and echo-response rewrites retain their explicit dialect. Quantumult X remote
`echo-response` resources preserve content types, extra headers and binary data;
`reject-dict` and `reject-array` produce empty JSON objects and arrays.
Surge `#!arguments` defaults fill template placeholders before `$argument` is
passed to the script. Binary body mode supplies `Uint8Array` data. Surge Map Local
responses (text, base64 and remote files) and simple `http-response-jq del(.path)`
rewrites are converted as well. Unsupported directives, download failures or
invalid JavaScript reject the whole import instead of saving partial content.

Shared downloads are fetched once per import/refresh. Module storage keeps a
compressed table of unique script sources; exported rules retain ordinary script
operations. Each downloaded source is limited to 4 MiB, and the final compressed
module still has to fit the sync limit. Refresh resolves the whole dependency
set again and commits only a complete, validated result.

HTTPS traffic requires MITM to be enabled and the CA certificate to be trusted.
These are buffered HTTP scripts; cron, DNS hooks and client-specific control APIs
are not implemented. Compatibility should be checked with real script samples.

---

## Subscriptions

A subscription serves Surge or Quantumult X content over **http(s)**.
NaiveFlow fetches it (HTTP 2xx, UTF-8 body required), parses it using the selected
format, validates the [limits](#limits), and stores the result as one module.

On **refresh** the file is fetched once and the module's content is replaced
as a whole, in one write:

1. Each incoming rule set is matched to the module's existing set of the
   **same kind and name** (duplicates pair up in order). A matched set keeps
   its `id`, so its routing assignment, its switch, and its parameter values
   survive. Parameter overrides are kept while the parameter still exists
   and, for a picker, still offers that value.
2. A set that appears for the first time gets a new `id` and, for a routing
   set, its `routing` seed.
3. A set that disappeared is gone, and its assignment is dropped.
4. The module's **name**, **switch**, and subscription URL are untouched; its
   description and icons are replaced.

A refresh whose result is identical to what is stored is a no-op. A file that
fails the limits is rejected in full and the stored module is left as it was.
A subscribed module's rule sets are read-only in the app: their switches,
parameter values, and routing assignments can be changed, their rules and
names cannot.

A module can also be offered through the `naiveflow://add-module?link=…` deep
link, where `link` is the subscription URL. The app offers Surge and Quantumult X
format selection, previews the module's rule sets and, on confirmation, subscribes
to it.

---

## Limits

| Limit                         | Value |
| ----------------------------- | ----- |
| Rule sets per module          | **64**, routing and MITM combined |
| Rules per routing rule set    | 100,000 (as for a standalone set) |
| Rules per MITM rule set       | 10,000, and 256 parameters (as for a standalone set) |
| Icon, per variant             | **64 KB** decoded |
| Encoded module                | **900 KB** of JSON |

The last line is the one to design for. A module syncs as a single record and
a record larger than the sync payload limit never leaves the device, so an
import or refresh that would exceed it is **rejected outright** rather than
stored in a state that silently stops syncing. Icons count toward the budget
at four thirds of their byte size (they are base64 inside the JSON); a
domain-suffix rule costs roughly 35 bytes.

---

## Worked example

A Surge `.sgmodule` file:

```ini
#!name=My Service
#!desc=Redirect API requests for My Service.

[URL Rewrite]
^https://api.myservice.example/v1/ https://api.myservice.example/v2/ 302

[MITM]
hostname = %APPEND% api.myservice.example
```

The equivalent Quantumult X `.snippet` rewrite:

```ini
^https://api.myservice.example/v1/ url 302 https://api.myservice.example/v2/
hostname = api.myservice.example
```

Each imports one module with one MITM rule set. Toggling the module off removes
its rules from the Network Extension; turning it back on restores them. MITM
must also be enabled for the rules to take effect.

---

## Behavior reference

- **One record.** A module and its rule sets are stored, synced, and merged
  as a single item; last writer wins for the whole module.
- **Module switch gates everything.** A disabled module contributes no
  routing entries and no MITM sets; a MITM set also needs its own switch.
- **Same tiers, same specificity.** Module routing sets load into User (or
  Neutral on Default) and compete by the rules in the Routing guide; on an
  exact tie a standalone set beats a module set, an earlier module beats a
  later one, and an earlier set beats a later one in the same module.
- **Standalone MITM wins duplicates.** For an identical host suffix the
  standalone set is the last writer and wins.
- **Assignments are per set and per device.** Kept across refreshes by name
  matching, dropped when the set disappears or the module is deleted, and
  reset to Default when the assigned proxy or chain is deleted.
- **Subscribed is read-only.** Rules and names come from the file; switches,
  parameter values, and assignments are yours.
- **Parameters are per module.** MITM parameters are merged by name across
  the module's sets and edited on the module page; one value feeds every set
  that declares the name.
- **Limits are hard.** A module that cannot sync is not imported.

