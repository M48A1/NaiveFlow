//
//  TunnelLifecycle.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/13/26.
//

import Synchronization

typealias TunnelPhase = RuntimeCoordinator.Phase

nonisolated enum IPStackAbortContext: UInt8, AtomicRepresentable {
    case none
    case teardown
}
