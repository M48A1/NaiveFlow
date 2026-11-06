//
//  OutboundPacket+UDP.swift
//  NaiveFlowIP
//
//  Created by NodePassProject on 9/25/26.
//

import Foundation

extension OutboundPacket {
    public init?(datagram payload: Data, from source: IPEndpoint, to destination: IPEndpoint) {
        let udpLength = UDPHeader.length + payload.count
        let ipLength: Int
        switch (source.address, destination.address) {
        case (.v4, .v4):
            ipLength = IPv4Header.length
            guard ipLength + udpLength <= 0xFFFF else { return nil }

        }
        self.init(byteCount: ipLength + udpLength) { packet in
            switch (source.address, destination.address) {
            case (.v4(let sourceAddress), .v4(let destinationAddress)):
                IPv4Header(
                    totalLength: ipLength + udpLength,
                    timeToLive: Constants.hopLimit,
                    protocol: 17,
                    source: sourceAddress,
                    destination: destinationAddress,
                    identification: PacketIdentification.next()
                ).write(to: packet)

            }
            let udp = UnsafeMutableRawBufferPointer(rebasing: packet[ipLength...])
            UDPHeader(sourcePort: source.port, destinationPort: destination.port, totalLength: udpLength).write(to: udp)
            payload.withUnsafeBytes { UnsafeMutableRawBufferPointer(rebasing: udp[UDPHeader.length...]).copyMemory(from: $0) }

        }
    }

    public init?(portUnreachable datagram: InboundDatagram) {
        let packet: OutboundPacket? = datagram.packet.withUnsafeBytes { quoted in
            switch (datagram.source.address, datagram.destination.address) {
            case (.v4(let source), .v4(let destination)):
                ICMPMessage.error(type: 3, code: 3, quoting: quoted, from: destination, to: source)

            }
        }
        guard let packet else { return nil }
        self = packet
    }
}
