import Foundation
import HeidrunCore

/// Chat-input slash-command dispatch. Lines that start with a single
/// `/` followed by a non-empty command name are intercepted before
/// the normal chat broadcast path and routed to a per-command handler
/// here. Other connected users never see the `/cmd` line; responses
/// (when any) go to the sender only via `sendSystemReply`.
///
/// Adding a new command:
///   1. Add a `handleFooCommand(args:)` method below.
///   2. Add a `case "foo": await handleFooCommand(args: args)` arm to
///      `handleChatCommandIfPresent`.
///   3. Cover it in `Tests/HeidrunServerKitTests/ChatCommandsTests.swift`.
extension ClientSession {

    /// Returns `true` when `body` was a recognised — or at least
    /// well-formed — slash command and has been fully handled.
    /// `false` means the caller should fall through to the normal
    /// chat broadcast path (the body wasn't a command at all).
    ///
    /// "Well-formed" includes unknown commands: an unknown `/foo`
    /// still returns `true` (with a sender-only error reply) so the
    /// `/foo` token is never broadcast as chat.
    func handleChatCommandIfPresent(body: String, header: PacketHeader) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        // Single-`/` prefix only. `//emph` and bare `/` fall through
        // to normal chat so users can still say literally those things.
        guard trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("//"),
              trimmed.count > 1 else {
            return false
        }
        let tokens = trimmed.dropFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard let head = tokens.first else { return false }
        let command = head.lowercased()
        let args = tokens.dropFirst().map(String.init)

        serverLogger.debug("chat command", metadata: [
            "command": "\(command)",
            "socketID": "\(socketID)",
            "nickname": "\(nickname)"
        ])

        switch command {
        case "version":
            await handleVersionCommand(args: args)
        case "away":
            await handleAwayCommand(args: args)
        default:
            serverLogger.info("unknown chat command", metadata: [
                "command": "\(command)",
                "socketID": "\(socketID)",
                "nickname": "\(nickname)"
            ])
            await sendSystemReply("Unknown command: /\(command)")
        }
        return true
    }

    /// `/version` — sender-only verbose system block. Eight lines:
    /// semver, build (id + optional date), Swift compiler version,
    /// platform, configured server name, listening ports (with TLS
    /// sibling pair when configured), uptime, live user count.
    func handleVersionCommand(args: [String]) async {
        let identifier = HeidrunServerInfo.buildIdentifier
        let buildDate = HeidrunServerInfo.buildDate
        let buildLine = buildDate.isEmpty
            ? "build: \(identifier)"
            : "build: \(identifier) (\(buildDate))"

        let portsLine: String = {
            let cleartextPort = configuration.port
            let cleartextPair = "\(cleartextPort)/\(cleartextPort + 1)"
            guard let tlsPort = configuration.tlsPort else {
                return "ports: \(cleartextPair)"
            }
            return "ports: \(cleartextPair) (TLS \(tlsPort)/\(tlsPort + 1))"
        }()

        let userCount = await registry.snapshot().count
        let uptime = HeidrunServerInfo.formatUptime(since: configuration.startedAt)

        await sendSystemReply(lines: [
            "HeidrunServer \(HeidrunServerInfo.version)",
            buildLine,
            "swift: \(HeidrunServerInfo.swiftCompilerVersion)",
            "platform: \(HeidrunServerInfo.platformDescription)",
            "server: \(configuration.serverName)",
            portsLine,
            "uptime: \(uptime)",
            "users: \(userCount)"
        ])
    }

    /// `/away` — toggle the `manuallyAway` flag, broadcast the
    /// updated status to everyone via the shared `applyAwayState`,
    /// and confirm the new state privately to the sender.
    func handleAwayCommand(args: [String]) async {
        manuallyAway.toggle()
        await applyAwayState()
        await sendSystemReply(manuallyAway ? "You are now away." : "Welcome back.")
    }
}
