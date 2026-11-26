import CryptoKit
import Foundation

public struct SecretDigest: Codable, Hashable, Sendable {
    public let salt: Data
    public let hash: Data

    public init(salt: Data, hash: Data) {
        self.salt = salt
        self.hash = hash
    }
}

public enum SecretValidationError: Error, Equatable, LocalizedError {
    case tooShort
    case tooLong
    case blank

    public var errorDescription: String? {
        switch self {
        case .tooShort: return "Use at least \(SecretHasher.minLength) characters."
        case .tooLong: return "Use at most \(SecretHasher.maxLength) characters."
        case .blank: return "The secret can't be only spaces."
        }
    }
}

/// Secret words are never stored in plain text: only a salted SHA-256.
/// Typing on the overlay is matched by checking every suffix of the typed buffer,
/// so the word works even after accidental keystrokes.
public enum SecretHasher {
    public static let minLength = 2
    public static let maxLength = 32

    public static func normalize(_ secret: String) -> String {
        secret.lowercased()
    }

    public static func validate(_ secret: String) throws {
        let normalized = normalize(secret)
        if normalized.trimmingCharacters(in: .whitespaces).isEmpty { throw SecretValidationError.blank }
        if normalized.count < minLength { throw SecretValidationError.tooShort }
        if normalized.count > maxLength { throw SecretValidationError.tooLong }
    }

    public static func makeDigest(for secret: String) throws -> SecretDigest {
        try validate(secret)
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return SecretDigest(salt: salt, hash: hash(secret, salt: salt))
    }

    public static func hash(_ secret: String, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(normalize(secret).utf8))
        return Data(hasher.finalize())
    }

    public static func matches(_ candidate: String, digest: SecretDigest) -> Bool {
        hash(candidate, salt: digest.salt) == digest.hash
    }

    /// True when the typed buffer ends with the secret.
    public static func matchesSuffix(of buffer: String, digest: SecretDigest) -> Bool {
        let chars = Array(normalize(buffer))
        guard chars.count >= minLength else { return false }
        for length in minLength...min(maxLength, chars.count) {
            if matches(String(chars.suffix(length)), digest: digest) {
                return true
            }
        }
        return false
    }
}
