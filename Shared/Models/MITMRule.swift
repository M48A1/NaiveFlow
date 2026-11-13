//
//  MITMRule.swift
//  NaiveFlow
//
//  Created by NodePassProject on 5/3/26.
//

import Foundation

nonisolated enum MITMPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case httpRequest
    case httpResponse

    var id: String { rawValue }
}

extension MITMPhase: CustomStringConvertible {
    var description: String {
        switch self {
        case .httpRequest:
            String(localized: "Request")
        case .httpResponse:
            String(localized: "Response")
        }
    }
}

nonisolated enum MITMJSONOperation: Equatable, Sendable {
    case add(path: String, value: String)
    case replace(path: String, value: String)
    case delete(path: String)
    case replaceRecursive(key: String, value: String)
    case deleteRecursive(key: String)
    case removeWhereKeyExists(path: String, key: String)
    case removeWhereFieldIn(path: String, field: String, values: String)
}

extension MITMJSONOperation: CustomStringConvertible {
    var action: String {
        switch self {
        case .add:                  return "add"
        case .replace:              return "replace"
        case .delete:               return "delete"
        case .replaceRecursive:     return "replace-recursive"
        case .deleteRecursive:      return "delete-recursive"
        case .removeWhereKeyExists: return "remove-where-key-exists"
        case .removeWhereFieldIn:   return "remove-where-field-in"
        }
    }

    var description: String {
        switch self {
        case .add(let path, _),
             .replace(let path, _),
             .delete(let path),
             .removeWhereKeyExists(let path, _),
             .removeWhereFieldIn(let path, _, _):
            return "\(action) \(path)"
        case .replaceRecursive(let key, _),
             .deleteRecursive(let key):
            return "\(action) \(key)"
        }
    }
}

extension MITMJSONOperation: Codable {
    private enum Action: String, Codable {
        case add
        case replace
        case delete
        case replaceRecursive
        case deleteRecursive
        case removeWhereKeyExists
        case removeWhereFieldIn
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case path
        case key
        case field
        case value
        case values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Action.self, forKey: .action) {
        case .add:
            self = .add(
                path: try container.decode(String.self, forKey: .path),
                value: try container.decode(String.self, forKey: .value)
            )
        case .replace:
            self = .replace(
                path: try container.decode(String.self, forKey: .path),
                value: try container.decode(String.self, forKey: .value)
            )
        case .delete:
            self = .delete(path: try container.decode(String.self, forKey: .path))
        case .replaceRecursive:
            self = .replaceRecursive(
                key: try container.decode(String.self, forKey: .key),
                value: try container.decode(String.self, forKey: .value)
            )
        case .deleteRecursive:
            self = .deleteRecursive(key: try container.decode(String.self, forKey: .key))
        case .removeWhereKeyExists:
            self = .removeWhereKeyExists(
                path: try container.decode(String.self, forKey: .path),
                key: try container.decode(String.self, forKey: .key)
            )
        case .removeWhereFieldIn:
            self = .removeWhereFieldIn(
                path: try container.decode(String.self, forKey: .path),
                field: try container.decode(String.self, forKey: .field),
                values: try container.decode(String.self, forKey: .values)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .add(let path, let value):
            try container.encode(Action.add, forKey: .action)
            try container.encode(path, forKey: .path)
            try container.encode(value, forKey: .value)
        case .replace(let path, let value):
            try container.encode(Action.replace, forKey: .action)
            try container.encode(path, forKey: .path)
            try container.encode(value, forKey: .value)
        case .delete(let path):
            try container.encode(Action.delete, forKey: .action)
            try container.encode(path, forKey: .path)
        case .replaceRecursive(let key, let value):
            try container.encode(Action.replaceRecursive, forKey: .action)
            try container.encode(key, forKey: .key)
            try container.encode(value, forKey: .value)
        case .deleteRecursive(let key):
            try container.encode(Action.deleteRecursive, forKey: .action)
            try container.encode(key, forKey: .key)
        case .removeWhereKeyExists(let path, let key):
            try container.encode(Action.removeWhereKeyExists, forKey: .action)
            try container.encode(path, forKey: .path)
            try container.encode(key, forKey: .key)
        case .removeWhereFieldIn(let path, let field, let values):
            try container.encode(Action.removeWhereFieldIn, forKey: .action)
            try container.encode(path, forKey: .path)
            try container.encode(field, forKey: .field)
            try container.encode(values, forKey: .values)
        }
    }
}

nonisolated enum MITMOperation: Equatable, Sendable {
    case rewrite(MITMRewriteAction)
    case headerAdd(name: String, value: String)
    case headerDelete(name: String)
    case headerReplace(name: String, value: String)
    case script(scriptBase64: String, dialect: MITMScriptDialect = .surge)
    case bodyReplace(search: String, replacement: String)
    case bodyJSON(MITMJSONOperation)

    /// Operations produced by the supported module importers or script compiler.
    var isSupportedMITMOperation: Bool {
        switch self {
        case .script, .headerReplace, .rewrite(.redirect302), .rewrite(.reject200Gif),
             .rewrite(.reject200Text(content: "")), .bodyJSON(.delete):
            return true
        default:
            return false
        }
    }
}

extension MITMOperation: CustomStringConvertible {
    var description: String {
        switch self {
        case .rewrite:
            String(localized: "Rewrite")
        case .headerAdd:
            String(localized: "Header Add")
        case .headerDelete:
            String(localized: "Header Delete")
        case .headerReplace:
            String(localized: "Header Replace")
        case .script:
            String(localized: "Script")
        case .bodyReplace:
            String(localized: "Body Replace")
        case .bodyJSON:
            String(localized: "Body JSON")
        }
    }
}

extension MITMOperation: Codable {
    private enum Kind: String, Codable {
        case rewrite
        case headerAdd
        case headerDelete
        case headerReplace
        case script
        case bodyReplace
        case bodyJSON
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case value
        case replacement
        case search
        case script
        case json
        case dialect
        case rewrite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .rewrite:
            self = .rewrite(try container.decode(MITMRewriteAction.self, forKey: .rewrite))
        case .headerAdd:
            self = .headerAdd(
                name: try container.decode(String.self, forKey: .name),
                value: try container.decode(String.self, forKey: .value)
            )
        case .headerDelete:
            self = .headerDelete(name: try container.decode(String.self, forKey: .name))
        case .headerReplace:
            self = .headerReplace(
                name: try container.decode(String.self, forKey: .name),
                value: try container.decode(String.self, forKey: .value)
            )
        case .script:
            self = .script(scriptBase64: try container.decode(String.self, forKey: .script),
                           dialect: try container.decodeIfPresent(MITMScriptDialect.self, forKey: .dialect) ?? .surge)
        case .bodyReplace:
            self = .bodyReplace(
                search: try container.decode(String.self, forKey: .search),
                replacement: try container.decode(String.self, forKey: .replacement)
            )
        case .bodyJSON:
            self = .bodyJSON(try container.decode(MITMJSONOperation.self, forKey: .json))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rewrite(let action):
            try container.encode(Kind.rewrite, forKey: .kind)
            try container.encode(action, forKey: .rewrite)
        case .headerAdd(let name, let value):
            try container.encode(Kind.headerAdd, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(value, forKey: .value)
        case .headerDelete(let name):
            try container.encode(Kind.headerDelete, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .headerReplace(let name, let value):
            try container.encode(Kind.headerReplace, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(value, forKey: .value)
        case .script(let scriptBase64, let dialect):
            try container.encode(Kind.script, forKey: .kind)
            try container.encode(scriptBase64, forKey: .script)
            try container.encode(dialect, forKey: .dialect)
        case .bodyReplace(let search, let replacement):
            try container.encode(Kind.bodyReplace, forKey: .kind)
            try container.encode(search, forKey: .search)
            try container.encode(replacement, forKey: .replacement)
        case .bodyJSON(let operation):
            try container.encode(Kind.bodyJSON, forKey: .kind)
            try container.encode(operation, forKey: .json)
        }
    }
}

nonisolated struct MITMRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var phase: MITMPhase
    var urlPattern: String
    var operation: MITMOperation

    init(
        id: UUID = UUID(),
        phase: MITMPhase,
        urlPattern: String,
        operation: MITMOperation
    ) {
        self.id = id
        self.phase = phase
        self.urlPattern = urlPattern
        self.operation = operation
    }

    private enum CodingKeys: String, CodingKey {
        case phase
        case urlPattern
        case operation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.phase = try container.decode(MITMPhase.self, forKey: .phase)
        self.urlPattern = try container.decode(String.self, forKey: .urlPattern)
        self.operation = try container.decode(MITMOperation.self, forKey: .operation)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phase, forKey: .phase)
        try container.encode(urlPattern, forKey: .urlPattern)
        try container.encode(operation, forKey: .operation)
    }
}

extension MITMRule {
    var summaryTitle: String {
        "\(phase.description) \(operation.description)"
    }

    var summarySubtitle: String {
        switch operation {
        case .rewrite(let action):
            switch action {
            case .transparent(let url), .redirect302(let url):
                return url
            case .reject200Text:
                return String(localized: "Reject Text")
            case .reject200Gif:
                return String(localized: "Reject GIF")
            case .reject200Data:
                return String(localized: "Reject Data")
            }
        case .headerAdd(let name, _):
            return name
        case .headerDelete(let name):
            return name
        case .headerReplace(let name, _):
            return name
        case .script(let scriptBase64, _):
            let bytes = Data(base64Encoded: scriptBase64)?.count ?? 0
            return String(localized: "\(bytes) byte(s)")
        case .bodyReplace(let search, _):
            return search
        case .bodyJSON(let operation):
            return operation.description
        }
    }
}

nonisolated enum MITMRewriteAction: Equatable, Sendable {
    case transparent(url: String)
    case redirect302(url: String)
    case reject200Text(content: String)
    case reject200Gif
    case reject200Data(base64: String)
}

extension MITMRewriteAction: Codable {
    private enum Kind: String, Codable {
        case transparent
        case redirect302
        case reject200Text
        case reject200Gif
        case reject200Data
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case url
        case content
        case base64
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .transparent:
            self = .transparent(url: try container.decode(String.self, forKey: .url))
        case .redirect302:
            self = .redirect302(url: try container.decode(String.self, forKey: .url))
        case .reject200Text:
            self = .reject200Text(content: try container.decode(String.self, forKey: .content))
        case .reject200Gif:
            self = .reject200Gif
        case .reject200Data:
            self = .reject200Data(base64: try container.decode(String.self, forKey: .base64))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .transparent(let url):
            try container.encode(Kind.transparent, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .redirect302(let url):
            try container.encode(Kind.redirect302, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .reject200Text(let content):
            try container.encode(Kind.reject200Text, forKey: .kind)
            try container.encode(content, forKey: .content)
        case .reject200Gif:
            try container.encode(Kind.reject200Gif, forKey: .kind)
        case .reject200Data(let base64):
            try container.encode(Kind.reject200Data, forKey: .kind)
            try container.encode(base64, forKey: .base64)
        }
    }
}

nonisolated struct MITMParameter: Codable, Equatable, Identifiable, Sendable {
    enum InputType: Int, Codable, Sendable { case input = 0, picker = 1 }
    enum DataType: Int, Codable, Sendable { case string = 0 }

    var type: InputType
    var dataType: DataType
    var name: String
    var defaultValue: String
    var options: [String]
    var label: String?
    var description: String?

    var id: String { name }

    init(
        type: InputType,
        dataType: DataType = .string,
        name: String,
        defaultValue: String,
        options: [String] = [],
        label: String? = nil,
        description: String? = nil
    ) {
        self.type = type
        self.dataType = dataType
        self.name = name
        self.defaultValue = defaultValue
        self.options = options
        self.label = label
        self.description = description
    }

    func accepts(_ value: String) -> Bool {
        switch type {
        case .picker: return options.contains(value)
        case .input:  return true
        }
    }

    func effectiveValue(_ override: String?) -> String {
        guard let override, accepts(override) else { return defaultValue }
        return override
    }
}

nonisolated struct MITMRuleSet: Codable, Equatable, Identifiable, SoftDeletable, Sendable {
    static let maxRuleCount = 10000
    static let maxParameterCount = 256

    var id = UUID()
    var name: String
    var enabled: Bool
    var domainSuffixes: [String]
    var rules: [MITMRule]
    var parameters: [MITMParameter]
    var parameterValues: [String: String]
    var subscriptionURL: URL?
    var iconLight: Data?
    var iconDark: Data?
    var updatedAt: Date
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        domainSuffixes: [String] = [],
        rules: [MITMRule] = [],
        parameters: [MITMParameter] = [],
        parameterValues: [String: String] = [:],
        subscriptionURL: URL? = nil,
        iconLight: Data? = nil,
        iconDark: Data? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.domainSuffixes = domainSuffixes
        self.rules = rules
        self.parameters = parameters
        self.parameterValues = parameterValues
        self.subscriptionURL = subscriptionURL
        self.iconLight = iconLight
        self.iconDark = iconDark
        self.updatedAt = updatedAt
    }

    func resolvedParameters() -> [(name: String, value: String)] {
        parameters.map { ($0.name, $0.effectiveValue(parameterValues[$0.name])) }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case domainSuffixes
        case rules
        case parameters
        case parameterValues
        case subscriptionURL
        case iconLight
        case iconDark
        case updatedAt
        case deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.domainSuffixes = try container.decode([String].self, forKey: .domainSuffixes)
        self.name = try container.decode(String.self, forKey: .name)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.rules = try container.decodeSkippingInvalid([MITMRule].self, forKey: .rules)
        self.parameters = (try? container.decodeSkippingInvalid([MITMParameter].self, forKey: .parameters)) ?? []
        self.parameterValues = (try? container.decodeIfPresent([String: String].self, forKey: .parameterValues)) ?? [:]
        self.subscriptionURL = try container.decodeIfPresent(URL.self, forKey: .subscriptionURL)
        self.iconLight = try container.decodeIfPresent(Data.self, forKey: .iconLight)
        self.iconDark = try container.decodeIfPresent(Data.self, forKey: .iconDark)
        self.deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? deletedAt ?? .distantPast
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(domainSuffixes, forKey: .domainSuffixes)
        try container.encode(rules, forKey: .rules)
        if !parameters.isEmpty { try container.encode(parameters, forKey: .parameters) }
        if !parameterValues.isEmpty { try container.encode(parameterValues, forKey: .parameterValues) }
        try container.encodeIfPresent(subscriptionURL, forKey: .subscriptionURL)
        try container.encodeIfPresent(iconLight, forKey: .iconLight)
        try container.encodeIfPresent(iconDark, forKey: .iconDark)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }

}
