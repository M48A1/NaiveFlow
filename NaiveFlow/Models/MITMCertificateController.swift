import Foundation
import Observation
import Security
import CryptoKit

@MainActor
@Observable
final class MITMCertificateController {
    @ObservationIgnored private let store = MITMCertificateStore()
    @ObservationIgnored private var identity: MITMCertificateStore.CA?

    private(set) var certificateName: String?
    private(set) var fingerprint: String?
    private(set) var isTrusted = false
    private(set) var isInvalid = false

    var hasCA: Bool { certificateName != nil }

    func refresh(_ certificatePKCS12: String?) {
        let previousFingerprint = fingerprint
        let wasTrusted = isTrusted
        if let certificatePKCS12 {
            identity = try? MITMPKCS12.decode(certificatePKCS12)
        } else {
            _ = store.reloadCA()
            identity = store.loadCA()
        }
        isInvalid = certificatePKCS12 != nil && identity == nil
        let der = identity?.certificateDER
        let certificate = der.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        certificateName = certificate.map { SecCertificateCopySubjectSummary($0) as String? ?? "NaiveFlow Root Certificate" }
        fingerprint = der.map { SHA256.hash(data: $0).map { String(format: "%02X", $0) }.joined(separator: ":") }
        isTrusted = store.isCATrusted(identity)
        if previousFingerprint != fingerprint || wasTrusted != isTrusted {
            AWNotificationCenter.notifyConfigurationVersionChanged()
        }
    }

    func deleteLegacyCertificate() {
        store.delete()
        AWNotificationCenter.notifyConfigurationVersionChanged()
    }

    func certificateData() -> Data? { identity?.certificateDER }
    func mobileConfigData() -> Data? { store.exportMobileConfig(for: identity) }
}
