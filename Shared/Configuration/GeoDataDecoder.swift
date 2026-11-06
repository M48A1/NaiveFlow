import Foundation

/// V2Ray routercommon GeoIPList/GeoSiteList protobuf wire schema.
/// https://github.com/v2fly/v2ray-core/blob/master/app/router/routercommon/common.proto
/// Only selected categories are materialized. Unknown fields are skipped;
/// unsupported matching semantics are rejected, never silently simplified.
nonisolated enum GeoDataDecoder {
    private struct Field {
        let number: UInt64
        let integer: UInt64?
        let bytes: Data?
    }
    private struct Wire {
        let data: Data
        var position = 0
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard position < data.count else { throw NativeGeoFailure("Truncated protobuf varint.") }
                let b = data[position]; position += 1
                guard shift != 63 || b <= 1 else { throw NativeGeoFailure("Protobuf varint overflow.") }
                value |= UInt64(b & 127) << shift
                if b & 128 == 0 { return value }
            }
            throw NativeGeoFailure("Invalid protobuf varint.")
        }
        mutating func next() throws -> Field? {
            guard position < data.count else { return nil }
            let key = try varint(); let number = key >> 3
            guard number > 0 else { throw NativeGeoFailure("Invalid protobuf field.") }
            switch key & 7 {
            case 0: return Field(number: number, integer: try varint(), bytes: nil)
            case 1, 5:
                let count = key & 7 == 1 ? 8 : 4
                guard count <= data.count - position else { throw NativeGeoFailure("Truncated protobuf fixed field.") }
                position += count
                return Field(number: number, integer: nil, bytes: nil)
            case 2:
                let count = try varint()
                guard count <= UInt64(data.count - position) else { throw NativeGeoFailure("Truncated protobuf message.") }
                let end = position + Int(count)
                let bytes = data.subdata(in: position..<end); position = end
                return Field(number: number, integer: nil, bytes: bytes)
            default: throw NativeGeoFailure("Unsupported protobuf wire type.")
            }
        }
    }
    private static func text(_ data: Data?) throws -> String {
        guard let data, let value = String(data: data, encoding: .utf8) else { throw NativeGeoFailure("Invalid UTF-8 protobuf string.") }
        return value
    }
    private static func category(_ data: Data) throws -> String {
        var wire = Wire(data: data)
        while let field = try wire.next() {
            if field.number == 1 { return try text(field.bytes).uppercased() }
        }
        throw NativeGeoFailure("Geo entry has no category.")
    }
    static func ip(_ data: Data, category selected: String) throws -> [CIDRPrefix] {
        var result: [CIDRPrefix] = []; var found = false
        var root = Wire(data: data)
        while let field = try root.next() {
            try Task.checkCancellation()
            guard field.number == 1, let entry = field.bytes else { continue }
            guard try category(entry) == selected.uppercased() else { continue }
            guard !found else { throw NativeGeoFailure("Duplicate GeoIP category.") }; found = true
            var wire = Wire(data: entry)
            while let field = try wire.next() {
                if field.number == 3, let inverse = field.integer, inverse != 0 { throw NativeGeoFailure("Inverse GeoIP categories are unsupported.") }
                guard field.number == 2, let record = field.bytes else { continue }
                var cidr = Wire(data: record); var address: Data?; var length: UInt64 = 0
                while let field = try cidr.next() {
                    if field.number == 1 { address = field.bytes }
                    if field.number == 2 { guard let n = field.integer else { throw NativeGeoFailure("Invalid CIDR prefix.") }; length = n }
                }
                guard let address, address.count == 4 || address.count == 16,
                      length <= UInt64(address.count * 8) else { throw NativeGeoFailure("Invalid GeoIP CIDR.") }
                // IPv4-only scope: discard valid non-IPv4 records from mixed data.
                guard address.count == 4 else { continue }
                let literal = address.map { String($0) }.joined(separator: ".") + "/" + String(length)
                guard let prefix = CIDRPrefix.parse(literal) else { throw NativeGeoFailure("Invalid IPv4 network.") }
                result.append(prefix)
                guard result.count <= NativeGeoDatabase.maximumEntries else { throw NativeGeoFailure("Too many GeoIP records.") }
                if result.count & 0x3FFF == 0 { try Task.checkCancellation() }
            }
        }
        guard found else { throw NativeGeoFailure("GeoIP category not found: \(selected).") }
        return Array(Set(result)).sorted { $0.prefixLength > $1.prefixLength }
    }
    static func site(_ data: Data, category selected: String) throws -> [NativeGeoDatabase.Domain] {
        let selector = selected.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard !selector.isEmpty, selector.count <= 2, !selector[0].isEmpty, selector.count == 1 || !selector[1].isEmpty else { throw NativeGeoFailure("Invalid GeoSite category selector.") }
        var root = Wire(data: data); var result: [NativeGeoDatabase.Domain] = []; var found = false
        while let field = try root.next() {
            try Task.checkCancellation()
            guard field.number == 1, let entry = field.bytes else { continue }
            guard try category(entry) == selector[0].uppercased() else { continue }
            guard !found else { throw NativeGeoFailure("Duplicate GeoSite category.") }; found = true
            var wire = Wire(data: entry)
            while let field = try wire.next() {
                guard field.number == 2, let record = field.bytes else { continue }
                var domain = Wire(data: record); var type: UInt64 = 0; var value: String?; var attributes: Set<String> = []
                while let field = try domain.next() {
                    switch field.number {
                    case 1: guard let t = field.integer else { throw NativeGeoFailure("Invalid domain type.") }; type = t
                    case 2: value = try text(field.bytes)
                    case 3:
                        guard let bytes = field.bytes else { throw NativeGeoFailure("Invalid domain attribute.") }
                        var attr = Wire(data: bytes); var key: String?; var enabled = false
                        while let f = try attr.next() {
                            if f.number == 1 { key = try text(f.bytes) }
                            if f.number == 2 || f.number == 3 { enabled = (f.integer ?? 0) != 0 }
                        }
                        if enabled, let key { attributes.insert(key.lowercased()) }
                    default: break
                    }
                }
                if selector.count == 2 && !attributes.contains(selector[1].lowercased()) { continue }
                guard let value else { throw NativeGeoFailure("GeoSite domain has no value.") }
                let kind: NativeGeoDatabase.Domain.Kind
                switch type {
                case 0: kind = .keyword
                case 1: kind = .regex
                case 2: kind = .suffix
                case 3: kind = .full
                default: throw NativeGeoFailure("Unsupported GeoSite domain type.")
                }
                result.append(try normalized(kind, value))
                guard result.count <= NativeGeoDatabase.maximumEntries else { throw NativeGeoFailure("Too many GeoSite records.") }
                if result.count & 0x3FFF == 0 { try Task.checkCancellation() }
            }
        }
        guard found else { throw NativeGeoFailure("GeoSite category not found: \(selected).") }
        return Array(Set(result))
    }
    private static func lines(_ data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { throw NativeGeoFailure("Geo text is not UTF-8.") }
        return ConfigurationImport.normalize(text).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") && !$0.hasPrefix(";") }
    }
    static func cidrText(_ data: Data) throws -> [CIDRPrefix] {
        var result: Set<CIDRPrefix> = []
        for line in try lines(data) {
            guard let prefix = CIDRPrefix.parse(line) else { throw NativeGeoFailure("Invalid IPv4 CIDR text line: \(line.prefix(100)).") }
            result.insert(prefix)
            guard result.count <= NativeGeoDatabase.maximumEntries else { throw NativeGeoFailure("Too many CIDR lines.") }
        }
        return result.sorted { $0.prefixLength > $1.prefixLength }
    }
    static func domainText(_ data: Data) throws -> [NativeGeoDatabase.Domain] {
        var result: Set<NativeGeoDatabase.Domain> = []
        for line in try lines(data) {
            let pairs = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let kind: NativeGeoDatabase.Domain.Kind
            let value: String
            if pairs.count == 2 {
                switch pairs[0] {
                case "domain": kind = .suffix
                case "full": kind = .full
                case "keyword": kind = .keyword
                case "regexp": kind = .regex
                default: throw NativeGeoFailure("Unsupported domain text prefix.")
                }
                value = String(pairs[1])
            } else { kind = .suffix; value = line }
            result.insert(try normalized(kind, value))
            guard result.count <= NativeGeoDatabase.maximumEntries else { throw NativeGeoFailure("Too many domain lines.") }
        }
        return Array(result)
    }
    private static func normalized(_ kind: NativeGeoDatabase.Domain.Kind, _ raw: String) throws -> NativeGeoDatabase.Domain {
        guard !raw.isEmpty, raw.utf8.count <= 4096 else { throw NativeGeoFailure("Empty or oversized domain condition.") }
        let value: String
        switch kind {
        case .suffix, .full:
            guard let host = DNSName.normalizedHost(raw), !host.contains("*") else { throw NativeGeoFailure("Invalid GeoSite hostname.") }
            value = host
        case .keyword: value = raw.lowercased()
        case .regex: _ = try NSRegularExpression(pattern: raw); value = raw
        }
        return .init(kind: kind, value: value)
    }
}
