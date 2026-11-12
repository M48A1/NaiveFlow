import Compression
import Foundation

/// Store each downloaded script once, compressed, while keeping ordinary script
/// operations in memory and in the exported MITM policy.
nonisolated enum ModuleScriptArchive {
    static let sourceMarker = ForeignScriptContext.sourceMarker
    private static let referencePrefix = "module-script:"
    static let maximumExpandedBytes = 32 * 1024 * 1024
    private static let maximumSourceBytes = 4 * 1024 * 1024

    static func pack(_ sets: [ModuleMITMRuleSet]) throws -> (sets: [ModuleMITMRuleSet], sources: [Data]) {
        var packed = sets
        var indices: [String: Int] = [:]
        var sources: [Data] = []
        var sourceBytes = 0
        var expandedBytes = 0
        for setIndex in packed.indices {
            for ruleIndex in packed[setIndex].rules.indices {
                guard case .script(let base64, let dialect) = packed[setIndex].rules[ruleIndex].operation,
                      let data = Data(base64Encoded: base64), let script = String(data: data, encoding: .utf8) else { continue }
                expandedBytes += data.count
                guard expandedBytes <= maximumExpandedBytes else { throw ModuleImportError.tooLarge }
                let prefix: String
                let source: String
                if let marker = script.range(of: sourceMarker) {
                    prefix = String(script[..<marker.lowerBound])
                    source = String(script[marker.upperBound...])
                } else { prefix = ""; source = script }
                let index: Int
                if let existing = indices[source] { index = existing }
                else {
                    sourceBytes += source.utf8.count
                    guard sourceBytes <= 16 * 1024 * 1024 else { throw ModuleImportError.tooLarge }
                    index = sources.count
                    indices[source] = index
                    sources.append(try compress(Data(source.utf8)))
                }
                let reference = referencePrefix + String(index) + ":" + Data(prefix.utf8).base64EncodedString()
                packed[setIndex].rules[ruleIndex].operation = .script(scriptBase64: reference, dialect: dialect)
            }
        }
        return (packed, sources)
    }

    static func unpack(_ sets: [ModuleMITMRuleSet], sources: [Data]) throws -> [ModuleMITMRuleSet] {
        var unpacked = sets
        var decoded: [Int: String] = [:]
        var sourceBytes = 0
        var expandedBytes = 0
        for setIndex in unpacked.indices {
            for ruleIndex in unpacked[setIndex].rules.indices {
                guard case .script(let reference, let dialect) = unpacked[setIndex].rules[ruleIndex].operation,
                      reference.hasPrefix(referencePrefix) else { continue }
                let fields = reference.dropFirst(referencePrefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2, let index = Int(fields[0]), sources.indices.contains(index),
                      let prefixData = Data(base64Encoded: String(fields[1])),
                      let prefix = String(data: prefixData, encoding: .utf8) else { throw ModuleImportError.undecodableBody }
                let source: String
                if let cached = decoded[index] { source = cached }
                else {
                    source = try decompress(sources[index])
                    sourceBytes += source.utf8.count
                    guard sourceBytes <= 16 * 1024 * 1024 else { throw ModuleImportError.tooLarge }
                    decoded[index] = source
                }
                expandedBytes += prefix.utf8.count + source.utf8.count + sourceMarker.utf8.count
                guard expandedBytes <= maximumExpandedBytes else { throw ModuleImportError.tooLarge }
                let script = prefix.isEmpty ? source : prefix + sourceMarker + source
                unpacked[setIndex].rules[ruleIndex].operation = .script(scriptBase64: Data(script.utf8).base64EncodedString(), dialect: dialect)
            }
        }
        return unpacked
    }

    private static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumSourceBytes else { throw ModuleImportError.tooLarge }
        var output = Data(count: data.count + 1024)
        let count = output.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                compression_encode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, target.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0 else { throw ModuleImportError.undecodableBody }
        output.count = count
        return output
    }

    private static func decompress(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw ModuleImportError.undecodableBody }
        var output = Data(count: maximumSourceBytes + 1)
        let count = output.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, target.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0, count <= maximumSourceBytes else { throw ModuleImportError.tooLarge }
        output.count = count
        guard let source = String(data: output, encoding: .utf8) else { throw ModuleImportError.undecodableBody }
        return source
    }
}
