//
//  CertificatePolicy.swift
//  NaiveFlow
//
//  Created by NodePassProject on 4/11/26.
//

import Foundation
import CryptoKit
import Security
import Synchronization

nonisolated enum CertificatePolicy {
    // MARK: - Verification
    
    enum Verification {
        case trusted
        case rejected(reason: String)
    }
    
    static func verify(chain: [SecCertificate], serverName: String, policy: TLSCertificatePolicy = .init()) async -> Verification {
        switch prepare(chain: chain, serverName: serverName, policy: policy) {
        case .decided(let verification):
            return verification
        case .evaluate(let trust):
            let handoff = TrustHandoff(trust: trust)
            let resumed = OneShotLatch()
            return await withCheckedContinuation { continuation in
                evaluationQueue.async {
                    let status = SecTrustEvaluateAsyncWithError(handoff.trust, evaluationQueue) { _, trusted, error in
                        guard resumed.claim() else { return }
                        continuation.resume(returning: outcome(trusted: trusted, error: error))
                    }
                    if status != errSecSuccess, resumed.claim() {
                        continuation.resume(returning: .rejected(reason: "Certificate evaluation could not start (\(status))"))
                    }
                }
            }
        }
    }

    private static let evaluationQueue = DispatchQueue(
        label: "com.argsment.NaiveFlow.CertificatePolicy",
        qos: .userInitiated
    )
    
    private struct TrustHandoff: @unchecked Sendable {
        let trust: SecTrust
    }

    private enum Preparation {
        case decided(Verification)
        case evaluate(SecTrust)
    }

    private static func prepare(chain: [SecCertificate], serverName: String, policy: TLSCertificatePolicy) -> Preparation {
        guard let leaf = chain.first else {
            return .decided(.rejected(reason: "No server certificates received"))
        }

        if let expected = policy.certificateSHA256 {
            let actual = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
                .map { String(format: "%02x", $0) }.joined()
            return .decided(actual == expected ? .trusted : .rejected(reason: "Server certificate SHA-256 fingerprint mismatch"))
        }
        if policy.insecureSkipVerify { return .decided(.trusted) }

        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, serverName as CFString)
        guard SecTrustCreateWithCertificates(chain as CFArray, policy, &trust) == errSecSuccess,
              let trust else {
            return .decided(.rejected(reason: "Failed to create trust object"))
        }
        return .evaluate(trust)
    }

    private static func outcome(trusted: Bool, error: CFError?) -> Verification {
        if trusted {
            return .trusted
        }
        let message = (error as Error?)?.localizedDescription ?? "Certificate evaluation failed"
        return .rejected(reason: message)
    }

}
