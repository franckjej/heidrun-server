import Foundation
import Crypto
import _CryptoExtras

/// Password-at-rest hashing for `AccountStore`. Uses PBKDF2-SHA256 via
/// `swift-crypto`'s `_CryptoExtras` — Apple-maintained, Linux-portable,
/// no native deps. The original M3 design spec called for bcrypt; PBKDF2
/// was chosen because the Swift ecosystem has no clean stand-alone
/// bcrypt package. Switching to bcrypt or Argon2id later is a rolling
/// re-hash on next successful login (the stored PHC string carries the
/// algorithm identifier so `verify` can route by `$2b$…` vs `$pbkdf2…`).
///
/// On-disk format is PHC-string-like:
///
/// ```
/// $pbkdf2-sha256$<rounds>$<salt_base64>$<hash_base64>
/// ```
///
/// `rounds` is OWASP's 2023 recommendation for PBKDF2-SHA256 (210 000).
public enum PasswordHash {
    /// Default round count. Can be lowered in tests to keep them fast.
    public static let defaultRounds = 210_000
    /// Salt length in bytes (16 → 128 bits, well above the OWASP minimum).
    public static let saltByteCount = 16
    /// Derived-key length in bytes (32 → 256 bits, matches SHA-256 output).
    public static let derivedKeyByteCount = 32

    /// Hash `password` with a random salt; return a self-describing
    /// PHC-style string suitable for storing in the `accounts` table.
    public static func hash(
        _ password: String,
        rounds: Int = defaultRounds
    ) throws -> String {
        var saltBytes = [UInt8](repeating: 0, count: saltByteCount)
        for index in 0..<saltByteCount {
            saltBytes[index] = UInt8.random(in: 0...UInt8.max)
        }
        let saltData = Data(saltBytes)
        let derived = try KDF.Insecure.PBKDF2.deriveKey(
            from: Data(password.utf8),
            salt: saltData,
            using: .sha256,
            outputByteCount: derivedKeyByteCount,
            unsafeUncheckedRounds: rounds
        )
        let hashData = derived.withUnsafeBytes { Data($0) }
        return "$pbkdf2-sha256$\(rounds)$\(saltData.base64EncodedString())$\(hashData.base64EncodedString())"
    }

    /// Verify `password` against a previously-hashed PHC string. Returns
    /// `true` on match, `false` otherwise. Constant-time comparison so a
    /// timing attacker can't infer how many bytes matched.
    public static func verify(_ password: String, hashedPHC: String) -> Bool {
        guard let parts = parse(hashedPHC) else { return false }
        guard let derived = try? KDF.Insecure.PBKDF2.deriveKey(
            from: Data(password.utf8),
            salt: parts.salt,
            using: .sha256,
            outputByteCount: parts.expected.count,
            unsafeUncheckedRounds: parts.rounds
        ) else { return false }
        let candidate = derived.withUnsafeBytes { Data($0) }
        return constantTimeEqual(candidate, parts.expected)
    }

    private struct ParsedPHC {
        let rounds: Int
        let salt: Data
        let expected: Data
    }

    private static func parse(_ phc: String) -> ParsedPHC? {
        let parts = phc.split(separator: "$", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 4 else { return nil }
        guard parts[0] == "pbkdf2-sha256" else { return nil }
        guard let rounds = Int(parts[1]), rounds > 0 else { return nil }
        guard let salt = Data(base64Encoded: parts[2]),
              let expected = Data(base64Encoded: parts[3]) else { return nil }
        return ParsedPHC(rounds: rounds, salt: salt, expected: expected)
    }

    /// XOR-OR each byte pair so the comparison takes the same time
    /// regardless of where the mismatch occurs.
    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[lhs.startIndex + index] ^ rhs[rhs.startIndex + index]
        }
        return difference == 0
    }
}
