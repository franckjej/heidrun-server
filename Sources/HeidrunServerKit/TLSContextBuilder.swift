import Foundation
import NIOSSL

/// Load + validate a `NIOSSLContext` from on-disk PEM files. Used by
/// `HeidrunServer.start()` to set up the sibling TLS listener pair.
///
/// Keeps the cert-loading concern out of `HeidrunServer.swift` so the
/// listener-binding code stays focused on plumbing. Errors propagate
/// as `TLSContextError` so the executable can log a clear message
/// (and exit) when a deploy is half-configured.
public enum TLSContextBuilder {
    public enum TLSContextError: Swift.Error, Equatable {
        case missingCertificate(path: String)
        case missingPrivateKey(path: String)
        case loadFailed(reason: String)
    }

    /// Build a server-side `NIOSSLContext` from PEM-encoded certificate
    /// chain + private key. The cert chain may contain multiple
    /// certificates (server + intermediates); the first must match the
    /// private key.
    ///
    /// TLS cipher / version policy: NIO defaults (TLS 1.2 minimum,
    /// modern cipher suites). Good enough for Let's Encrypt-issued
    /// certs and modern clients; revisit if older clients show up.
    public static func makeContext(
        certificatePath: String,
        privateKeyPath: String
    ) throws -> NIOSSLContext {
        guard FileManager.default.fileExists(atPath: certificatePath) else {
            throw TLSContextError.missingCertificate(path: certificatePath)
        }
        guard FileManager.default.fileExists(atPath: privateKeyPath) else {
            throw TLSContextError.missingPrivateKey(path: privateKeyPath)
        }

        do {
            let certificates = try NIOSSLCertificate.fromPEMFile(certificatePath)
            let privateKey = try NIOSSLPrivateKey(file: privateKeyPath, format: .pem)
            var configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: certificates.map { .certificate($0) },
                privateKey: .privateKey(privateKey)
            )
            // Force a modern floor — Hotline clients that speak TLS at
            // all are modern reimplementations, no legacy compat to
            // preserve here.
            configuration.minimumTLSVersion = .tlsv12
            return try NIOSSLContext(configuration: configuration)
        } catch let error as TLSContextError {
            throw error
        } catch {
            throw TLSContextError.loadFailed(reason: "\(error)")
        }
    }
}
