/// Decide whether a destructive command may proceed. `assumeYes` (the
/// `--yes` flag) short-circuits the prompt; otherwise `confirm` is asked
/// and its boolean answer is returned. Pure so it's unit-testable — the
/// executable passes a closure that reads a y/N answer from the terminal.
public enum ConfirmationGate {
    public static func shouldProceed(assumeYes: Bool, confirm: () -> Bool) -> Bool {
        assumeYes ? true : confirm()
    }
}
