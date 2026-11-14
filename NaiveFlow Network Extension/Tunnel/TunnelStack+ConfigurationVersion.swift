import Foundation
import Synchronization

extension TunnelStack {
    func policyGroupsResponse() -> PolicyGroupsResponse {
        PolicyGroupsResponse(versionID: nativeBundle?.id, groups: domainRouter.policyStatus())
    }

    private func validateVersion(_ bundle: RuntimeConfigurationBundle) throws {
        try bundle.validate()
        try MITMRewritePolicy.validate(ruleSets: bundle.mitmRuleSets)
        // A synchronized CA can be installed after its profile is activated.
        // loadMITMSetting keeps HTTPS interception gated on local system trust.
        if bundle.mitmCertificatePKCS12 == nil,
           bundle.preferences["mitmEnabled"] == .boolean(true), !mitmCertificateStore.isCATrusted() {
            throw RuntimeConfigurationFailure.rejected("Install and trust the MITM CA before enabling interception.")
        }
    }

    /// Startup uses the exact published bytes. A broken candidate falls back to
    /// the previous complete version and records which candidate was rejected.
    func prepareStartupVersion() throws -> ProxyConfiguration? {
        let store = RuntimeBundleStore()
        guard let head = try store.head() else { throw RuntimeConfigurationFailure.unavailable }
        do {
            let bundle = try store.load(head.current)
            try validateVersion(bundle)
            nativeBundle = bundle
            AWCore.installRuntimePreferences(bundle.preferences)
            return bundle.selectedNode
        } catch {
            let original = error
            guard let previousID = head.previous else { throw original }
            let previous = try store.load(previousID)
            try validateVersion(previous)
            nativeBundle = previous
            AWCore.installRuntimePreferences(previous.preferences)
            try store.record(.init(versionID: head.current, activeVersionID: previousID,
                snapshotID: nil, status: .rejected, message: original.localizedDescription))
            return previous.selectedNode
        }
    }

    func restoreStartupVersion(after error: Error) throws -> ProxyConfiguration? {
        let store = RuntimeBundleStore()
        guard let head = try store.head(), let previousID = head.previous else { return nil }
        let previous = try store.load(previousID)
        try validateVersion(previous)
        nativeBundle = previous
        AWCore.installRuntimePreferences(previous.preferences)
        try store.record(.init(versionID: head.current, activeVersionID: previousID,
            snapshotID: nil, status: .rejected, message: error.localizedDescription))
        return previous.selectedNode
    }

    func confirmStartedVersion() throws {
        guard let bundle = nativeBundle else { return }
        try RuntimeBundleStore().record(.init(versionID: bundle.id, activeVersionID: bundle.id,
            snapshotID: bundle.snapshotID, status: .applied, message: nil))
        recordEngineConfirmation()
    }

    /// All fallible preparation precedes the synchronous module install. Intake
    /// and output are gated while OS tunnel settings or old flows are changing.
    /// On any failure, restore the whole previous version, including OS routes.
    func applyVersion(
        _ bundle: RuntimeConfigurationBundle,
        applySettings: @escaping @Sendable ([String: RuntimePreferenceValue]) async throws -> Void
    ) async throws -> RuntimeConfigurationReceipt {
        let store = RuntimeBundleStore()
        guard phase == .running else { throw RuntimeConfigurationFailure.unavailable }
        if nativeBundle?.id == bundle.id {
            if applyingVersion == nil {
                loadMITMSetting()
                publishUDPConfig()
            }
            let receipt = RuntimeConfigurationReceipt(versionID: bundle.id, activeVersionID: bundle.id,
                snapshotID: bundle.snapshotID, status: .applied, message: nil)
            try store.record(receipt)
            return receipt
        }
        guard applyingVersion == nil else { throw RuntimeConfigurationFailure.busy }
        applyingVersion = bundle.id
        defer { applyingVersion = nil }
        let old = nativeBundle
        let oldPreferences = AWCore.runtimePreferences()
        let oldConfiguration = configuration
        let epoch = runtime.epoch
        do {
            let connectionKeys = ["alwaysOnEnabled", "tunnelIncludeAllNetworks", "tunnelExcludeLocalNetworks",
                "tunnelExcludeAPNs", "tunnelExcludeCellularServices", "tunnelExcludeDeviceCommunication"]
            if connectionKeys.contains(where: { oldPreferences[$0] != bundle.preferences[$0] }) {
                throw RuntimeConfigurationFailure.reconnectRequired
            }
            try validateVersion(bundle)
            guard try store.head()?.current == bundle.id else { throw RuntimeConfigurationFailure.superseded }
            configurationTransition.store(true, ordering: .releasing)
            deferredRestartGeneration += 1
            deferredRestartScheduled = false
            lastRestartTime = MonotonicClock.now
            defer { configurationTransition.store(false, ordering: .releasing) }
            await udpPlane.apply(.reclaim)
            try await applySettings(bundle.preferences)
            guard phase == .running, runtime.epoch == epoch,
                  try store.head()?.current == bundle.id else { throw RuntimeConfigurationFailure.superseded }
            // No suspension between updating any module and starting intake.
            executeLifecycle(.stop, configuration: oldConfiguration)
            nativeBundle = bundle
            AWCore.installRuntimePreferences(bundle.preferences)
            guard let selected = bundle.selectedNode else {
                throw RuntimeConfigurationFailure.invalidBundle
            }
            executeLifecycle(.start, configuration: selected)
            let receipt = RuntimeConfigurationReceipt(versionID: bundle.id, activeVersionID: bundle.id,
                snapshotID: bundle.snapshotID, status: .applied, message: nil)
            try store.record(receipt)
            recordEngineConfirmation()
            return receipt
        } catch RuntimeConfigurationFailure.reconnectRequired {
            throw RuntimeConfigurationFailure.reconnectRequired
        } catch {
            let failure = error
            configurationTransition.store(true, ordering: .releasing)
            defer { configurationTransition.store(false, ordering: .releasing) }
            if phase == .running, runtime.epoch == epoch {
                nativeBundle = old
                if let old { AWCore.installRuntimePreferences(old.preferences) }
                else { AWCore.installRuntimePreferences(nil) }
                do { try await applySettings(oldPreferences) }
                catch {
                    // Continuing with uncertain OS routes would break rollback.
                    await stop()
                    throw RuntimeConfigurationFailure.rollbackFailed
                }
                if let oldConfiguration, phase == .running {
                    executeLifecycle(.restart, configuration: oldConfiguration)
                }
            }
            let receipt = RuntimeConfigurationReceipt(versionID: bundle.id, activeVersionID: old?.id,
                snapshotID: bundle.snapshotID, status: .rejected, message: failure.localizedDescription)
            try store.record(receipt)
            return receipt
        }
    }
}
