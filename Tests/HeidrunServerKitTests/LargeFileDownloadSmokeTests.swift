import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

/// End-to-end smoke test that drives a real `HotlineNetworkClient`
/// (Network.framework) against an in-process `HeidrunServerKit` server over
/// a loopback socket, downloading a single file LARGER than 4 GiB. Proves
/// nothing truncates at the 0xFFFF_FFFF boundary on the wire: the 64-bit
/// `fileSize64` pairing survives the file listing and every byte of the
/// over-4-GiB payload streams through `downloadStream(for:)`.
///
/// GATED behind `HEIDRUN_LARGEFILE_SMOKE` because the default run moves
/// ~4 GiB through the server (which buffers whole files in RAM, ~2× peak
/// for the resource-fork envelope copy → ~8 GiB transient). The normal
/// `swift test` run returns immediately.
@Suite("Large-file download smoke", .serialized)
struct LargeFileDownloadSmokeTests {

    private func withLargeFileServer<Result>(
        body: (UInt16, URL) async throws -> Result
    ) async throws -> Result {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "HeidrunServer-LargeFile-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun large-file smoke",
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            ),
            filesRootPath: rootURL.path
        )
        return try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            try await body(port, rootURL)
        }
    }

    @Test(">4 GiB single-file download streams every byte with no 4 GiB-boundary truncation")
    func largeFileDownloadRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["HEIDRUN_LARGEFILE_SMOKE"] != nil else { return }

        // Default just over 4 GiB so the size exceeds 0xFFFF_FFFF and the
        // 32-bit legacy field cannot represent it. Overridable via env.
        let totalBytes = UInt64(ProcessInfo.processInfo.environment["HEIDRUN_LARGEFILE_BYTES"] ?? "")
            ?? (4 * 1024 * 1024 * 1024 + 65_536)
        #expect(totalBytes > 0xFFFF_FFFF, "smoke test must exceed the 32-bit size cap")

        let fileName = "huge.bin"

        try await withLargeFileServer { port, rootURL in
            // Create the test file FAST as a sparse file: truncate to the
            // full length without writing 4 GiB of real bytes. The transfer
            // still moves `totalBytes` (server reads sparse zeros back).
            let fileURL = rootURL.appendingPathComponent(fileName)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            let writeHandle = try FileHandle(forWritingTo: fileURL)
            try writeHandle.truncate(atOffset: totalBytes)
            try writeHandle.close()

            let onDiskSize = try FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? UInt64
            #expect(onDiskSize == totalBytes, "sparse file must report the full length on disk")

            let client = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Admin", loginName: "admin", password: "admin")
            let networkClient = try #require(client as? HotlineNetworkClient)

            // Server must have negotiated the large-files capability (0x01F0).
            let largeFilesEnabled = await networkClient.largeFilesEnabled
            #expect(largeFilesEnabled, "server must negotiate large-files capability")

            // The listing must round-trip the 64-bit size over the wire.
            let entries = try await networkClient.listFiles(at: RemotePath(components: []))
            let entry = try #require(entries.first(where: { $0.name == fileName }),
                "listing must contain the seeded file")
            #expect(entry.size == totalBytes,
                "file-list size must round-trip 64-bit (> 0xFFFF_FFFF) over the wire")

            // Download and count every byte as it streams — never accumulate
            // the whole 4 GiB into a single Data.
            let handle = try await networkClient.startDownload(
                at: RemotePath(components: []),
                name: fileName,
                dataForkOffset: 0,
                resourceForkOffset: 0
            )
            #expect(handle.totalSize == totalBytes,
                "startDownload reply must report the 64-bit transfer size")

            var receivedBytes: UInt64 = 0
            for try await chunk in networkClient.downloadStream(for: handle) {
                receivedBytes += UInt64(chunk.count)
            }

            #expect(receivedBytes == totalBytes,
                "downloaded byte count must equal the full file length with no truncation")

            await client.disconnect()
        }
    }
}
