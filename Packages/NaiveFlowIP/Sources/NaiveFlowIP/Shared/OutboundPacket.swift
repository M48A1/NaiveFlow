//
//  OutboundPacket.swift
//  NaiveFlowIP
//
//  Created by NodePassProject on 9/20/26.
//

import Foundation

public struct OutboundPacket: @unchecked Sendable {
    public let data: NSData

    public init(data: NSData) {
        self.data = data
    }

    public init(byteCount: Int, _ fill: (UnsafeMutableRawBufferPointer) -> Void) {
        let bytes = calloc(1, max(byteCount, 1)).unsafelyUnwrapped
        fill(UnsafeMutableRawBufferPointer(start: bytes, count: byteCount))
        self.init(data: NSData(bytesNoCopy: bytes, length: byteCount, freeWhenDone: true))
    }

    init(copying bytes: UnsafeRawBufferPointer) {
        self.init(data: NSData(bytes: bytes.baseAddress, length: bytes.count))
    }

    var flags: TCPHeader.Flags {
        TCPHeader.Flags(rawValue: CFDataGetBytePtr(data)[IPv4Header.length + 13])
    }
}
