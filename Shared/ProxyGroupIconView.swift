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
#endif
