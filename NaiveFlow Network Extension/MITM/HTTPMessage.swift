//
//  HTTPMessage.swift
//  NaiveFlow
//
//  Created by NodePassProject on 6/4/26.
//

import Foundation

nonisolated struct HTTPMessage {
    let phase: MITMPhase
    var method: String?
    var url: String?
    var originalURL: String?
    var status: Int?
    var headers: [(name: String, value: String)]
    var body: Data
    let ruleSetID: UUID?
    var requestHeaders: [(name: String, value: String)] = []
}
