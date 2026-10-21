import CoreKit
import Foundation

/// Problems that can only happen while writing a container. Reading reports through
/// `CoreError.invalidArchive`; writing has its own reasons, none of which a valid archive
/// can ever reach.
public enum ZipWriterError: Error, Equatable, Sendable {
  /// A single entry does not fit in the 32-bit size fields of a plain zip.
  case entryTooLarge(path: String)
  /// The finished container would cross the 4 GiB line where zip64 becomes mandatory.
  case containerTooLarge
  /// More entries than the 16-bit counter of the end-of-central-directory record holds.
  case tooManyEntries
  case duplicatePath(String)
  case invalidPath(String)

  /// English one-liner for logs. It names archive-internal paths only, never user data.
  public var message: String {
    switch self {
    case .entryTooLarge(let path):
      return "Entry \(path) is larger than 4 GiB, which plain zip cannot address"
    case .containerTooLarge:
      return "The archive would be larger than 4 GiB, which plain zip cannot address"
    case .tooManyEntries:
      return "The archive would hold more than 65535 entries"
    case .duplicatePath(let path):
      return "Entry \(path) was added twice"
    case .invalidPath(let path):
      return "Entry path \(path) is not usable inside a zip container"
    }
  }
}

/// Writes a zip container with the "stored" method only: no compression, no zip64, no
/// encryption of individual entries. The database snapshot and the CSV files are already
/// the bulk of an archive and the whole file is optionally sealed as one blob, so entry
/// compression would only buy complexity.
///
/// The output is deterministic: entries appear in the order they were added, timestamps
/// come from `modified` (default 1980-01-01, the start of the DOS epoch) and no extra
/// fields are written. The same input always produces the same bytes.
public struct ZipWriter: Sendable {
  /// Plain zip addresses offsets and sizes with 32 bits.
  public static let maximumContainerSize = Int(UInt32.max)
  public static let maximumEntryCount = Int(UInt16.max)

  private struct PendingEntry {
    let path: String
    let name: [UInt8]
    let data: Data
    let checksum: UInt32
  }

  private var entries: [PendingEntry] = []
  private var paths: Set<String> = []
  private let dosDate: UInt16
  private let dosTime: UInt16

  /// - Parameter modified: the calendar day stamped on every entry. Zip inherits the DOS
  ///   epoch, so days before 1980-01-01 are clamped to it. The time of day is always
  ///   midnight: an archive must not become a record of when its owner was at the machine.
  public init(modified: DateOnly = DateOnly(year: 1980, month: 1, day: 1)) {
    let year = max(modified.year, 1980)
    let month = min(max(modified.month, 1), 12)
    let day = min(max(modified.day, 1), 31)
    self.dosDate =
      UInt16(truncatingIfNeeded: ((year - 1980) << 9) | (month << 5) | day)
    self.dosTime = 0
  }

  public var count: Int { entries.count }
  public var addedPaths: [String] { entries.map(\.path) }

  public mutating func add(path: String, data: Data) throws {
    let name = [UInt8](path.utf8)
    guard !path.isEmpty, name.count <= Int(UInt16.max), !path.hasPrefix("/"),
      !path.hasSuffix("/"), !path.contains("\\"), !name.contains(0),
      !path.split(separator: "/").contains("..")
    else { throw ZipWriterError.invalidPath(path) }
    guard !paths.contains(path) else { throw ZipWriterError.duplicatePath(path) }
    guard data.count <= ZipWriter.maximumContainerSize else {
      throw ZipWriterError.entryTooLarge(path: path)
    }
    guard entries.count < ZipWriter.maximumEntryCount else {
      throw ZipWriterError.tooManyEntries
    }
    paths.insert(path)
    entries.append(
      PendingEntry(path: path, name: name, data: data, checksum: CRC32.checksum(data)))
  }

  public mutating func add(path: String, text: String) throws {
    try add(path: path, data: Data(text.utf8))
  }

  /// Serialises the container: local headers and payloads first, then the central
  /// directory, then the end-of-central-directory record.
  public func finish() throws -> Data {
    var output = Data()
    var directory = Data()

    for entry in entries {
      let localOffset = output.count
      guard localOffset <= ZipWriter.maximumContainerSize else {
        throw ZipWriterError.containerTooLarge
      }
      let size = UInt32(entry.data.count)

      output.appendLittleEndian(UInt32(0x0403_4B50))  // local file header signature
      output.appendLittleEndian(UInt16(20))  // version needed to extract: 2.0
      output.appendLittleEndian(ZipWriter.generalPurposeFlags)
      output.appendLittleEndian(UInt16(0))  // method 0: stored
      output.appendLittleEndian(dosTime)
      output.appendLittleEndian(dosDate)
      output.appendLittleEndian(entry.checksum)
      output.appendLittleEndian(size)  // compressed size
      output.appendLittleEndian(size)  // uncompressed size
      output.appendLittleEndian(UInt16(entry.name.count))
      output.appendLittleEndian(UInt16(0))  // no extra field
      output.append(contentsOf: entry.name)
      output.append(entry.data)

      directory.appendLittleEndian(UInt32(0x0201_4B50))  // central file header signature
      directory.appendLittleEndian(ZipWriter.versionMadeBy)
      directory.appendLittleEndian(UInt16(20))  // version needed to extract: 2.0
      directory.appendLittleEndian(ZipWriter.generalPurposeFlags)
      directory.appendLittleEndian(UInt16(0))  // method 0: stored
      directory.appendLittleEndian(dosTime)
      directory.appendLittleEndian(dosDate)
      directory.appendLittleEndian(entry.checksum)
      directory.appendLittleEndian(size)
      directory.appendLittleEndian(size)
      directory.appendLittleEndian(UInt16(entry.name.count))
      directory.appendLittleEndian(UInt16(0))  // no extra field
      directory.appendLittleEndian(UInt16(0))  // no comment
      directory.appendLittleEndian(UInt16(0))  // disk number start
      directory.appendLittleEndian(UInt16(0))  // internal attributes
      directory.appendLittleEndian(ZipWriter.externalAttributes)
      directory.appendLittleEndian(UInt32(localOffset))
      directory.append(contentsOf: entry.name)
    }

    let directoryOffset = output.count
    guard directoryOffset <= ZipWriter.maximumContainerSize,
      directoryOffset + directory.count + 22 <= ZipWriter.maximumContainerSize
    else { throw ZipWriterError.containerTooLarge }

    output.append(directory)
    output.appendLittleEndian(UInt32(0x0605_4B50))  // end of central directory signature
    output.appendLittleEndian(UInt16(0))  // this disk
    output.appendLittleEndian(UInt16(0))  // disk holding the central directory
    output.appendLittleEndian(UInt16(entries.count))
    output.appendLittleEndian(UInt16(entries.count))
    output.appendLittleEndian(UInt32(directory.count))
    output.appendLittleEndian(UInt32(directoryOffset))
    output.appendLittleEndian(UInt16(0))  // no archive comment
    return output
  }

  /// Bit 11 declares the entry name to be UTF-8, which is the only spelling written here.
  private static let generalPurposeFlags = UInt16(0x0800)
  /// Upper byte 3 = UNIX, lower byte 20 = version 2.0 of the specification.
  private static let versionMadeBy = UInt16(0x0314)
  /// UNIX mode 0o100644 in the upper 16 bits: a regular, owner-writable file.
  private static let externalAttributes = UInt32(0x81A4_0000)
}

extension Data {
  fileprivate mutating func appendLittleEndian(_ value: UInt16) {
    append(UInt8(truncatingIfNeeded: value))
    append(UInt8(truncatingIfNeeded: value >> 8))
  }

  fileprivate mutating func appendLittleEndian(_ value: UInt32) {
    append(UInt8(truncatingIfNeeded: value))
    append(UInt8(truncatingIfNeeded: value >> 8))
    append(UInt8(truncatingIfNeeded: value >> 16))
    append(UInt8(truncatingIfNeeded: value >> 24))
  }
}
