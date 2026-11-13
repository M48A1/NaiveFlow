import Foundation
import CryptoKit
import Security
import Testing
@testable import NaiveFlow

struct NodeCertificatePolicyTests {
    private static let der = Data(base64Encoded: "MIIC+DCCAeCgAwIBAgIUX0ilknM8uYYgus8vSoE2MNjLQ3gwDQYJKoZIhvcNAQELBQAwHDEaMBgGA1UEAwwRbm9kZS5leGFtcGxlLnRlc3QwHhcNMjYxMTEzMTMyMjAwWhcNMzYxMTEwMTMyMjAwWjAcMRowGAYDVQQDDBFub2RlLmV4YW1wbGUudGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMO4QZonhl6Il4OprKuD6lxn1yEkL9wX4s1mVYF0Ya2P+hrdFLXcRJrJ1KjTUKcHMx/UQNWTIvZyQoMUPnyGqsaQIloOaH/UT7HR0wsfyavflxuihkpAPHVhN02Hi3AbpK0PsPG/zQKD5c+FORJg6uLQj2hx+4cLscaGi/S2VZwqWAqQ6YrcINrgWaQrO82j3Amwu/Z8BhfQ4LjfxVjIkt1RUCjg3KhgnKtn5rdeXrAP95bJQ9lKb2aJtmnUzkDgEgVMJdoY++y53XvRr7LXzlo5Tlgv6cxu5T7t6gkqykKM54T1Iy8bqmCtEQf8pOFCeeORm9yLozYMS5TJ8vR8FW8CAwEAAaMyMDAwHQYDVR0OBBYEFEU79yfEpoIYHW0+xo3op47QW+uaMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBALRFkKCzTfUIah0S2Rv9/DF6LcxRILXtkPsXMbRFZqvX9s/driOv0+dRptmfYUYuMOFb95CV7Mg2/ZsOnm9RFtQz7KmDZdNZBSa9RsHqhp0Kfth046Ap0Bv6qHkbYF0WBA+7pw8qvN7wkn2liuTSMU5KXuRUfQ5Fd0EbxStfKFHOQh3lIfCzTjJGyhVfbayc+86+UKX3yfiEddF+iDtKxUUDIDldM/EvSXG+NsMZvtDtRgQAEvwBugd7WAlARm3eSPfL4CtNHpbqMU2o1sNcULG6P2fqdb85KiTh16AE+762fGWoWO8goDgyUtCbYeRnkWt3Egck/E0Trbmncwq12So=")!
    private static var pin: String { SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined() }
    private static var policy: TLSCertificatePolicy { .init(certificateSHA256: pin) }
    private static func trusted(_ result: CertificatePolicy.Verification) -> Bool {
        if case .trusted = result { return true }
        return false
    }

    @Test func selfSignedCertificateIsTrustedOnlyByTheConfiguredNode() async throws {
        let certificate = try #require(SecCertificateCreateWithData(nil, Self.der as CFData))
        #expect(Self.trusted(await CertificatePolicy.verify(chain: [certificate], serverName: "node.example.test", policy: Self.policy)))
        #expect(!Self.trusted(await CertificatePolicy.verify(chain: [certificate], serverName: "node.example.test")))
    }

    @Test func mismatchedPinIsRejectedEvenWhenVerificationIsDisabled() async throws {
        let certificate = try #require(SecCertificateCreateWithData(nil, Self.der as CFData))
        let policy = TLSCertificatePolicy(insecureSkipVerify: true, certificateSHA256: String(repeating: "0", count: 64))
        #expect(!Self.trusted(await CertificatePolicy.verify(chain: [certificate], serverName: "node.example.test", policy: policy)))
    }

    @Test func skipVerificationIsScopedToTheSuppliedPolicy() async throws {
        let certificate = try #require(SecCertificateCreateWithData(nil, Self.der as CFData))
        #expect(Self.trusted(await CertificatePolicy.verify(chain: [certificate], serverName: "node.example.test", policy: .init(insecureSkipVerify: true))))
        #expect(!Self.trusted(await CertificatePolicy.verify(chain: [certificate], serverName: "node.example.test")))
        #expect(!Self.trusted(await CertificatePolicy.verify(chain: [], serverName: "node.example.test", policy: Self.policy)))
    }

    @Test func fingerprintIsNormalizedAndValidated() throws {
        let formatted = Self.pin.uppercased().map(String.init).joined(separator: ":")
        #expect(TLSCertificatePolicy(certificateSHA256: "  \(formatted)\n").certificateSHA256 == Self.pin)
        #expect(TLSCertificatePolicy.isValidFingerprint(formatted))
        #expect(!TLSCertificatePolicy.isValidFingerprint(String(repeating: "g", count: 64)))
        #expect(!TLSCertificatePolicy.isValidFingerprint("abc"))
        #expect(TLSCertificatePolicy.isValidFingerprint(""))
        #expect(throws: (any Error).self) {
            try TLSCertificatePolicy.fingerprint(in: ["server-cert-fingerprint-sha256": "abc"])
        }
    }

    @Test func legacyTLSJSONKeepsVerificationEnabled() throws {
        let tls = try JSONDecoder().decode(TLSConfiguration.self, from: Data(#"{"serverName":"node.example.test"}"#.utf8))
        #expect(tls.certificatePolicy == .init())
        let encoded = try JSONEncoder().encode(TLSConfiguration(serverName: "node.example.test", insecureSkipVerify: true, serverCertificateFingerprint: Self.pin))
        let decoded = try JSONDecoder().decode(TLSConfiguration.self, from: encoded)
        #expect(decoded.certificatePolicy == .init(insecureSkipVerify: true, certificateSHA256: Self.pin))
        #expect(decoded != tls)
        #expect(Set([decoded, tls]).count == 2)
    }

    @Test func malformedPinsInStoredJSONAreRejected() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TLSConfiguration.self, from: Data(#"{"serverName":"node.example.test","serverCertificateFingerprint":"bad"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TLSCertificatePolicy.self, from: Data(#"{"certificateSHA256":"bad"}"#.utf8))
        }
    }

    private var nodes: [ProxyConfiguration] {
        let tls = TLSConfiguration(serverName: "node.example.test", insecureSkipVerify: true, serverCertificateFingerprint: Self.pin)
        return [
            ProxyConfiguration(name: "Nowhere", serverAddress: "node.example.test", serverPort: 443,
                outbound: .nowhere(NowhereConfiguration(key: "test", certificatePolicy: tls.certificatePolicy))),
            ProxyConfiguration(name: "Hysteria", serverAddress: "node.example.test", serverPort: 443,
                outbound: .hysteria(HysteriaConfiguration(password: "test", serverName: "node.example.test", certificatePolicy: tls.certificatePolicy))),
            ProxyConfiguration(name: "Trojan", serverAddress: "node.example.test", serverPort: 443,
                outbound: .trojan(TrojanConfiguration(password: "test", tls: tls))),
            ProxyConfiguration(name: "AnyTLS", serverAddress: "node.example.test", serverPort: 443,
                outbound: .anytls(AnyTLSConfiguration(password: "test", securityLayer: .tls(tls)))),
            ProxyConfiguration(name: "VLESS", serverAddress: "node.example.test", serverPort: 443,
                outbound: .vless(VLESSConfiguration(uuid: UUID(), encryption: "none", flow: nil, transport: .raw, security: .tls(tls))))
        ]
    }

    @Test func nodeTrustSurvivesStoredJSONAndShareLinks() throws {
        for node in nodes {
            let data = try JSONEncoder().encode(node)
            let decoded = try JSONDecoder().decode(ProxyConfiguration.self, from: data)
            #expect(decoded.nodeCertificatePolicy == node.nodeCertificatePolicy)
            let imported = try ProxyConfiguration.parse(url: node.toURLString())
            #expect(imported.nodeCertificatePolicy == node.nodeCertificatePolicy, "\(node.name)")
        }
    }

    @Test func surgeStyleOptionsReachTheCompiledNodeAndSurviveExport() throws {
        let result = TextConfigurationPipeline.process(text: """
            [Proxy]
            Edge = trojan, node.example.test, 443, password=test, skip-cert-verify=true, server-cert-fingerprint-sha256=\(Self.pin)
            [Rule]
            FINAL, Edge
            """)
        #expect(result.isActivatable)
        let node = try #require(result.compiled.proxies.first)
        #expect(node.nodeCertificatePolicy == .init(insecureSkipVerify: true, certificateSHA256: Self.pin))
        let roundTrip = try ProxyConfiguration.parse(url: node.toURLString())
        #expect(roundTrip.nodeCertificatePolicy == node.nodeCertificatePolicy)
    }

    @Test func invalidSurgeStylePinCannotActivate() {
        let result = TextConfigurationPipeline.process(text: """
            [Proxy]
            Edge = trojan, node.example.test, 443, password=test, server-cert-fingerprint-sha256=bad
            [Rule]
            FINAL, Edge
            """)
        #expect(!result.isActivatable)
    }

    @Test func clashTLSNodesPreserveNodeSpecificVerification() throws {
        for type in ["trojan", "anytls", "vless", "hysteria2"] {
            let result = try ClashProxyParser.parse(yaml: """
                proxies:
                  - name: Edge
                    type: \(type)
                    server: node.example.test
                    port: 443
                    password: test
                    uuid: 00000000-0000-0000-0000-000000000001
                    tls: true
                    skip-cert-verify: true
                    server-cert-fingerprint-sha256: \(Self.pin)
                """)
            let node = try #require(result.configurations.first)
            #expect(node.nodeCertificatePolicy == .init(insecureSkipVerify: true, certificateSHA256: Self.pin), "\(type)")
        }
    }

    @Test func quicPeerVerificationUsesTheNodePin() async {
        #expect(await QUICTLSHandler.verifyPeer(certificates: [Self.der], serverName: "node.example.test", policy: Self.policy) == nil)
        #expect(await QUICTLSHandler.verifyPeer(certificates: [Self.der], serverName: "node.example.test") != nil)
    }

    @Test func legacyQUICNodeJSONDefaultsToSystemTrust() throws {
        let hysteria = try JSONDecoder().decode(HysteriaConfiguration.self, from: Data(#"{"password":"test","serverName":"node.example.test"}"#.utf8))
        let nowhere = try JSONDecoder().decode(NowhereConfiguration.self, from: Data(#"{"key":"test"}"#.utf8))
        #expect(hysteria.certificatePolicy == .init())
        #expect(nowhere.certificatePolicy == .init())
    }

    @Test func quicConnectionPoolsDoNotReuseConnectionsAcrossTrustPolicies() throws {
        func hysteria(_ policy: TLSCertificatePolicy) -> HysteriaRuntimeConfiguration {
            HysteriaRuntimeConfiguration(configuration: HysteriaConfiguration(password: "policy-test", serverName: "pool.example.test", certificatePolicy: policy), proxyHost: "pool.example.test", proxyPort: 443)
        }
        let normal = HysteriaClient.shared(for: hysteria(.init()))
        let pinned = HysteriaClient.shared(for: hysteria(Self.policy))
        #expect(normal !== pinned)
        #expect(normal === HysteriaClient.shared(for: hysteria(.init())))

        func nowhere(_ policy: TLSCertificatePolicy) throws -> NowhereRuntimeConfiguration {
            try NowhereRuntimeConfiguration(proxyHost: "pool.example.test", connectHost: "pool.example.test", proxyPort: 443,
                configuration: NowhereConfiguration(key: "policy-test", certificatePolicy: policy))
        }
        let first = try NowhereClient.shared(for: nowhere(.init()))
        let second = try NowhereClient.shared(for: nowhere(Self.policy))
        #expect(first !== second)
        #expect(first === (try NowhereClient.shared(for: nowhere(.init()))))
    }
    @Test func removedGlobalTrustKeysRequireNodeConfiguration() {
        for key in ["allow-insecure", "trusted-certificate"] {
            let value = key == "allow-insecure" ? "true" : Self.pin
            let result = TextConfigurationPipeline.process(text: "[General]\n\(key) = \(value)\n")
            #expect(!result.isActivatable)
            #expect(!ConfigurationSettingsBindings.names.contains(key))
        }
    }

}
