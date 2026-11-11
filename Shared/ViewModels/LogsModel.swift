//
//  LogsModel.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/30/26.
//

import Foundation
import Observation

@MainActor
@Observable
class LogsModel {
    enum LogLevel: String {
        case info
        case warning
        case error
    }

    struct LogEntry: Identifiable, Equatable {
        let id: UUID
        let timestamp: Date
        let level: LogLevel
        let message: String
    }

    @ObservationIgnored private var generation: UInt64 = 0
    private(set) var logs: [LogEntry] = []

    func clear() {
        generation &+= 1
        logs = []
    }

    func poll(using tunnel: TunnelController) async {
        let generation = self.generation
        let response = await tunnel.send(.fetchLogs)

        guard !Task.isCancelled, generation == self.generation else { return }

        guard let response,
              let payload = try? JSONDecoder().decode(LogsResponse.self, from: response) else { return }

        self.logs = payload.logs.map { entry in
            LogEntry(
                id: entry.id,
                timestamp: Date(timeIntervalSinceReferenceDate: entry.timestamp),
                level: LogLevel(rawValue: entry.level.rawValue) ?? .info,
                message: entry.message
            )
        }
    }
}
