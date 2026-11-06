//
//  ICMPMessage.swift
//  NaiveFlowIP
//
//  Created by NodePassProject on 9/25/26.
//

enum ICMPMessage {
    static func error(
        type: UInt8,
        code: UInt8,
        parameter: UInt32 = 0,
        quoting datagram: UnsafeRawBufferPointer,
        from source: IPAddress.V4,
        to destination: IPAddress.V4
    ) -> OutboundPacket {
        let quoted = min(datagram.count, IPv4Header.length + 8)
        let length = IPv4Header.length + 8 + quoted
        return OutboundPacket(byteCount: length) { packet in
            IPv4Header(
                totalLength: length,
                timeToLive: 255,
                protocol: 1,
                source: source,
                destination: destination,
                identification: PacketIdentification.next()
            ).write(to: packet)
            let message = UnsafeMutableRawBufferPointer(rebasing: packet[IPv4Header.length...])
            message[0] = type
            message[1] = code
            message.storeBytes(of: parameter.bigEndian, toByteOffset: 4, as: UInt32.self)
            UnsafeMutableRawBufferPointer(rebasing: message[8...]).copyMemory(from: UnsafeRawBufferPointer(rebasing: datagram[..<quoted]))
            storeChecksum(in: packet, from: IPv4Header.length, at: IPv4Header.length + 2)
        }
    }

    static func storeChecksum(
        in buffer: UnsafeMutableRawBufferPointer,
        from start: Int,
        at offset: Int,
        pseudoHeaderFor source: IPAddress? = nil,
        destination: IPAddress? = nil,
        protocol: UInt8 = 0
    ) {
        buffer.storeBytes(of: UInt16(0), toByteOffset: offset, as: UInt16.self)
        var checksum = InternetChecksum()
        if let source, let destination {
            checksum.update(pseudoHeaderFor: source, destination: destination, protocol: `protocol`, length: buffer.count - start)
        }
        checksum.update(bufferPointer: UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(buffer)[start...]))
        buffer.storeBytes(of: checksum.finalize(), toByteOffset: offset, as: UInt16.self)
    }
}
