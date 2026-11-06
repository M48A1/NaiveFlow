//
//  ShadowsocksProtocol.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/6/26.
//

import Foundation

nonisolated enum ShadowsocksProtocol {

    static func buildAddressHeader(host: String, port: UInt16) -> Data {
        guard IPv4Only.supportsHost(host) else { return Data() }
        var data = Data()

        if let ipv4 = parseIPv4(host) {
            data.append(0x01)
            data.append(contentsOf: ipv4)
        } else {
            let domainBytes = Array(host.utf8.prefix(255))
            data.append(0x03)
            data.append(UInt8(domainBytes.count))
            data.append(contentsOf: domainBytes)
        }

        data.append(UInt8(port >> 8))
        data.append(UInt8(port & 0xFF))

        return data
    }

    static func encodeUDPPacket(host: String, port: UInt16, payload: Data) -> Data {
        guard IPv4Only.supportsHost(host) else { return Data() }
        var data = buildAddressHeader(host: host, port: port)
        data.append(payload)
        return data
    }

    static func decodeUDPPacket(data: Data) -> (host: String, port: UInt16, payload: Data)? {
        guard !data.isEmpty else { return nil }
        var offset = data.startIndex

        let addressType = data[offset]
        offset += 1

        let host: String
        switch addressType {
        case 0x01:
            guard data.endIndex - offset >= 4 + 2 else { return nil }
            host = "\(data[offset]).\(data[offset+1]).\(data[offset+2]).\(data[offset+3])"
            offset += 4

        case 0x03:
            guard data.endIndex - offset >= 1 else { return nil }
            let domainLen = Int(data[offset])
            offset += 1
            guard data.endIndex - offset >= domainLen + 2 else { return nil }
            guard let domain = String(data: data[offset..<(offset + domainLen)], encoding: .utf8) else { return nil }
            host = domain
            offset += domainLen

        case 0x04: return nil // Unsupported address family.

        default:
            return nil
        }

        guard data.endIndex - offset >= 2 else { return nil }
        let port = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2

        let payload = Data(data[offset...])
        return (host, port, payload)
    }

    // MARK: - IP Parsing

    private static func parseIPv4(_ address: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, address, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

}
