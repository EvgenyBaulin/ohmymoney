import AppCore
import AppDatabase
import Foundation

/// Gathers a problem report from the application as it is running.
///
/// Everything it asks for is a count, a version, a date or a flag. Nothing it can reach is a
/// sum or a name, and `ProblemReport` has nowhere to put one if it were.
@MainActor
enum ProblemReportService {
  /// What a report reads from the database itself: the rows of every table, and the verdict
  /// of `PRAGMA integrity_check` — `nil` when there was nothing to check or the check threw.
  struct DatabaseReading: Sendable {
    var rowCounts: [String: Int] = [:]
    var integrityCheckPassed: Bool?
  }

  typealias DatabaseReader = @Sendable (DatabaseStack?, CSVExportService?) -> DatabaseReading

  /// Every table counted and the whole file checked: on a large database, seconds of work.
  nonisolated static func read(
    _ stack: DatabaseStack?, _ export: CSVExportService?
  )
    -> DatabaseReading
  {
    DatabaseReading(
      rowCounts: (try? export?.rowCounts()) ?? [:],
      // Not run is not failed: without a database there is nothing to check.
      integrityCheckPassed: stack.flatMap { try? $0.integrityCheckPassed() })
  }

  static func gather(
    environment: AppEnvironment, compute: ComputeStore, crashReport: URL? = nil,
    reading readDatabase: @escaping DatabaseReader = ProblemReportService.read
  ) async -> ProblemReport {
    let journals = ProblemReport.journals(Logbook.shared.files(), now: Date())
    let stack = environment.stack
    let bytes =
      stack.flatMap {
        (try? FileManager.default.attributesOfItem(atPath: $0.url.path)[.size]) as? Int
      } ?? 0
    // Off the main thread: the window that asked stays alive while the file is read.
    let export = environment.csvExport
    let reading = await Task.detached(priority: .userInitiated) {
      readDatabase(stack, export)
    }.value
    let ledger = compute.snapshot?.ledger
    return ProblemReport(
      appVersion: AppEnvironment.appVersion,
      buildVersion: AppEnvironment.buildVersion,
      systemVersion: AppEnvironment.systemVersion,
      distribution: AppEnvironment.distribution,
      language: environment.language.resolvedCode,
      schemaVersion: stack?.applied.onDisk ?? 0,
      databaseBytes: bytes,
      integrityCheckPassed: reading.integrityCheckPassed,
      rowCounts: reading.rowCounts,
      firstOperation: ledger?.firstDay?.iso,
      lastOperation: ledger?.rows.last?.day.iso,
      settings: settings(of: environment),
      lastRun: compute.lastRunDurations,
      standIns: Array(AppDependencies.missingReaders),
      lastSessionWasInterrupted: environment.lastSessionWasInterrupted,
      dependencies: dependencies(),
      journalFailure: Logbook.shared.openFailure,
      journals: journals,
      crashReport: crashReport)
  }

  /// Writes the report where the owner chose. Returns what to tell the owner when it could
  /// not be written, `nil` when it was: words from the catalog in the language of the
  /// interface, never the type of the error — that goes to the journal.
  static func save(_ report: ProblemReport, to url: URL, language: AppLanguage) -> String? {
    do {
      try report.zipped().write(to: url, options: .atomic)
      AppLog.info(
        "report.saved", .app, "a problem report was written",
        [LogPair("journals", .count(report.contents.journalFiles))])
      return nil
    } catch {
      AppLog.error(
        "report.failed", .app, "a problem report could not be written",
        [LogPair("error", .error(error)), LogPair("code", .count((error as NSError).code))])
      return language("report.saveFailed", table: "Settings")
    }
  }

  /// What the application is built on («версии зависимостей»).
  static func dependencies() -> [String: String] {
    var versions = ["grdb": StorageVersions.grdb, "sqlite": StorageVersions.sqlite]
    #if os(macOS)
      if let sparkle = UpdateService.sparkleVersion { versions["sparkle"] = sparkle }
    #endif
    return versions
  }

  /// The categories the application chose by itself and remembers by id.
  private static let categoryKeys = [
    AnalyticsSettings.cashbackCategoryKey,
    PlanningSettings.reconcileExpenseCategoryKey,
    PlanningSettings.reconcileIncomeCategoryKey,
    AccountSettings.transferFeeCategoryKey,
  ]

  /// Planning settings that are lists of ids of what they are about — reminders put off,
  /// operations said not to pay a due date, counts whose difference the owner called real,
  /// answers about a count remembered — and go in as a count only.
  private static let countedOnly: Set = [
    PlanningSettings.dismissedRemindersKey, PlanningSettings.scheduledMatchRejectionsKey,
    PlanningSettings.firstCountKeptKey, PlanningSettings.beforeCountAnswersKey,
  ]

  /// The settings of a report («настройки без личных данных: язык, валюты, пороги,
  /// флаги»): what the archive carries — language, theme, currencies — and the thresholds and
  /// switches the numbers are computed with, as the application uses them, defaults included.
  ///
  /// Every value added here is a number, a switch, a level, a currency code, a state or the id
  /// of a category. The captions of «для кого» are the owner's own words and stay out; the
  /// dismissed reminders, the operations said not to pay a due date, the counts whose
  /// difference was called real and the answers about a count remembered are ids of what they
  /// were about, and go in as a count.
  static func settings(of environment: AppEnvironment) -> [String: String] {
    var values = environment.portableSettings()
    guard let settings = environment.settings else { return values }
    func stored(_ key: String) -> String? { (try? settings.string(key)) ?? nil }

    values["events.automatic"] = environment.assignsEventAutomatically ? "1" : "0"
    var rows: [String: String] = [:]
    for key in PlanningSettings.storageKeys { rows[key] = stored(key) }
    let planning = PlanningSettings(storedValues: rows)
    for (key, value) in planning.storedValues where !countedOnly.contains(key) {
      values[key] = value
    }
    values["reminders.dismissed.count"] = String(planning.dismissedReminders.count)
    values["planning.scheduledMatchRejections.count"] = String(
      planning.scheduledMatchRejections.count)
    values["reconcile.firstCountKept.count"] = String(planning.firstCountKept.count)
    values["reconcile.beforeCountAnswers.count"] = String(planning.beforeCountAnswers.count)
    var accountRows: [String: String] = [:]
    for key in AccountSettings.storageKeys { accountRows[key] = stored(key) }
    let accounts = AccountSettings(storedValues: accountRows)
    values[AccountSettings.defaultCurrencyKey] = accounts.defaultCurrency.code
    if let setup = accounts.setup { values[AccountSettings.setupKey] = setup.rawValue }
    let sensitivity =
      stored(AnalyticsSettings.anomalySensitivityKey).flatMap(AnomalySensitivity.init(rawValue:))
      ?? .standard
    values[AnalyticsSettings.anomalySensitivityKey] = sensitivity.rawValue
    for key in categoryKeys {
      // Read back as an id, so nothing but an id can reach the file.
      if let id = stored(key).flatMap(UUID.init(uuidString:)) { values[key] = id.uuidString }
    }
    return values
  }
}
