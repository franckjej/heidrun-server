import Foundation
import HeidrunCore

extension ClientSession {
    /// Handle `disconnectUser` (110). Requires the `disconnectUsers`
    /// privilege; guests get an errorID=1 reply. Acks the kicker first
    /// so the success/error reply is observed before the target's TCP
    /// drop ripples through. `.banFlag` is read but ignored — persistent
    /// ban lists land in v1.5.
    func handleKick(header: PacketHeader, fields: [PacketField]) async {
        guard authenticatedAccount?.has(.disconnectUsers) == true else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 110
            ))
            return
        }
        let target = fields.uint16(.socket) ?? 0
        try? await writer(PacketEncoder.emptyReply(
            taskNumber: header.taskNumber,
            transactionID: 110
        ))
        guard target != 0,
              let session = await registry.lookup(socketID: target) else { return }
        await session.disconnectNow()
    }

    /// Handle `createLogin` (350). Requires `createAccounts`. Reads
    /// XOR-obfuscated login + password fields plus a plain nickname and
    /// an 8-byte privileges blob.
    func handleCreateLogin(header: PacketHeader, fields: [PacketField]) async {
        guard authenticatedAccount?.has(.createAccounts) == true else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 350
            ))
            return
        }
        let login = Self.obfuscatedString(.login, from: fields, encoding: stringEncoding) ?? ""
        let password = Self.obfuscatedString(.password, from: fields, encoding: stringEncoding) ?? ""
        let nickname = fields.string(.nickname, encoding: stringEncoding) ?? ""
        let permissions = Self.privilegesField(from: fields)
        guard !login.isEmpty else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 350
            ))
            return
        }
        do {
            _ = try await accounts.create(
                login: login,
                password: password,
                nickname: nickname,
                permissions: permissions
            )
            try? await writer(PacketEncoder.emptyReply(
                taskNumber: header.taskNumber,
                transactionID: 350
            ))
        } catch {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 350
            ))
        }
    }

    /// Handle `deleteLogin` (351). Requires `deleteAccounts`.
    func handleDeleteLogin(header: PacketHeader, fields: [PacketField]) async {
        guard authenticatedAccount?.has(.deleteAccounts) == true else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 351
            ))
            return
        }
        let login = Self.obfuscatedString(.login, from: fields, encoding: stringEncoding) ?? ""
        guard !login.isEmpty else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 351
            ))
            return
        }
        let removed = (try? await accounts.delete(login: login)) ?? false
        if removed {
            try? await writer(PacketEncoder.emptyReply(
                taskNumber: header.taskNumber,
                transactionID: 351
            ))
        } else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 351
            ))
        }
    }

    /// Handle `openLogin` (352). Requires `readAccounts`. **Note the
    /// quirk**: 352 sends the `.login` field PLAIN (not XOR-obfuscated)
    /// — see HEClient.m:995 and the corresponding client emit path.
    func handleOpenLogin(header: PacketHeader, fields: [PacketField]) async {
        guard authenticatedAccount?.has(.readAccounts) == true else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 352
            ))
            return
        }
        let login = fields.string(.login, encoding: stringEncoding) ?? ""
        guard !login.isEmpty,
              let account = try? await accounts.get(login: login) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 352
            ))
            return
        }
        try? await writer(PacketEncoder.openLoginReply(
            taskNumber: header.taskNumber,
            account: account,
            encoding: stringEncoding
        ))
    }

    /// Handle `modifyLogin` (353). Requires `modifyAccounts`. The
    /// password field follows the legacy `modifyLogin` convention:
    /// - missing field → keep existing password
    /// - single 0x00 byte → set password to empty string
    /// - any other obfuscated bytes → set to that string
    func handleModifyLogin(header: PacketHeader, fields: [PacketField]) async {
        guard authenticatedAccount?.has(.modifyAccounts) == true else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 353
            ))
            return
        }
        let login = Self.obfuscatedString(.login, from: fields, encoding: stringEncoding) ?? ""
        let nickname = fields.string(.nickname, encoding: stringEncoding) ?? ""
        let permissions = Self.privilegesField(from: fields)
        let password = Self.modifyPasswordField(from: fields, encoding: stringEncoding)
        guard !login.isEmpty else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 353
            ))
            return
        }
        let updated = (try? await accounts.update(
            login: login,
            nickname: nickname,
            iconID: nil,
            permissions: permissions,
            newPassword: password
        ))
        if updated != nil {
            try? await writer(PacketEncoder.emptyReply(
                taskNumber: header.taskNumber,
                transactionID: 353
            ))
        } else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 353
            ))
        }
    }

    /// Decode the 8-byte privileges blob into a UInt64 in the same
    /// byte order as `HeidrunCore.UserPrivileges.init(bytes:)` (byte 0
    /// = low bits).
    nonisolated static func privilegesField(from fields: [PacketField]) -> UInt64 {
        guard let field = fields.first(.privileges) else { return 0 }
        var value: UInt64 = 0
        for (index, byte) in field.data.enumerated() where index < 8 {
            value |= UInt64(byte) << (index * 8)
        }
        return value
    }

    /// Read the `modifyLogin` password field: nil → keep current,
    /// single 0x00 → clear, anything else → XOR-deobfuscate.
    nonisolated static func modifyPasswordField(
        from fields: [PacketField],
        encoding: String.Encoding
    ) -> String? {
        guard let field = fields.first(.password) else { return nil }
        if field.data == Data([0x00]) { return "" }
        var bytes = Array(field.data)
        for index in bytes.indices { bytes[index] ^= 0xFF }
        return String(data: Data(bytes), encoding: encoding)
    }
}
