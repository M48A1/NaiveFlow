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

    private(set) var logs: [LogEntry] = []

    func clear() {
        logs = []
    }

    func poll(using tunnel: TunnelController) async {
        let response = await tunnel.send(.fetchLogs)

        guard !Task.isCancelled else { return }

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
