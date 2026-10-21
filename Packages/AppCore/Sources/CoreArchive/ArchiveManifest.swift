import CoreKit
import Foundation

/// The paths a transfer archive is made of. They are part of the format: the future
/// Windows build and anyone opening the container by hand rely on them.
public enum ArchivePaths {
  public static let manifest = "manifest.json"
  public static let database = "data/database.sqlite"
  public static let settings = "settings.json"
  public static let csvDirectory = "data/csv/"

  /// `data/csv/transactions.csv` for the table `transactions`.
  public static func csv(table: String) -> String {
    "\(csvDirectory)\(table).csv"
  }

  /// The table name behind a `data/csv/…` path, or nil for anything else. A table is a name,
  /// never a path: one with a separator in it, or one of dots only, is no table, so a file of
  /// `data/csv/../x.csv` can never be taken for the table `../x` by whatever uses the name.
  public static func table(forCSVPath path: String) -> String? {
    guard path.hasPrefix(csvDirectory), path.hasSuffix(".csv") else { return nil }
    let start = path.index(path.startIndex, offsetBy: csvDirectory.count)
    let end = path.index(path.endIndex, offsetBy: -4)
    guard start < end else { return nil }
    let table = path[start..<end]
    guard !table.contains("/"), !table.contains("\\"), !table.allSatisfy({ $0 == "." }) else {
      return nil
    }
    return String(table)
  }
}

/// `manifest.json`: what the archive is, when it was written and what has to be inside it.
///
/// Field names are the format. They are spelled out here rather than derived, so renaming
/// a Swift property can never silently change the file an older build has to read.
public struct ArchiveManifest: Codable, Equatable, Sendable {
  /// Bumped when the layout of the container changes in a way older builds cannot read.
  public static let currentFormatVersion = 1

  /// Version of the archive layout, not of the application.
  public let formatVersion: Int
  /// Marketing version of the application that wrote the archive, for diagnostics.
  public let appVersion: String
  /// Version of the database schema inside `data/database.sqlite`.
  public let schemaVersion: Int
  /// The day the archive was written; the time of day is deliberately not recorded.
  public let createdAt: DateOnly
  /// Where it was written: "macOS", later "Windows". Supplied by the caller — the core
  /// never asks the operating system anything.
  public let platform: String
  /// Row count per table, checked on import against the CSV files in the container.
  public let rowCounts: [String: Int]
  /// Lower-case SHA-256 hex digest per path, for every file except `manifest.json`.
  public let checksums: [String: String]

  public init(
    formatVersion: Int = ArchiveManifest.currentFormatVersion,
    appVersion: String,
    schemaVersion: Int,
    createdAt: DateOnly,
    platform: String,
    rowCounts: [String: Int],
    checksums: [String: String]
  ) {
    self.formatVersion = formatVersion
    self.appVersion = appVersion
    self.schemaVersion = schemaVersion
    self.createdAt = createdAt
    self.platform = platform
    self.rowCounts = rowCounts
    self.checksums = checksums
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion
    case appVersion
    case schemaVersion
    case createdAt
    case platform
    case rowCounts
    case checksums
  }

  /// The fields as the format names them. The day is read as a string here and parsed, rather
  /// than left to `DateOnly`, so that a day that does not parse is named as this field.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    formatVersion = try container.decode(Int.self, forKey: .formatVersion)
    appVersion = try container.decode(String.self, forKey: .appVersion)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    guard let day = DateOnly(iso: try container.decode(String.self, forKey: .createdAt)) else {
      throw DecodingError.dataCorruptedError(
        forKey: .createdAt, in: container, debugDescription: "not a day in ISO 8601")
    }
    createdAt = day
    platform = try container.decode(String.self, forKey: .platform)
    rowCounts = try container.decode([String: Int].self, forKey: .rowCounts)
    checksums = try container.decode([String: String].self, forKey: .checksums)
  }

  /// Stable bytes: keys are sorted and slashes are not escaped, so two exports of the same
  /// data are byte-identical and the file stays readable in a text editor.
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  /// Throws `Unreadable` with the field that did not decode and why.
  public static func decode(_ data: Data) throws -> ArchiveManifest {
    do {
      return try JSONDecoder().decode(ArchiveManifest.self, from: data)
    } catch let error as DecodingError {
      throw Unreadable(error)
    } catch {
      throw Unreadable(field: Unreadable.wholeManifest, problem: .notJSON)
    }
  }
}

extension ArchiveManifest {
  /// Why `manifest.json` did not decode: which of its fields, and what was wrong with it. The
  /// owner reads «В архиве нет читаемого манифеста» either way; the journal gets the field, so
  /// an archive of another implementation — later, the Windows build — can be told what it got
  /// wrong. Only the names the format defines are given, never a value or a key of the file.
  public struct Unreadable: Error, Equatable, Sendable {
    public enum Problem: String, Equatable, Sendable {
      /// Not JSON, or not a JSON object.
      case notJSON
      /// The field is not there.
      case missing
      /// The field is `null`.
      case null
      /// The field holds another type, a string for a number for instance.
      case wrongType
      /// The field has the right type and a value that does not parse, a date for instance.
      case malformed
    }

    /// A top-level field of the manifest (`schemaVersion`, `rowCounts`, …), or `manifest` for
    /// the text as a whole.
    public let field: String
    public let problem: Problem

    public init(field: String, problem: Problem) {
      self.field = field
      self.problem = problem
    }

    /// The field named when the text as a whole is at fault.
    public static let wholeManifest = "manifest"

    init(_ error: DecodingError) {
      switch error {
      case .keyNotFound(let key, let context):
        self.init(field: Self.field(context.codingPath + [key]), problem: .missing)
      case .valueNotFound(_, let context):
        self.init(field: Self.field(context.codingPath), problem: .null)
      case .typeMismatch(_, let context):
        self.init(
          field: Self.field(context.codingPath),
          problem: context.codingPath.isEmpty ? .notJSON : .wrongType)
      case .dataCorrupted(let context):
        self.init(
          field: Self.field(context.codingPath),
          problem: context.codingPath.isEmpty ? .notJSON : .malformed)
      @unknown default:
        self.init(field: Self.wholeManifest, problem: .malformed)
      }
    }

    /// The top-level field a coding path starts at — one the format defines, or the manifest
    /// as a whole. A key deeper in (a table name of `rowCounts`) comes from the file and is
    /// never repeated.
    private static func field(_ path: [any CodingKey]) -> String {
      guard let first = path.first, CodingKeys(stringValue: first.stringValue) != nil else {
        return wholeManifest
      }
      return first.stringValue
    }
  }
}
