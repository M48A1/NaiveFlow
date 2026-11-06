//
//  IPAddress.swift
//  RuleProxyIP
//
//  Created by NodePassProject on 9/20/26.
//

public enum IPAddress: Hashable, Sendable {
    public struct V4: Hashable, Sendable, ExpressibleByIntegerLiteral {
        public var rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public init(integerLiteral value: UInt32) {
            rawValue = value
        }

        init(bytes pointer: UnsafeRawPointer) {
            rawValue = UInt32(bigEndian: pointer.loadUnaligned(as: UInt32.self))
        }

        func write(to pointer: UnsafeMutableRawPointer) {
            pointer.storeBytes(of: rawValue.bigEndian, as: UInt32.self)
        }

        var isUnspecified: Bool { rawValue == 0 }
        var isBroadcast: Bool { rawValue == .max }
        var isMulticast: Bool { rawValue >> 28 == 0xE }
        var isLoopback: Bool { rawValue >> 24 == 127 }
    }

    case v4(V4)

    public var byteCount: Int {
        4
    }

    public init(bytes pointer: UnsafeRawPointer) {
        self = .v4(V4(bytes: pointer))
    }

    public func write(to pointer: UnsafeMutableRawPointer) {
        switch self {
        case .v4(let address): address.write(to: pointer)
        }
    }
}

extension IPAddress: CustomStringConvertible {
    public var description: String {
        switch self {
        case .v4(let address):
            let value = address.rawValue
            return "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
        }
    }
}
