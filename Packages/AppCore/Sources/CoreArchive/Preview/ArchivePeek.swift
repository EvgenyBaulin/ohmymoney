import CoreKit
import Foundation

/// What a glance at an archive file can tell without a password and without reading it whole:
/// the preview of Finder (space bar) shows this, and nothing else.
///
/// An archive without a password starts with its manifest — the builder writes
/// `manifest.json` first, stored, sizes in the local header — so the first few kilobytes say
/// the day it was made, the version that made it and how many operations it carries. A file
/// with a password starts with the 48 bytes of `EncryptionHeader`, which hold only how the key
/// is made: nothing about the data can be read there, and the preview says «encrypted». The
/// format is not changed for the preview.
public enum ArchivePeek {
  /// How many bytes from the start of the file `read(prefix:)` needs at most: the local header
  /// of the manifest and the manifest itself. A manifest is a few kilobytes even with every
  /// table counted.
  public static let prefixByteCount = 256 * 1024

  public enum Result: Equatable, Sendable {
    /// A password protects the file: what is inside cannot be seen without it.
    case encrypted
    case plain(Facts)
    /// Not an archive this app writes, or the start of one that is damaged.
    case unreadable
  }

  /// What the manifest of an archive without a password says.
  public struct Facts: Equatable, Sendable {
    public let createdAt: DateOnly
    public let appVersion: String
    public let schemaVersion: Int
    /// Rows of the operations table; `nil` for a file that has no such table — an export of a
    /// report or a trip is an archive of a few tables, without operations.
    public let operations: Int?
    /// How many tables the file carries.
    public let tables: Int

    public init(
      createdAt: DateOnly, appVersion: String, schemaVersion: Int, operations: Int?, tables: Int
    ) {
      self.createdAt = createdAt
      self.appVersion = appVersion
      self.schemaVersion = schemaVersion
      self.operations = operations
      self.tables = tables
    }
  }

  /// The table whose rows are the operations, as the export names it.
  public static let operationsTable = "transactions"

  private static let localHeaderSignature: UInt32 = 0x0403_4B50
  private static let localHeaderSize = 30

  /// Reads the facts from the first bytes of a file (`prefixByteCount` of them, or the whole
  /// file when it is shorter).
  public static func read(prefix data: Data) -> Result {
    if EncryptionHeader.looksEncrypted(data) { return .encrypted }
    let bytes = [UInt8](data.prefix(prefixByteCount))
    guard bytes.count >= localHeaderSize, uint32(bytes, 0) == localHeaderSignature else {
      return .unreadable
    }
    let flags = uint16(bytes, 6)
    let method = uint16(bytes, 8)
    let size = Int(uint32(bytes, 18))
    let nameLength = Int(uint16(bytes, 26))
    let extraLength = Int(uint16(bytes, 28))
    // Bit 3: the sizes follow the data instead of the header. The app never writes it; a file
    // that does is not one of ours, and its size cannot be known from here.
    guard method == 0, flags & 0x0008 == 0 else { return .unreadable }
    let nameEnd = localHeaderSize + nameLength
    let dataStart = nameEnd + extraLength
    guard nameEnd <= bytes.count,
      String(decoding: bytes[localHeaderSize..<nameEnd], as: UTF8.self) == ArchivePaths.manifest,
      dataStart + size <= bytes.count
    else { return .unreadable }
    guard let manifest = try? ArchiveManifest.decode(Data(bytes[dataStart..<(dataStart + size)]))
    else { return .unreadable }
    return .plain(
      Facts(
        createdAt: manifest.createdAt, appVersion: manifest.appVersion,
        schemaVersion: manifest.schemaVersion,
        operations: manifest.rowCounts[operationsTable],
        tables: manifest.rowCounts.count))
  }

  private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }
}
