import SwiftUI
import PhotosUI
#if os(iOS)
import VisionKit
import AVFoundation
#else
import UniformTypeIdentifiers
#endif
import ImageIO
import CoreImage

nonisolated enum ClientQRPayload {
    static func normalize(_ payload: String) throws -> String {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 65_536, !text.isEmpty else { throw ClientFailure("The QR code is empty or too large.") }
        let source = DeepLinkManager.extractAddProxyLink(from: text) ?? text
        if let url = URL(string: source), url.scheme?.lowercased() == "https", url.host?.isEmpty == false {
            return source
        }
        guard (try? SubscriptionFetcher.parseLocal(data: Data(source.utf8)))?.configurations.isEmpty == false else {
            throw ClientFailure("This QR code does not contain a supported node link or HTTPS subscription.")
        }
        return source
    }

    static func readImage(_ data: Data) throws -> [String] {
        guard data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ClientFailure("Choose an image smaller than 20 MiB containing a readable QR code.") }
        // Use the software QR detector for still images as well as devices
        // without a Vision inference context. Live scanning uses VisionKit.
        guard let detector = CIDetector(ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
            throw ClientFailure("QR image recognition is unavailable.")
        }
        let payloads = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        var seen: Set<String> = []
        let values = payloads.compactMap { try? normalize($0) }.filter { seen.insert($0).inserted }
        guard !values.isEmpty else { throw ClientFailure("No supported node or subscription QR code was found in this image.") }
        return values
    }
}

struct ClientQRImportView: View {
    @Environment(\.dismiss) private var dismiss
#if os(iOS)
    @State private var camera = false
#else
    @State private var choosingFile = false
#endif
    @State private var photo: PhotosPickerItem?
    @State private var results: [String] = []
    @State private var importSource: QRSource?
    @State private var loading = false
    @State private var error: String?
    private struct QRSource: Identifiable { let id = UUID(); let text: String }
    var body: some View {
        NavigationStack {
            List {
                Section {
#if os(iOS)
                    Button("Scan with Camera", systemImage: "camera") { Task { await openCamera() } }
#else
                    Button("Choose QR Image File", systemImage: "folder") { choosingFile = true }
                        .disabled(loading)
#endif
                    PhotosPicker(selection: $photo, matching: .images) { Label("Choose QR Image", systemImage: "photo") }
                        .disabled(loading)
                    if loading { ProgressView("Reading QR codes…") }
                } footer: { Text("Scans node links and HTTPS subscriptions. Nothing is downloaded or imported until you review and confirm the content.") }
                if !results.isEmpty {
                    Section("Choose Content to Import") {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, source in
                            Button { importSource = QRSource(text: source) } label: {
                                Text(source).font(.system(.caption, design: .monospaced)).lineLimit(4)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import QR Code").clientInlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
#if os(iOS)
            .sheet(isPresented: $camera) {
                NavigationStack {
                    ClientCameraScanner { payload in
                        camera = false
                        do { results = [try ClientQRPayload.normalize(payload)] }
                        catch { self.error = error.localizedDescription }
                    } failure: { message in camera = false; error = message }
                    .navigationTitle("Scan QR Code").clientInlineTitle()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { camera = false } } }
                }
            }
#else
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
                Task {
                    loading = true
                    defer { loading = false }
                    do {
                        let url = try result.get()
                        results = try await Task.detached(priority: .userInitiated) {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            let handle = try FileHandle(forReadingFrom: url)
                            defer { try? handle.close() }
                            let data = try handle.read(upToCount: 20 * 1024 * 1024 + 1) ?? Data()
                            return try ClientQRPayload.readImage(data)
                        }.value
                    } catch { self.error = error.localizedDescription }
                }
            }
#endif
            .sheet(item: $importSource) { ClientNodeImportView(source: $0.text).clientEditorWindow() }
            .onChange(of: photo) { _, item in
                Task {
                    guard let item else { return }
                    loading = true; defer { loading = false; photo = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw ClientFailure("The image could not be loaded.") }
                        results = try await Task.detached(priority: .userInitiated) { try ClientQRPayload.readImage(data) }.value
                    } catch { self.error = error.localizedDescription }
                }
            }
            .alert("Could Not Read QR Code", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
#if os(iOS)
    private func openCamera() async {
        guard DataScannerViewController.isSupported else { error = "Live scanning is unavailable on this device. Choose a QR image instead."; return }
        guard await AVCaptureDevice.requestAccess(for: .video), DataScannerViewController.isAvailable else {
            error = "Camera access is unavailable. Allow access in system Settings or choose a QR image."; return
        }
        camera = true
    }
#endif
}

#if os(iOS)
private struct ClientCameraScanner: UIViewControllerRepresentable {
    let result: (String) -> Void
    let failure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(result: result, failure: failure) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !controller.isScanning else { return }
        do { try controller.startScanning() }
        catch { Task { context.coordinator.failure(error.localizedDescription) } }
    }
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let result: (String) -> Void
        let failure: (String) -> Void
        private var delivered = false
        init(result: @escaping (String) -> Void, failure: @escaping (String) -> Void) { self.result = result; self.failure = failure }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    delivered = true; scanner.stopScanning(); result(payload); return
                }
            }
        }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { failure(error.localizedDescription) }
    }
}
#endif
