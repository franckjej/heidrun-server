import HeidrunCore

/// Stable string names for every `UserPrivileges` bit, so the admin CLI
/// can grant/revoke/list privileges by name. `UserPrivileges` lives in the
/// pinned protocol package (read-only here), so the name table is owned by
/// the server. Order matches the bit order in `UserPrivileges`.
public enum PrivilegeNames {
    public static let table: [(name: String, value: UserPrivileges)] = [
        // Byte 0
        ("deleteFiles", .deleteFiles),
        ("uploadFiles", .uploadFiles),
        ("downloadFiles", .downloadFiles),
        ("renameFiles", .renameFiles),
        ("moveFiles", .moveFiles),
        ("createFolders", .createFolders),
        ("deleteFolders", .deleteFolders),
        ("renameFolders", .renameFolders),
        // Byte 1
        ("moveFolders", .moveFolders),
        ("readChat", .readChat),
        ("sendChat", .sendChat),
        ("initiatePrivateChat", .initiatePrivateChat),
        ("closePrivateChat", .closePrivateChat),
        ("showInList", .showInList),
        ("createUser", .createUser),
        ("deleteUser", .deleteUser),
        // Byte 2  (bit 19 absent from the protocol definition)
        ("readUser", .readUser),
        ("modifyUser", .modifyUser),
        ("changeOwnPassword", .changeOwnPassword),
        ("readNews", .readNews),
        ("postNews", .postNews),
        ("disconnectUsers", .disconnectUsers),
        ("cannotBeDisconnected", .cannotBeDisconnected),
        // Byte 3
        ("getUserInfo", .getUserInfo),
        ("uploadAnywhere", .uploadAnywhere),
        ("useAnyName", .useAnyName),
        ("dontShowAgreement", .dontShowAgreement),
        ("commentFiles", .commentFiles),
        ("commentFolders", .commentFolders),
        ("viewDropBoxes", .viewDropBoxes),
        ("makeAliases", .makeAliases),
        // Byte 4
        ("canBroadcast", .canBroadcast),
        ("deleteArticles", .deleteArticles),
        ("createCategories", .createCategories),
        ("deleteCategories", .deleteCategories),
        ("createNewsBundles", .createNewsBundles),
        ("deleteNewsBundles", .deleteNewsBundles),
        ("uploadFolders", .uploadFolders),
        ("downloadFolders", .downloadFolders),
        // Byte 5
        ("sendMessages", .sendMessages)
    ]

    /// All known privilege names, in bit order. (= 40 entries.)
    public static var allNames: [String] { table.map(\.name) }

    /// Case-insensitive name → bit lookup. `nil` for an unknown name.
    public static func value(for name: String) -> UserPrivileges? {
        let needle = name.lowercased()
        return table.first { $0.name.lowercased() == needle }?.value
    }

    /// Names of every bit set in `privileges`, in bit order.
    public static func names(in privileges: UserPrivileges) -> [String] {
        table.filter { privileges.contains($0.value) }.map(\.name)
    }

    /// Parse a comma-separated name list into the matched bits plus any
    /// unrecognised names (trimmed; empty entries skipped).
    public static func parse(_ csv: String) -> (matched: UserPrivileges, unknown: [String]) {
        var matched = UserPrivileges()
        var unknown: [String] = []
        for raw in csv.split(separator: ",") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let bit = value(for: trimmed) {
                matched.formUnion(bit)
            } else {
                unknown.append(trimmed)
            }
        }
        return (matched, unknown)
    }
}
