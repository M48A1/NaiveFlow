//
//  MITMCertificateStore.swift
//  NaiveFlow
//
//  Created by NodePassProject on 5/3/26.
//

import Foundation
import CryptoKit
import Security
import Synchronization

nonisolated final class MITMCertificateStore: Sendable {

    // MARK: - Configuration

    private static let accessGroup = AWCore.Identifier.appGroupSuite

    private static let service = "com.argsment.NaiveFlow.MITM"

    private static let privateKeyTag = "\(service).caPrivateKey".data(using: .utf8)!
    private static let certificateAccount = "\(service).caCertificate"
    private static let serialAccount = "\(service).caSerial"

    typealias CA = (privateKey: SecKey, certificateDER: Data)

    private let cachedCA = Mutex<CA?>(nil)

    // MARK: - CA Lifecycle

    func loadCA() -> CA? {
        cachedCA.withLock { cache in try? loadCACachedUnlocked(&cache) }
    }

    func reloadCA() -> Bool {
        cachedCA.withLock { cache in
            let previous = cache?.certificateDER
            cache = nil
            return (try? loadCACachedUnlocked(&cache))?.certificateDER != previous
        }
    }

    func delete() {
        cachedCA.withLock { cache in deleteUnlocked(&cache) }
    }

    // MARK: - Trust State

    func isCATrusted() -> Bool { isCATrusted(loadCA()) }

    func isCATrusted(_ identity: CA?) -> Bool {
        guard let (caPrivateKey, caCertificateDER) = identity else {
            return false
        }

        let testHost = "naiveflow-mitm-trust-check.invalid"
        let leafKey = P256.Signing.PrivateKey()
        let now = Date()

        let leafDER: Data
        do {
            leafDER = try X509Builder.buildLeafCertificate(
                leafPublicKey: leafKey.publicKey,
                caPrivateKey: caPrivateKey,
                caCertificateDER: caCertificateDER,
                hostname: testHost,
                serial: randomSerial(),
                notBefore: now.addingTimeInterval(-60),
                notAfter: now.addingTimeInterval(60 * 60)
            )
        } catch {
            return false
        }

        guard let leafCertificate = SecCertificateCreateWithData(nil, leafDER as CFData),
              let caCertificate = SecCertificateCreateWithData(nil, caCertificateDER as CFData) else {
            return false
        }

        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, testHost as CFString)
        let chain: [SecCertificate] = [leafCertificate, caCertificate]
        let status = SecTrustCreateWithCertificates(chain as CFArray, policy, &trust)
        guard status == errSecSuccess, let trust else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    // MARK: - Export

    func exportMobileConfig(for identity: CA?) -> Data? {
        guard let (caPrivateKey, certificateDER) = identity else { return nil }

        let fingerprint = SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
        let identifier = "com.argsment.NaiveFlow.mitm.root.\(fingerprint)"
        let payloadIdentifier = "\(identifier).payload"
        let payloadUUID = UUID().uuidString
        let outerUUID = UUID().uuidString

        let plist: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": outerUUID,
            "PayloadDisplayName": "NaiveFlow Root Certificate",
            "PayloadDescription": "Installs NaiveFlow Root Certificate.",
            "PayloadOrganization": "NaiveFlow",
            "PayloadContent": [
                [
                    "PayloadType": "com.apple.security.root",
                    "PayloadVersion": 1,
                    "PayloadIdentifier": payloadIdentifier,
                    "PayloadUUID": payloadUUID,
                    "PayloadDisplayName": "NaiveFlow Root Certificate",
                    "PayloadDescription": "The CA is used in NaiveFlow app.",
                    "PayloadCertificateFileName": "NaiveFlowRootCertificate.cer",
                    "PayloadContent": certificateDER,
                ]
            ]
        ]

        guard let profileData = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ) else {
            return nil
        }

        return (try? signProfile(profileData, caPrivateKey: caPrivateKey, caCertificateDER: certificateDER)) ?? profileData
    }

    private func signProfile(_ profileData: Data, caPrivateKey: SecKey, caCertificateDER: Data) throws -> Data {
        let signingKey = try makeEphemeralSigningKey()
        let now = Date()
        let notAfter = Calendar(identifier: .gregorian).date(byAdding: .year, value: 1, to: now)
            ?? now.addingTimeInterval(60 * 60 * 24 * 365)

        let leafDER = try X509Builder.buildSigningCertificate(
            signingKey: signingKey,
            caPrivateKey: caPrivateKey,
            caCertificateDER: caCertificateDER,
            commonName: "NaiveFlow Profile Signing",
            serial: randomSerial(),
            notBefore: now.addingTimeInterval(-60 * 60),
            notAfter: notAfter
        )

        return try X509Builder.buildSignedProfile(
            profileData: profileData,
            signerPrivateKey: signingKey,
            signerCertificateDER: leafDER,
            certificates: [leafDER, caCertificateDER]
        )
    }

    private func makeEphemeralSigningKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = (error?.takeRetainedValue()).flatMap { CFErrorCopyDescription($0) as String? } ?? "unknown"
            throw NaiveFlowError.certificate(.keyGenerationFailed(detail: message))
        }
        return key
    }

    // MARK: - Leaf Signing Inputs

    /// Returns a fresh 16-byte random serial. Randomness, not a shared counter:
    /// two App Group processes could mint duplicates (RFC 5280 §4.1.2.2).
    func nextSerial() -> Data {
        randomSerial()
    }

    // MARK: - Private — CA load / generate / delete

    private func loadCACachedUnlocked(_ cache: inout CA?) throws -> CA {
        if let cache { return cache }
        let loaded = try loadCAUnlocked()
        cache = loaded
        return loaded
    }

    private func loadCAUnlocked() throws -> CA {
        let certificate = try readCertificateUnlocked()
        let key = try readPrivateKeyUnlocked()
        return (key, certificate)
    }

    private func deleteUnlocked(_ cache: inout CA?) {
        cache = nil
        deletePrivateKey()
        deleteCertificate()
        deleteSerial()
    }

    // MARK: - Private — Keychain (Private Key)

    private func readPrivateKeyUnlocked() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.privateKeyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecAttrAccessGroup as String: Self.accessGroup,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item, CFGetTypeID(item) == SecKeyGetTypeID() else {
            throw NaiveFlowError.certificate(.keychainReadFailed(status: status))
        }
        return item as! SecKey
    }

    private func deletePrivateKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.privateKeyTag,
            kSecAttrAccessGroup as String: Self.accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private — Keychain (Certificate)

    private func readCertificateUnlocked() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.certificateAccount,
            kSecReturnData as String: true,
            kSecAttrAccessGroup as String: Self.accessGroup,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw NaiveFlowError.certificate(.keychainReadFailed(status: status))
        }
        return data
    }

    private func deleteCertificate() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.certificateAccount,
            kSecAttrAccessGroup as String: Self.accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private — Keychain (Legacy serial item)

    /// Purges the legacy monotonic-counter serial item left behind by old installs; serials are now random.
    private func deleteSerial() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.serialAccount,
            kSecAttrAccessGroup as String: Self.accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Helpers

    private func randomSerial() -> Data {
        for _ in 0..<3 {
            var bytes = Data(count: 16)
            let status = bytes.withUnsafeMutableBytes { pointer in
                SecRandomCopyBytes(kSecRandomDefault, 16, pointer.baseAddress!)
            }
            if status == errSecSuccess {
                return bytes
            }
        }
        // SecRandomCopyBytes failed repeatedly (extremely rare); a zero buffer would
        // collapse every serial to 1. A v4 UUID gives 122 random bits, never all-zero.
        return withUnsafeBytes(of: UUID().uuid) { Data($0) }
    }
}
