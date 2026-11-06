//
//  MITMExportOperation.swift
//  RuleProxy
//
//  Created by NodePassProject on 10/9/26.
//

import Foundation

@MainActor
struct MITMExportScheduler {
    let debouncer: Debouncer
    let ruleSetStore: MITMRuleSetStore
    let moduleStore: ModuleStore

    func schedule() {
        debouncer.schedule { [ruleSetStore, moduleStore] in
            let ruleSets = moduleStore.exportedMITMRuleSets + ruleSetStore.ruleSets
            await MITMExportOperation(ruleSets: ruleSets).run()
        }
    }
}

@MainActor
struct MITMExportOperation {
    let ruleSets: [MITMRuleSet]

    func run() async {
        let ruleSets = ruleSets
        await Task.detached {
            _ = MITMSnapshot(ruleSets: ruleSets).exportBinaryToAppGroup()
            // Trust/certificate settings can change without changing rule bytes.
            // Notify only after the export, including that unchanged-byte case.
            ConfigurationCoordinator.Announcement.mitm.post()
        }.value
    }
}
