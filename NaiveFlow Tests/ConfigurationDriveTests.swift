import Foundation
import Testing
@testable import NaiveFlow

struct ConfigurationDriveTests {
    @Test func iCloudConfigurationPreservesMITMIdentityAndSettings() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try MITMPKCS12.create().base64EncodedString()
        let text = """
            [MITM]
            enable = true
            hostname = example.com
            ca-p12 = \(original)
            """
        _ = try await ConfigurationDrive(localDirectory: folder).save(text, name: "MITM.conf", replacing: nil)
        let received = try await ConfigurationDrive(localDirectory: folder).read("MITM.conf")
        let processed = TextConfigurationPipeline.process(text: received.text)
        #expect(processed.isActivatable)
        #expect(processed.compiled.textMITM.certificatePKCS12 == original)
        #expect(processed.compiled.textMITM.suffixes == ["example.com"])
        let first = try MITMPKCS12.decode(original)
        let second = try MITMPKCS12.decode(#require(processed.compiled.textMITM.certificatePKCS12))
        #expect(first.certificateDER == second.certificateDER)
        let invalid = TextConfigurationPipeline.process(text: "[MITM]\nca-p12 = invalid")
        #expect(!invalid.isActivatable)
    }

    @Test func namedFileCanBeUpdatedAndStaleDraftCannotOverwriteIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = ConfigurationDrive(localDirectory: folder)
        let second = ConfigurationDrive(localDirectory: folder)
        let name = try ConfigurationDrive.fileName(" Home ")
        let original = try await first.save("# original\r\n", name: name, replacing: nil)
        #expect(try await second.files() == ["Home.conf"])
        #expect(try await second.read(name).text == "# original\r\n")
        let edited = try await second.save("# edited", name: name, replacing: original.digest)
        await #expect(throws: ConfigurationDrive.Failure.changed) {
            try await first.save("# stale", name: name, replacing: original.digest)
        }
        await #expect(throws: ConfigurationDrive.Failure.alreadyExists) {
            try await first.save("# collision", name: name, replacing: nil)
        }
        #expect(try await first.read(name).digest == edited.digest)
        #expect(throws: ConfigurationDrive.Failure.invalidName) { try ConfigurationDrive.fileName("../outside") }
    }
}
