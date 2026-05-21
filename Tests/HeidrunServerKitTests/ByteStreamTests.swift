import Foundation
import Testing
@testable import HeidrunServerKit

@Suite("ByteStream")
struct ByteStreamTests {
    @Test("returns exactly the requested byte count across multiple chunks")
    func aggregatesChunks() async throws {
        let chunks: [Data] = [Data([0x01, 0x02]), Data([0x03]), Data([0x04, 0x05, 0x06])]
        var stream = ByteStream(source: AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        })

        let first = try await stream.receiveExactly(3)
        #expect(first == Data([0x01, 0x02, 0x03]))
        let second = try await stream.receiveExactly(3)
        #expect(second == Data([0x04, 0x05, 0x06]))
    }

    @Test("throws ByteStream.Error.endOfStream when the source closes mid-read")
    func detectsEarlyClose() async {
        var stream = ByteStream(source: AsyncStream { continuation in
            continuation.yield(Data([0x01]))
            continuation.finish()
        })
        do {
            _ = try await stream.receiveExactly(4)
            #expect(Bool(false), "expected throw")
        } catch ByteStream.Error.endOfStream {
            // expected
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }
}
