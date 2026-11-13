import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    var remnawaveHWIDEnabled = AWCore.getRemnawaveHWIDEnabled() {
        didSet { AWCore.setRemnawaveHWIDEnabled(remnawaveHWIDEnabled) }
    }
}
