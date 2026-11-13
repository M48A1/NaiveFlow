import Foundation
import CryptoKit

/// A coordinated file in the application's iCloud Drive Documents directory.
actor ConfigurationDrive {
    nonisolated struct Version: Sendable {
        let name: String
        let text: String
        let digest: String
    }

    nonisolated enum Failure: LocalizedError, Equatable {
        case unavailable, invalidName, alreadyExists, changed, downloading

        var errorDescription: String? {
            switch self {
            case .unavailable: "iCloud Drive is unavailable. Check your iCloud sign-in and NaiveFlow’s iCloud Drive access."
            case .invalidName: "Enter a file name without path separators."
            case .alreadyExists: "A configuration with that name already exists. Open it or choose a different name."
            case .changed: "This configuration changed in iCloud Drive. Load the latest version or save your draft under a new name."
            case .downloading: "iCloud Drive is downloading this configuration. Try again when it is available."
            }
        }
    }

    private let localDirectory: URL?

    init(localDirectory: URL? = nil) {
        self.localDirectory = localDirectory
    }

    func files() throws -> [String] {
        let folder = try directory()
        let urls = try coordinatedRead(folder) { url in
            try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        }
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "conf",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != false else { return nil }
            return url.lastPathComponent
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func read(_ name: String) throws -> Version {
        let url = try fileURL(name)
        let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if let status = values.ubiquitousItemDownloadingStatus, status != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw Failure.downloading
        }
        return try coordinatedRead(url) { try Self.readVersion($0, name: name) }
    }

    func save(_ text: String, name: String, replacing baseline: String?) throws -> Version {
        let data = Data(text.utf8)
        guard data.count <= ConfigurationImport.maximumBytes else {
            throw ConfigurationImport.Failure.tooLarge(bytes: data.count)
        }
        let url = try fileURL(name)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                          error: &coordinationError) { target in
            result = Result {
                if let baseline {
                    guard FileManager.default.fileExists(atPath: target.path) else { throw Failure.changed }
                    let availability = try target.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                    guard availability.ubiquitousItemDownloadingStatus.map({ $0 == .current }) != false,
                          (try? Self.readVersion(target, name: name).digest) == baseline,
                          NSFileVersion.unresolvedConflictVersionsOfItem(at: target)?.isEmpty != false else {
                        throw Failure.changed
                    }
                } else if FileManager.default.fileExists(atPath: target.path) {
                    throw Failure.alreadyExists
                }
                try data.write(to: target, options: .atomic)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.unavailable }
        try result.get()
        return Version(name: name, text: text, digest: Self.digest(data))
    }

    nonisolated static func fileName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), name.utf8.count <= 240,
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              !name.contains("/"), !name.contains("\\"), !name.contains(":") else { throw Failure.invalidName }
        return name.lowercased().hasSuffix(".conf") ? name : name + ".conf"
    }

    private func directory() throws -> URL {
        let folder: URL
        if let localDirectory {
            folder = localDirectory
        } else {
            guard let root = FileManager.default.url(forUbiquityContainerIdentifier: AWCore.Identifier.iCloudContainer) else {
                throw Failure.unavailable
            }
            folder = root.appendingPathComponent("Documents", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func fileURL(_ name: String) throws -> URL {
        guard try Self.fileName(name) == name else { throw Failure.invalidName }
        return try directory().appendingPathComponent(name, isDirectory: false)
    }

    private func coordinatedRead<T>(_ url: URL, read: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [],
                                                          error: &coordinationError) { target in
            result = Result { try read(target) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.unavailable }
        return try result.get()
    }

    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func readVersion(_ url: URL, name: String) throws -> Version {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.invalidName }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while data.count <= ConfigurationImport.maximumBytes {
            let count = min(65_536, ConfigurationImport.maximumBytes + 1 - data.count)
            guard let chunk = try file.read(upToCount: count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= ConfigurationImport.maximumBytes else {
            throw ConfigurationImport.Failure.tooLarge(bytes: data.count)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ConfigurationImport.Failure.unsupportedEncoding }
        return Version(name: name, text: text, digest: Self.digest(data))
    }
}
