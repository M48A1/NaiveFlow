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
        #expect(matcher.match(RouteQuery(url: "https://example.net/collect?id=1")).action == .reject)
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
}
