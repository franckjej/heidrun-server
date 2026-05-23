# Chat slash commands — design

**Status:** Approved 2026-05-23, implemented same day.
**Authors:** Jens Francke + Claude
**Scope:** First-pass `/command` system through the Hotline chat input,
shipping with two commands: `/version` and `/away`. Designed for
extension — adding a third command is one new method + one switch arm.

**Post-implementation amendment (2026-05-23):** The system-reply
prefix was changed from `« ` (U+00AB, MacRoman 0xC7) to `*** `
(plain ASCII) during first deploy. The non-ASCII prefix didn't
round-trip cleanly through the Linux server's
`String.data(using: .macOSRoman)` path on at least one client/server
combination — the receiver rendered the prefix as `â` instead of
the expected `«`. ASCII is robust against any encoding-decoder
mismatch and was a stylistic choice anyway. All references below
showing `« ` should be read as `*** ` in the shipped code.

## Context

Classic Hotline servers like HXD let users issue server commands by
typing `/cmd` into chat. The server intercepts those lines (they're
never broadcast as chat), performs the action, and may reply privately
to the sender. HeidrunServer has none of this today: every chat line
becomes a broadcast `chatPush` (transID 106). We want feature parity
with HXD's command surface, starting with the two most useful commands:

- `/version` — surface the running server's semver and build identifier
  so operators / users can confirm what they're connected to without
  shelling into the host.
- `/away` — let users explicitly toggle the `UserStatusFlags.away`
  bit, independent of the existing idle-driven supervisor (which only
  flips it after `idleAwayThreshold` seconds of inactivity).

## Goals

1. Intercept `/`-prefixed chat lines before they reach the broadcast
   path. Other connected users see nothing.
2. Reply to the sender privately for informational commands.
3. Toggle the away bit immediately on `/away`, surviving the idle
   supervisor's reconciliation loop (no fight).
4. Make adding a third command obvious: one method on
   `ClientSession+Commands`, one switch arm.

## Non-goals

- A pluggable command system or external command modules. Commands
  are first-class Swift code paths.
- `/me`-style action chat. Already handled by the existing
  `parameter` field; not a slash command.
- `/away [reason]` with custom away messages. Hotline's wire format
  doesn't carry per-user away reasons; adding storage for them is
  out of scope.
- `/back` as a separate command. `/away` is a toggle.

## Surface

### `/version`

Output (two `chatPush` lines joined by `\r`, delivered to the sender
only):

```
« HeidrunServer 0.7.0
« build: a1b2c3d (2026-05-23)
```

Build line collapses to `« build: dev` when `HEIDRUN_BUILD` is unset
or empty (local `swift run`). The `(date)` parenthetical is omitted
when `HEIDRUN_BUILD_DATE` is empty.

### `/away`

- Toggles the session's `manuallyAway` flag.
- Sends a sender-only confirmation chat line: `« You are now away.`
  or `« Welcome back.`
- Triggers `applyAwayState()`, which broadcasts a `userChanged` (301)
  to every connected session with the new effective status (admin
  color preserved on admins).

### Unknown command

Sender-only reply: `« Unknown command: /foo`. Never broadcast.

### Non-command paths preserved

| body                | behaviour                                      |
|---------------------|------------------------------------------------|
| `hello`             | normal chat broadcast (unchanged)              |
| `/` (alone)         | falls through to normal chat                   |
| `//emph`            | falls through to normal chat                   |
| `   /version   `    | trimmed → recognised → handled                 |
| `/Version`, `/AWAY` | case-insensitive on the command head           |
| `/version foo bar`  | extra tokens silently ignored                  |

## Architecture

### Files added

```
Sources/HeidrunServerKit/HeidrunServerInfo.swift     constants module
Sources/HeidrunServerKit/ClientSession+Commands.swift parser + handlers
Tests/HeidrunServerKitTests/ChatCommandsTests.swift  new suite
```

### Files modified

```
Sources/HeidrunServerKit/ClientSession.swift     handleChat early-return;
                                                 manuallyAway property;
                                                 idleAwayThreshold cached;
                                                 reconcileAwayState refactored;
                                                 applyAwayState added;
                                                 sendSystemReply helpers
Dockerfile                                       ARG GIT_REV + ARG BUILD_DATE
                                                 → ENV HEIDRUN_BUILD + …_DATE
docker-compose.yml                               build.args entries to forward
```

### `HeidrunServerInfo`

```swift
public enum HeidrunServerInfo {
    public static let version: String = "0.7.0"          // hand-bumped per release

    public static var buildIdentifier: String {
        sanitised(ProcessInfo.processInfo.environment["HEIDRUN_BUILD"], fallback: "dev")
    }

    public static var buildDate: String {
        sanitised(ProcessInfo.processInfo.environment["HEIDRUN_BUILD_DATE"], fallback: "")
    }

    /// Strip ASCII control bytes so a malformed build stamp can't
    /// corrupt the multi-line /version reply. Returns `fallback`
    /// when the input is nil or empty after stripping.
    private static func sanitised(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        let cleaned = raw.filter {
            !$0.isASCII || ($0.asciiValue ?? 0) >= 0x20
        }
        return cleaned.isEmpty ? fallback : cleaned
    }
}
```

Values are read on each access — tests can `setenv` / `unsetenv`
mid-suite and see the new value without restarting the process.

### `ClientSession+Commands.swift` (parser + dispatch)

```swift
extension ClientSession {
    /// Returns true if `body` was a recognised slash command and has
    /// been fully handled (caller should NOT broadcast). False means
    /// fall through to the normal chat broadcast path.
    func handleChatCommandIfPresent(body: String, header: PacketHeader) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        // Single-/ prefix only; "//emph" and "/" fall through to chat.
        guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//"), trimmed.count > 1 else {
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
        case "version": await handleVersionCommand(args: args)
        case "away":    await handleAwayCommand(args: args)
        default:
            serverLogger.info("unknown chat command", metadata: [
                "command": "\(command)",
                "socketID": "\(socketID)"
            ])
            await sendSystemReply("Unknown command: /\(command)")
        }
        return true
    }

    func handleVersionCommand(args: [String]) async {
        let buildDate = HeidrunServerInfo.buildDate
        let buildLine = buildDate.isEmpty
            ? "build: \(HeidrunServerInfo.buildIdentifier)"
            : "build: \(HeidrunServerInfo.buildIdentifier) (\(buildDate))"
        await sendSystemReply(lines: [
            "HeidrunServer \(HeidrunServerInfo.version)",
            buildLine
        ])
    }

    func handleAwayCommand(args: [String]) async {
        manuallyAway.toggle()
        await applyAwayState()
        await sendSystemReply(manuallyAway ? "You are now away." : "Welcome back.")
    }
}
```

### `ClientSession.swift` modifications

```swift
// new actor-isolated state
var manuallyAway: Bool = false
var idleAwayThreshold: TimeInterval = .greatestFiniteMagnitude
    // sentinel so applyAwayState invoked before the supervisor
    // ever runs treats the session as not-idle.

// new helpers
func sendSystemReply(_ text: String) async {
    let line = "« \(text)\r"
    try? await writer(PacketEncoder.chatPush(
        line: line, isAction: false, encoding: stringEncoding
    ))
}

func sendSystemReply(lines: [String]) async {
    let joined = lines.map { "« \($0)" }.joined(separator: "\r") + "\r"
    try? await writer(PacketEncoder.chatPush(
        line: joined, isAction: false, encoding: stringEncoding
    ))
}

/// Shared reconciliation between the idle supervisor and the /away
/// chat command — both must compute and broadcast through the same
/// path so they can never disagree on the broadcast wire state.
func applyAwayState() async {
    guard socketID != 0 else { return }
    let isIdle = Date().timeIntervalSince(lastActivityAt) >= idleAwayThreshold
    let isAway = isIdle || manuallyAway
    if isAway == awayBroadcast { return }

    let baseStatus = authenticatedAccount.initialHotStatus
    let awayBit: UInt16 = 1 << 0
    let newStatus: UInt16 = isAway ? (baseStatus | awayBit) : baseStatus
    guard let updated = await registry.updateMemberStatus(
        socketID: socketID, status: newStatus
    ) else { return }
    await registry.broadcast(
        PacketEncoder.userChangedPush(member: updated, encoding: stringEncoding),
        excluding: nil
    )
    awayBroadcast = isAway
    serverLogger.debug("away reconcile", metadata: [
        "socketID": "\(socketID)",
        "nickname": "\(nickname)",
        "isAway": "\(isAway)",
        "isIdle": "\(isIdle)",
        "manuallyAway": "\(manuallyAway)"
    ])
}

// existing entry-point for HeidrunServer — now delegates
public func reconcileAwayState(threshold: TimeInterval) async {
    self.idleAwayThreshold = threshold
    await applyAwayState()
}
```

### `handleChat` modification

One new line at the top of the existing method:

```swift
private func handleChat(header: PacketHeader, fields: [PacketField]) async {
    guard let body = fields.string(.message, encoding: stringEncoding) else {
        try? await writer(PacketEncoder.emptyReply(
            taskNumber: header.taskNumber, transactionID: 105
        ))
        return
    }
    // NEW: intercept /commands before the broadcast path.
    if await handleChatCommandIfPresent(body: body, header: header) {
        try? await writer(PacketEncoder.emptyReply(
            taskNumber: header.taskNumber, transactionID: 105
        ))
        return
    }
    // existing broadcast path unchanged
    let isAction = (fields.uint16(.parameter) ?? 0) != 0
    let line = " \(nickname): \(body)\r"
    let push = PacketEncoder.chatPush(line: line, isAction: isAction, encoding: stringEncoding)
    await registry.broadcast(push)
    try? await writer(PacketEncoder.emptyReply(
        taskNumber: header.taskNumber, transactionID: 105
    ))
}
```

The empty 105 ack still goes back to the sender even on `/command`
paths so the client doesn't time out waiting for a transaction reply.

## Data flow

`/version` (sender = Alice):
```
Alice         server                          Bob
  |            |                                |
  |--105 "/version"--->                         |
  |            handleChat → handleChatCommandIfPresent → handleVersionCommand
  |            |                                |
  |<--106 "« HeidrunServer …"+"« build: …"      |
  |<--105 emptyReply (ack)                      |
  |            |   (no broadcast to Bob)        |
```

`/away` (sender = Alice):
```
Alice         server                          Bob
  |            |                                |
  |--105 "/away"--->                            |
  |            handleChat → ... → handleAwayCommand → applyAwayState
  |            |                                |
  |<--301 userChanged(alice, away|baseStatus)   |
  |            |---------------- 301 userChanged(alice, …) ---->
  |<--106 "« You are now away."                 |
  |<--105 emptyReply (ack)                      |
```

The `301 userChanged` is broadcast to *all* sessions (including
Alice, `excluding: nil`) so every client's roster updates consistently.

## Build-time wiring

`Dockerfile` additions:

```dockerfile
# Build stage, near other ARGs
ARG GIT_REV=dev
ARG BUILD_DATE=

# Runtime stage, after USER heidrun
ENV HEIDRUN_BUILD=${GIT_REV}
ENV HEIDRUN_BUILD_DATE=${BUILD_DATE}
```

`docker-compose.yml` `build:` block:

```yaml
build:
  context: .
  dockerfile: Dockerfile
  args:
    GIT_REV: ${HEIDRUN_BUILD:-dev}
    BUILD_DATE: ${HEIDRUN_BUILD_DATE:-}
  secrets:
    - gh_token
```

Operator stamping:

```bash
HEIDRUN_BUILD="$(git rev-parse --short HEAD)" \
HEIDRUN_BUILD_DATE="$(date -u +%Y-%m-%d)" \
DOCKER_BUILDKIT=1 GH_TOKEN="$(gh auth token)" \
  docker compose build
```

Unset env vars resolve to `dev` and empty, matching `HeidrunServerInfo`'s
fallbacks. README's "Building" section gets a 5-line note documenting
this incantation.

## Behaviour matrix — away interaction with the idle supervisor

| starting state             | `/away` typed       | supervisor tick (idle) | supervisor tick (active) |
|----------------------------|---------------------|------------------------|--------------------------|
| not idle, manual=false     | manual=true, away   | (no change yet)        | (no change)              |
| not idle, manual=true      | manual=false, back  | (no change yet)        | (no change)              |
| idle, manual=false (auto)  | manual=true, stays  | (already away)         | clears away              |
| idle, manual=true          | manual=false, stays | stays (still idle)     | clears away              |

`applyAwayState` skips when `isAway == awayBroadcast`, so the
"stays" cells produce zero packets on the wire.

## Test plan

New suite `Tests/HeidrunServerKitTests/ChatCommandsTests.swift`,
serialized (env-var manipulation requires it). One test per row:

- `/version returns version + build to sender only` — assert sender
  receives chat 106 starting `« HeidrunServer `; assert other client
  receives no chat for this transaction.
- `/version build line includes env-stamped identifier` — `setenv
  HEIDRUN_BUILD=abc1234`, `HEIDRUN_BUILD_DATE=2026-05-23`; second
  line must equal `« build: abc1234 (2026-05-23)`.
- `/version falls back to 'dev' when HEIDRUN_BUILD unset/empty` —
  unset both; second line must equal `« build: dev` (no parenthetical).
- `/version strips control bytes from env-stamped values` —
  `setenv HEIDRUN_BUILD="abc\n1234"`; assert the response is one
  line per server line, no embedded newlines.
- `/away flips the away bit and broadcasts userChanged to all` —
  alice + bob; alice `/away`; bob receives 301 with
  `UserStatusFlags.away` set in the status low byte.
- `/away second invocation clears the away bit` — toggle twice; second
  broadcast clears.
- `/away on an admin preserves the red color byte` — admin login,
  `/away`; broadcasted status high byte stays 36.
- `/away sends sender-only confirmation` — alice receives `« You are
  now away.` chat; bob does not.
- `/away wins against the idle supervisor` — `/away` manually, then
  call `reconcileAwayState` with a threshold large enough that idle is
  false; assert no redundant userChanged is broadcast.
- `Unknown /foo replies privately and never broadcasts` — `« Unknown
  command: /foo` to alice; nothing to bob.
- `Case-insensitive command head` — `/Version`, `/AWAY` recognised.
- `Body of just '/' falls through as normal chat` — bob receives a
  normal `alice: /` chat line.
- `Whitespace-padded /command is recognised` — `  /version  ` →
  handled.
- `// prefix falls through as normal chat` — `//emph` reaches bob as
  user chat.

Existing tests around `reconcileAwayState` still pass because
`manuallyAway` defaults to `false` and the new logic collapses to the
old `isIdle` decision.

Env-var tests use `defer { unsetenv(...) }` to avoid leaking state.

## Error handling

| condition                  | response                                        |
|----------------------------|-------------------------------------------------|
| pre-login `/away`          | `applyAwayState` no-ops on `socketID == 0`      |
| pre-login `/version`       | safe (only reads constants); reply still sent   |
| malformed env-stamp        | sanitised by `HeidrunServerInfo.sanitised`      |
| chat writer fails          | `try?` swallow (existing pattern across the codebase) |
| unknown command            | sender-only `« Unknown command: /foo`           |

## Out of scope / future commands

The dispatcher is intentionally easy to extend. Plausible next
additions, each one method + one switch arm:

- `/me <action>` — re-route to the existing `parameter`-driven action
  branch rather than the broadcast.
- `/users` or `/who` — sender-only list of connected nicks.
- `/uptime` — sender-only `HeidrunServer up Xd Yh Zm`.
- `/kick <socketID>` — sugar for the existing 110 transaction,
  gated on `.disconnectUsers`.
- `/broadcast <message>` — sugar for 355, gated on `.canBroadcast`.

None of these are part of this spec.
