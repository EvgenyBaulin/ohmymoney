import AppCore
import AppDatabase
import Foundation
import Observation

/// The weekly check of the live database, «Проверить сейчас» and «Исправить».
///
/// A check runs off the main thread and writes nothing. It is quiet: the scheduled one reports
/// only when it finds something wrong (a line of «Стоит посмотреть» and the settings), the one
/// asked for always says its result. What it found is kept on this Mac, with the day — never in
/// the database or the archive.
@MainActor
@Observable
final class IntegrityCheckService {
  /// What the last check found, and when.
  struct Record: Codable, Equatable, Sendable {
    var checkedAt: Date
    var report: DatabaseCheck.Report
  }

  enum Repair: Equatable {
    /// `removed` rows went, after the copy `copy`.
    case repaired(removed: Int)
    /// The copy before the repair was not written, so nothing was touched.
    case noCopy
    case failed
  }

  static let recordKey = "integrity.record"
  /// How many rows were wrong in the last check: what «Стоит посмотреть» reads.
  static let problemsKey = "integrity.problems"

  private(set) var record: Record?
  private(set) var isRunning = false
  private(set) var isRepairing = false

  private let stack: DatabaseStack
  private let backups: BackupService?
  private let defaults: UserDefaults?

  init(stack: DatabaseStack, backups: BackupService?, defaults: UserDefaults?) {
    self.stack = stack
    self.backups = backups
    self.defaults = defaults
    record = Self.stored(in: defaults)
  }

  /// The weekly check, when it is due.
  func runIfDue(now: Date = Date()) async {
    guard !isRunning, IntegritySchedule.isDue(lastCheck: record?.checkedAt, now: now) else {
      return
    }
    await check(now: now)
  }

  /// A check now, outside the schedule; the next scheduled one is a week after it.
  @discardableResult
  func check(now: Date = Date()) async -> DatabaseCheck.Report? {
    guard !isRunning else { return nil }
    isRunning = true
    defer { isRunning = false }
    AppLog.info("integrity.started", .db, "the database is being checked", [])
    let stack = self.stack
    do {
      let report = try await Task.detached(priority: .utility) {
        try stack.checkDatabase()
      }.value
      store(Record(checkedAt: now, report: report))
      AppLog.info(
        "integrity.done", .db, "the database was checked",
        [
          LogPair("problems", .count(report.problemCount)),
          LogPair("operations", .count(report.operations)),
        ])
      return report
    } catch {
      AppLog.error(
        "integrity.failed", .db, "the check of the database did not finish",
        [LogPair("error", .error(error))])
      return nil
    }
  }

  /// «Исправить»: a copy first, then the safe rows go in one write, then the database is
  /// checked again. Without the copy nothing is touched.
  func repair(now: Date = Date()) async -> Repair {
    guard !isRepairing, let backups else { return .failed }
    isRepairing = true
    defer { isRepairing = false }
    do {
      _ = try await backups.writeBackup(now: now, label: "before-repair")
    } catch {
      AppLog.error(
        "integrity.repairNoCopy", .db, "no copy could be kept before the repair",
        [LogPair("error", .error(error))])
      return .noCopy
    }
    let stack = self.stack
    do {
      let removed = try await Task.detached(priority: .utility) {
        try stack.repairDatabase()
      }.value
      AppLog.info(
        "integrity.repaired", .db, "orphan rows were removed",
        [LogPair("rows", .count(removed))])
      await check(now: now)
      return .repaired(removed: removed)
    } catch {
      AppLog.error(
        "integrity.repairFailed", .db, "the repair of the database did not finish",
        [LogPair("error", .error(error))])
      return .failed
    }
  }

  private func store(_ new: Record) {
    record = new
    guard let defaults else { return }
    if let data = try? JSONEncoder().encode(new) { defaults.set(data, forKey: Self.recordKey) }
    defaults.set(new.report.problemCount, forKey: Self.problemsKey)
  }

  static func stored(in defaults: UserDefaults?) -> Record? {
    guard let data = defaults?.data(forKey: recordKey) else { return nil }
    return try? JSONDecoder().decode(Record.self, from: data)
  }

  /// How many rows the last check found wrong; 0 when it found none or never ran.
  static func storedProblems(in defaults: UserDefaults?) -> Int {
    defaults?.integer(forKey: problemsKey) ?? 0
  }
}
