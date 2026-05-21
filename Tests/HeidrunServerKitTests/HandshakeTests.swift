import Foundation
import Testing
@testable import HeidrunServerKit

@Suite("Handshake")
struct HandshakeTests {
    @Test("parses a well-formed TRTPHOTL handshake and returns a success ack")
    func acceptsValidHandshake() throws {
        let inbound = Data([
            0x54, 0x52, 0x54, 0x50,
            0x48, 0x4F, 0x54, 0x4C,
            0x00, 0x01,
            0x00, 0x02
        ])
        let ack = try Handshake.parse(inbound)
        #expect(ack == Data([
            0x54, 0x52, 0x54, 0x50,
            0x00, 0x00, 0x00, 0x00
        ]))
    }

    @Test("rejects a handshake whose magic doesn't start with TRTPHOTL")
    func rejectsBadMagic() {
        let bogus = Data(repeating: 0, count: 12)
        do {
            _ = try Handshake.parse(bogus)
            #expect(Bool(false), "expected throw")
        } catch Handshake.Error.badMagic {
            // expected
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    @Test("rejects a short handshake")
    func rejectsShort() {
        do {
            _ = try Handshake.parse(Data([0x54, 0x52, 0x54, 0x50]))
            #expect(Bool(false), "expected throw")
        } catch Handshake.Error.truncated {
            // expected
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }
}
