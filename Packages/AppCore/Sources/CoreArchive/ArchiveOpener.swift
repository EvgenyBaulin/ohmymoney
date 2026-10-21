import CoreKit
import Foundation

/// Opens a transfer archive and refuses everything that is not exactly what it claims to
/// be: unknown format version, wrong password, damaged container, digest that does not
/// match, row count that does not match.
///
/// A schema older than the running application is fine — the migration happens outside,
/// on the extracted database. A newer schema is refused: the application cannot invent
/// tables it does not know about yet.
public enum ArchiveOpener {
  public struct OpenedArchive: Equatable, Sendable {
    public let manifest: ArchiveManifest
    /// Every entry except `manifest.json`, keyed by its path inside the container.
    public let files: [String: Data]

    public init(manifest: ArchiveManifest, files: [String: Data]) {
      self.manifest = manifest
      self.files = files
    }

    public var database: Data? { files[ArchivePaths.database] }
    public var settings: Data? { files[ArchivePaths.settings] }

    public func csv(table: String) -> Data? { files[ArchivePaths.csv(table: table)] }

    public var csvTables: [String] {
      files.keys.compactMap(ArchivePaths.table(forCSVPath:)).sorted()
    }
  }

  /// True when the file starts with the encrypted-archive magic, so the application knows
  /// to ask for a password before it does anything else.
  public static func isEncrypted(_ data: Data) -> Bool {
    EncryptionHeader.looksEncrypted(data)
  }

  /// Opens a container that is not encrypted.
  ///
  /// - Parameter supportedSchemaVersion: the newest schema this build understands.
  public static func open(_ data: Data, supportedSchemaVersion: Int) throws -> OpenedArchive {
    guard !isEncrypted(data) else {
      // The file is fine, the password is simply not there yet: the caller asks for one
      // and comes back through the other entry point.
      throw CoreError.invalidArchive(reason: .wrongPassword)
    }
    return try verify(container: data, supportedSchemaVersion: supportedSchemaVersion)
  }

  /// Opens an encrypted container. A password that does not match, and a file somebody
  /// edited after it was written, both end as `.wrongPassword`: the authentication tag
  /// cannot tell them apart and neither can we.
  public static func open(
    _ data: Data, password: String, cipher: ArchiveCipher, supportedSchemaVersion: Int
  ) throws -> OpenedArchive {
    let payload = try EncryptionHeader.open(
      container: data, password: password, cipher: cipher)
    return try verify(container: payload, supportedSchemaVersion: supportedSchemaVersion)
  }

  /// Checks a plain zip payload against its own manifest.
  private static func verify(
    container: Data, supportedSchemaVersion: Int
  ) throws -> OpenedArchive {
    var files = try ZipReader.files(in: container)
    guard let manifestData = files.removeValue(forKey: ArchivePaths.manifest) else {
      throw CoreError.invalidArchive(reason: .manifestMissing)
    }
    let manifest = try ArchiveManifest.decode(manifestData)

    guard manifest.formatVersion >= 1 else {
      throw CoreError.invalidArchive(reason: .manifestUnreadable)
    }
    guard manifest.formatVersion <= ArchiveManifest.currentFormatVersion else {
      throw CoreError.invalidArchive(reason: .unsupportedFormatVersion)
    }
    guard manifest.schemaVersion <= supportedSchemaVersion else {
      throw CoreError.unsupportedSchemaVersion(
        found: manifest.schemaVersion, supported: supportedSchemaVersion)
    }

    try verifyChecksums(manifest: manifest, files: files)
    try verifyRowCounts(manifest: manifest, files: files)
    return OpenedArchive(manifest: manifest, files: files)
  }

  /// Every file must be listed, and every listed file must be there with the right digest.
  /// An entry nobody vouched for is as suspicious as one that changed.
  public static func verifyChecksums(
    manifest: ArchiveManifest, files: [String: Data]
  ) throws {
    guard manifest.checksums.count == files.count else {
      throw CoreError.invalidArchive(reason: .checksumMismatch)
    }
    for (path, expected) in manifest.checksums {
      guard let data = files[path] else {
        throw CoreError.invalidArchive(reason: .checksumMismatch)
      }
      guard SHA256.hexDigest(data) == expected.lowercased() else {
        throw CoreError.invalidArchive(reason: .checksumMismatch)
      }
    }
  }

  /// Compares the row counts in the manifest with the CSV files that are actually there.
  /// A counted table without a CSV file in the container is not checked, here or anywhere
  /// else: its rows live only in the database snapshot, which its SHA-256 digest vouches for
  /// as a whole, and nothing counts them against the manifest. This app counts only the
  /// tables it writes as CSV, so for its own archives every count is checked.
  public static func verifyRowCounts(
    manifest: ArchiveManifest, files: [String: Data]
  ) throws {
    for (table, expected) in manifest.rowCounts {
      guard let csv = files[ArchivePaths.csv(table: table)] else { continue }
      guard expected >= 0, countCSVRows(csv) == expected else {
        throw CoreError.invalidArchive(reason: .rowCountMismatch)
      }
    }
  }

  /// Counts data rows in an RFC 4180 file: records separated by line breaks, with breaks
  /// inside quoted fields not counting, minus the header row. A trailing line break does
  /// not open a record of its own, and neither does a blank line — nothing between two breaks,
  /// not even quotes — which the CSV reader and `pandas.read_csv` skip as well: a file an
  /// editor or another implementation ended with an empty line counts the rows anyone reads
  /// from it. The CSV export counts its records by it too, so its journal and a manifest count
  /// the same way. A UTF-8 byte-order mark at the very start is skipped, as the reader skips it:
  /// Numbers, Excel and many editors begin a file with one.
  public static func countCSVRows(_ data: Data) -> Int {
    var records = 0
    var quoted = false
    var sawContent = false
    var previousWasCarriageReturn = false
    let mark: [UInt8] = [0xEF, 0xBB, 0xBF]
    let start =
      data.starts(with: mark)
      ? data.index(data.startIndex, offsetBy: mark.count) : data.startIndex
    for byte in data[start...] {
      if quoted {
        if byte == 0x22 { quoted = false }
        sawContent = true
        previousWasCarriageReturn = false
        continue
      }
      switch byte {
      case 0x22:  // quotation mark opens a field that may contain line breaks
        quoted = true
        sawContent = true
        previousWasCarriageReturn = false
      case 0x0D:
        if sawContent { records += 1 }
        sawContent = false
        previousWasCarriageReturn = true
      case 0x0A:
        if previousWasCarriageReturn {
          previousWasCarriageReturn = false  // the line feed of a CRLF pair
        } else {
          if sawContent { records += 1 }
          sawContent = false
        }
      default:
        sawContent = true
        previousWasCarriageReturn = false
      }
    }
    if sawContent { records += 1 }  // last record without a trailing break
    return max(0, records - 1)  // the header is not data
  }
}
