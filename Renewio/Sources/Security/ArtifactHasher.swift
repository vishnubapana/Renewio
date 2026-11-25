import CryptoKit
import Foundation

enum ArtifactHasher {
    /// SHA-256 hex digest of a file (streaming).
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func matches(fileAt url: URL, expectedHex: String) throws -> Bool {
        let actual = try sha256Hex(ofFileAt: url)
        return actual.lowercased() == expectedHex.lowercased()
    }
}
