import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("File download (HTXF)", .serialized)
struct FileDownloadTests {
    private func withSeededFilesServer<Result>(
        body: (HeidrunServer, UInt16, URL) async throws -> Result
    ) async throws -> Result {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "HeidrunServer-Download-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            filesRootPath: rootURL.path
        )
        return try await ServerTestHelpers.withRunningServer(configuration: configuration) { server, port in
            try await body(server, port, rootURL)
        }
    }

    /// Pull every chunk out of a `downloadStream` and concatenate.
    private func drain(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var bytes = Data()
        for try await chunk in stream {
            bytes.append(chunk)
        }
        return bytes
    }

    @Test("startDownload + downloadStream round-trips a seeded file's bytes")
    func roundTripsBytes() async throws {
        try await withSeededFilesServer { _, port, rootURL in
            let payload = Data("Hello from HeidrunServer's HTXF channel.".utf8)
            try payload.write(to: rootURL.appendingPathComponent("greeting.txt"))

            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let handle = try await client.startDownload(
                at: RemotePath(components: []),
                name: "greeting.txt",
                dataForkOffset: 0,
                resourceForkOffset: 0
            )
            let stream = client.downloadStream(for: handle)
            let received = try await drain(stream)
            #expect(received == payload)
        }
    }

    @Test("startDownload with a non-zero dataForkOffset resumes mid-file")
    func resumesFromOffset() async throws {
        try await withSeededFilesServer { _, port, rootURL in
            let full = Data("abcdefghijklmnopqrstuvwxyz".utf8)
            try full.write(to: rootURL.appendingPathComponent("alphabet.txt"))

            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let handle = try await client.startDownload(
                at: RemotePath(components: []),
                name: "alphabet.txt",
                dataForkOffset: 10,
                resourceForkOffset: 0
            )
            let stream = client.downloadStream(for: handle)
            let received = try await drain(stream)
            #expect(received == Data("klmnopqrstuvwxyz".utf8))
        }
    }

    @Test("startDownload on a missing file fails fast — no HTXF connect needed")
    func missingFile() async throws {
        try await withSeededFilesServer { _, port, _ in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            do {
                _ = try await client.startDownload(
                    at: RemotePath(components: []),
                    name: "ghost.txt",
                    dataForkOffset: 0,
                    resourceForkOffset: 0
                )
                #expect(Bool(false), "expected startDownload to throw")
            } catch {
                // expected
            }
        }
    }
}
