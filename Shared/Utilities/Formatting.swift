//
//  Formatting.swift
//  NaiveFlow
//
//  Created by NodePassProject on 9/23/26.
//

import Foundation

nonisolated enum Formatting {
    private static let byteCountStyle = ByteCountFormatStyle(style: .binary, spellsOutZero: false)

    static func formatBytes(_ bytes: Int64) -> String {
        bytes.formatted(byteCountStyle)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)
        )
    }
}
