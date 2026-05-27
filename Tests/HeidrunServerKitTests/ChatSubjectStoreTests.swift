import Foundation
import Testing
@testable import HeidrunServerKit

@Suite("ChatSubjectStore")
struct ChatSubjectStoreTests {
    private func tempPath() -> String {
        NSTemporaryDirectory() + "chatsubject-\(UUID().uuidString).json"
    }

    @Test("seeds from the config value when no file exists")
    func seedsFromConfig() async {
        let store = ChatSubjectStore(seed: "Hello", persistencePath: tempPath())
        #expect(await store.current() == "Hello")
    }

    @Test("set writes through and survives a reload from disk")
    func persistedValueWins() async {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = ChatSubjectStore(seed: "Hello", persistencePath: path)
        await first.set("Live topic")

        // A fresh store at the same path ignores the seed and loads disk.
        let second = ChatSubjectStore(seed: "Hello", persistencePath: path)
        #expect(await second.current() == "Live topic")
    }

    @Test("no persistence path → set is in-memory only, current reflects it")
    func inMemoryWhenNoPath() async {
        let store = ChatSubjectStore(seed: "", persistencePath: nil)
        await store.set("ephemeral")
        #expect(await store.current() == "ephemeral")
    }
}
