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
        case "broadcast":
            await handleBroadcastCommand(args: args)
        case "topic":
            await handleTopicCommand(args: args)
        case "me":
            await handleMeCommand(args: args)
        case "who", "users":
            await handleWhoCommand(args: args)
        case "whoami":
            await handleWhoamiCommand(args: args)
        case "uptime":
            await handleUptimeCommand(args: args)
        case "usershistory", "history":
            await handleUsersHistoryCommand(args: args)
        case "audit", "transfers", "authlog", "adminlog":
            await handleAuditCommand(command: command, args: args)
        case "kick":
            await handleKickCommand(args: args)
        case "invisible":
            await handleInvisibleCommand(args: args)
        case "visible":
            await handleVisibleCommand(args: args)
        case "help":
            await handleHelpCommand(args: args)
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

    /// `/me <action>` — IRC-style action chat. Broadcasts a 106 push
    /// to every connected session (including the sender so they see
    /// their own action) with `isAction=true` and a `* nickname action`
    /// line that classic Hotline clients render as italicised /
    /// asterisk-prefixed text. Empty bodies surface a usage hint.
    func handleMeCommand(args: [String]) async {
        let action = args.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !action.isEmpty else {
            await sendSystemReply("Usage: /me <action>")
            return
        }
        let line = " *\(nickname) \(action)\r"
        let push = PacketEncoder.chatPush(line: line, isAction: true, encoding: stringEncoding)
        await registry.broadcast(push, excluding: nil)
    }

    /// `/who` / `/users` — sender-only dump of the live roster with
    /// each connected user's nickname + socketID so the operator has
    /// the socket numbers handy for `/kick`. Invisible peers are
    /// filtered the same way the wire `getUserList` (300) reply
    /// filters them; the requester always sees themselves regardless
    /// of their own visibility state.
    func handleWhoCommand(args: [String]) async {
        let members = await registry.snapshot(visibleTo: socketID)
        var lines: [String] = ["Connected users (\(members.count)):"]
        for member in members {
            lines.append("  \(member.nickname) (socket=\(member.socketID))")
        }
        await sendSystemReply(lines: lines)
    }

    /// `/whoami` — sender-only 10-line block describing the current
    /// session: nickname, socket, login (or "guest" for anonymous),
    /// remote host (`ip:port`), client version, login timestamp, TLS
    /// yes/no, admin yes/no, away yes/no (the *effective* state
    /// last broadcast — matches what peers see), and the raw
    /// privilege bitmask for ops debugging "why doesn't my
    /// privilege X work?". No privilege gate: a user can always
    /// inspect their own session even when `.getUserInfo` is denied.
    func handleWhoamiCommand(args: [String]) async {
        let loginValue = authenticatedAccount?.login ?? "—"
        let hostValue = remoteHost ?? "—"
        let clientValue = clientVersion.map { "\($0)" } ?? "—"
        let sinceValue = loginAt.map(Self.formatLoginTime) ?? "—"
        let permissions = authenticatedAccount?.permissions ?? 0
        let isAdmin = authenticatedAccount?.isAdmin ?? false

        await sendSystemReply(lines: [
            "you: \(nickname)",
            "socket: \(socketID)",
            "login: \(loginValue)",
            "host: \(hostValue)",
            "client: \(clientValue)",
            "since: \(sinceValue)",
            "tls: \(isTLS ? "yes" : "no")",
            "admin: \(isAdmin)",
            "away: \(awayBroadcast)",
            "invisible: \(isInvisible)",
            "permissions: 0x\(String(permissions, radix: 16))"
        ])
    }

    /// `/invisible` — admin-only. Hide the session from peer rosters.
    /// Broadcasts `userLeft` (302) so existing clients drop the row,
    /// flips the registry's invisibility bit so subsequent
    /// `getUserList` (300) replies exclude the session, and suppresses
    /// future `userChanged` broadcasts (idle-away, /away, nickname
    /// changes) until the operator runs `/visible` again. The session
    /// stays fully connected — chat lines, broadcasts, file ops all
    /// reach them — they're just absent from rosters.
    func handleInvisibleCommand(args: [String]) async {
        guard hasPrivilege(.disconnectUsers) else {
            await sendSystemReply("Permission denied: /invisible requires the disconnectUsers privilege.")
            return
        }
        if isInvisible {
            await sendSystemReply("Already invisible.")
            return
        }
        isInvisible = true
        _ = await registry.updateMemberInvisible(socketID: socketID, isInvisible: true)
        await registry.broadcast(
            PacketEncoder.userLeftPush(socketID: socketID),
            excluding: socketID
        )
        await sendSystemReply("You are now invisible. Peers see you as left.")
    }

    /// `/visible` — admin-only. Re-introduce the session to peers'
    /// rosters: clears the registry's invisibility bit and broadcasts
    /// `userChanged` (301) carrying the current member record so
    /// existing clients re-add the row with whatever nickname / icon
    /// / status the session has now.
    func handleVisibleCommand(args: [String]) async {
        guard hasPrivilege(.disconnectUsers) else {
            await sendSystemReply("Permission denied: /visible requires the disconnectUsers privilege.")
            return
        }
        if !isInvisible {
            await sendSystemReply("Already visible.")
            return
        }
        isInvisible = false
        guard let updated = await registry.updateMemberInvisible(
            socketID: socketID, isInvisible: false
        ) else {
            return
        }
        await registry.broadcast(
            PacketEncoder.userChangedPush(member: updated, encoding: stringEncoding),
            excluding: socketID
        )
        await sendSystemReply("You are now visible.")
    }

    /// `/uptime` — sender-only one-liner with the server's uptime.
    /// A focused subset of `/version` for operators who just want
    /// the duration without the rest of the system block.
    func handleUptimeCommand(args: [String]) async {
        let uptime = HeidrunServerInfo.formatUptime(since: configuration.startedAt)
        await sendSystemReply("uptime: \(uptime)")
    }

    /// `/kick <socketID>` — disconnect a target by socket. Gated on
    /// `.disconnectUsers` (admin-only by default). Sugar for the
    /// existing 110 transaction with a chat-friendly interface.
    /// Self-kick is refused; unknown sockets get a sender-only
    /// "no such user" reply.
    func handleKickCommand(args: [String]) async {
        guard hasPrivilege(.disconnectUsers) else {
            await sendSystemReply("Permission denied: /kick requires the disconnectUsers privilege.")
            return
        }
        guard let first = args.first, let target = UInt16(first) else {
            await sendSystemReply("Usage: /kick <socketID>   (find IDs with /who)")
            return
        }
        guard target != socketID else {
            await sendSystemReply("Can't kick yourself.")
            return
        }
        guard let session = await registry.lookup(socketID: target) else {
            await sendSystemReply("No such user (socket=\(target)).")
            return
        }
        let snapshot = await session.infoSnapshot()
        await session.disconnectNow()
        await sendSystemReply("Kicked \(snapshot.nickname) (socket=\(target)).")
    }

    /// `/help` — sender-only list of every command registered in this
    /// dispatcher with a one-line description. Mirrors what's in the
    /// README so a user inside the client can discover the full set
    /// without leaving the chat window.
    func handleHelpCommand(args: [String]) async {
        await sendSystemReply(lines: [
            "Available commands:",
            "  /version            — server version, build, and runtime info",
            "  /uptime             — show server uptime",
            "  /usershistory [h]   — user join/leave history, last h hours (admin)",
            "  /audit [--type …] [--user …] [--since Nh|Nd] [--limit N] — audit log (admin)",
            "  /who, /users        — list connected users",
            "  /whoami             — your own session info",
            "  /away               — toggle your away status",
            "  /me <action>        — send an action chat line",
            "  /broadcast <text>   — server-wide broadcast popup (admin)",
            "  /topic [text]       — show or set the public chat topic (set: admin)",
            "  /kick <socketID>    — disconnect a user by socket (admin)",
            "  /invisible          — hide from peer user lists (admin)",
            "  /visible            — re-appear in peer user lists (admin)",
            "  /help               — show this list"
        ])
    }

    /// `/usershistory [hours]` (alias `/history`) — admin-only. Lists
    /// every user that entered or left in the last `hours` (default 1,
    /// clamped 1…24), oldest first, one `HH:mm:ss  <nick> entered|left`
    /// line each. Gated on `.disconnectUsers`. Backed by the audit log
    /// (presence events); replies that it's off when the operator
    /// disabled it (audit_log_enabled=false / HEIDRUN_AUDIT_LOG_ENABLED=0).
    func handleUsersHistoryCommand(args: [String]) async {
        guard hasPrivilege(.disconnectUsers) else {
            await sendSystemReply("Permission denied: /usershistory requires the disconnectUsers privilege.")
            return
        }
        guard let auditLog else {
            await sendSystemReply("Audit log is disabled on this server.")
            return
        }
        let hours = max(1, min(24, args.first.flatMap(Int.init) ?? 1))
        let events = await auditLog.query(
            type: [.join, .leave], account: nil, withinHours: hours, limit: 500
        )
        guard !events.isEmpty else {
            await sendSystemReply("No user activity in the last \(hours)h.")
            return
        }
        var lines = ["User history (last \(hours)h):"]
        for event in events {
            let when = Self.formatHistoryTime(event.timestamp)
            let verb = event.kind == .join ? "entered" : "left"
            let socketText = event.socket.map { " (\($0))" } ?? ""
            lines.append("  \(when)  \(event.nickname ?? "?")\(socketText) \(verb)")
        }
        await sendSystemReply(lines: lines)
    }

    /// Maps a `type:` token (or an alias command's implied type) to the
    /// event kinds it covers. `nil` for an unknown token.
    static func auditKinds(forType type: String) -> [AuditEvent.Kind]? {
        switch type {
        case "transfer", "transfers": return [.upload, .download]
        case "auth": return [.loginOK, .loginFail]
        case "admin": return [.accountCreate, .accountModify, .accountDelete, .kick, .broadcast, .topic]
        case "presence": return [.join, .leave]
        default: return nil
        }
    }

    /// Restore a `--flag` token mangled by macOS NSTextView "smart dashes",
    /// which rewrites a typed `--` into an em-dash (—, U+2014) or en-dash
    /// (–, U+2013). A leading such dash is mapped back to `--` so flags
    /// typed in a chat input still parse. Everything else passes through.
    static func normalizeAuditFlag(_ token: String) -> String {
        if token.hasPrefix("\u{2014}") || token.hasPrefix("\u{2013}") {
            return "--" + token.dropFirst()
        }
        return token
    }

    /// `true` when the args ask for usage (`help` / `--help` / `-h` / `?`).
    static func auditArgsRequestHelp(_ args: [String]) -> Bool {
        let tokens: Set<String> = ["help", "--help", "-h", "?"]
        return args.contains { tokens.contains(normalizeAuditFlag($0).lowercased()) }
    }

    /// Alias command → implied default `type` filter (nil = no filter).
    static func defaultAuditType(forCommand command: String) -> String? {
        switch command {
        case "transfers": return "transfer"
        case "authlog": return "auth"
        case "adminlog": return "admin"
        default: return nil          // "audit"
        }
    }

    struct AuditQuery: Equatable {
        var kinds: [AuditEvent.Kind]?
        var account: String?
        var hours: Int
        var limit: Int
    }

    /// Parse `--flag value` audit args. Each recognised flag consumes the
    /// next token as its value; an unknown flag or a dangling flag (no
    /// following value) is skipped, leaving its default. Unknown `--type`
    /// value → nil kinds (all).
    static func parseAuditArgs(_ args: [String], impliedType: String? = nil) -> AuditQuery {
        var kinds = impliedType.flatMap(auditKinds(forType:))
        var account: String?
        var hours = 24
        var limit = 50
        var index = 0
        while index < args.count {
            let flag = Self.normalizeAuditFlag(args[index]).lowercased()
            let value: String? = index + 1 < args.count ? args[index + 1] : nil
            switch flag {
            case "--type":
                if let value { kinds = auditKinds(forType: value.lowercased()); index += 1 }
            case "--user", "--account":
                if let value { account = value; index += 1 }
            case "--since":
                if let value { hours = parseSince(value) ?? hours; index += 1 }
            case "--limit":
                if let value { limit = Int(value).map { max(1, min(500, $0)) } ?? limit; index += 1 }
            default:
                break
            }
            index += 1
        }
        return AuditQuery(kinds: kinds, account: account, hours: max(1, hours), limit: limit)
    }

    /// `Nh` / `Nd` → hours. Bare integer treated as hours.
    static func parseSince(_ value: String) -> Int? {
        let lower = value.lowercased()
        if lower.hasSuffix("d"), let days = Int(lower.dropLast()) { return max(1, days) * 24 }
        if lower.hasSuffix("h"), let hrs = Int(lower.dropLast()) { return max(1, hrs) }
        return Int(lower).map { max(1, $0) }
    }

    /// `/audit [--type …] [--user …] [--since Nh|Nd] [--limit N]` (+ aliases
    /// `/transfers`, `/authlog`, `/adminlog`). Admin-only, gated on
    /// `.disconnectUsers` (same as `/usershistory`).
    func handleAuditCommand(command: String, args: [String]) async {
        if Self.auditArgsRequestHelp(args) {
            await sendAuditUsage()
            return
        }
        guard hasPrivilege(.disconnectUsers) else {
            await sendSystemReply("Permission denied: /audit requires the disconnectUsers privilege.")
            return
        }
        guard let auditLog else {
            await sendSystemReply("Audit log is disabled on this server.")
            return
        }
        let query = Self.parseAuditArgs(args, impliedType: Self.defaultAuditType(forCommand: command))
        let events = await auditLog.query(
            type: query.kinds, account: query.account, withinHours: query.hours, limit: query.limit
        )
        guard !events.isEmpty else {
            await sendSystemReply("No audit events match (last \(query.hours)h).")
            return
        }
        var lines = ["Audit (\(events.count), last \(query.hours)h):"]
        for event in events {
            let when = Self.formatHistoryTime(event.timestamp)
            let who = event.nickname ?? event.account ?? "?"
            var parts = ["  \(when)  \(event.kind.rawValue)  \(who)"]
            if let target = event.target { parts.append(target) }
            if let bytes = event.bytes { parts.append("\(bytes)B") }
            if let ip = event.ip { parts.append(ip) }
            lines.append(parts.joined(separator: "  "))
        }
        await sendSystemReply(lines: lines)
    }

    /// Usage block for `/audit help` (and `--help` / `-h` / `?`).
    func sendAuditUsage() async {
        await sendSystemReply(lines: [
            "/audit — query the audit log (admin):",
            "  /audit [--type transfer|auth|admin|presence] [--user <name>] [--since Nh|Nd] [--limit N]",
            "  defaults: all types, last 24h, 50 rows (limit max 500)",
            "  e.g.  /audit --type auth --user bob --since 7d",
            "  aliases: /transfers /authlog /adminlog   (presence also: /usershistory)"
        ])
    }

    /// `HH:mm:ss` in the server's local timezone — terse, time-only (the
    /// list is bounded to 24h). Distinct from `formatLoginTime`'s
    /// date+zone form.
    static func formatHistoryTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// `/broadcast <message>` — send a server-wide broadcast popup
    /// (transID 355) to every connected session, including the
    /// sender so they see their own message as confirmation it
    /// landed. Gated on `.canBroadcast` (admin-only by default).
    /// Empty bodies surface a usage hint instead of broadcasting.
    ///
    /// Differs from the existing 355 transaction handler
    /// (`handleBroadcast`) in two ways: (1) the 355 transaction
    /// excludes the originator because their own client renders the
    /// message locally before the round-trip — here, the sender is
    /// in a chat window and needs to see the broadcast surface
    /// through the same channel everyone else sees; (2) a sender-only
    /// `*** Broadcast sent.` chat line confirms the privilege check
    /// passed and the message went out.
    func handleBroadcastCommand(args: [String]) async {
        guard hasPrivilege(.canBroadcast) else {
            await sendSystemReply("Permission denied: /broadcast requires the canBroadcast privilege.")
            return
        }
        let message = args.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else {
            await sendSystemReply("Usage: /broadcast <message>")
            return
        }
        await audit(.broadcast, detail: message)
        // Native 355 push for clients that render server broadcasts as
        // a modal popup (mobius, mierauhotline, classic Hotline).
        await registry.broadcast(
            PacketEncoder.serverBroadcastPush(message: message, encoding: stringEncoding),
            excluding: nil
        )
        // Chat-window fallback so clients without a broadcast-popup UI
        // (notably heidrun-swift today) still surface the message. The
        // " *** BROADCAST from <nick>: <msg> ***" framing is visually
        // distinct from regular `<nick>: <text>` chat so it's hard to
        // miss in the scroll. Trade-off: clients that DO render the
        // 355 popup will see the message twice (once as popup, once as
        // chat) — acceptable until those clients can be taught to
        // suppress one or the other.
        let chatLine = " *** BROADCAST from \(nickname): \(message) ***\r"
        await registry.broadcast(
            PacketEncoder.chatPush(line: chatLine, isAction: false, encoding: stringEncoding),
            excluding: nil
        )
        await sendSystemReply("Broadcast sent.")
    }

    /// `/topic [text]` — show or set the **public** chat topic.
    /// `/topic` with no args reports the current topic to the sender
    /// only (ungated — anyone may read it). `/topic <text>` sets it,
    /// gated on `.canBroadcast` (same as `/broadcast`): persists via
    /// `ChatSubjectStore`, then broadcasts TX 119 (Chat ID 0) to every
    /// connected session so all clients update their header. Clearing
    /// the topic is out of scope for now.
    func handleTopicCommand(args: [String]) async {
        let text = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            let current = await chatSubject.current()
            await sendSystemReply(current.isEmpty ? "No topic set." : "Current topic: \(current)")
            return
        }
        guard hasPrivilege(.canBroadcast) else {
            await sendSystemReply("Permission denied: /topic requires the canBroadcast privilege.")
            return
        }
        await chatSubject.set(text)
        await audit(.topic, target: text)
        await registry.broadcast(
            PacketEncoder.publicChatSubjectPush(subject: text, encoding: stringEncoding),
            excluding: nil
        )
        await sendSystemReply("Topic set: \(text)")
    }
}
