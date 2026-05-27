import Foundation

/// Holds the server-wide **public** chat topic and persists it to a small
/// JSON file (default `<db>.chatsubject.json`). Mirrors the `NewsTree`
/// persistence model: a persisted value wins on boot; the configured
/// `chatSubject` seed is used only when no file exists yet.
public actor ChatSubjectStore {
    private var subject: String
    private let persistencePath: String?

    public init(seed: String, persistencePath: String?) {
        if let persistencePath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: persistencePath)),
           let snapshot = try? Snapshot.decode(from: data) {
            self.subject = snapshot.subject
        } else {
            self.subject = seed
        }
        self.persistencePath = persistencePath
    }

    /// The current public topic. Empty string == no topic.
    func current() -> String { subject }

    /// Update the topic and write it through to disk (best-effort —
    /// a disk hiccup loses persistence, not the in-memory value).
    func set(_ newSubject: String) {
        subject = newSubject
        persist()
    }

    private func persist() {
        guard let persistencePath else { return }
        guard let data = try? Snapshot(subject: subject).encoded() else { return }
        try? data.write(to: URL(fileURLWithPath: persistencePath), options: [.atomic])
    }

    /// On-disk shape. `schemaVersion` lets future fields migrate.
    struct Snapshot: Codable, Sendable {
        static let currentSchemaVersion = 1
        var schemaVersion: Int
        var subject: String

        init(subject: String) {
            self.schemaVersion = Self.currentSchemaVersion
            self.subject = subject
        }

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }

        static func decode(from data: Data) throws -> Snapshot {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.schemaVersion == currentSchemaVersion else {
                throw DecodeError.unknownSchemaVersion(snapshot.schemaVersion)
            }
            return snapshot
        }

        enum DecodeError: Error, Equatable {
            case unknownSchemaVersion(Int)
        }
    }
}
