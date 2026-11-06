import Foundation
import Testing
@testable import RuleProxy

struct IPv4OnlyTests {
    @Test func rejectsUnsupportedLiteralAtEveryConfigurationEntry() {
        for text in [
            "[Rule]\nIP-CIDR6,2001:db8::/32,DIRECT",
            "[Rule]\nSRC-IP,2001:db8::/32,DIRECT",
            "[GeoIP]\nZZ=2001:db8::/32",
            "[Host]\nexample.com=::1",
            "[DNS]\nserver=[::1]:53",
            "[DNS]\ndoh=https://[2001:db8::1]/dns-query",
            "[DNS]\nbootstrap-dns=2001:db8::53",
            "[Proxy]\nNode=socks5,2001:db8::1,1080",
            "[General]\nipv6=true",
            "[General]\ntun-included-routes=2001:db8::/32"
        ] { #expect(!ConfigurationCoordinator().compile(text: text).isActivatable) }
    }

    @Test func addressEncodersNeverTreatUnsupportedLiteralAsDomain() {
        for host in ["::1", "2001:db8::1", "[::ffff:192.0.2.1]"] {
            #expect(ShadowsocksProtocol.buildAddressHeader(host: host, port: 443).isEmpty)
            #expect(AnyTLSProtocol.encodeAddrPort(host: host, port: 443).isEmpty)
            #expect(TrojanProtocol.encodeAddressPort(host: host, port: 443).isEmpty)
            #expect(SOCKS5Handshake.encodeAddress(host: host).isEmpty)
            #expect(VLESSProtocol.encodeRequestHeader(uuid: UUID(), command: .tcp, destinationAddress: host, destinationPort: 443).isEmpty)
        }
        #expect(!ShadowsocksProtocol.buildAddressHeader(host: "192.0.2.1", port: 443).isEmpty)
        #expect(!AnyTLSProtocol.encodeAddrPort(host: "example.com", port: 443).isEmpty)
    }

    @Test func DNSAndBootstrapDoNotAcceptUnsupportedUpstreams() {
        #expect(DNSUpstream.parsePlain("[::1]:53") == nil)
        #expect(DNSUpstream.parseDoH("https://[2001:db8::1]/dns-query") == nil)
        #expect(DNSBootstrapPolicy.parse("2001:db8::53") == nil)
        #expect(HostMapping.canonicalAddress("::1") == nil)
        #expect(!DNSAddressFamily.ipv4.admits("::1"))
    }

    @Test func unsupportedProxyLiteralFailsBeforeConnecting() {
        #expect(throws: (any Error).self) { try ProxyConfiguration.parse(url: "socks5://[2001:db8::1]:1080") }
    }
}
