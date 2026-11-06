import Foundation
import Testing
@testable import RuleProxyIP

struct IPv4PacketTests {
    @Test func decodesIPv4UDPAfterHeaderSimplification() throws {
        let source = IPEndpoint(address: .v4(0xC0000201), port: 1234)
        let destination = IPEndpoint(address: .v4(0xC6336401), port: 53)
        let bytes = Data([1, 2, 3, 4])
        let packet = try #require(OutboundPacket(datagram: bytes, from: source, to: destination))
        var decoder = PacketDecoder(decodesUDP: true)
        Data(referencing: packet.data).withUnsafeBytes { decoder.decode($0) }
        let datagram = try #require(decoder.udp)
        #expect(datagram.source == source)
        #expect(datagram.destination == destination)
        #expect(datagram.payload == bytes)
        #expect(packet.data.length == IPv4Header.length + UDPHeader.length + bytes.count)
    }

    @Test func unsupportedFamilyProducesNoFlowOrReply() {
        var bytes = Data(repeating: 0, count: 48)
        bytes[0] = 0x60
        var decoder = PacketDecoder(decodesUDP: true)
        bytes.withUnsafeBytes { decoder.decode($0) }
        #expect(decoder.udp == nil)
        #expect(decoder.tcp == nil)
        #expect(decoder.output.isEmpty)
    }

    @Test func packetTemplateKeepsIPv4TCPChecksumAndLayout() {
        let local = IPEndpoint(address: .v4(0xC0000201), port: 443)
        let remote = IPEndpoint(address: .v4(0xC6336401), port: 50000)
        let template = PacketTemplate(from: local, to: remote)
        var bytes = Data(repeating: 0, count: IPv4Header.length + TCPHeader.length)
        bytes.withUnsafeMutableBytes {
            template.encode(into: $0, sequenceNumber: 1, acknowledgmentNumber: 2, flags: [.ack],
                options: TCPHeader.Options(), window: 4096, payloadLength: 0, payloadSum: 0)
        }
        bytes.withUnsafeBytes { raw in
            let header = IPv4Header(parsing: raw)
            #expect(header?.totalLength == bytes.count)
            #expect(header?.source.rawValue == 0xC0000201)
            #expect(header?.destination.rawValue == 0xC6336401)
            var checksum = InternetChecksum()
            checksum.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[..<IPv4Header.length]))
            #expect(checksum.finalize() == 0)
        }
    }
}
