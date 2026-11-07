import Foundation

/// Publication never mutates the manually maintained node/rule stores. Their
/// complete bytes are retained as a baseline; text mode has one authoritative
/// immutable document version, so rollback cannot delete unrelated user items.
@MainActor
struct ConfigurationPublisher {
    let activation: ConfigurationActivation
    let tunnel: TunnelController?
    var runningOverride: Bool? = nil
    var ruleSetLoader: NativeRuleSet.Loader? = nil
    var geoLoader: NativeGeoResources.Loader? = nil
    var deliveryOverride: (@MainActor (RuntimeConfigurationBundle, Bool) async throws -> RuntimeConfigurationReceipt?)? = nil
    var preferencesSink: @MainActor ([String: RuntimePreferenceValue]?) -> Void = { AWCore.installRuntimePreferences($0) }

    var stateSink: @MainActor (RuntimeConfigurationBundle) -> Void = { _ in }

    private var isRunning: Bool { runningOverride ?? tunnel?.hasRunningTunnel ?? false }
    private func deliver(_ bundle: RuntimeConfigurationBundle, running: Bool) async throws -> RuntimeConfigurationReceipt? {
        if let deliveryOverride { return try await deliveryOverride(bundle, running) }
        return try await tunnel?.applyRuntimeVersion(bundle, requireRunning: running)
    }
    private func validateReceipt(_ receipt: RuntimeConfigurationReceipt?, for bundle: RuntimeConfigurationBundle, required: Bool) throws {
        guard let receipt else {
            if required { throw RuntimeConfigurationFailure.unavailable }
            return
        }
        guard receipt.status == .applied else {
            throw RuntimeConfigurationFailure.rejected(receipt.message ?? "Version rejected")
        }
        guard receipt.versionID == bundle.id, receipt.activeVersionID == bundle.id else {
            throw RuntimeConfigurationFailure.superseded
        }
    }
    private func restoreRunning(_ bundle: RuntimeConfigurationBundle) async throws {
        let receipt = try await deliver(bundle, running: true)
        try validateReceipt(receipt, for: bundle, required: true)
    }
    var bundleStore: RuntimeBundleStore {
        RuntimeBundleStore(directory: activation.store.directory.appendingPathComponent("runtime", isDirectory: true))
    }
    /// Feeds a restored bundle's preference view to the sink. A manual baseline
    /// (`snapshotID == nil`) must not pin, so it sends `nil` to leave live manual
    /// edits in effect; a text version pins its captured values.
    private func sinkPreferences(_ bundle: RuntimeConfigurationBundle) {
        preferencesSink(bundle.pinsRuntimePreferences ? bundle.preferences : nil)
    }

    func publish(text: String) async throws -> (ConfigurationActivation.Activation, ConfigurationInstaller.Outcome) {
        try activation.saveDraft(text)
        var result = ConfigurationCoordinator().compile(text: text)
        guard result.isActivatable else {
            throw ConfigurationActivation.Failure.notActivatable(errors: result.errorCount, warnings: result.warningCount)
        }
        let ruleSetContents = try await NativeRuleSet.resolve(result.parsed, loader: ruleSetLoader)
        let geoResources = try await NativeGeoResources.resolve(result.parsed,
            cacheDirectory: activation.store.directory.appendingPathComponent("geo-sources", isDirectory: true), loader: geoLoader)
        if !ruleSetContents.isEmpty || geoResources != nil {
            result = ConfigurationCoordinator().compile(text: text, ruleSetContents: ruleSetContents, geoResources: geoResources)
            guard result.isActivatable else {
                throw NativeRuleSet.Failure(message: result.diagnostics.filter { $0.severity == .error }
                    .map(\.localizedDescription).joined(separator: "\n"))
            }
        }
        let mitm = try await result.compiled.textMITM.resolveScripts()
        try Task.checkCancellation()
        let lease = try bundleStore.lease()
        defer { withExtendedLifetime(lease) {} }
        let originalManifest = activation.store.manifest()
        var head = try bundleStore.head()
        if head == nil {
            let fallback = try ActiveConfiguration.load() ?? directNode()
            let baseline = RuntimeConfigurationBundle(id: UUID(), snapshotID: nil, parentID: nil,
                preferences: AWCore.runtimePreferences(), nodes: [fallback], selectedNodeID: fallback.id,
                rules: nil, finalAction: .defaultProxy, mitmRuleSets: [],
                legacyRouting: AWCore.getRoutingData(), legacyMITM: AWCore.getMITMData())
            try bundleStore.publish(baseline, expected: nil)
            head = try bundleStore.head()
        }
        guard let head else { throw RuntimeConfigurationFailure.invalidBundle }
        let previous = try bundleStore.load(head.current)
        let compiled = result.compiled
        let snapshot = ConfigurationSnapshot(text: text, compiled: compiled)
        var nodes = compiled.proxies
        for chain in compiled.chains {
            if let composite = chain.resolveComposite(from: compiled.proxies) {
                nodes.append(composite)
            }
        }
        // Synthesized helper nodes (e.g. built-in DIRECT group members) must be
        // dialable at runtime but are not counted as user proxies.
        nodes.append(contentsOf: compiled.syntheticProxies)
        if nodes.isEmpty { nodes = [directNode()] }
        let selected = nodes.first { $0.id == previous.selectedNodeID }
            ?? nodes.first { $0.name == previous.selectedNode?.name } ?? nodes[0]
        let preferences = try AWCore.captureRuntimePreferences(
            base: previous.pinsRuntimePreferences ? previous.preferences : nil
        ) {
            // Server fields select their transport; explicit mode fields run last.
            let keys = compiled.settings.values.keys.sorted {
                let a = $0.hasSuffix("dns-mode"), b = $1.hasSuffix("dns-mode")
                return a == b ? $0 < $1 : !a
            }
            for key in keys {
                if let value = compiled.settings.values[key] { ConfigurationSettingsBindings.write(key, value) }
            }
            HostMapping.store(compiled.hosts)
            try ActiveConfiguration.store(selected)
        }
        let bundle = RuntimeConfigurationBundle(id: UUID(), snapshotID: snapshot.id, parentID: previous.id,
            preferences: preferences, nodes: nodes, selectedNodeID: selected.id,
            rules: compiled.orderedRules, finalAction: compiled.finalAction, mitmRuleSets: mitm,
            policyGroups: compiled.policyGroups,
            legacyRouting: nil, legacyMITM: nil, geo: compiled.geo)
        let previousCompiled = activation.active?.compiled
        let plan = ConfigurationCoordinator().plan(from: previousCompiled, to: compiled)
        try activation.store.save(snapshot)
        // The small host journal restores metadata after an offline/startup
        // rejection or a host process crash; the kernel only writes receipts.
        try JSONEncoder().encode(originalManifest).write(
            to: bundleStore.directory.appendingPathComponent("\(bundle.id.uuidString).manifest-backup.json"), options: .atomic
        )
        do { try bundleStore.publish(bundle, expected: head) }
        catch {
            let original = error
            if try bundleStore.head()?.current == bundle.id { _ = try bundleStore.rollback(expected: bundle.id) }
            throw original
        }
        activation.store.clearConfirmation()
        AWNotificationCenter.notifyConfigurationVersionChanged()
        let wasRunning = isRunning
        do {
            preferencesSink(preferences)
            let receipt = try await deliver(bundle, running: wasRunning)
            try validateReceipt(receipt, for: bundle, required: wasRunning)
            guard try bundleStore.head()?.current == bundle.id else { throw RuntimeConfigurationFailure.superseded }
            try activation.store.activate(snapshot.id, confirmed: receipt != nil)
            stateSink(bundle)
            var notes: [String] = []
            if !compiled.geo.sources.isEmpty {
                notes.append("Geo data: \(compiled.geo.sources.count) source(s), \(compiled.geo.entryCount) entries pinned to this version. Reapply to refresh; rollback uses saved data.")
            }
            if receipt == nil { notes.append("Version saved. The stopped tunnel will validate and confirm it at its next start.") }
            notes.append("Text configuration is authoritative for this version; manual node and rule stores are preserved for rollback.")
            let installed = ConfigurationInstallation(snapshotId: snapshot.id)
            let execution = ConfigurationReloadPlan(changes: plan.reload.changes + [
                .init(field: "runtime-version", scope: .stackRestart, summary: "All modules switch to the same immutable version.")
            ])
            let outcome = ConfigurationInstaller.Outcome(installation: installed, plan: execution, modulePlan: plan,
                addedProxies: compiled.proxies.map(\.name), updatedProxies: [], removedProxies: [],
                addedGroups: compiled.proxyGroups.map(\.name), removedGroups: [],
                ruleSets: compiled.ruleSets.map(\.name), removedRuleSets: [], notes: notes)
            return (.init(snapshot: snapshot, result: result), outcome)
        } catch {
            let original = error
            do {
                _ = try bundleStore.rollback(expected: bundle.id)
                AWNotificationCenter.notifyConfigurationVersionChanged()
                sinkPreferences(previous)
                stateSink(previous)
                try activation.store.restoreManifest(originalManifest)
                if wasRunning {
                    try await restoreRunning(previous)
                }
            } catch {
                activation.record("Configuration failed and recovery needs attention: \(error.localizedDescription)")
                throw RuntimeConfigurationFailure.rejected("\(original.localizedDescription) Recovery: \(error.localizedDescription)")
            }
            activation.record(original.localizedDescription)
            throw original
        }
    }

    func rollback() async throws -> ConfigurationRollbackOutcome {
        let lease = try bundleStore.lease()
        defer { withExtendedLifetime(lease) {} }
        guard let original = try bundleStore.head(), let previousID = original.previous else {
            throw ConfigurationActivation.Failure.nothingToRollBack
        }
        let previous = try bundleStore.load(previousID)
        let current = try bundleStore.load(original.current)
        let oldManifest = activation.store.manifest()
        let wasRunning = isRunning
        _ = try bundleStore.rollback(expected: original.current)
        activation.store.clearConfirmation()
        AWNotificationCenter.notifyConfigurationVersionChanged()
        do {
            preferencesSink(previous.pinsRuntimePreferences ? previous.preferences : nil)
            let receipt = try await deliver(previous, running: wasRunning)
            try validateReceipt(receipt, for: previous, required: wasRunning)
            stateSink(previous)
            if let id = previous.snapshotID {
                try activation.store.activate(id, confirmed: receipt != nil)
                if let snapshot = activation.store.snapshot(id) { try activation.saveDraft(snapshot.text) }
            } else { try activation.store.restoreManifest(.init()) }
            return ConfigurationRollbackOutcome(summary: "Restored the previous complete runtime version.",
                notes: [receipt == nil ? "The tunnel will confirm the restored version at next start." : "All kernel modules confirmed the restored version."],
                plan: ConfigurationReloadPlan(changes: [.init(field: "runtime-version", scope: .stackRestart,
                    summary: "Restored the previous immutable version.")]))
        } catch {
            let originalError = error
            try bundleStore.restoreHead(original, expected: previousID)
            sinkPreferences(current)
            stateSink(current)
            try activation.store.restoreManifest(oldManifest)
            if wasRunning { try await restoreRunning(current) }
            throw originalError
        }
    }

    /// Complete a deferred/offline apply, or adopt the version that startup
    /// restored. Receipts identify the exact immutable version, never latest-id.
    func reconcile() throws {
        let lease = try bundleStore.lease()
        defer { withExtendedLifetime(lease) {} }
        try reconcileLocked()
    }

    /// Resume a publication interrupted by host termination, including one that
    /// needed reconnecting the provider. Called once the host knows VPN status.
    func recoverPending() async throws {
        let lease = try bundleStore.lease()
        defer { withExtendedLifetime(lease) {} }
        try reconcileLocked()
        guard isRunning, let head = try bundleStore.head() else { return }
        if let receipt = try bundleStore.receipt(head.current), receipt.requestID == head.requestID { return }
        let bundle = try bundleStore.load(head.current)
        do {
            let delivered = try await deliver(bundle, running: true)
            try validateReceipt(delivered, for: bundle, required: true)
            guard let receipt = delivered else { throw RuntimeConfigurationFailure.unavailable }
            try bundleStore.record(receipt)
            try reconcileLocked()
        } catch {
            try bundleStore.record(.init(versionID: bundle.id, activeVersionID: head.previous,
                snapshotID: bundle.snapshotID, status: .rejected, message: error.localizedDescription))
            try reconcileLocked()
            if let restored = try bundleStore.head(), restored.current != bundle.id {
                let previous = try bundleStore.load(restored.current)
                try await restoreRunning(previous)
            }
        }
    }

    private func reconcileLocked() throws {
        guard let head = try bundleStore.head(), let receipt = try bundleStore.receipt(head.current),
              receipt.requestID == head.requestID, receipt.versionID == head.current else { return }
        switch receipt.status {
        case .applied:
            let bundle = try bundleStore.load(head.current)
            try validateReceipt(receipt, for: bundle, required: true)
            sinkPreferences(bundle)
            stateSink(bundle)
            if let id = bundle.snapshotID { try activation.store.activate(id, confirmed: true) }
        case .rejected:
            let backupURL = bundleStore.directory.appendingPathComponent("\(head.current.uuidString).manifest-backup.json")
            let backup = try JSONDecoder().decode(ConfigurationSnapshotStore.Manifest.self, from: Data(contentsOf: backupURL))
            _ = try bundleStore.rollback(expected: head.current)
            if let current = try bundleStore.head() {
                let bundle = try bundleStore.load(current.current)
                sinkPreferences(bundle)
                stateSink(bundle)
                try activation.store.restoreManifest(backup)
            }
            activation.record(receipt.message ?? "The kernel restored the previous configuration.")
        }
    }

    private func directNode() -> ProxyConfiguration {
        ProxyConfiguration(name: "Direct", serverAddress: "", serverPort: 0, outbound: .direct(DirectConfiguration()))
    }
}

nonisolated struct ConfigurationRollbackOutcome: Sendable {
    let summary: String
    let notes: [String]
    let plan: ConfigurationReloadPlan
}
