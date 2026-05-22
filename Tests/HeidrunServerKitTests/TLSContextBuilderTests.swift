import Testing
import Foundation
@testable import HeidrunServerKit

@Suite("TLSContextBuilder")
struct TLSContextBuilderTests {
    /// PEM pair lives in `Tests/HeidrunServerKitTests/TestCerts/` and is
    /// copied into the test bundle via `resources:` in `Package.swift`.
    private static func testCertPaths() -> (cert: String, key: String) {
        let certsDir = Bundle.module.bundleURL.appendingPathComponent("TestCerts", isDirectory: true)
        return (
            cert: certsDir.appendingPathComponent("test-cert.pem").path,
            key: certsDir.appendingPathComponent("test-key.pem").path
        )
    }

    @Test("loads a valid PEM cert + key pair into an NIOSSLContext")
    func happyPath() throws {
        let (certPath, keyPath) = Self.testCertPaths()
        // Should succeed without throwing.
        _ = try TLSContextBuilder.makeContext(
            certificatePath: certPath,
            privateKeyPath: keyPath
        )
    }

    @Test("throws missingCertificate when the cert file isn't on disk")
    func missingCertificate() {
        let (_, keyPath) = Self.testCertPaths()
        #expect(throws: TLSContextBuilder.TLSContextError.missingCertificate(
            path: "/nonexistent/cert.pem"
        )) {
            _ = try TLSContextBuilder.makeContext(
                certificatePath: "/nonexistent/cert.pem",
                privateKeyPath: keyPath
            )
        }
    }

    @Test("throws missingPrivateKey when the key file isn't on disk")
    func missingPrivateKey() {
        let (certPath, _) = Self.testCertPaths()
        #expect(throws: TLSContextBuilder.TLSContextError.missingPrivateKey(
            path: "/nonexistent/key.pem"
        )) {
            _ = try TLSContextBuilder.makeContext(
                certificatePath: certPath,
                privateKeyPath: "/nonexistent/key.pem"
            )
        }
    }

    @Test("throws loadFailed when both files exist but contain garbage")
    func loadFailed() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heidrun-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let badCert = tempDir.appendingPathComponent("bad-cert.pem")
        let badKey = tempDir.appendingPathComponent("bad-key.pem")
        try Data("not a real PEM".utf8).write(to: badCert)
        try Data("also not a real PEM".utf8).write(to: badKey)

        #expect(throws: TLSContextBuilder.TLSContextError.self) {
            _ = try TLSContextBuilder.makeContext(
                certificatePath: badCert.path,
                privateKeyPath: badKey.path
            )
        }
    }
}
