import Foundation
import CryptoKit

/// Lowercase hex SHA-256, as written into the backup manifests.
func sha256Hex<D: DataProtocol>(_ data: D) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
