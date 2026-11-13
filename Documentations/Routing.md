# Routing

Routing is configured in the text Configuration document. The extension installs
ordered rules from its complete immutable runtime version.

Rules run from top to bottom; the first matching rule selects its action. `FINAL`
provides the terminal action. Each rule carries its own policy: DIRECT, REJECT,
PROXY, a named node, or a configured proxy group.

```ini
[Rule]
DOMAIN-SUFFIX, example.com, DIRECT
IP-CIDR, 192.168.0.0/16, DIRECT, no-resolve
FINAL, PROXY
```

The preview and tunnel use `OrderedRouteMatcher`. Domain rules, CIDR rules,
logical expressions, external rule sets and explicit Geo resources are compiled
and validated before publication. DNS-dependent matching can defer its decision;
`no-resolve` prevents an extra resolution for that rule.

See [Configuration.md](Configuration.md), [RuleSets.md](RuleSets.md),
[GeoDatabases.md](GeoDatabases.md) and
[ConfigurationArchitecture.md](ConfigurationArchitecture.md).
