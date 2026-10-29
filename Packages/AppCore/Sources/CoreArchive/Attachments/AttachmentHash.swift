import Foundation

/// The name of a file in the folder of attachments: the SHA-256 of its content, as 64 lower-case
/// hex characters. The same content has the same name, so a file that is attached twice is kept
/// once.
public enum AttachmentHash {
  public static let hexLength = 64

  /// Whether `text` is a digest: exactly 64 hex digits, in either case.
  public static func isValid(_ text: String) -> Bool {
    text.utf8.count == hexLength && text.utf8.allSatisfy(isHexDigit)
  }

  /// The digest of bytes held in memory.
  public static func hexDigest(of data: Data) -> String {
    SHA256.hexDigest(data)
  }

  /// `aa/bb/<hash>`: two levels of 256 folders keep any one folder small however many files
  /// there are. `nil` for a text that is not a digest, so a path is never built from one.
  public static func relativePath(for hash: String) -> String? {
    guard isValid(hash) else { return nil }
    let lower = hash.lowercased()
    return "\(lower.prefix(2))/\(lower.dropFirst(2).prefix(2))/\(lower)"
  }

  /// The digest a relative path `aa/bb/<hash>` names, only if the folders match the digest.
  public static func hash(forRelativePath path: String) -> String? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, isValid(parts[2]) else { return nil }
    let hash = parts[2].lowercased()
    guard parts[0] == String(hash.prefix(2)), parts[1] == String(hash.dropFirst(2).prefix(2))
    else { return nil }
    return hash
  }

  /// A hasher for content that arrives in pieces, so a file of any size is hashed without
  /// being held in memory.
  public struct Stream: Sendable {
    private var sha = SHA256()
    public private(set) var byteCount: Int64 = 0

    public init() {}

    public mutating func update(_ data: Data) {
      sha.update(data)
      byteCount += Int64(data.count)
    }

    public mutating func finalize() -> String {
      SHA256.hexString(sha.finalize())
    }
  }

  private static func isHexDigit(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x30...0x39, 0x41...0x46, 0x61...0x66: true
    default: false
    }
  }
}
