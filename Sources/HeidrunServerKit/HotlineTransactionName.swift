/// Maps Hotline wire transaction IDs (the `header.transactionID` the server
/// dispatches on) to short human names, for the `heidrun-admin log --table`
/// ACTION column. The server dispatches on raw `UInt16` literals (no enum),
/// so this is the single name table — keep it in sync with the `switch
/// header.transactionID` in `ClientSession`'s dispatch. Unknown IDs return
/// nil (callers render `txn <id>`).
public enum HotlineTransactionName {
    public static func name(for transactionID: UInt16) -> String? {
        table[transactionID]
    }

    private static let table: [UInt16: String] = [
        101: "getNews",
        103: "postNews",
        105: "sendChat",
        107: "login",
        108: "sendPrivMsg",
        109: "disconnect",
        110: "kickUser",
        112: "createPrivChat",
        113: "invitePrivChat",
        114: "rejectPrivChat",
        115: "joinPrivChat",
        116: "leavePrivChat",
        120: "setPrivChatSubject",
        121: "agreeAgreement",
        200: "getFileList",
        202: "downloadFile",
        203: "uploadFile",
        204: "deleteFile",
        205: "createFolder",
        206: "getFileInfo",
        207: "setFileInfo",
        208: "moveFile",
        209: "makeAlias",
        210: "downloadFolder",
        212: "downloadBanner",
        213: "uploadFolder",
        214: "deleteTransfer",
        300: "getUserNameList",
        303: "getUserInfo",
        304: "setUserInfo",
        350: "createAccount",
        351: "deleteAccount",
        352: "openAccount",
        353: "modifyAccount",
        355: "broadcast",
        370: "getNewsBundles",
        371: "getNewsCategory",
        380: "deleteNewsBundle",
        381: "createNewsBundle",
        382: "createNewsCategory",
        400: "getNewsArticle",
        410: "postNewsArticle",
        411: "deleteNewsArticle",
        500: "ping"
    ]
}
