import Foundation

/// Formats a unified-log epoch-millis timestamp for display, optionally with
/// the date. Shared by the line and table log formatters so the `--date`
/// toggle renders identically in both views.
enum LogTimestamp {
    /// `HH:mm:ss`, or `yyyy-MM-dd HH:mm:ss` when `withDate` is set.
    static func string(_ millis: Int64, withDate: Bool) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        return (withDate ? dateTimeFormatter : timeFormatter).string(from: date)
    }

    private static let timeFormatter = make("HH:mm:ss")
    private static let dateTimeFormatter = make("yyyy-MM-dd HH:mm:ss")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = .current
        return formatter
    }
}
