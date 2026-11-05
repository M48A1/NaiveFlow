//
//  ConnectionFailureReporter.swift
//  RuleProxy
//
//  Created by NodePassProject on 4/18/26.
//

import Foundation

nonisolated final class ConnectionFailureReporter {
    private let prefix: String
    private let logger: RuleProxyLogger
    private var reported = false

    init(prefix: String, logger: RuleProxyLogger) {
        self.prefix = prefix
        self.logger = logger
    }

    func report(operation: String, endpoint: @autoclosure () -> String, error: Error) {
        guard !reported else { return }
        reported = true
        guard let level = RuleProxyError.logLevel(of: error) else { return }
        logger.log("\(prefix) \(endpoint()): \(operation) failed: \(RuleProxyError.logDescription(error))", level: level)
    }

    func markReported() {
        reported = true
    }
}
