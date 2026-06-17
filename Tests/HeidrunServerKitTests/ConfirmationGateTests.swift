import Testing
@testable import HeidrunServerKit

@Suite("ConfirmationGate")
struct ConfirmationGateTests {
    @Test("--yes proceeds without prompting")
    func yesSkipsPrompt() {
        var prompted = false
        let proceed = ConfirmationGate.shouldProceed(assumeYes: true) {
            prompted = true; return false
        }
        #expect(proceed)
        #expect(!prompted)
    }

    @Test("without --yes, a 'y' reply proceeds and 'n' aborts")
    func promptDecides() {
        #expect(ConfirmationGate.shouldProceed(assumeYes: false) { true })
        #expect(!ConfirmationGate.shouldProceed(assumeYes: false) { false })
    }
}
