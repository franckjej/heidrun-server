import Foundation

extension ClientSession {
    /// Record one audit event, stamping the acting session's identity
    /// and — only when `log_ip_addresses` is enabled — its IP. No-op when
    /// the audit log is disabled (`auditLog == nil`). Override `account`/
    /// `nickname`/`socket` for events that fire before the session is
    /// fully registered (e.g. a failed login).
    func audit(
        _ kind: AuditEvent.Kind,
        account: String? = nil,
        nickname overrideNickname: String? = nil,
        socket overrideSocket: UInt16? = nil,
        target: String? = nil,
        bytes: Int64? = nil,
        result: String? = nil,
        detail: String? = nil
    ) async {
        guard let auditLog else { return }
        let resolvedSocket = overrideSocket ?? (socketID == 0 ? nil : socketID)
        await auditLog.record(AuditEvent(
            timestamp: Date(),
            kind: kind,
            account: account ?? authenticatedAccount?.login,
            nickname: overrideNickname ?? nickname,
            socket: resolvedSocket,
            ip: configuration.logIPAddresses ? remoteIP : nil,
            target: target,
            bytes: bytes,
            result: result,
            detail: detail
        ))
    }
}
