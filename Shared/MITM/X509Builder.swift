//
//  X509Builder.swift
//  NaiveFlow
//
//  Created by NodePassProject on 5/3/26.
//

import Foundation
import CryptoKit
import Network
import Security

nonisolated enum X509Builder {

    // MARK: - Public API

    static func buildCACertificate(
        privateKey: SecKey,
        subjectCN: String,
        organization: String,
        serial: Data,
        notBefore: Date,
        notAfter: Date
    ) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw NaiveFlowError.certificate(.publicKeyExportFailed)
        }
        let spki = try buildECP256SPKI(publicKey: publicKey)
        let subject = encodeName(commonName: subjectCN, organization: organization)

        let extensions = encodeExtensions([
            encodeBasicConstraintsCA(pathLength: 0),
            encodeKeyUsage(keyCertSign: true, cRLSign: true, digitalSignature: false),
            try encodeSubjectKeyIdentifier(spki: spki),
        ])

        let tbs = encodeTBSCertificate(
            serial: normalizeSerial(serial),
            issuer: subject,
            validity: encodeValidity(notBefore: notBefore, notAfter: notAfter),
            subject: subject,
            spki: spki,
            extensions: extensions
        )

        let signature = try sign(privateKey: privateKey, data: tbs)
        return encodeCertificate(tbs: tbs, signature: signature)
    }

    static func buildLeafCertificate(
        leafPublicKey: P256.Signing.PublicKey,
        caPrivateKey: SecKey,
        caCertificateDER: Data,
        hostname: String,
        serial: Data,
        notBefore: Date,
        notAfter: Date
    ) throws -> Data {
        let leafSPKI = try buildECP256SPKI(publicKeyX963: leafPublicKey.x963Representation)
        let caComponents = try parseCAComponents(certificateDER: caCertificateDER)

        let cnHostname: String
        if hostname.hasPrefix("["), hostname.hasSuffix("]"), hostname.count >= 2 {
            cnHostname = String(hostname.dropFirst().dropLast())
        } else {
            cnHostname = hostname
        }
        let subject = encodeName(commonName: cnHostname, organization: "NaiveFlow")
        let validity = encodeValidity(notBefore: notBefore, notAfter: notAfter)

        let extensions = encodeExtensions([
            encodeBasicConstraintsLeaf(),
            encodeKeyUsage(keyCertSign: false, cRLSign: false, digitalSignature: true),
            encodeExtendedKeyUsageServerAuth(),
            try encodeSubjectKeyIdentifier(spki: leafSPKI),
            encodeAuthorityKeyIdentifier(keyIdentifier: caComponents.subjectKeyIdentifier),
            encodeSubjectAltName(hostname: hostname),
        ])

        let tbs = encodeTBSCertificate(
            serial: normalizeSerial(serial),
            issuer: caComponents.subjectDN,
            validity: validity,
            subject: subject,
            spki: leafSPKI,
            extensions: extensions
        )

        let signature = try sign(privateKey: caPrivateKey, data: tbs)
        return encodeCertificate(tbs: tbs, signature: signature)
    }

    static func buildSigningCertificate(
        signingKey: SecKey,
        caPrivateKey: SecKey,
        caCertificateDER: Data,
        commonName: String,
        serial: Data,
        notBefore: Date,
        notAfter: Date
    ) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(signingKey) else {
            throw NaiveFlowError.certificate(.publicKeyExportFailed)
        }
        let spki = try buildECP256SPKI(publicKey: publicKey)
        let caComponents = try parseCAComponents(certificateDER: caCertificateDER)
        let subject = encodeName(commonName: commonName, organization: "NaiveFlow")

        let extensions = encodeExtensions([
            encodeBasicConstraintsLeaf(),
            encodeKeyUsage(keyCertSign: false, cRLSign: false, digitalSignature: true),
            try encodeSubjectKeyIdentifier(spki: spki),
            encodeAuthorityKeyIdentifier(keyIdentifier: caComponents.subjectKeyIdentifier),
        ])

        let tbs = encodeTBSCertificate(
            serial: normalizeSerial(serial),
            issuer: caComponents.subjectDN,
            validity: encodeValidity(notBefore: notBefore, notAfter: notAfter),
            subject: subject,
            spki: spki,
            extensions: extensions
        )

        let signature = try sign(privateKey: caPrivateKey, data: tbs)
        return encodeCertificate(tbs: tbs, signature: signature)
    }

    // MARK: - CMS Profile Signing

    static func buildSignedProfile(
        profileData: Data,
        signerPrivateKey: SecKey,
        signerCertificateDER: Data,
        certificates: [Data]
    ) throws -> Data {
        let (issuer, serial) = try parseIssuerAndSerial(certificateDER: signerCertificateDER)

        let digestAlgorithm = ASN1.sequence(ASN1OID.sha256)

        let contentTypeAttr = ASN1.sequence(
            ASN1OID.attrContentType + ASN1.set(ASN1OID.data)
        )
        let messageDigestAttr = ASN1.sequence(
            ASN1OID.attrMessageDigest + ASN1.set(ASN1.octetString(Data(SHA256.hash(data: profileData))))
        )
        let attributes = derSortedSetOf([contentTypeAttr, messageDigestAttr])

        let signature = try sign(privateKey: signerPrivateKey, data: ASN1.set(attributes))
        let signedAttrs = ASN1.contextSpecific(tag: 0, constructed: true, content: attributes)

        var signerInfo = Data()
        signerInfo.append(ASN1.integer(1))
        signerInfo.append(ASN1.sequence(issuer + serial))
        signerInfo.append(digestAlgorithm)
        signerInfo.append(signedAttrs)
        signerInfo.append(algorithmECDSAWithSHA256)
        signerInfo.append(ASN1.octetString(signature))

        let eContent = ASN1.contextSpecific(tag: 0, constructed: true, content: ASN1.octetString(profileData))
        let encapContentInfo = ASN1.sequence(ASN1OID.data + eContent)

        var certificateSet = Data()
        for certificate in certificates { certificateSet.append(certificate) }

        var signedData = Data()
        signedData.append(ASN1.integer(1))
        signedData.append(ASN1.set(digestAlgorithm))
        signedData.append(encapContentInfo)
        signedData.append(ASN1.contextSpecific(tag: 0, constructed: true, content: certificateSet))
        signedData.append(ASN1.set(ASN1.sequence(signerInfo)))

        let content = ASN1.contextSpecific(tag: 0, constructed: true, content: ASN1.sequence(signedData))
        return ASN1.sequence(ASN1OID.signedData + content)
    }

    private static func parseIssuerAndSerial(certificateDER: Data) throws -> (issuer: Data, serial: Data) {
        var parser = ASN1Parser(data: certificateDER)
        let certificate = try parser.readSequence()
        var certificateParser = ASN1Parser(data: certificate)
        let tbs = try certificateParser.readSequence()
        var tbsParser = ASN1Parser(data: tbs)
        try tbsParser.skipExplicitContextSpecific(tag: 0)
        let serial = try tbsParser.readNextWithHeader(expectedTag: 0x02)
        try tbsParser.skipNext()
        let issuer = try tbsParser.readNextWithHeader(expectedTag: 0x30)
        return (issuer, serial)
    }

    private static func derSortedSetOf(_ elements: [Data]) -> Data {
        let sorted = elements.sorted { lhs, rhs in
            let count = max(lhs.count, rhs.count)
            for index in 0..<count {
                let left = index < lhs.count ? lhs[lhs.startIndex + index] : 0
                let right = index < rhs.count ? rhs[rhs.startIndex + index] : 0
                if left != right { return left < right }
            }
            return lhs.count < rhs.count
        }
        var out = Data()
        for element in sorted { out.append(element) }
        return out
    }

    // MARK: - Subject / Issuer

    private static func encodeName(commonName: String, organization: String) -> Data {
        var rdnSequence = Data()
        rdnSequence.append(encodeRDN(oid: ASN1OID.organizationName, value: organization))
        rdnSequence.append(encodeRDN(oid: ASN1OID.commonName, value: commonName))
        return ASN1.sequence(rdnSequence)
    }

    private static func encodeRDN(oid: Data, value: String) -> Data {
        var attributeTypeAndValue = Data()
        attributeTypeAndValue.append(oid)
        attributeTypeAndValue.append(ASN1.utf8String(value))
        let attributeSequence = ASN1.sequence(attributeTypeAndValue)
        return ASN1.set(attributeSequence)
    }

    // MARK: - Validity

    private static func encodeValidity(notBefore: Date, notAfter: Date) -> Data {
        var validity = Data()
        validity.append(encodeTime(notBefore))
        validity.append(encodeTime(notAfter))
        return ASN1.sequence(validity)
    }

    private static func encodeTime(_ date: Date) -> Data {
        let components = utcComponents(date)
        if components.year >= 1950 && components.year <= 2049 {
            let twoDigitYear = components.year % 100
            let utcTime = String(
                format: "%02d%02d%02d%02d%02d%02dZ",
                twoDigitYear, components.month, components.day, components.hour, components.minute, components.second
            )
            return ASN1.utcTime(utcTime)
        } else {
            let generalized = String(
                format: "%04d%02d%02d%02d%02d%02dZ",
                components.year, components.month, components.day, components.hour, components.minute, components.second
            )
            return ASN1.generalizedTime(generalized)
        }
    }

    private static func utcComponents(
        _ date: Date
    ) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        let secondsPerDay = 86_400
        let total = Int(date.timeIntervalSince1970.rounded(.down))
        var days = total / secondsPerDay
        var secondOfDay = total % secondsPerDay
        if secondOfDay < 0 {
            secondOfDay += secondsPerDay
            days -= 1
        }
        let hour = secondOfDay / 3600
        let minute = (secondOfDay % 3600) / 60
        let second = secondOfDay % 60

        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day, hour, minute, second)
    }

    // MARK: - SubjectPublicKeyInfo

    private static func buildECP256SPKI(publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            _ = error?.takeRetainedValue()
            throw NaiveFlowError.certificate(.publicKeyExportFailed)
        }
        return try buildECP256SPKI(publicKeyX963: raw)
    }

    private static func buildECP256SPKI(publicKeyX963: Data) throws -> Data {
        guard publicKeyX963.count == 65, publicKeyX963.first == 0x04 else {
            throw NaiveFlowError.certificate(.invalidPublicKey)
        }

        var algorithm = Data()
        algorithm.append(ASN1OID.ecPublicKey)
        algorithm.append(ASN1OID.prime256v1)
        let algorithmSequence = ASN1.sequence(algorithm)

        let subjectPublicKey = ASN1.bitString(unusedBits: 0, content: publicKeyX963)

        var spki = Data()
        spki.append(algorithmSequence)
        spki.append(subjectPublicKey)
        return ASN1.sequence(spki)
    }

    // MARK: - Extensions

    private static func encodeExtensions(_ extensions: [Data]) -> Data {
        var inner = Data()
        for entry in extensions { inner.append(entry) }
        let sequence = ASN1.sequence(inner)
        return ASN1.contextSpecific(tag: 3, constructed: true, content: sequence)
    }

    private static func encodeExtension(oid: Data, critical: Bool, value: Data) -> Data {
        var inner = Data()
        inner.append(oid)
        if critical {
            inner.append(ASN1.boolean(true))
        }
        inner.append(ASN1.octetString(value))
        return ASN1.sequence(inner)
    }

    private static func encodeBasicConstraintsCA(pathLength: Int) -> Data {
        var basicConstraints = Data()
        basicConstraints.append(ASN1.boolean(true))
        basicConstraints.append(ASN1.integer(Int64(pathLength)))
        let value = ASN1.sequence(basicConstraints)
        return encodeExtension(oid: ASN1OID.basicConstraints, critical: true, value: value)
    }

    private static func encodeBasicConstraintsLeaf() -> Data {
        let value = ASN1.sequence(Data())
        return encodeExtension(oid: ASN1OID.basicConstraints, critical: true, value: value)
    }

    private static func encodeKeyUsage(keyCertSign: Bool, cRLSign: Bool, digitalSignature: Bool) -> Data {
        var positions: [Int] = []
        if digitalSignature { positions.append(0) }
        if keyCertSign      { positions.append(5) }
        if cRLSign          { positions.append(6) }
        guard let highest = positions.max() else {
            let bitString = ASN1.bitString(unusedBits: 0, content: Data())
            return encodeExtension(oid: ASN1OID.keyUsage, critical: true, value: bitString)
        }
        var byte: UInt8 = 0
        for position in positions {
            byte |= UInt8(0x80 >> position)
        }
        let unused = UInt8(7 - highest)
        let bitString = ASN1.bitString(unusedBits: unused, content: Data([byte]))
        return encodeExtension(oid: ASN1OID.keyUsage, critical: true, value: bitString)
    }

    private static func encodeSubjectAltName(hostname: String) -> Data {
        let generalName: Data
        if let ipBytes = parseIPAddress(hostname) {
            generalName = ASN1.contextSpecific(tag: 7, constructed: false, content: ipBytes)
        } else {
            let asciiHost = Self.idnaASCII(hostname) ?? hostname
            let nameBytes = Data(asciiHost.utf8)
            generalName = ASN1.contextSpecific(tag: 2, constructed: false, content: nameBytes)
        }
        let value = ASN1.sequence(generalName)
        return encodeExtension(oid: ASN1OID.subjectAltName, critical: false, value: value)
    }

    private static func parseIPAddress(_ hostname: String) -> Data? {
        let trimmed: String
        if hostname.hasPrefix("["), hostname.hasSuffix("]") {
            trimmed = String(hostname.dropFirst().dropLast())
        } else {
            trimmed = hostname
        }
        if trimmed.contains("%") { return nil }
        if Self.isDottedQuadIPv4(trimmed), let v4 = IPv4Address(trimmed) {
            return v4.rawValue
        }

        return nil
    }

    private static func isDottedQuadIPv4(_ string: String) -> Bool {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard (1...3).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), value <= 255
            else { return false }
        }
        return true
    }

    private static func idnaASCII(_ hostname: String) -> String? {
        guard hostname.contains(where: { !$0.isASCII }) else { return hostname }
        var labels: [String] = []
        for label in hostname.split(separator: ".", omittingEmptySubsequences: false) {
            if label.allSatisfy({ $0.isASCII }) {
                labels.append(String(label))
            } else {
                guard let punycode = punycodeEncode(String(label)) else { return nil }
                labels.append("xn--" + punycode)
            }
        }
        return labels.joined(separator: ".")
    }

    private static func punycodeEncode(_ input: String) -> String? {
        let base = 36, tmin = 1, tmax = 26, skew = 38, damp = 700
        let initialBias = 72, initialN = 128
        func adapt(_ delta: Int, _ pointCount: Int, _ firstTime: Bool) -> Int {
            var delta = firstTime ? delta / damp : delta / 2
            delta += delta / pointCount
            var k = 0
            while delta > ((base - tmin) * tmax) / 2 {
                delta /= (base - tmin)
                k += base
            }
            return k + (((base - tmin + 1) * delta) / (delta + skew))
        }
        func digit(_ value: Int) -> Character {
            Character(UnicodeScalar(UInt8(value < 26 ? value + 97 : value - 26 + 48)))
        }
        let scalars = Array(input.unicodeScalars)
        var output = ""
        var n = initialN, delta = 0, bias = initialBias
        var basic = 0
        for scalar in scalars where scalar.value < 0x80 {
            output.append(Character(scalar))
            basic += 1
        }
        if basic > 0 { output.append("-") }
        var handled = basic
        while handled < scalars.count {
            var m = Int.max
            for scalar in scalars where Int(scalar.value) >= n && Int(scalar.value) < m { m = Int(scalar.value) }
            if m - n > (Int.max - delta) / (handled + 1) { return nil }
            delta += (m - n) * (handled + 1)
            n = m
            for scalar in scalars {
                let codePoint = Int(scalar.value)
                if codePoint < n {
                    delta += 1
                    if delta == 0 { return nil }
                }
                if codePoint == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basic)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return output
    }

    private static func encodeExtendedKeyUsageServerAuth() -> Data {
        let value = ASN1.sequence(ASN1OID.serverAuth)
        return encodeExtension(oid: ASN1OID.extKeyUsage, critical: false, value: value)
    }

    private static func encodeSubjectKeyIdentifier(spki: Data) throws -> Data {
        let publicKeyContent = try extractSubjectPublicKey(spki: spki)
        let digest = sha1(publicKeyContent)
        let value = ASN1.octetString(Data(digest))
        return encodeExtension(oid: ASN1OID.subjectKeyIdentifier, critical: false, value: value)
    }

    private static func encodeAuthorityKeyIdentifier(keyIdentifier: Data) -> Data {
        let inner = ASN1.contextSpecific(tag: 0, constructed: false, content: keyIdentifier)
        let value = ASN1.sequence(inner)
        return encodeExtension(oid: ASN1OID.authorityKeyIdentifier, critical: false, value: value)
    }

    // MARK: - Algorithm Identifier

    private static let algorithmECDSAWithSHA256: Data = {
        ASN1.sequence(ASN1OID.ecdsaWithSHA256)
    }()

    // MARK: - TBSCertificate

    private static func encodeTBSCertificate(
        serial: Data,
        issuer: Data,
        validity: Data,
        subject: Data,
        spki: Data,
        extensions: Data
    ) -> Data {
        var tbs = Data()
        let versionInner = ASN1.integer(2)
        let versionWrapped = ASN1.contextSpecific(tag: 0, constructed: true, content: versionInner)
        tbs.append(versionWrapped)
        tbs.append(ASN1.rawInteger(serial))
        tbs.append(algorithmECDSAWithSHA256)
        tbs.append(issuer)
        tbs.append(validity)
        tbs.append(subject)
        tbs.append(spki)
        tbs.append(extensions)

        return ASN1.sequence(tbs)
    }

    // MARK: - Outer Certificate

    private static func encodeCertificate(tbs: Data, signature: Data) -> Data {
        var inner = Data()
        inner.append(tbs)
        inner.append(algorithmECDSAWithSHA256)
        inner.append(ASN1.bitString(unusedBits: 0, content: signature))
        return ASN1.sequence(inner)
    }

    // MARK: - Signing

    private static func sign(privateKey: SecKey, data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        let algorithm: SecKeyAlgorithm = .ecdsaSignatureMessageX962SHA256
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, data as CFData, &error) as Data? else {
            let cfError = error?.takeRetainedValue()
            throw NaiveFlowError.certificate(.signingFailed(detail: cfError.flatMap { CFErrorCopyDescription($0) as String? } ?? "unknown"))
        }
        return signature
    }

    fileprivate static func validateRootCA(_ der: Data, publicKey: SecKey) throws {
        var outer = ASN1Parser(data: der)
        var certificate = ASN1Parser(data: try outer.readSequence())
        let signed = try certificate.readNextWithHeader(expectedTag: 0x30)
        let algorithm = try certificate.readNextWithHeader(expectedTag: 0x30)
        let signature = try ASN1Parser.contentOf(certificate.readNextWithHeader(expectedTag: 0x03))
        guard outer.isAtEnd, certificate.isAtEnd, algorithm == algorithmECDSAWithSHA256, signature.first == 0,
              SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256,
                  Data(signed) as CFData, Data(signature.dropFirst()) as CFData, nil) else {
            throw MITMPKCS12.Failure.invalidIdentity
        }

        var tbs = ASN1Parser(data: try ASN1Parser.contentOf(signed))
        try tbs.skipExplicitContextSpecific(tag: 0)
        try tbs.skipNext()
        try tbs.skipNext()
        let issuer = try tbs.readNextWithHeader(expectedTag: 0x30)
        try tbs.skipNext()
        let subject = try tbs.readNextWithHeader(expectedTag: 0x30)
        try tbs.skipNext()
        var wrapper = ASN1Parser(data: try tbs.readExplicitContextSpecific(tag: 3))
        var extensions = ASN1Parser(data: try wrapper.readSequence())
        guard issuer == subject else { throw MITMPKCS12.Failure.invalidIdentity }
        while !extensions.isAtEnd {
            var entry = ASN1Parser(data: try extensions.readSequence())
            guard try entry.readNextWithHeader(expectedTag: 0x06) == ASN1OID.basicConstraints else { continue }
            if try entry.peekTag() == 0x01 { try entry.skipNext() }
            let value = try ASN1Parser.contentOf(entry.readNextWithHeader(expectedTag: 0x04))
            var bounds = ASN1Parser(data: value)
            var constraints = ASN1Parser(data: try bounds.readSequence())
            guard try constraints.readNextWithHeader(expectedTag: 0x01) == ASN1.boolean(true) else { break }
            _ = try parseCAComponents(certificateDER: der)
            return
        }
        throw MITMPKCS12.Failure.invalidIdentity
    }

    // MARK: - CA Component Reuse

    private struct CAComponents {
        let subjectDN: Data
        let subjectKeyIdentifier: Data
    }

    private static func parseCAComponents(certificateDER: Data) throws -> CAComponents {
        var parser = ASN1Parser(data: certificateDER)
        let certificate = try parser.readSequence()
        var certificateParser = ASN1Parser(data: certificate)
        let tbs = try certificateParser.readSequence()
        var tbsParser = ASN1Parser(data: tbs)
        try tbsParser.skipExplicitContextSpecific(tag: 0)
        try tbsParser.skipNext()
        try tbsParser.skipNext()
        try tbsParser.skipNext()
        try tbsParser.skipNext()
        let subjectDN = try tbsParser.readNextWithHeader(expectedTag: 0x30)
        try tbsParser.skipNext()
        let extensionsBlob = try tbsParser.readExplicitContextSpecific(tag: 3)
        let keyIdentifier = try extractSKIFromExtensions(extensionsBlob)
        return CAComponents(subjectDN: subjectDN, subjectKeyIdentifier: keyIdentifier)
    }

    private static func extractSKIFromExtensions(_ blob: Data) throws -> Data {
        var parser = ASN1Parser(data: blob)
        let sequence = try parser.readSequence()
        var sequenceParser = ASN1Parser(data: sequence)
        while !sequenceParser.isAtEnd {
            let extensionData = try sequenceParser.readSequence()
            var extensionParser = ASN1Parser(data: extensionData)
            let oid = try extensionParser.readNextWithHeader(expectedTag: 0x06)
            let oidContent = try ASN1Parser.contentOf(oid)
            if try extensionParser.peekTag() == 0x01 {
                try extensionParser.skipNext()
            }
            let octets = try extensionParser.readNextWithHeader(expectedTag: 0x04)
            let octetContent = try ASN1Parser.contentOf(octets)
            if oidContent == ASN1OID.contentSubjectKeyIdentifier {
                var inner = ASN1Parser(data: octetContent)
                let identifier = try inner.readNextWithHeader(expectedTag: 0x04)
                return try ASN1Parser.contentOf(identifier)
            }
        }
        throw NaiveFlowError.certificate(.asn1ParseFailed(detail: "CA cert missing SubjectKeyIdentifier"))
    }

    private static func extractSubjectPublicKey(spki: Data) throws -> Data {
        var parser = ASN1Parser(data: spki)
        let sequence = try parser.readSequence()
        var sequenceParser = ASN1Parser(data: sequence)
        try sequenceParser.skipNext()
        let bitString = try sequenceParser.readNextWithHeader(expectedTag: 0x03)
        let content = try ASN1Parser.contentOf(bitString)
        // First content byte is "unused bits" — skip it.
        guard !content.isEmpty else {
            throw NaiveFlowError.certificate(.asn1ParseFailed(detail: "Empty BIT STRING"))
        }
        return content.dropFirst()
    }

    // MARK: - Helpers

    private static func normalizeSerial(_ serial: Data) -> Data {
        var trimmed = serial
        while trimmed.count > 1 && trimmed.first == 0x00 {
            trimmed = trimmed.dropFirst()
        }
        if trimmed.isEmpty || (trimmed.count == 1 && trimmed.first == 0x00) {
            trimmed = Data([0x01])
        }
        if let first = trimmed.first, first & 0x80 != 0 {
            var prefixed = Data([0x00])
            prefixed.append(trimmed)
            return prefixed
        }
        return trimmed
    }

    private static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }
}

// MARK: - PKCS #12

/// Password-free PKCS #12 containing one P-256 private key and one root CA.
nonisolated enum MITMPKCS12 {
    static let configurationKey = "ca-p12"
    static let maximumEncodedBytes = 24 * 1024

    enum Failure: LocalizedError {
        case invalidIdentity

        var errorDescription: String? {
            "Expected a NaiveFlow PKCS #12 root CA and its matching P-256 private key."
        }
    }

    private static let keyBag = Data([0x06, 0x0B, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x01])
    private static let certBag = Data([0x06, 0x0B, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x03])
    private static let x509 = Data([0x06, 0x0A, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x16, 0x01])
    private static let ecAlgorithm = ASN1.sequence(ASN1OID.ecPublicKey + ASN1OID.prime256v1)

    static func create() throws -> Data {
        let key = P256.Signing.PrivateKey()
        let privateKey = try securityKey(key)
        let now = Date()
        let serial = Data(SHA256.hash(data: key.publicKey.x963Representation).prefix(16))
        let expiry = Calendar(identifier: .gregorian).date(byAdding: .year, value: 10, to: now)
            ?? now.addingTimeInterval(10 * 365 * 24 * 60 * 60)
        let certificate = try X509Builder.buildCACertificate(
            privateKey: privateKey, subjectCN: "NaiveFlow Root Certificate", organization: "NaiveFlow",
            serial: serial, notBefore: now.addingTimeInterval(-3600), notAfter: expiry
        )
        let ecKey = ASN1.sequence(ASN1.integer(1) + ASN1.octetString(key.rawRepresentation))
        let privateKeyInfo = ASN1.sequence(ASN1.integer(0) + ecAlgorithm + ASN1.octetString(ecKey))
        let certificateBag = ASN1.sequence(x509 + explicit(ASN1.octetString(certificate)))
        // A shared localKeyID pairs the certificate with its key in external PKCS #12 readers.
        let localKeyID = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x15])
        let attributes = ASN1.set(ASN1.sequence(localKeyID + ASN1.set(ASN1.octetString(serial))))
        let bags = ASN1.sequence(keyBag + explicit(privateKeyInfo) + attributes)
            + ASN1.sequence(certBag + explicit(certificateBag) + attributes)
        return ASN1.sequence(ASN1.integer(3) + contentInfo(ASN1.sequence(contentInfo(ASN1.sequence(bags)))))
    }

    static func decode(_ value: String) throws -> MITMCertificateStore.CA {
        guard value.utf8.count <= maximumEncodedBytes, let data = Data(base64Encoded: value) else {
            throw Failure.invalidIdentity
        }
        var pfx = try sequence(data)
        guard try pfx.readNextWithHeader(expectedTag: 0x02) == ASN1.integer(3) else { throw Failure.invalidIdentity }
        var safe = try sequence(readContentInfo(&pfx))
        var bags = try sequence(readContentInfo(&safe))
        guard pfx.isAtEnd, safe.isAtEnd else { throw Failure.invalidIdentity }

        var keyBag = ASN1Parser(data: try bags.readSequence())
        guard try keyBag.readNextWithHeader(expectedTag: 0x06) == Self.keyBag else { throw Failure.invalidIdentity }
        var keyInfo = try sequence(keyBag.readExplicitContextSpecific(tag: 0))
        guard try keyInfo.readNextWithHeader(expectedTag: 0x02) == ASN1.integer(0),
              try keyInfo.readNextWithHeader(expectedTag: 0x30) == ecAlgorithm else { throw Failure.invalidIdentity }
        var ec = try sequence(ASN1Parser.contentOf(keyInfo.readNextWithHeader(expectedTag: 0x04)))
        guard try ec.readNextWithHeader(expectedTag: 0x02) == ASN1.integer(1) else { throw Failure.invalidIdentity }
        let scalar = try ASN1Parser.contentOf(ec.readNextWithHeader(expectedTag: 0x04))
        guard scalar.count == 32 else { throw Failure.invalidIdentity }
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(scalar))

        var certBag = ASN1Parser(data: try bags.readSequence())
        guard bags.isAtEnd,
              try certBag.readNextWithHeader(expectedTag: 0x06) == Self.certBag else { throw Failure.invalidIdentity }
        var cert = try sequence(certBag.readExplicitContextSpecific(tag: 0))
        guard try cert.readNextWithHeader(expectedTag: 0x06) == x509 else { throw Failure.invalidIdentity }
        var octets = ASN1Parser(data: try cert.readExplicitContextSpecific(tag: 0))
        let der = Data(try ASN1Parser.contentOf(octets.readNextWithHeader(expectedTag: 0x04)))
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let publicKey = SecCertificateCopyKey(certificate),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              publicBytes == key.publicKey.x963Representation else { throw Failure.invalidIdentity }
        try X509Builder.validateRootCA(der, publicKey: publicKey)
        return (try securityKey(key), der)
    }

    private static func securityKey(_ key: P256.Signing.PrivateKey) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let result = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil) else {
            throw Failure.invalidIdentity
        }
        return result
    }

    private static func explicit(_ data: Data) -> Data {
        ASN1.contextSpecific(tag: 0, constructed: true, content: data)
    }

    private static func contentInfo(_ data: Data) -> Data {
        ASN1.sequence(ASN1OID.data + explicit(ASN1.octetString(data)))
    }

    private static func sequence(_ data: Data) throws -> ASN1Parser {
        var outer = ASN1Parser(data: data)
        let inner = try outer.readSequence()
        guard outer.isAtEnd else { throw Failure.invalidIdentity }
        return ASN1Parser(data: inner)
    }

    private static func readContentInfo(_ source: inout ASN1Parser) throws -> Data {
        var info = ASN1Parser(data: try source.readSequence())
        guard try info.readNextWithHeader(expectedTag: 0x06) == ASN1OID.data else { throw Failure.invalidIdentity }
        var content = ASN1Parser(data: try info.readExplicitContextSpecific(tag: 0))
        let data = try ASN1Parser.contentOf(content.readNextWithHeader(expectedTag: 0x04))
        guard info.isAtEnd, content.isAtEnd else { throw Failure.invalidIdentity }
        return data
    }
}

// MARK: - ASN.1 Encoding Primitives

nonisolated private enum ASN1 {
    static func sequence(_ content: Data) -> Data {
        emit(tag: 0x30, content: content)
    }

    static func set(_ content: Data) -> Data {
        emit(tag: 0x31, content: content)
    }

    static func contextSpecific(tag: UInt8, constructed: Bool, content: Data) -> Data {
        let classBits: UInt8 = 0x80
        let constructedBit: UInt8 = constructed ? 0x20 : 0x00
        return emit(tag: classBits | constructedBit | (tag & 0x1F), content: content)
    }

    static func integer(_ value: Int64) -> Data {
        if value == 0 {
            return Data([0x02, 0x01, 0x00])
        }
        var bytes: [UInt8] = []
        var remaining = value
        let negative = remaining < 0
        repeat {
            bytes.insert(UInt8(truncatingIfNeeded: remaining & 0xFF), at: 0)
            remaining >>= 8
        } while !(remaining == 0 || remaining == -1)

        if !negative, let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        } else if negative, let first = bytes.first, first & 0x80 == 0 {
            bytes.insert(0xFF, at: 0)
        }
        return emit(tag: 0x02, content: Data(bytes))
    }

    static func rawInteger(_ content: Data) -> Data {
        emit(tag: 0x02, content: content)
    }

    static func boolean(_ value: Bool) -> Data {
        emit(tag: 0x01, content: Data([value ? 0xFF : 0x00]))
    }

    static func octetString(_ content: Data) -> Data {
        emit(tag: 0x04, content: content)
    }

    static func bitString(unusedBits: UInt8, content: Data) -> Data {
        var payload = Data([unusedBits])
        payload.append(content)
        return emit(tag: 0x03, content: payload)
    }

    static func utf8String(_ value: String) -> Data {
        emit(tag: 0x0C, content: Data(value.utf8))
    }

    static func utcTime(_ value: String) -> Data {
        emit(tag: 0x17, content: Data(value.utf8))
    }

    static func generalizedTime(_ value: String) -> Data {
        emit(tag: 0x18, content: Data(value.utf8))
    }

    static func emit(tag: UInt8, content: Data) -> Data {
        var out = Data()
        out.append(tag)
        out.append(encodeLength(content.count))
        out.append(content)
        return out
    }

    static func encodeLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

// MARK: - Pre-encoded OIDs and constants

nonisolated private enum ASN1OID {
    static let commonName               = Data([0x06, 0x03, 0x55, 0x04, 0x03])
    static let organizationName         = Data([0x06, 0x03, 0x55, 0x04, 0x0A])
    static let basicConstraints         = Data([0x06, 0x03, 0x55, 0x1D, 0x13])
    static let keyUsage                 = Data([0x06, 0x03, 0x55, 0x1D, 0x0F])
    static let extKeyUsage              = Data([0x06, 0x03, 0x55, 0x1D, 0x25])
    static let subjectAltName           = Data([0x06, 0x03, 0x55, 0x1D, 0x11])
    static let subjectKeyIdentifier     = Data([0x06, 0x03, 0x55, 0x1D, 0x0E])
    static let authorityKeyIdentifier   = Data([0x06, 0x03, 0x55, 0x1D, 0x23])

    static let contentSubjectKeyIdentifier = Data([0x55, 0x1D, 0x0E])

    static let ecPublicKey = Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
    static let prime256v1  = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
    static let ecdsaWithSHA256 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    static let serverAuth  = Data([0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])

    static let data             = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])
    static let signedData       = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02])
    static let sha256           = Data([0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01])
    static let attrContentType  = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03])
    static let attrMessageDigest = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04])
}

// MARK: - Minimal ASN.1 Parser

nonisolated private struct ASN1Parser {
    let data: Data
    var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func peekTag() throws -> UInt8 {
        guard offset < data.endIndex else {
            throw NaiveFlowError.certificate(.asn1ParseFailed(detail: "Unexpected end of data"))
        }
        return data[offset]
    }

    mutating func readSequence() throws -> Data {
        try readContent(expectedTag: 0x30)
    }

    mutating func readNextWithHeader(expectedTag: UInt8?) throws -> Data {
        guard offset < data.endIndex else {
            throw NaiveFlowError.certificate(.asn1ParseFailed(detail: "Unexpected end of data"))
        }
        let tag = data[offset]
        if let expected = expectedTag, tag != expected {
            throw NaiveFlowError.certificate(.asn1ParseFailed(detail: "Tag mismatch: expected \(expected), got \(tag)"))
        }
        let start = offset
        let (length, lengthBytes) = try parseLength(at: offset + 1)
        let total = 1 + lengthBytes + length
        let end = start + total
        guard end <= data.endIndex else {
            throw NaiveFlowError.certificate(.asn1ParseFailed(detail: "Length overrun"))
        }
        offset = end
        return data[start..<end]
    }

    mutating func skipNext() throws {
        _ = try readNextWithHeader(expectedTag: nil)
    }

    mutating func readExplicitContextSpecific(tag: UInt8) throws -> Data {
        let expected: UInt8 = 0xA0 | (tag & 0x1F)
        let blob = try readNextWithHeader(expectedTag: expected)
        return try ASN1Parser.contentOf(blob)
    }

    mutating func skipExplicitContextSpecific(tag: UInt8) throws {
        let expected: UInt8 = 0xA0 | (tag & 0x1F)
        _ = try readNextWithHeader(expectedTag: expected)
    }

    private mutating func readContent(expectedTag: UInt8) throws -> Data {
        let blob = try readNextWithHeader(expectedTag: expectedTag)
        return try ASN1Parser.contentOf(blob)
    }

    private func parseLength(at start: Int) throws -> (length: Int, bytes: Int) {
        guard start < data.endIndex else {
            throw NaiveFlowError.certificate(.asn1ParseFailed(detail: "Length truncated"))
        }
        let first = data[start]
        if first & 0x80 == 0 {
            return (Int(first), 1)
        }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, start + count < data.endIndex else {
            throw NaiveFlowError.certificate(.asn1ParseFailed(detail: "Length encoding invalid"))
        }
        var length: UInt64 = 0
        for i in 0..<count {
            length = (length << 8) | UInt64(data[start + 1 + i])
        }
        let remaining = data.endIndex - (start + 1 + count)
        guard length <= UInt64(Int.max), length <= UInt64(remaining) else {
            throw NaiveFlowError.certificate(.asn1ParseFailed(detail:
                "Length \(length) exceeds remaining buffer \(remaining)"
            ))
        }
        return (Int(length), 1 + count)
    }

    static func contentOf(_ tlv: Data) throws -> Data {
        guard tlv.count >= 2 else {
            throw NaiveFlowError.certificate(.asn1ParseFailed(detail: "TLV too short"))
        }
        let lengthByte = tlv[tlv.startIndex + 1]
        let lengthHeaderBytes: Int
        if lengthByte & 0x80 == 0 {
            lengthHeaderBytes = 1
        } else {
            lengthHeaderBytes = 1 + Int(lengthByte & 0x7F)
        }
        let prefix = 1 + lengthHeaderBytes
        guard tlv.count >= prefix else {
            throw NaiveFlowError.certificate(.asn1ParseFailed(detail: "TLV truncated"))
        }
        return tlv.suffix(from: tlv.startIndex + prefix)
    }
}
