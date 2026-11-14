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
            throw ClientFailure("The tag may contain only letters, numbers, hyphens, and underscores.")
        }
        let section: ConfigurationDocument.SectionKind = site ? .geoSite : .geoIP
        let parsed = NaiveFlowConfigurationParser.parse(text: text).configuration
        let existing = (site ? parsed.geoSite : parsed.geoIP)[key]
        if let originalValue {
            guard existing == originalValue else { throw ClientFailure("This source has changed. Reopen it before editing.") }
        } else if existing != nil {
            throw ClientFailure("This tag already exists. Edit the existing source.")
        }
        if deleting {
            guard originalValue != nil else { throw ClientFailure("There is no source to delete.") }
            return ClientDocumentEditing.set(text, section: section, key: key, value: nil)
        }
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let checksum = checksum.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.contains(where: { $0.isNewline }), !category.contains(where: { $0.isNewline }) else {
            throw ClientFailure("The URL and source category cannot contain line breaks.")
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
