/// Shared parsing for audit-log filters, used by both the `/audit` chat
/// command and the `heidrun-admin audit` CLI command so the `--type`
/// keywords and `--since Nh|Nd` syntax stay identical.
public enum AuditQueryParsing {
    /// Map a `--type` keyword to the audit kinds it selects. Recognises the
    /// grouped keywords (transfer/auth/admin/presence) and any single raw
    /// `AuditEvent.Kind` rawValue (e.g. "kick"). `nil` for anything else.
    public static func kinds(forTypeKeyword keyword: String) -> [AuditEvent.Kind]? {
        switch keyword.lowercased() {
        case "transfer", "transfers": return [.upload, .download]
        case "auth":                  return [.loginOK, .loginFail]
        case "admin":                 return [.accountCreate, .accountModify, .accountDelete, .kick, .broadcast, .topic]
        case "presence":              return [.join, .leave]
        default:                      return AuditEvent.Kind(rawValue: keyword.lowercased()).map { [$0] }
        }
    }

    /// Parse `--since` into a window in hours. Accepts `Nh`, `Nd`, or a bare
    /// integer (treated as hours). `nil` when the value doesn't parse.
    public static func hours(fromSince value: String) -> Int? {
        let lower = value.lowercased()
        if lower.hasSuffix("d"), let days = Int(lower.dropLast()) { return max(1, days) * 24 }
        if lower.hasSuffix("h"), let hrs = Int(lower.dropLast()) { return max(1, hrs) }
        if let raw = Int(lower) { return max(1, raw) }
        return nil
    }
}
