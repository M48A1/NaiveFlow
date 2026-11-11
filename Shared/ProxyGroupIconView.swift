#if canImport(SwiftUI)
import SwiftUI
import ImageIO

/// Immutable, small decoded bitmap; safe to create away from the UI actor.
nonisolated final class ProxyGroupIconBitmap: NSObject, @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
    var byteCost: Int { image.bytesPerRow * image.height }
}

@MainActor
enum ProxyGroupIconLoader {
    nonisolated static let maxDownloadBytes = 2 * 1024 * 1024
    nonisolated static let maxPixelSize = 128
    private static let cache: NSCache<NSURL, ProxyGroupIconBitmap> = {
        let cache = NSCache<NSURL, ProxyGroupIconBitmap>()
        cache.countLimit = 32
        cache.totalCostLimit = 1024 * 1024
        return cache
    }()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()
    private static var activeDownloads = 0

    static func load(_ url: URL) async -> ProxyGroupIconBitmap? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        // Bound simultaneous buffers across hosts, not only per host.
        while activeDownloads >= 4 {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return nil }
            if let cached = cache.object(forKey: url as NSURL) { return cached }
        }
        guard !Task.isCancelled else { return nil }
        activeDownloads += 1
        defer { activeDownloads -= 1 }
        do {
            let (data, response) = try await BoundedHTTPFetcher.fetch(url, maxBytes: maxDownloadBytes, session: session)
            guard (200..<300).contains(response.statusCode), !Task.isCancelled else { return nil }
            let bitmap = await Task.detached(priority: .utility) { thumbnail(data) }.value
            guard !Task.isCancelled, let bitmap else { return nil }
            cache.setObject(bitmap, forKey: url as NSURL, cost: bitmap.byteCost)
            return bitmap
        } catch { return nil }
    }

    nonisolated static func thumbnail(_ data: Data) -> ProxyGroupIconBitmap? {
        guard data.count <= maxDownloadBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return ProxyGroupIconBitmap(image)
    }
}

struct ProxyGroupIconView: View {
    @Environment(\.scenePhase) private var scenePhase
    let iconURL: String?
    var size: CGFloat = 28
    @State private var bitmap: ProxyGroupIconBitmap?
    private var loadURL: URL? { scenePhase == .active ? ProxyGroupIconURL.parse(iconURL) : nil }

    var body: some View {
        Group {
            if let bitmap {
                Image(decorative: bitmap.image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "folder")
                    .resizable().scaledToFit()
                    .padding(size * 0.12)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        .accessibilityHidden(true)
        .task(id: loadURL) {
            bitmap = nil
            guard let url = loadURL else { return }
            let loaded = await ProxyGroupIconLoader.load(url)
            guard !Task.isCancelled else { return }
            bitmap = loaded
        }
        .onDisappear { bitmap = nil }
    }
}
#endif
