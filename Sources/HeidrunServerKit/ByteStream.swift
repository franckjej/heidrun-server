import Foundation

/// Async byte aggregator. Wraps any `AsyncSequence<Data>` source and
/// hands out exact-byte slices on demand. Used by `ClientSession` to
/// gather full Hotline frames out of NIO's variable-size ByteBuffer
/// inbound stream. Not Sendable on purpose: a session owns one
/// `ByteStream` and reads from it on a single async task.
struct ByteStream<Source: AsyncSequence & Sendable> where Source.Element == Data {
    // Hoisted out of the generic struct so callers can pattern-match
    // `ByteStream.Error.endOfStream` without spelling the generic parameter.
    typealias Error = ByteStreamError

    private var iterator: Source.AsyncIterator
    private var pending = Data()

    init(source: Source) {
        self.iterator = source.makeAsyncIterator()
    }

    mutating func receiveExactly(_ count: Int) async throws -> Data {
        while pending.count < count {
            guard let nextChunk = try await iterator.next() else {
                throw ByteStreamError.endOfStream
            }
            pending.append(nextChunk)
        }
        let slice = pending.prefix(count)
        pending.removeSubrange(pending.startIndex..<(pending.startIndex + count))
        return Data(slice)
    }
}

/// Errors thrown by `ByteStream.receiveExactly(_:)`.
enum ByteStreamError: Swift.Error, Equatable {
    case endOfStream
}
