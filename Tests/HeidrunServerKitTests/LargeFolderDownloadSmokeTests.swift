import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

/// End-to-end smoke test that drives a real `HotlineNetworkClient`
/// (Network.framework) against an in-process `HeidrunServerKit` server over
/// a loopback socket, downloading a FOLDER that contains one file LARGER
/// than 4 GiB. Proves the folder stream framing survives the 0xFFFF_FFFF
/// boundary: the per-item size prefix is the 8-byte UInt64 form on a
/// large-file session, the 64-bit fork headers round-trip, and every byte
/// of the over-4-GiB data fork streams through `folderDownloadStream(for:)`.
///
/// GATED behind `HEIDRUN_LARGEFILE_SMOKE` because the default run moves
/// ~4 GiB through the server (which buffers whole files in RAM, ~2× peak
/// for the resource-fork envelope copy). The normal `swift test` run
/// returns immediately.
@Suite("Large-folder download smoke", .serialized)
struct LargeFolderDownloadSmokeTests {

    private func withLargeFileServer<Result>(
        body: (UInt16, URL) async throws -> Result
    ) async throws -> Result {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "HeidrunServer-LargeFolder-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun large-folder smoke",
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            ),
            filesRootPath: rootURL.path
        )
        return try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            try await body(port, rootURL)
        }
    }

    @Test(">4 GiB folder download streams every data-fork byte with no 4 GiB-boundary truncation")
    func largeFolderDownloadRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["HEIDRUN_LARGEFILE_SMOKE"] != nil else { return }

        // Default just over 4 GiB so the size exceeds 0xFFFF_FFFF and the
        // 32-bit legacy prefix cannot represent it. Overridable via env.
        let totalBytes = UInt64(ProcessInfo.processInfo.environment["HEIDRUN_LARGEFILE_BYTES"] ?? "")
            ?? (4 * 1024 * 1024 * 1024 + 65_536)
        #expect(totalBytes > 0xFFFF_FFFF, "smoke test must exceed the 32-bit size cap")

        let folderName = "Bundle"
        let bigFileName = "huge.bin"

        try await withLargeFileServer { port, rootURL in
            // Seed a sub-directory containing one sparse file just over
            // 4 GiB: truncate to the full length without writing real
            // bytes. The transfer still moves `totalBytes` (server reads
            // sparse zeros back).
            let folderURL = rootURL.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let fileURL = folderURL.appendingPathComponent(bigFileName)
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

            let handle = try await networkClient.startFolderDownload(
                at: RemotePath(components: []),
                name: folderName
            )
            // The folder reply's advertised total includes the >4 GiB
            // file's framed envelope, so it must exceed the 32-bit cap —
            // proving the 64-bit xferSize64 reply field.
            #expect(handle.totalSize > 0xFFFF_FFFF,
                "startFolderDownload reply must report a 64-bit transfer size")

            // Drive the stream, summing the data-fork byte count of each
            // file item — never accumulate the whole bundle. The big file
            // is the only non-directory item, so its data fork alone must
            // equal `totalBytes`.
            var dataForkBytes: UInt64 = 0
            var sawBigFile = false
            for try await item in networkClient.folderDownloadStream(for: handle) where !item.isDirectory {
                dataForkBytes += UInt64(item.data.count)
                if item.relativePath.last == bigFileName {
                    sawBigFile = true
                }
            }

            #expect(sawBigFile, "the >4 GiB file must appear as a stream item")
            #expect(dataForkBytes == totalBytes,
                "decoded data-fork bytes must equal the full file length with no truncation")

            await client.disconnect()
        }
    }
}
