//
//  IPEndpoint.swift
//  RuleProxyIP
//
//  Created by NodePassProject on 9/20/26.
//

public struct IPEndpoint: Hashable, Sendable {
    public var address: IPAddress
    public var port: UInt16

    init(address: IPAddress, port: UInt16) {
        self.address = address
        self.port = port
    }
}

extension IPEndpoint: CustomStringConvertible {
    public var description: String {
        "\(address):\(port)"
    }
}
