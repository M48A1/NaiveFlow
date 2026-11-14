import Foundation

nonisolated struct ClientGeoSourceDraft: Identifiable {
    let id = UUID()
    var key = ""
    var source = ""
    var format: String
    var category = ""
    var checksum = ""
    var originalValue: String?

    init(site: Bool, reference: NativeGeoResources.Reference? = nil, originalValue: String? = nil) {
        format = site ? "geosite-dat" : "geoip-dat"
        self.originalValue = originalValue
        if let reference {
            key = site ? reference.key : reference.key.uppercased()
            source = reference.url.absoluteString
            format = reference.format
            category = reference.category
            checksum = reference.checksum ?? ""
        }
    }

    func applying(to text: String, site: Bool, deleting: Bool = false) throws -> String {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !key.isEmpty, key.utf8.count <= 128, key.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ClientFailure("分类标识只能包含字母、数字、连字符和下划线。")
        }
        let section: ConfigurationDocument.SectionKind = site ? .geoSite : .geoIP
        let parsed = NaiveFlowConfigurationParser.parse(text: text).configuration
        let existing = (site ? parsed.geoSite : parsed.geoIP)[key]
        if let originalValue {
            guard existing == originalValue else { throw ClientFailure("数据源已发生变化，请重新打开后编辑。") }
        } else if existing != nil {
            throw ClientFailure("这个分类标识已存在，请编辑已有数据源。")
        }
        if deleting {
            guard originalValue != nil else { throw ClientFailure("没有可删除的数据源。") }
            return ClientDocumentEditing.set(text, section: section, key: key, value: nil)
        }
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let checksum = checksum.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.contains(where: { $0.isNewline }), !category.contains(where: { $0.isNewline }) else {
            throw ClientFailure("地址和来源分类不能包含换行。")
        }
        _ = try NativeRuleSet.sourceURL(source)
        var fields = [ClientDocumentEditing.token(source), ClientDocumentEditing.token("format=" + format)]
        if !category.isEmpty { fields.append(ClientDocumentEditing.token("category=" + category)) }
        if !checksum.isEmpty { fields.append(ClientDocumentEditing.token("sha256=" + checksum)) }
        let updated = ClientDocumentEditing.set(text, section: section, key: key, value: fields.joined(separator: ", "))
        _ = try NativeGeoResources.references(NaiveFlowConfigurationParser.parse(text: updated).configuration)
        return updated
    }
}
