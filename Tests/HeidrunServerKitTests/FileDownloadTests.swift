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

    @Test("framed single-file download round-trips both forks via downloadEnvelope")
    func downloadFramedRoundTrip() async throws {
        try await withSeededFilesServer { _, port, rootURL in
            let dataFork = Data("framed data fork bytes".utf8)
            let resourceFork = Data((0..<128).map { UInt8(($0 * 7) & 0xFF) })
            // Seed the data fork + the resource-fork sidecar directly
            // on disk so the server doesn't have to receive the file
            // first; this isolates the download path.
            try dataFork.write(to: rootURL.appendingPathComponent("framed.bin"))
            try resourceFork.write(to: rootURL.appendingPathComponent("._framed.bin.rsrc"))

            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let handle = try await client.startDownload(
                at: RemotePath(components: []),
                name: "framed.bin",
                dataForkOffset: 0,
                resourceForkOffset: 0
            )
            // Client + server both advertised resourceForkSupport, so
            // the handle should report a framed transfer.
            #expect(handle.framed == true)

            let envelope = try await client.downloadEnvelope(for: handle)
            #expect(envelope.data == dataFork)
            #expect(envelope.resourceFork == resourceFork)
            #expect(envelope.fileName == "framed.bin")
        }
    }

    @Test("a classic client that never sends 0xE002 still receives the FILP envelope")
    func classicClientGetsEnvelope() async throws {
        try await withSeededFilesServer { _, port, rootURL in
            let payload = Data("classic clients expect a flattened file object".utf8)
            try payload.write(to: rootURL.appendingPathComponent("classic.txt"))

            let client = try await RawHotlineClient.connect(port: port)
            defer { client.close() }
            _ = try await client.loginClassic(nickname: "Nostalgia")
            let reply = try await client.send(transactionID: 202, fields: [
                .string(.fileName, "classic.txt", encoding: .macOSRoman),
                .path(.filePath, RemotePath(components: []), encoding: .macOSRoman)
            ])
            let transferID = try #require(reply.uint32(.transferID))
            let transferSize = try #require(reply.uint32(.transferSize))
            #expect(transferSize > UInt32(payload.count), "transferSize must cover the envelope, not just the data fork")

            let wire = try await client.readTransfer(transferID: transferID, count: Int(transferSize))
            #expect(wire.prefix(4) == Data("FILP".utf8))
            let envelope = try UploadFraming.decode(wire)
            #expect(envelope.data == payload)
            #expect(envelope.fileName == "classic.txt")
        }
    }

    @Test("resume ships a resumed envelope: the data-fork remainder plus the whole resource fork")
    func resumeShipsResumedEnvelope() async throws {
        try await withSeededFilesServer { _, port, rootURL in
            let full = Data("0123456789abcdef".utf8)
            let resourceFork = Data([0xFF, 0xEE])
            try full.write(to: rootURL.appendingPathComponent("partial.bin"))
            try resourceFork.write(to: rootURL.appendingPathComponent("._partial.bin.rsrc"))

            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let handle = try await client.startDownload(
                at: RemotePath(components: []),
                name: "partial.bin",
                dataForkOffset: 8,
                resourceForkOffset: 0
            )
            let received = try await drain(client.downloadStream(for: handle))
            #expect(received == Data("89abcdef".utf8))
            #expect(await client.consumeResourceFork(for: handle.transferID) == resourceFork)
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
