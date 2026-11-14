//
//  Operations.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/20/26.
//

import Foundation
import Observation

@MainActor
@Observable
final class Operations {
    @ObservationIgnored private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    /// The editable document and its immutable runtime publications.
    var configurationDocument: ConfigurationDocumentOperations {
        ConfigurationDocumentOperations(
            activation: ConfigurationActivation(),
            tunnel: container.tunnel,
            selection: container.selection
        )
    }

    var tunnel: TunnelOperations {
        TunnelOperations(tunnel: container.tunnel, selection: container.selection)
    }
}
