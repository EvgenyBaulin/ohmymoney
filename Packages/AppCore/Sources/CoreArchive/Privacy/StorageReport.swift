import Foundation

/// A size shaped for a sentence: «12.3» and the token of the unit. Decimal units (1 MB =
/// 1 000 000 bytes), as the Finder shows them; the point is always a point (the interface puts
/// its own separator).
public struct StorageSize: Hashable, Sendable {
  public enum Unit: String, Hashable, Sendable, CaseIterable {
    case bytes = "privacy.storage.unit.bytes"
    case kilobytes = "privacy.storage.unit.kb"
    case megabytes = "privacy.storage.unit.mb"
    case gigabytes = "privacy.storage.unit.gb"
  }

  public var unit: Unit
  /// Whole units.
  public var whole: Int64
  /// One decimal digit, 0…9; always 0 for bytes.
  public var tenth: Int

  public init(bytes: Int64) {
    let value = max(0, bytes)
    let steps: [(Unit, Int64)] = [
      (.gigabytes, 1_000_000_000), (.megabytes, 1_000_000), (.kilobytes, 1_000),
    ]
    for (unit, size) in steps where value >= size {
      self.unit = unit
      self.whole = value / size
      self.tenth = Int((value % size) * 10 / size)
      return
    }
    self.unit = .bytes
    self.whole = value
    self.tenth = 0
  }

  /// «12.3», or «512» for bytes.
  public var number: String {
    unit == .bytes ? String(whole) : "\(whole).\(tenth)"
  }
}

/// Plain numbers the app reads from the database and the disk for «Что знает приложение».
public struct StorageFacts: Hashable, Sendable {
  /// Rows by table name.
  public var tableRows: [String: Int]
  public var databaseBytes: Int64
  public var attachmentCount: Int
  public var attachmentBytes: Int64
  public var backupCount: Int
  public var backupBytes: Int64
  public var journalCount: Int
  public var journalBytes: Int64

  public init(
    tableRows: [String: Int] = [:], databaseBytes: Int64 = 0, attachmentCount: Int = 0,
    attachmentBytes: Int64 = 0, backupCount: Int = 0, backupBytes: Int64 = 0,
    journalCount: Int = 0, journalBytes: Int64 = 0
  ) {
    self.tableRows = tableRows
    self.databaseBytes = databaseBytes
    self.attachmentCount = attachmentCount
    self.attachmentBytes = attachmentBytes
    self.backupCount = backupCount
    self.backupBytes = backupBytes
    self.journalCount = journalCount
    self.journalBytes = journalBytes
  }
}

/// What the app knows and keeps: records, the database, attachments, backups and the journal,
/// as lines the interface fills into sentences by key. Nothing here is a name or an amount of
/// the owner's — only counts and sizes.
public struct StorageReport: Hashable, Sendable {
  public enum Section: String, Hashable, Sendable, CaseIterable {
    case records = "privacy.storage.records"
    case database = "privacy.storage.database"
    case attachments = "privacy.storage.attachments"
    case backups = "privacy.storage.backups"
    case journal = "privacy.storage.journal"
  }

  /// One line of the report. `key` is the string-catalog key; `count` and `size` are the
  /// arguments (`nil` when the line has no such number).
  public struct Line: Hashable, Sendable {
    public var section: Section
    public var count: Int?
    public var size: StorageSize?
    public var bytes: Int64
    public var key: String { section.rawValue }
  }

  public struct Table: Hashable, Sendable {
    public var name: String
    public var rows: Int
  }

  /// One line per section, in the order of `Section.allCases`.
  public let lines: [Line]
  /// Tables with rows, the biggest first, equal counts by name.
  public let tables: [Table]
  public let totalRecords: Int
  public let totalBytes: Int64

  public static let totalKey = "privacy.storage.total"

  public init(_ facts: StorageFacts) {
    let rows = facts.tableRows.filter { $0.value > 0 }
    self.tables = rows.map { Table(name: $0.key, rows: $0.value) }
      .sorted { ($1.rows, $0.name) < ($0.rows, $1.name) }
    self.totalRecords = rows.values.reduce(0, +)
    let database = max(0, facts.databaseBytes)
    let attachments = max(0, facts.attachmentBytes)
    let backups = max(0, facts.backupBytes)
    let journal = max(0, facts.journalBytes)
    self.lines = [
      Line(
        section: .records, count: totalRecords, size: nil, bytes: 0),
      Line(
        section: .database, count: nil, size: StorageSize(bytes: database), bytes: database),
      Line(
        section: .attachments, count: max(0, facts.attachmentCount),
        size: StorageSize(bytes: attachments), bytes: attachments),
      Line(
        section: .backups, count: max(0, facts.backupCount), size: StorageSize(bytes: backups),
        bytes: backups),
      Line(
        section: .journal, count: max(0, facts.journalCount), size: StorageSize(bytes: journal),
        bytes: journal),
    ]
    self.totalBytes = database + attachments + backups + journal
  }

  public var totalSize: StorageSize { StorageSize(bytes: totalBytes) }

  public func line(_ section: Section) -> Line {
    lines.first { $0.section == section }!
  }
}
