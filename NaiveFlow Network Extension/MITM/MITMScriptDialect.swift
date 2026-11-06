//
//  MITMScriptDialect.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/6/26.
//

import Foundation

/// Which scripting dialect a script targets. The engine injects exactly one
/// dialect's globals per run, so a Surge script never sees Quantumult X globals
/// (and vice versa) — environment sniffing stays reliable.
nonisolated enum MITMScriptDialect: Sendable {
    case native
    case surge
    case quantumultX
}
