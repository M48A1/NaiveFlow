//
//  OrderedRouteMatcherTests.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation
import Testing
@testable import NaiveFlow

struct OrderedRouteMatcherTests {

    private func rule(
        _ line: Int,
        _ matcher: OrderedRoutingRule.Matcher,
        _ action: RouteMatchAction,
        noResolve: Bool = false
    ) -> OrderedRoutingRule {
        OrderedRoutingRule(line: line, matcher: matcher, action: action, noResolve: noResolve)
    }

    @Test func firstMatchingRuleWins() {
        let matcher = OrderedRouteMatcher(
            rules: [
                rule(1, .domainSuffix("example.com"), .reject),
                rule(2, .domainSuffix("www.example.com"), .direct),
            ],
            finalAction: .defaultProxy
        )

        let result = matcher.match(RouteQuery(host: "www.example.com"))
        #expect(result.action == .reject)
        #expect(result.ruleLine == 1)
    }

    @Test func suffixMatchesSubdomainsOnly() {
        let matcher = OrderedRouteMatcher(
            rules: [rule(1, .domainSuffix("example.com"), .direct)],
            finalAction: .defaultProxy
        )

        #expect(matcher.match(RouteQuery(host: "example.com")).action == .direct)
        #expect(matcher.match(RouteQuery(host: "a.example.com")).action == .direct)
        #expect(matcher.match(RouteQuery(host: "example.com.evil.test")).action == .defaultProxy)
        #expect(matcher.match(RouteQuery(host: "notexample.com")).action == .defaultProxy)
    }

    @Test func ipRulesNeedAResolvedAddress() {
        let matcher = OrderedRouteMatcher(
            rules: [rule(1, .ipCIDR(CIDRPrefix.parse("10.0.0.0/8")!), .reject)],
            finalAction: .direct
        )

        #expect(matcher.match(RouteQuery(host: "intranet.test")).action == .direct)
        #expect(matcher.match(RouteQuery(ip: "10.1.2.3")).action == .reject)
        #expect(matcher.match(RouteQuery(ip: "192.168.1.1")).action == .direct)
    }

    @Test func unsupportedAddressPrefixIsRejected() {
        #expect(CIDRPrefix.parse("2001:db8::/32") == nil)
    }

    @Test func wildcardKeywordAndRegexRules() {
        let matcher = OrderedRouteMatcher(
            rules: [
                rule(1, .domainWildcard("*.ads.example.com"), .reject),
                rule(2, .domainKeyword("tracker"), .direct),
                rule(3, .urlRegex("/collect\\?"), .reject),
            ],
            finalAction: .defaultProxy
        )

        #expect(matcher.match(RouteQuery(host: "img.ads.example.com")).action == .reject)
        #expect(matcher.match(RouteQuery(host: "tracker.example.net")).action == .direct)
        #expect(matcher.match(RouteQuery(host: "example.net", url: "https://example.net/collect?id=1")).action == .reject)
        #expect(matcher.match(RouteQuery(host: "example.net")).action == .defaultProxy)
    }

    @Test func geoRulesUseInjectedLookup() {
        struct FakeGeo: GeoIPLookup {
            func countryCode(for address: String) -> String? { "CN" }
            func asn(for address: String) -> Int? { 4134 }
        }

        let matcher = OrderedRouteMatcher(
            rules: [
                rule(1, .geoIP("CN"), .direct),
                rule(2, .ipASN(4134), .reject),
            ],
            finalAction: .defaultProxy,
            geoIP: FakeGeo()
        )

        #expect(matcher.match(RouteQuery(ip: "1.2.3.4")).action == .direct)

        let empty = OrderedRouteMatcher(
            rules: [rule(1, .geoIP("CN"), .direct)],
            finalAction: .defaultProxy
        )
        #expect(empty.match(RouteQuery(ip: "1.2.3.4")).action == .defaultProxy)
    }

    @Test func finalActionDecidesWhenNothingMatches() {
        let matcher = OrderedRouteMatcher(
            rules: [rule(1, .domainSuffix("example.com"), .direct)],
            finalAction: .reject
        )

        let result = matcher.match(RouteQuery(host: "example.org"))
        #expect(result.action == .reject)
        #expect(result.isFinal)
    }

    @Test func documentPreviewUsesOrderedRules() {
        let result = TextConfigurationPipeline.process(text: """
            [Proxy]
            A = direct
            [Rule]
            DOMAIN-SUFFIX, blocked.com, REJECT
            DOMAIN-KEYWORD, ads, DIRECT
            FINAL, PROXY
            """)

        #expect(result.route(host: "x.blocked.com").action == .reject)
        #expect(result.route(host: "ads.example.org").action == .direct)
        #expect(result.route(host: "example.org").action == .defaultProxy)
        #expect(result.decidingLine(host: "x.blocked.com") == 4)
        #expect(result.decidingLine(host: "example.org") == nil)
    }

    @Test func domainPlusPortAndProtocolRulesMatchTogether() {
        let matcher = OrderedRouteMatcher(
            rules: [
                rule(1, .allOf([.domainSuffix("example.com"), .destinationPort(443), .protocolName("UDP")]), .reject),
            ],
            finalAction: .direct
        )

        // The post-sniff re-match carries the full connection context, so the
        // combined rule hits; dropping any condition falls through to FINAL.
        #expect(matcher.match(RouteQuery(host: "example.com", destinationPort: 443, protocolName: "UDP")).action == .reject)
        #expect(matcher.match(RouteQuery(host: "example.com", destinationPort: 443)).action == .direct)
        #expect(matcher.match(RouteQuery(host: "example.com", protocolName: "UDP")).action == .direct)
        #expect(matcher.match(RouteQuery(host: "example.com", destinationPort: 8443, protocolName: "UDP")).action == .direct)
    }

    @Test func finalVerdictIsDistinguishedFromRuleMatch() {
        let matcher = OrderedRouteMatcher(
            rules: [rule(1, .domainSuffix("example.com"), .direct)],
            finalAction: .reject
        )

        // An explicit rule match is not FINAL…
        let ruleHit = matcher.match(RouteQuery(host: "example.com"))
        #expect(ruleHit.isFinal == false)
        #expect(ruleHit.action == .direct)

        // …while the terminal catch-all is, so callers can defer a FINAL reject
        // until domain sniffing completes.
        let finalHit = matcher.match(RouteQuery(host: "other.org"))
        #expect(finalHit.isFinal == true)
        #expect(finalHit.action == .reject)
    }

    @Test func domainAndIPRulesBothMatchFromOneQuery() {
        let matcher = OrderedRouteMatcher(
            rules: [
                rule(1, .domainSuffix("example.com"), .direct),
                rule(2, .ipCIDR(CIDRPrefix.parse("10.0.0.0/8")!), .reject),
            ],
            finalAction: .defaultProxy
        )

        // A post-sniff query carries both the recovered domain and the original
        // destination IP, so a domain rule can win over a later IP/FINAL rule.
        let both = RouteQuery(host: "example.com", ip: "10.1.2.3")
        #expect(matcher.match(both).action == .direct)

        // With only the IP, the earlier domain rule cannot match yet, so the
        // matcher defers instead of letting the later IP rule win early.
        if case .deferred = matcher.evaluate(RouteQuery(ip: "10.1.2.3"), allowAddressResolution: false) {
            // expected
        } else {
            Issue.record("Expected deferral when a host rule precedes an IP rule and the host is unknown")
        }
    }

    @Test func hostUnknownDefersPortRulesToo() {
        let matcher = OrderedRouteMatcher(
            rules: [
                rule(1, .domainSuffix("example.com"), .direct),
                rule(2, .destinationPort(443), .reject),
            ],
            finalAction: .defaultProxy
        )

        // Without the host, the later port rule must not win before the earlier
        // domain rule had a chance to match.
        if case .deferred = matcher.evaluate(RouteQuery(ip: "1.2.3.4", destinationPort: 443), allowAddressResolution: false) {
            // expected
        } else {
            Issue.record("Expected deferral when a host rule precedes a port rule and the host is unknown")
        }
    }

    @Test func negatedDomainIsUnknownWithoutHost() {
        let matcher = OrderedRouteMatcher(
            rules: [
                rule(1, .negated(.domain("example.com")), .reject),
            ],
            finalAction: .defaultProxy
        )

        // NOT DOMAIN cannot be decided while the host is unknown, so it defers
        // rather than matching early.
        if case .deferred = matcher.evaluate(RouteQuery(ip: "1.2.3.4"), allowAddressResolution: false) {
            // expected
        } else {
            Issue.record("Expected deferral for NOT DOMAIN while the host is unknown")
        }
    }

    // MARK: - Missing flow metadata (script HTTP / proxy DoH)

    /// Mirrors how `OutboundConnector.resolveRoute` — the dialer used by script
    /// HTTP and proxy DoH — collapses a native decision into one action: a matched
    /// rule keeps its action, and anything that did not match falls back to the
    /// default route. Those requests carry no source address/port and never will,
    /// so the matcher is asked to treat missing metadata as a non-match rather than
    /// a deferral (`deferOnMissingMetadata: false`).
    private func resolveLikeScriptOrDoH(
        _ matcher: OrderedRouteMatcher,
        ip: String,
        port: UInt16 = 443,
        protocolName: String = "TCP"
    ) -> RouteMatchAction {
        let query = RouteQuery(ip: ip, destinationPort: port, protocolName: protocolName)
        switch matcher.evaluate(query, deferOnHostUnknown: false, deferOnMissingMetadata: false) {
        case .matched(let result):
            return result.action
        case .needsAddress, .deferred:
            return .defaultProxy
        }
    }

    @Test func sourceIPRuleDoesNotSinkLaterRejectWithoutSourceAddress() {
        let matcher = OrderedRouteMatcher(
            rules: [
                rule(1, .sourceIP(CIDRPrefix.parse("192.0.2.0/24")!), .direct),
                rule(2, .ipCIDR(CIDRPrefix.parse("1.2.3.4/32")!), .reject),
            ],
            finalAction: .direct
        )

        // Regression: with no source address the first rule cannot match. The scan
        // must continue to the IP-CIDR reject instead of deferring and letting the
        // caller fall through to the default route.
        #expect(resolveLikeScriptOrDoH(matcher, ip: "1.2.3.4") == .reject)
        // Destinations the later rules do not claim still reach FINAL.
        #expect(resolveLikeScriptOrDoH(matcher, ip: "8.8.8.8") == .direct)
    }

    @Test func missingMetadataStillDefersByDefaultForPreviews() {
        let matcher = OrderedRouteMatcher(
            rules: [
                rule(1, .sourceIP(CIDRPrefix.parse("192.0.2.0/24")!), .direct),
                rule(2, .ipCIDR(CIDRPrefix.parse("1.2.3.4/32")!), .reject),
            ],
            finalAction: .direct
        )

        // Default semantics keep deferring: a DNS-time preview must not cache the
        // IP-CIDR verdict while the source address is still unknown.
        if case .deferred = matcher.evaluate(RouteQuery(ip: "1.2.3.4"), deferOnHostUnknown: false) {
            // expected
        } else {
            Issue.record("Expected deferral when source metadata is missing and deferral is allowed")
        }
    }

    @Test func matchingSourceAddressStillWinsUnderTerminalPolicy() {
        let matcher = OrderedRouteMatcher(
            rules: [
                rule(1, .sourceIP(CIDRPrefix.parse("192.0.2.0/24")!), .direct),
                rule(2, .ipCIDR(CIDRPrefix.parse("1.2.3.4/32")!), .reject),
            ],
            finalAction: .direct
        )

        // When the flow does carry a matching source address, the earlier rule
        // still wins under the terminal policy.
        if case .matched(let result) = matcher.evaluate(
            RouteQuery(ip: "1.2.3.4", sourceIP: "192.0.2.10", destinationPort: 443, protocolName: "TCP"),
            deferOnHostUnknown: false, deferOnMissingMetadata: false
        ) {
            #expect(result.action == .direct)
            #expect(result.ruleLine == 1)
        } else {
            Issue.record("Expected the matching SRC-IP rule to win")
        }
    }

    @Test func missingSourcePortSkipsRuleRatherThanDeferring() {
        let matcher = OrderedRouteMatcher(
            rules: [
                rule(1, .sourcePort(1234), .direct),
                rule(2, .destinationPort(443), .reject),
            ],
            finalAction: .direct
        )

        // SRC-PORT is unavailable for a script/DoH request; the later port reject
        // must still fire instead of the evaluation deferring to the default route.
        #expect(resolveLikeScriptOrDoH(matcher, ip: "1.2.3.4", port: 443) == .reject)
    }
}
