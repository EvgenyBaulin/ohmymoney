import CoreKit
import Foundation

/// Reads the zip containers `ZipWriter` produces, and any other plain zip whose entries
/// are stored without compression.
///
/// The central directory is the source of truth, exactly as the specification asks: the
/// reader walks it and then visits each local header to find the payload. Every entry is
/// verified against its CRC-32 before it is handed back, so a container that survived the
/// structural checks still cannot deliver a silently damaged file.
public enum ZipReader {
  public struct Entry: Equatable, Sendable {
    public let path: String
    public let data: Data
    public let checksum: UInt32

    public init(path: String, data: Data, checksum: UInt32) {
      self.path = path
      self.data = data
      self.checksum = checksum
    }
  }

  private static let localHeaderSignature: UInt32 = 0x0403_4B50
  private static let centralHeaderSignature: UInt32 = 0x0201_4B50
  private static let endOfDirectorySignature: UInt32 = 0x0605_4B50
  private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
  private static let zip64LocatorSize = 20
  /// What a zip64 container puts in a classic field whose value lives in a zip64 record
  /// (APPNOTE 4.4.1.4). No classic container of ours can hold it: `ZipWriter` refuses 4 GiB.
  private static let zip64Marker = UInt32.max
  private static let endOfDirectorySize = 22
  private static let centralHeaderSize = 46
  private static let localHeaderSize = 30
  /// The end record may be followed by a comment of at most 64 KiB.
  private static let maximumCommentSize = Int(UInt16.max)

  /// Entries in central-directory order, which is the order they were written in.
  public static func entries(in data: Data) throws -> [Entry] {
    let bytes = [UInt8](data)
    guard bytes.count >= endOfDirectorySize else {
      throw CoreError.invalidArchive(reason: .notAZipContainer)
    }
    let endOffset = try locateEndOfDirectory(bytes)

    // A zip64 container from another writer is a format this reader does not follow, like a
    // compressed one — not a damaged file. Its counts and offsets are elsewhere, so reading on
    // would only end in «truncated».
    let hasZip64Locator =
      endOffset >= zip64LocatorSize
      && uint32(bytes, endOffset - zip64LocatorSize) == zip64LocatorSignature
    let classicFieldsHeldElsewhere =
      uint16(bytes, endOffset + 10) == UInt16.max || uint16(bytes, endOffset + 8) == UInt16.max
    guard uint32(bytes, endOffset + 12) != zip64Marker,
      uint32(bytes, endOffset + 16) != zip64Marker,
      !(hasZip64Locator && classicFieldsHeldElsewhere)
    else { throw CoreError.invalidArchive(reason: .unsupportedFormatVersion) }

    let entryCount = Int(uint16(bytes, endOffset + 10))
    let directorySize = Int(uint32(bytes, endOffset + 12))
    let directoryOffset = Int(uint32(bytes, endOffset + 16))
    guard directoryOffset >= 0, directorySize >= 0,
      directoryOffset + directorySize <= bytes.count,
      directoryOffset + directorySize <= endOffset
    else { throw CoreError.invalidArchive(reason: .truncated) }

    var found: [Entry] = []
    found.reserveCapacity(entryCount)
    var cursor = directoryOffset
    for _ in 0..<entryCount {
      guard cursor + centralHeaderSize <= directoryOffset + directorySize else {
        throw CoreError.invalidArchive(reason: .truncated)
      }
      guard uint32(bytes, cursor) == centralHeaderSignature else {
        throw CoreError.invalidArchive(reason: .notAZipContainer)
      }
      let flags = uint16(bytes, cursor + 8)
      let method = uint16(bytes, cursor + 10)
      let checksum = uint32(bytes, cursor + 16)
      let storedSize = Int(uint32(bytes, cursor + 20))
      let nameLength = Int(uint16(bytes, cursor + 28))
      let extraLength = Int(uint16(bytes, cursor + 30))
      let commentLength = Int(uint16(bytes, cursor + 32))
      let localOffset = Int(uint32(bytes, cursor + 42))
      let headerEnd = cursor + centralHeaderSize + nameLength + extraLength + commentLength
      guard headerEnd <= directoryOffset + directorySize else {
        throw CoreError.invalidArchive(reason: .truncated)
      }
      // Bit 0 marks the legacy per-entry encryption, which this format never uses. Sizes or an
      // offset of -1 live in the entry's zip64 extra field, which this reader does not follow.
      guard flags & 0x0001 == 0, method == 0,
        uint32(bytes, cursor + 20) != zip64Marker, uint32(bytes, cursor + 24) != zip64Marker,
        uint32(bytes, cursor + 42) != zip64Marker
      else {
        throw CoreError.invalidArchive(reason: .unsupportedFormatVersion)
      }

      let nameStart = cursor + centralHeaderSize
      let nameBytes = bytes[nameStart..<(nameStart + nameLength)]
      let path = String(decoding: nameBytes, as: UTF8.self)
      cursor = headerEnd

      // Directory markers carry no payload; the archive format stores files only.
      if path.hasSuffix("/") && storedSize == 0 { continue }

      guard localOffset >= 0, localOffset + localHeaderSize <= bytes.count else {
        throw CoreError.invalidArchive(reason: .truncated)
      }
      guard uint32(bytes, localOffset) == localHeaderSignature else {
        throw CoreError.invalidArchive(reason: .notAZipContainer)
      }
      let localNameLength = Int(uint16(bytes, localOffset + 26))
      let localExtraLength = Int(uint16(bytes, localOffset + 28))
      let payloadStart = localOffset + localHeaderSize + localNameLength + localExtraLength
      guard payloadStart >= 0, storedSize >= 0, payloadStart + storedSize <= bytes.count else {
        throw CoreError.invalidArchive(reason: .truncated)
      }
      let payload = Data(bytes[payloadStart..<(payloadStart + storedSize)])
      guard CRC32.checksum(payload) == checksum else {
        throw CoreError.invalidArchive(reason: .checksumMismatch)
      }
      found.append(Entry(path: path, data: payload, checksum: checksum))
    }
    return found
  }

  /// Every entry as a lookup table. A path repeated inside one container is a malformed
  /// archive, not a merge: it is rejected rather than silently resolved.
  public static func files(in data: Data) throws -> [String: Data] {
    var files: [String: Data] = [:]
    for entry in try entries(in: data) {
      guard files.updateValue(entry.data, forKey: entry.path) == nil else {
        throw CoreError.invalidArchive(reason: .notAZipContainer)
      }
    }
    return files
  }

  /// Scans backwards for the end-of-central-directory record, which is the only structure
  /// a zip can be found by: it sits at the tail, after an optional comment.
  private static func locateEndOfDirectory(_ bytes: [UInt8]) throws -> Int {
    let lowest = max(0, bytes.count - endOfDirectorySize - maximumCommentSize)
    var offset = bytes.count - endOfDirectorySize
    while offset >= lowest {
      if uint32(bytes, offset) == endOfDirectorySignature {
        let commentLength = Int(uint16(bytes, offset + 20))
        if offset + endOfDirectorySize + commentLength == bytes.count { return offset }
      }
      offset -= 1
    }
    // A container that starts like a zip but has lost its tail was cut short; anything
    // else was never a zip to begin with.
    if bytes.count >= 4, uint32(bytes, 0) == localHeaderSignature {
      throw CoreError.invalidArchive(reason: .truncated)
    }
    throw CoreError.invalidArchive(reason: .notAZipContainer)
  }

  private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }
}
