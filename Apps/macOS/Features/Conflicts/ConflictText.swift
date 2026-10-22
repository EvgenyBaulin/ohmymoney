import AppCore
import AppDatabase
import Foundation

/// The words of the exchange and of the conflicts, from the table `Sync`.
@MainActor
enum ConflictText {
  static let table = "Sync"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func count(_ key: String, _ value: Int, _ environment: AppEnvironment) -> String {
    environment.language.format(key, table: table, counts: value)
  }

  /// The label of a row of the comparison. A column without a label of its own is «Другие
  /// данные», which is what the comparison makes of every such column together.
  static func label(_ column: String, _ environment: AppEnvironment) -> String {
    ConflictComparison.labelled.contains(column) || column == "other"
      ? t("sync.field.\(column)", environment) : t("sync.field.other", environment)
  }

  static func cell(_ cell: ConflictComparison.Cell, _ environment: AppEnvironment) -> String {
    switch cell {
    case .value(let text): text
    case .empty: "—"
    case .other: t("sync.conflicts.otherValue", environment)
    }
  }

  /// «Синхронизировано · 14:02», in the language of the interface.
  static func syncedLine(at date: Date, _ environment: AppEnvironment) -> String {
    let time = date.formatted(
      Date.FormatStyle(date: .omitted, time: .shortened).locale(environment.language.locale))
    return environment.language.format("sync.status.syncedAt", table: table, time)
  }

  static func statusDetail(_ status: SyncStatus, _ environment: AppEnvironment) -> String? {
    switch status {
    case .notConfigured: t("sync.status.notConfigured.detail", environment)
    case .running: nil
    case .synced(let date): syncedLine(at: date, environment)
    case .waiting(let changes): count("sync.status.waiting.detail", changes, environment)
    case .failed(let failure): t(failure.messageKey, environment)
    }
  }

  /// Lines under the status: the existing books that were sent for the first time, and a fresh
  /// copy of the whole database in the folder.
  static func outcomeLines(_ outcome: SyncOutcome?, _ environment: AppEnvironment) -> [String] {
    guard let outcome else { return [] }
    var lines: [String] = []
    if outcome.rowsSeeded > 0 {
      lines.append(count("sync.status.seeded", outcome.rowsSeeded, environment))
    }
    if outcome.snapshotWritten { lines.append(t("sync.status.snapshot", environment)) }
    return lines
  }

  /// «Копия от 21 октября 2026 г., 14:02 · устройство a1b2c3d4».
  static func offerLine(_ offer: SyncSnapshotOffer, _ environment: AppEnvironment) -> String {
    let date = offer.madeAt.formatted(
      Date.FormatStyle(date: .long, time: .shortened).locale(environment.language.locale))
    return environment.language.format(
      "sync.bootstrap.offer", table: table, date, offer.deviceLabel)
  }
}
