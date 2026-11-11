//
//  ProxyGroup.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/8/26.
//

import Foundation

nonisolated struct ProxyGroup: Identifiable, Codable, Hashable, SoftDeletable {
    enum Kind: String, Codable {
        case servers, chains
    }

    let id: UUID
    var name: String
    var kind: Kind
    var iconURL: String?
    var memberIds: [UUID]
    var updatedAt: Date
    var deletedAt: Date? = nil

    init(id: UUID = UUID(), name: String, kind: Kind, memberIds: [UUID] = [], iconURL: String? = nil, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.kind = kind
        self.memberIds = memberIds
        self.iconURL = iconURL
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        memberIds = try container.decodeIfPresent([UUID].self, forKey: .memberIds) ?? []
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? deletedAt ?? .distantPast
    }
}

/// Presentation metadata; never used for routing or probe requests.
nonisolated enum ProxyGroupIconURL {
    static func parse(_ value: String?) -> URL? {
        guard let value, !value.isEmpty,
              let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !value.contains(where: { $0.isWhitespace }) else { return nil }
        return url
    }
}
