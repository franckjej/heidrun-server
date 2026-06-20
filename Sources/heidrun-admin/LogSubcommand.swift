#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import ArgumentParser
import Logging
import HeidrunServerKit

struct Log: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stream the server's activity: audit events + operational log, merged.")

    @OptionGroup var global: GlobalOptions
    @Flag(name: [.short, .long], help: "Follow: keep streaming until Ctrl-C.") var follow = false
    @Option(help: "Backfill this many recent records first.") var lines = 50
    @Option(help: "audit | op | both.") var source = "both"
    @Option(name: [.long, .customLong("account")], help: "Filter by account login.") var user: String?
    @Option(help: "Minimum operational level (trace…critical).") var level: String?
    @Option(help: "Audit type: transfer|auth|admin|presence|<kind>.") var type: String?
    @Option(help: "Follow poll interval in milliseconds.") var interval = 500
    @Option(help: "Override the op-log NDJSON path.") var opLogPath: String?
    @Flag(help: "Emit JSON.") var json = false
    @Flag(help: "Render as an aligned fixed-width table.") var table = false

    func run() async throws {
        let configuration = try global.resolvedConfiguration()
        if table, json {
            throw ValidationError("--table and --json are mutually exclusive.")
        }
        let sourceFilter = UnifiedLogFilter.SourceFilter(parsing: source)
        let minLevel = level.flatMap { Logger.Level(rawValue: $0.lowercased()) }
        let auditKinds: [String]? = try type.map { keyword in
            guard let kinds = AuditQueryParsing.kinds(forTypeKeyword: keyword) else {
                throw ValidationError("Unknown --type '\(keyword)'.")
            }
            return kinds.map(\.rawValue)
        }

        let auditLog: AuditLog? = sourceFilter == .op ? nil : try global.openAuditLog()
        let resolvedOpPath = opLogPath ?? configuration.operationalLogPath
        let wantOp = sourceFilter != .audit
        if sourceFilter == .op, resolvedOpPath == nil {
            throw ValidationError("No operational log path configured (set operational_log_path / HEIDRUN_OP_LOG_PATH).")
        }
        if wantOp, let path = resolvedOpPath, !FileManager.default.fileExists(atPath: path) {
            FileHandle.standardError.write(Data(
                "note: operational log \(path) not found yet — showing audit events only.\n".utf8))
        }

        func passes(_ record: UnifiedLogRecord) -> Bool {
            UnifiedLogFilter.matches(record, sourceFilter: sourceFilter,
                                     user: user, minLevel: minLevel, auditKinds: auditKinds)
        }
        var headerShown = false
        func render(_ records: [UnifiedLogRecord]) {
            let kept = records.filter(passes)
            guard !kept.isEmpty else { return }
            if json {
                for record in kept {
                    if let text = try? AdminFormat.json(UnifiedLogLineDTO(record)) { print(text) }
                }
            } else if table {
                if !headerShown {
                    print(UnifiedLogTableFormatter.header())
                    headerShown = true
                }
                print(UnifiedLogTableFormatter.rows(kept))
            } else {
                print(UnifiedLogFormatter.lines(kept))
            }
        }

        // Backfill the recent tail from both sources.
        let backfillAudit = await auditLog?.recentIdentifiedEvents(limit: lines) ?? []
        var auditCursor = backfillAudit.last?.id ?? 0
        var opReader: OpLogTailReader?
        var backfillOp: [NDJSONLogRecord] = []
        if wantOp, let path = resolvedOpPath, FileManager.default.fileExists(atPath: path) {
            let historyReader = OpLogTailReader(path: path, fromEnd: false)
            backfillOp = Array(historyReader.poll().suffix(lines))
            opReader = OpLogTailReader(path: path, fromEnd: true)   // follow from here
        }
        render(UnifiedLog.backfill(audit: backfillAudit, op: backfillOp, limit: lines))

        guard follow else { return }

        // Follow: poll both sources, merge with a watermark, print settled rows.
        let stop = StopFlag()
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signalSource.setEventHandler { stop.stop() }
        signal(SIGINT, SIG_IGN)
        signalSource.resume()

        var merger = UnifiedLogMerger(windowMillis: 300)
        while !stop.isStopped {
            var fresh: [UnifiedLogRecord] = []
            if let auditLog {
                let rows = await auditLog.eventsAfter(id: auditCursor, limit: 500)
                if let lastID = rows.last?.id { auditCursor = lastID }
                fresh.append(contentsOf: rows.map(UnifiedLogRecord.init(audit:)))
            }
            if let opReader {
                fresh.append(contentsOf: opReader.poll().map(UnifiedLogRecord.init(op:)))
            }
            merger.add(fresh)
            render(merger.emit(nowMillis: Int64(Date().timeIntervalSince1970 * 1000)))
            try? await Task.sleep(nanoseconds: UInt64(max(50, interval)) * 1_000_000)
        }
        render(merger.drain())
    }
}

/// SIGINT flag for the follow loop. Set from the signal handler, polled by the
/// loop. Kept in the executable (touches process signals), not the Kit.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}
