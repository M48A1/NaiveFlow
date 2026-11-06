import Foundation
import Testing
@testable import RuleProxy

struct NativeConfigurationTests {
    @Test func firstMatchAndFinalAreExecutedInDocumentOrder() {
        let result = TextConfigurationPipeline.process(text: """
            [Rule]
            DOMAIN-SUFFIX, example.com, REJECT
            DOMAIN, api.example.com, DIRECT
            FINAL, DIRECT
            """)
        #expect(result.isActivatable)
        #expect(result.route(host: "api.example.com").action == .reject)
        #expect(result.route(host: "elsewhere.test").action == .direct)
    }

    @Test func earlierIPRuleWaitsBeforeALaterDomainRuleWins() {
        let result = TextConfigurationPipeline.process(text: """
            [Rule]
            IP-CIDR, 10.0.0.0/8, REJECT
            DOMAIN, example.com, DIRECT
            FINAL, PROXY
            """)
        let matcher = OrderedRouteMatcher(rules: result.compiled.orderedRules, finalAction: result.compiled.finalAction)
        if case .needsAddress = matcher.evaluate(RouteQuery(host: "example.com")) {} else { Issue.record("DNS must be awaited") }
        #expect(matcher.match(RouteQuery(host: "example.com", ip: "10.2.3.4")).action == .reject)
        #expect(matcher.match(RouteQuery(host: "example.com", ip: "203.0.113.1")).action == .direct)
    }

    @Test func noResolveDoesNotTriggerLookupOrInvertUnknownIP() {
        let result = TextConfigurationPipeline.process(text: """
            [Rule]
            IP-CIDR, 10.0.0.0/8, REJECT, no-resolve
            FINAL, DIRECT
            """)
        let matcher = OrderedRouteMatcher(rules: result.compiled.orderedRules, finalAction: result.compiled.finalAction)
        if case .matched(let match) = matcher.evaluate(RouteQuery(host: "example.com")) {
            #expect(match.action == .direct)
        } else { Issue.record("no-resolve must not request DNS") }
    }

    @Test func flowMetadataIsDeferredAtDNSTimeAndMatchedAtFlowTime() {
        let result = TextConfigurationPipeline.process(text: """
            [Rule]
            AND,((PROTOCOL,TCP),(DEST-PORT,443)),REJECT
            FINAL, DIRECT
            """)
        #expect(result.isActivatable)
        let matcher = OrderedRouteMatcher(rules: result.compiled.orderedRules, finalAction: result.compiled.finalAction)
        if case .deferred = matcher.evaluate(RouteQuery(host: "example.com"), allowFinal: false) {} else {
            Issue.record("DNS must not cache a flow-specific FINAL")
        }
        #expect(matcher.match(RouteQuery(destinationPort: 443, protocolName: "TCP")).action == .reject)
        #expect(matcher.match(RouteQuery(destinationPort: 443, protocolName: "UDP")).action == .direct)
    }

    @Test func logicalORKnownMatchDoesNotNeedUnnecessaryDNS() {
        let result = TextConfigurationPipeline.process(text: """
            [Rule]
            OR,((DOMAIN,example.com),(IP-CIDR,10.0.0.0/8)),DIRECT
            FINAL, REJECT
            """)
        #expect(result.isActivatable)
        let matcher = OrderedRouteMatcher(rules: result.compiled.orderedRules, finalAction: result.compiled.finalAction)
        if case .matched(let match) = matcher.evaluate(RouteQuery(host: "example.com")) {
            #expect(match.action == .direct)
        } else { Issue.record("The known OR operand already decides the rule") }
    }

    @Test func explicitGeoDataIsActuallyUsed() {
        let result = TextConfigurationPipeline.process(text: """
            [GeoIP]
            ZZ = 10.0.0.0/8
            AS64500 = 192.0.2.0/24
            [GeoSite]
            local = example.com, example.org
            [Rule]
            GEOSITE, local, DIRECT
            GEOIP, ZZ, REJECT
            IP-ASN, 64500, REJECT
            FINAL, PROXY
            """)
        #expect(result.isActivatable)
        #expect(result.route(host: "api.example.org").action == .direct)
        #expect(result.route(ip: "10.0.0.1").action == .reject)
        #expect(result.route(ip: "192.0.2.100").action == .reject)
        #expect(result.route(ip: "203.0.113.1").action == .defaultProxy)
    }

    @Test func nonByteAlignedCIDRDoesNotTrapOrOvermatch() throws {
        let prefix = try #require(CIDRPrefix.parse("192.0.2.128/25"))
        #expect(prefix.contains("192.0.2.129"))
        #expect(!prefix.contains("192.0.2.127"))
        let v6 = try #require(CIDRPrefix.parse("2001:db8::/33"))
        #expect(v6.contains("2001:db8::1"))
        #expect(!v6.contains("2001:db8:8000::1"))
    }

    @Test func invalidNestedRegexOrMetadataIsRejectedBeforePublish() {
        for text in ["DOMAIN-REGEX, [, DIRECT", "AND,((DOMAIN-REGEX,[),(PROTOCOL,TCP)),DIRECT",
                     "DEST-PORT, 70000, DIRECT", "PROTOCOL, HTTP, DIRECT"] {
            #expect(!TextConfigurationPipeline.process(text: "[Rule]\n" + text).isActivatable)
        }
    }

    @Test func explicitGroupSelectionSupportsNestedAndBuiltinMembers() {
        let result = TextConfigurationPipeline.process(text: """
            [Proxy]
            First = socks5, 127.0.0.1, 1080
            Second = socks5, 127.0.0.1, 1081
            [Proxy Group]
            Choice = select, First, Second, selected=Second
            Nested = select, Choice, DIRECT, selected=DIRECT
            [Rule]
            DOMAIN, example.com, Choice
            FINAL, Nested
            """)
        #expect(result.isActivatable)
        #expect(result.route(host: "example.com").action.configurationID == result.compiled.proxies.last?.id)
        #expect(result.route(host: "other.test").action == .direct)
    }

    @Test func textRewritesCompileToExistingKernelOperations() {
        let result = TextConfigurationPipeline.process(text: #"""
            [MITM]
            enable = false
            hostname = example.com
            [URL Rewrite]
            ^https://example.com/old, redirect, https://example.com/new
            [Header Rewrite]
            request, ^https://example.com/, add, X-Test, "a,b"
            [Body Rewrite]
            response, ^https://example.com/, replace, "old", "new"
            response, ^https://example.com/, json-delete, $.ads
            [Map Local]
            ^https://example.com/local, text, ""
            """#)
        #expect(result.isActivatable)
        let rules = result.compiled.textMITM.rules
        #expect(rules.count == 5)
        #expect(rules[0].operation == .rewrite(.redirect302(url: "https://example.com/new")))
        #expect(rules[1].operation == .headerAdd(name: "X-Test", value: "a,b"))
        #expect(rules[2].phase == .httpResponse)
        #expect(rules[3].operation == .bodyJSON(.delete(path: "$.ads")))
        #expect(rules[4].operation == .rewrite(.reject200Text(content: "")))
    }

    @Test func framingHeadersAndUnimplementedFeaturesAreRejected() {
        for directive in ["request, ., replace, Content-Length, 1", "response, ., add, Transfer-Encoding, chunked"] {
            let text = "[MITM]\nhostname = example.com\n[Header Rewrite]\n" + directive
            #expect(!TextConfigurationPipeline.process(text: text).isActivatable)
        }
        #expect(!TextConfigurationPipeline.process(text: "[Host]\nexample.com = server:1.1.1.1").isActivatable)
    }

    @Test func scriptsUseNativeABIAndEmbedArgumentsWithoutExecuting() async throws {
        let source = Data("function process(ctx) { throw new Error($argument); }".utf8).base64EncodedString()
        let result = TextConfigurationPipeline.process(text: """
            [MITM]
            enable = false
            hostname = example.com
            [Script]
            test = type=http-response, pattern=., source=base64:\(source), argument=hello
            """)
        #expect(result.isActivatable)
        let sets = try await result.compiled.textMITM.resolveScripts()
        let rule = try #require(sets.first?.rules.first)
        if case .script(let encoded) = rule.operation {
            let text = try #require(String(data: try #require(Data(base64Encoded: encoded)), encoding: .utf8))
            #expect(text.contains("const $argument = \"hello\";"))
        } else { Issue.record("Expected the native script operation") }
    }

    @Test func exportedMITMSetPreservesScopesParametersAndScriptBytes() async throws {
        let source = Data("function process(ctx) { return ctx; }".utf8).base64EncodedString()
        let set = MITMRuleSet(name: "Scope", domainSuffixes: ["example.com"],
            rules: [MITMRule(phase: .httpResponse, urlPattern: ".", operation: .script(scriptBase64: source))],
            parameterValues: ["value": "a,b"])
        let text = ConfigurationExporter.export(.init(mitmEnabled: false, mitmRuleSets: [set])).text
        let result = TextConfigurationPipeline.process(text: text)
        #expect(result.isActivatable)
        let restored = try await result.compiled.textMITM.resolveScripts()
        #expect(restored.first?.id == set.id)
        #expect(restored.first?.parameterValues == set.parameterValues)
        #expect(restored.first?.rules.first?.operation == set.rules.first?.operation)
    }
}
