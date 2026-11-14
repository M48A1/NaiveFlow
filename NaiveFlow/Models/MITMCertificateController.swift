import Foundation
import Observation

@MainActor
@Observable
final class MITMCertificateController {

    @ObservationIgnored private let store = MITMCertificateStore()

    private(set) var hasCA: Bool = false
    private(set) var isTrusted: Bool = false

    init() {
        (hasCA, isTrusted) = currentState()
    }

    func refresh() {
        let (exists, trustedNow) = currentState()
        guard exists != hasCA || trustedNow != isTrusted else { return }
        hasCA = exists
        isTrusted = trustedNow
        AWNotificationCenter.notifyConfigurationVersionChanged()
    }

    func ensureCA() throws {
        _ = try store.loadOrCreateCA()
        refresh()
    }

    func regenerate() throws {
        _ = try store.regenerate()
        refresh()
    }

    func delete() {
        store.delete()
        refresh()
    }

    func certificateData() -> Data? {
        store.exportCertificateDER()
    }

    func mobileConfigData() -> Data? {
        store.exportMobileConfig()
    }

    private func currentState() -> (hasCA: Bool, isTrusted: Bool) {
        let exists = store.exportCertificateDER() != nil
        return (exists, exists && store.isCATrusted())
    }
}
