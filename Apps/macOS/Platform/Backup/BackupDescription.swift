import AppCore
import AppDatabase
import Foundation

/// The small file beside a copy that says what is in it — read without opening the copy.
/// `2026-10-06 23.32 · 1.12.0 · после правки.json` beside `….sqlite`: JSON, UTF-8, sorted keys,
/// dates as ISO 8601 in UTC, money in units of 1/10000 (`amountE4`), `formatVersion` 1.
/// Unlike the journal it may name accounts and hold amounts: it lies in the owner's folder
/// of copies and never leaves it by itself.
struct BackupDescription: Codable, Equatable, Sendable {
  struct Last: Codable, Equatable, Sendable {
    var occurredAt: Date
    var kind: String
    var amountE4: Int64
    var currency: String
    var note: String?
  }

  struct Balance: Codable, Equatable, Sendable {
    var account: String
    var currency: String
    var amountE4: Int64
  }

  var formatVersion = 1
  var takenAt: Date
  var appVersion: String
  /// `change`, `daily`, `beforeMigration`, `beforeRestore`, `beforeImport` or `beforeRepair`.
  var reason: String
  /// How the copy was checked after it was written: `quick` (`quick_check`) or `full`
  /// (`integrity_check`, the copy of the day). Absent in descriptions written by 1.12 before
  /// the check was recorded and in those worked out later for an old copy.
  var check: String?
  var operations: Int
  var lastOperation: Last?
  var balances: [Balance]

  init(snapshot: BackupSnapshot, takenAt: Date, appVersion: String, reason: BackupName.Reason) {
    self.takenAt = takenAt
    self.appVersion = appVersion
    self.reason = Self.token(reason)
    operations = snapshot.operations.count
    lastOperation = snapshot.lastOperation.map {
      Last(
        occurredAt: $0.occurredAt, kind: $0.kind, amountE4: $0.amountE4, currency: $0.currency,
        note: $0.note)
    }
    balances = snapshot.balances.map {
      Balance(account: $0.account, currency: $0.currency, amountE4: $0.amountE4)
    }
  }

  static func token(_ reason: BackupName.Reason) -> String {
    switch reason {
    case .change: "change"
    case .daily: "daily"
    case .beforeMigration: "beforeMigration"
    case .beforeRestore: "beforeRestore"
    case .beforeImport: "beforeImport"
    case .beforeRepair: "beforeRepair"
    }
  }

  /// Where the description of the copy at `copy` is: its name with `.json` for `.sqlite`.
  static func url(forCopyAt copy: URL) -> URL {
    copy.deletingPathExtension().appendingPathExtension("json")
  }

  /// The description kept beside a copy; nil when none is there or it cannot be read. The copy
  /// itself is never opened.
  static func read(forCopyAt copy: URL) -> BackupDescription? {
    guard let data = try? Data(contentsOf: url(forCopyAt: copy)) else { return nil }
    return try? decoder.decode(BackupDescription.self, from: data)
  }

  /// Works the description out of the copy (opened read-only) — written beside every new copy,
  /// and for an old one on demand — and keeps it beside the copy when `keeping`. Nil when the
  /// copy cannot be read; a copy without a description is no worse off for it.
  @discardableResult
  static func compute(
    forCopyAt copy: URL, reason: BackupName.Reason? = nil, appVersion: String? = nil,
    takenAt: Date? = nil, check: String? = nil, keeping: Bool = true
  ) -> BackupDescription? {
    guard let snapshot = try? BackupSnapshot.of(fileAt: copy) else { return nil }
    let parsed = BackupCopy.parse(copy.lastPathComponent)
    var description = BackupDescription(
      snapshot: snapshot, takenAt: takenAt ?? parsed?.moment ?? Date(),
      appVersion: appVersion ?? "", reason: reason ?? parsed?.reason ?? .change)
    description.check = check
    if keeping { write(description, forCopyAt: copy) }
    return description
  }

  /// Written beside a new copy, right after the copy takes its name.
  static func write(
    forCopyAt copy: URL, reason: BackupName.Reason, appVersion: String, takenAt: Date,
    check: String? = nil
  ) {
    compute(
      forCopyAt: copy, reason: reason, appVersion: appVersion, takenAt: takenAt, check: check)
  }

  private static func write(_ description: BackupDescription, forCopyAt copy: URL) {
    do {
      let data = try encoder.encode(description)
      try data.write(to: url(forCopyAt: copy), options: .atomic)
    } catch {
      AppLog.warning(
        "backup.descriptionFailed", .backup, "the description beside a copy was not written",
        [LogPair("error", .error(error))])
    }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
