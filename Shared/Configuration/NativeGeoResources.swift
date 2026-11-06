import Foundation
import CryptoKit

/// Explicit, manual refresh: every configuration apply resolves all sources.
/// Immutable source blobs are an audit cache, never a silent fallback.
nonisolated enum NativeGeoResources {
    static let maximumSourceBytes = 64 * 1024 * 1024
    static let maximumTotalBytes = 128 * 1024 * 1024
    typealias Loader = @Sendable (URL) async throws -> Data
    struct Reference: Sendable {
        let key: String
        let site: Bool
        let url: URL
        let format: String
        let category: String
        let checksum: String?
    }
    static func isExternal(_ value: String) -> Bool {
        let first = ConfigurationDocument.unquoted(ConfigurationDocument.splitList(value).first ?? "").lowercased()
        return first.hasPrefix("https:") || first.hasPrefix("http:") || first.hasPrefix("file:")
    }
    static func references(_ parsed: ParsedConfiguration) throws -> [Reference] {
        var references: [Reference] = []
        for (site, pairs) in [(false, parsed.geoIP.pairs), (true, parsed.geoSite.pairs)] {
            for (key, raw) in pairs where isExternal(raw) {
                let fields = ConfigurationDocument.splitList(raw).map(ConfigurationDocument.unquoted)
                guard let first = fields.first else { continue }
                let url = try NativeRuleSet.sourceURL(first)
                var options: [String: String] = [:]
                for field in fields.dropFirst() {
                    let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard pair.count == 2, ["format", "category", "sha256"].contains(pair[0]), options[pair[0]] == nil else {
                        throw NativeGeoFailure("Geo source \(key): invalid or duplicate option.")
                    }
                    options[pair[0]] = pair[1]
                }
                let format = options["format"] ?? (site ? "geosite-dat" : "geoip-dat")
                guard (site ? ["geosite-dat", "domain"] : ["geoip-dat", "cidr"]).contains(format) else {
                    throw NativeGeoFailure("Geo source \(key): unsupported format \(format).")
                }
                if !site, key.uppercased().hasPrefix("AS") {
                    guard let asn = Int(key.dropFirst(2)), asn > 0 else { throw NativeGeoFailure("Geo source \(key): invalid ASN key.") }
                }
                let category = options["category"] ?? key
                guard !category.isEmpty, !key.isEmpty else { throw NativeGeoFailure("Geo source has an empty category.") }
                if let sha = options["sha256"], sha.count != 64 || !sha.allSatisfy({ $0.isHexDigit && $0.isASCII }) {
                    throw NativeGeoFailure("Geo source \(key): sha256 must contain 64 hexadecimal digits.")
                }
                references.append(Reference(key: key, site: site, url: url, format: format, category: category, checksum: options["sha256"]?.lowercased()))
            }
        }
        guard references.count <= 32 else { throw NativeGeoFailure("At most 32 Geo source declarations are allowed.") }
        return references
    }

    @concurrent
    static func resolve(_ parsed: ParsedConfiguration, cacheDirectory: URL, loader: Loader? = nil) async throws -> NativeGeoDatabase? {
        let refs = try references(parsed)
        guard !refs.isEmpty else { return nil }
        var loaded: [URL: Data] = [:]
        var total = 0
        var database = NativeGeoDatabase()
        var blobs: [String: Data] = [:]
        for ref in refs {
            try Task.checkCancellation()
            do {
                let data: Data
                if let cached = loaded[ref.url] { data = cached }
                else {
                    if let loader { data = try await loader(ref.url) }
                    else { data = try await download(ref.url) }
                    guard !data.isEmpty, data.count <= maximumSourceBytes else { throw NativeGeoFailure("Geo source is empty or exceeds 64 MiB.") }
                    total += data.count
                    guard total <= maximumTotalBytes else { throw NativeGeoFailure("Geo downloads exceed 128 MiB.") }
                    loaded[ref.url] = data
                }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if let expected = ref.checksum, digest != expected { throw NativeGeoFailure("SHA-256 mismatch.") }
                if ref.site {
                    let records = ref.format == "geosite-dat"
                        ? try GeoDataDecoder.site(data, category: ref.category)
                        : try GeoDataDecoder.domainText(data)
                    guard !records.isEmpty else { throw NativeGeoFailure("Selected GeoSite category is empty.") }
                    database.domains[ref.key.lowercased(), default: []].append(contentsOf: records)
                } else {
                    let prefixes = ref.format == "geoip-dat"
                        ? try GeoDataDecoder.ip(data, category: ref.category)
                        : try GeoDataDecoder.cidrText(data)
                    guard !prefixes.isEmpty else { throw NativeGeoFailure("Selected GeoIP category has no IPv4 prefixes.") }
                    let token = ref.key.uppercased()
                    let asn = token.hasPrefix("AS") ? Int(token.dropFirst(2)) : nil
                    database.networks.append(contentsOf: prefixes.map { .init(prefix: $0, country: asn == nil ? token : nil, asn: asn) })
                }
                guard database.entryCount <= NativeGeoDatabase.maximumEntries else { throw NativeGeoFailure("Geo database exceeds two million entries.") }
                database.sources.append(.init(url: ref.url.absoluteString, sha256: digest, loadedAt: Date(), format: ref.format))
                blobs[digest] = data
            } catch { throw NativeGeoFailure("Geo source \(ref.key) (\(ref.url.absoluteString)): \(error.localizedDescription)") }
        }
        try database.validate()
        try Task.checkCancellation()
        // Content-addressed, atomically written files cannot replace any active version.
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        for (hash, data) in blobs {
            let path = cacheDirectory.appendingPathComponent(hash + ".dat")
            if FileManager.default.fileExists(atPath: path.path) {
                guard (try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximumSourceBytes else { throw NativeGeoFailure("Geo source cache is oversized.") }
                let bytes = try Data(contentsOf: path)
                guard SHA256.hash(data: bytes) == SHA256.hash(data: data) else { throw NativeGeoFailure("Geo source cache is corrupted.") }
            } else { try data.write(to: path, options: .atomic) }
        }
        // Bound the non-authoritative audit cache; rollback uses runtime bundles.
        let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { $0.pathExtension == "dat" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var retained = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            retained += size
            if retained > maximumTotalBytes * 2 { try? FileManager.default.removeItem(at: file) }
        }
        return database
    }

    private static func download(_ url: URL) async throws -> Data {
        if url.isFileURL {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true, let count = size.fileSize, count <= maximumSourceBytes else { throw NativeGeoFailure("Invalid or oversized local Geo file.") }
            let data = try Data(contentsOf: url)
            guard data.count <= maximumSourceBytes else { throw NativeGeoFailure("Geo file exceeds 64 MiB.") }
            return data
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https", response.expectedContentLength <= Int64(maximumSourceBytes) else {
            throw NativeGeoFailure("Geo download requires HTTPS, 2xx status and at most 64 MiB.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumSourceBytes else { throw NativeGeoFailure("Geo download exceeds 64 MiB.") }
            data.append(byte)
            if data.count & 0xFFFF == 0 { try Task.checkCancellation() }
        }
        return data
    }
}
