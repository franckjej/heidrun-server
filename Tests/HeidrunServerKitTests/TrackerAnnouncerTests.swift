import Testing
import Foundation
@testable import HeidrunServerKit

@Suite("TrackerHost.parse")
struct TrackerHostParseTests {
    @Test("host-only string defaults port to 5498 and password to empty")
    func hostOnly() {
        let parsed = TrackerHost.parse("hltracker.com")
        #expect(parsed == TrackerHost(host: "hltracker.com", port: 5498, password: ""))
    }

    @Test("host:port form uses the specified port")
    func hostAndPort() {
        let parsed = TrackerHost.parse("hltracker.com:5500")
        #expect(parsed == TrackerHost(host: "hltracker.com", port: 5500, password: ""))
    }

    @Test("host:port:password form parses all three components")
    func fullForm() {
        let parsed = TrackerHost.parse("private.example:5498:my-tracker-pw")
        #expect(parsed == TrackerHost(host: "private.example", port: 5498, password: "my-tracker-pw"))
    }

    @Test("trailing colons in the password are preserved (maxSplits=2)")
    func passwordWithColon() {
        let parsed = TrackerHost.parse("private.example:5498:pass:with:colons")
        #expect(parsed?.password == "pass:with:colons")
    }

    @Test("leading/trailing whitespace is trimmed before parsing")
    func whitespaceTrimmed() {
        let parsed = TrackerHost.parse("  hltracker.com:5498  ")
        #expect(parsed == TrackerHost(host: "hltracker.com", port: 5498, password: ""))
    }

    @Test("empty input rejects the parse")
    func emptyRejected() {
        #expect(TrackerHost.parse("") == nil)
        #expect(TrackerHost.parse("   ") == nil)
    }

    @Test("missing host rejects the parse")
    func missingHostRejected() {
        #expect(TrackerHost.parse(":5498") == nil)
    }

    @Test("non-numeric port falls back to 5498 rather than rejecting")
    func portFallback() {
        let parsed = TrackerHost.parse("hltracker.com:not-a-port")
        #expect(parsed == TrackerHost(host: "hltracker.com", port: 5498, password: ""))
    }
}

@Suite("TrackerAnnouncer")
struct TrackerAnnouncerTests {
    /// Capture sent datagrams without opening a real UDP socket so we can
    /// assert on the wire bytes the announcer produced.
    private actor SendRecorder {
        var sends: [(host: TrackerHost, packet: Data)] = []
        func record(_ host: TrackerHost, _ packet: Data) {
            sends.append((host, packet))
        }
    }

    @Test("announceOnce sends one packet per configured tracker")
    func oneSendPerTracker() async {
        let recorder = SendRecorder()
        let trackers = [
            TrackerHost(host: "public.tracker.example"),
            TrackerHost(host: "private.tracker.example", port: 5498, password: "secret")
        ]
        let announcer = TrackerAnnouncer(
            trackers: trackers,
            serverName: "Heidrun",
            announceDescription: "Test deploy",
            advertisedPort: 5500,
            userCountProvider: { 3 },
            send: { tracker, payload in
                await recorder.record(tracker, payload)
            },
            randomPassID: { 0xCAFE_BABE }
        )

        await announcer.announceOnce()

        let captured = await recorder.sends
        #expect(captured.count == 2)
        #expect(captured[0].host.host == "public.tracker.example")
        #expect(captured[1].host.host == "private.tracker.example")
    }

    @Test("announceOnce embeds live user count and configured name/description")
    func packetContent() async {
        let recorder = SendRecorder()
        let announcer = TrackerAnnouncer(
            trackers: [TrackerHost(host: "tracker.example")],
            serverName: "Test Serv",
            announceDescription: "Fooz",
            advertisedPort: 16,
            userCountProvider: { 2 },
            send: { tracker, payload in
                await recorder.record(tracker, payload)
            },
            randomPassID: { 1 }
        )

        await announcer.announceOnce()

        // Same golden vector as the codec test — confirms the announcer
        // hands the full TrackerRegistration through unchanged.
        let expected = Data([
            0x00, 0x01,
            0x00, 0x10,
            0x00, 0x02,
            0x00, 0x00,
            0x00, 0x00, 0x00, 0x01,
            0x09, 0x54, 0x65, 0x73, 0x74, 0x20, 0x53, 0x65, 0x72, 0x76,
            0x04, 0x46, 0x6f, 0x6f, 0x7a,
            0x00
        ])
        let captured = await recorder.sends
        #expect(captured.first?.packet == expected)
    }

    @Test("per-tracker password is carried in that tracker's packet only")
    func perTrackerPassword() async {
        let recorder = SendRecorder()
        let trackers = [
            TrackerHost(host: "a", password: ""),
            TrackerHost(host: "b", password: "secret")
        ]
        let announcer = TrackerAnnouncer(
            trackers: trackers,
            serverName: "S",
            announceDescription: "D",
            advertisedPort: 5500,
            userCountProvider: { 0 },
            send: { tracker, payload in
                await recorder.record(tracker, payload)
            },
            randomPassID: { 0 }
        )

        await announcer.announceOnce()

        let captured = await recorder.sends
        // Last byte of `a`'s packet is the zero-length password byte.
        #expect(captured[0].packet.last == 0x00)
        // `b`'s packet ends with 0x06 + "secret".
        #expect(captured[1].packet.suffix(7) == Data([0x06, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74]))
    }

    @Test("send errors on one tracker don't block the rest")
    func errorIsolation() async {
        struct BrokenTracker: Error {}
        let recorder = SendRecorder()
        let trackers = [
            TrackerHost(host: "broken"),
            TrackerHost(host: "working")
        ]
        let announcer = TrackerAnnouncer(
            trackers: trackers,
            serverName: "S",
            announceDescription: "D",
            advertisedPort: 5500,
            userCountProvider: { 0 },
            send: { tracker, payload in
                if tracker.host == "broken" {
                    throw BrokenTracker()
                }
                await recorder.record(tracker, payload)
            },
            randomPassID: { 0 }
        )

        await announcer.announceOnce()

        let captured = await recorder.sends
        #expect(captured.count == 1)
        #expect(captured.first?.host.host == "working")
    }

    @Test("empty tracker list short-circuits start without spawning a task")
    func emptyListNoop() async {
        let announcer = TrackerAnnouncer(
            trackers: [],
            serverName: "S",
            announceDescription: "D",
            advertisedPort: 5500,
            userCountProvider: { 0 },
            send: { _, _ in
                Issue.record("send should never be called for an empty tracker list")
            }
        )
        await announcer.start()
        await announcer.stop()
    }
}
