import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    var iCloudSyncEnabled = AWCore.getICloudSyncEnabled() {
        didSet {
            AWCore.setICloudSyncEnabled(iCloudSyncEnabled)
            Task { await CloudSync.shared.syncEnabledDidChange() }
        }
    }
    var remnawaveHWIDEnabled = AWCore.getRemnawaveHWIDEnabled() {
        didSet { AWCore.setRemnawaveHWIDEnabled(remnawaveHWIDEnabled) }
    }
}
