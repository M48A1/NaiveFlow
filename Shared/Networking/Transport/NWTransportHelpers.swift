//
//  NWTransportHelpers.swift
//  RuleProxy
//
//  Created by NodePassProject on 7/6/26.
//

import Foundation
import Synchronization
import Network

// MARK: - Stall

nonisolated final class NWStallLatch: Sendable {
    private let stallError = Mutex<NWError?>(nil)

    func watch(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak connection, self] state in
            switch state {
            case .waiting(let error), .failed(let error):
                if self.record(error) { connection?.cancel() }
            default:
                break
            }
        }
    }

    func failure(for error: NWError, operation: RuleProxyError.Transport.Operation) -> any Error {
        (stallError.withLock { $0 } ?? error).engineError(operation: operation)
    }

    private func record(_ error: NWError) -> Bool {
        stallError.withLock { stored in
            guard stored == nil else { return false }
            stored = error
            return true
        }
    }
}

// MARK: - NWError

extension NWError {
    nonisolated func ruleproxyError(operation: RuleProxyError.Transport.Operation) -> RuleProxyError {
        switch self {
        case .posix(let code):
            return .transport(.posix(operation, errno: code.rawValue))
        case .dns:
            return .dns(.resolutionFailed(host: nil, detail: localizedDescription))
        default:
            return .transport(.connectionFailed(endpoint: nil, detail: localizedDescription))
        }
    }
    
    nonisolated func engineError(operation: RuleProxyError.Transport.Operation) -> any Error {
        if case .posix(.ECANCELED) = self { return CancellationError() }
        return ruleproxyError(operation: operation)
    }
    
    nonisolated var connectWaitingDescription: String {
        switch self {
        case .posix(let code):
            return "waiting(errno \(code.rawValue): \(String(cString: strerror(code.rawValue))))"
        case .dns(let code):
            return "waiting(dns \(code))"
        default:
            return "waiting(\(localizedDescription))"
        }
    }
}

// MARK: - RuleProxyError

extension RuleProxyError {
    nonisolated static func networkFailure(_ error: Error, operation: Transport.Operation) -> RuleProxyError {
        if error is CancellationError { return .transport(.terminated) }
        if let nwError = error as? NWError { return nwError.ruleproxyError(operation: operation) }
        if let ruleproxyError = error as? RuleProxyError { return ruleproxyError }
        return .transport(.connectionFailed(endpoint: nil, detail: error.localizedDescription))
    }
    
    nonisolated static func errnoCode(from error: Error) -> Int32 {
        if error is CancellationError { return ECANCELED }
        if let nwError = error as? NWError, case .posix(let posix) = nwError { return posix.rawValue }
        return -1
    }
}

// MARK: - NWEndpoint.Host

extension NWEndpoint.Host {
    nonisolated init?(ipLiteral ip: String) {
        if ip.contains(":") {
            guard let address = IPv6Address(ip) else { return nil }
            self = .ipv6(address)
        } else {
            guard let address = IPv4Address(ip) else { return nil }
            self = .ipv4(address)
        }
    }
    
    nonisolated static func dialHost(for host: String, resolution: DialResolution) async throws -> NWEndpoint.Host {
        if let literal = NWEndpoint.Host(ipLiteral: host) { return literal }
        switch resolution {
        case .system:
            return .name(host, nil)
        case .proxies:
            let resolver = DNSResolver.proxies
            guard !resolver.usesSystemUpstream,
                  let resolved = await resolver.resolveHost(host),
                  let literal = NWEndpoint.Host(ipLiteral: resolved)
            else { return .name(host, nil) }
            return literal
        case .localRequests:
            let resolver = DNSResolver.localRequests
            var address = await resolver.resolveHost(host, family: .ipv4)
            if address == nil {
                address = await resolver.resolveHost(host, family: .ipv6)
            }
            guard let resolved = address, let literal = NWEndpoint.Host(ipLiteral: resolved) else {
                throw RuleProxyError.dns(.resolutionFailed(host: host, detail: nil))
            }
            return literal
        }
    }
}

// MARK: - Dial resolution

nonisolated enum DialResolution: Sendable {
    case system
    case proxies
    case localRequests
}
