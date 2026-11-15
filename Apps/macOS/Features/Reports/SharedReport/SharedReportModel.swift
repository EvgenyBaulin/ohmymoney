import AppCore
import Foundation
import Observation

/// The choices of «Отчёт для другого человека…»: the span, the accounts and the categories that go
/// in, whether descriptions and places go, the format and the lock. Nothing here touches the
/// data: the report is made from the snapshot the screens read, and the original never changes.
@Observable
@MainActor
final class SharedReportModel {
  enum Format: String, CaseIterable, Hashable, Sendable {
    case pdf
    case csv
  }

  enum Stage: Equatable {
    case editing
    case working
    case failed
  }

  /// One account or category the owner can tick.
  struct Choice: Identifiable, Hashable {
    let id: UUID
    let name: String
    /// A hidden account: listed only after «Показать скрытые», with the warning.
    var hidden = false
  }

  let dataset: Dataset
  let today: DateOnly
  let calendar: CalendarContext

  var periodStart: Date
  var periodEnd: Date
  var accounts: Set<UUID>
  var categories: Set<UUID>
  var showsNotes = true
  var showsPlaces = true
  var showsHidden = false
  var format: Format = .pdf
  var lock = EncryptedExportForm()
  var stage: Stage = .editing

  let accountChoices: [Choice]
  let spendingChoices: [Choice]
  let incomeChoices: [Choice]

  /// The previous calendar month, every visible account and every top category: the report
  /// most people are asked for, ready to narrow.
  init(dataset: Dataset, today: DateOnly, calendar: CalendarContext) {
    self.dataset = dataset
    self.today = today
    self.calendar = calendar
    let month = today.monthKey.previous
    periodStart = calendar.noon(of: month.firstDay)
    periodEnd = calendar.noon(
      of: DateOnly(year: month.year, month: month.month, day: calendar.daysInMonth(month)))
    accountChoices = dataset.paymentMethods
      .filter { !$0.archived }
      .sorted { ($0.hidden ? 1 : 0, $0.sort, $0.name) < ($1.hidden ? 1 : 0, $1.sort, $1.name) }
      .map { Choice(id: $0.id, name: $0.name, hidden: $0.hidden) }
    func tops(_ kind: CategoryKind) -> [Choice] {
      dataset.categories
        .filter { $0.kind == kind && $0.parentId == nil && !$0.archived }
        .sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
        .map { Choice(id: $0.id, name: $0.name) }
    }
    spendingChoices = tops(.expense)
    incomeChoices = tops(.income)
    accounts = Set(accountChoices.filter { !$0.hidden }.map(\.id))
    categories = Set((spendingChoices + incomeChoices).map(\.id))
  }

  /// The accounts the list shows: the hidden ones only when asked.
  var visibleAccounts: [Choice] {
    accountChoices.filter { showsHidden || !$0.hidden }
  }

  var hasHiddenAccounts: Bool { accountChoices.contains(where: \.hidden) }

  /// A hidden account is ticked: the file will carry it, and the owner is told.
  var warnsAboutHidden: Bool {
    accountChoices.contains { $0.hidden && accounts.contains($0.id) }
  }

  var range: DayRange {
    DayRange(calendar.day(of: periodStart), calendar.day(of: periodEnd))
  }

  var request: SharedReport.Request {
    // A hidden account the list does not show does not go, even if it was ticked before.
    let shown = Set(visibleAccounts.map(\.id))
    return SharedReport.Request(
      range: range, accountIds: accounts.intersection(shown), categoryIds: categories,
      showsNotes: showsNotes, showsPlaces: showsPlaces)
  }

  var report: SharedReport {
    SharedReport.make(request, dataset: dataset, preparedOn: today)
  }

  var periodIsEmpty: Bool { range.isEmpty }

  var canSave: Bool {
    stage != .working && !periodIsEmpty && !request.accountIds.isEmpty
      && !categories.isEmpty && lock.answer != nil
  }

  func toggle(account id: UUID) {
    if accounts.contains(id) { accounts.remove(id) } else { accounts.insert(id) }
  }

  func toggle(category id: UUID) {
    if categories.contains(id) { categories.remove(id) } else { categories.insert(id) }
  }

  /// «OhMyMoney — 2026-10-01…2026-10-31.pdf»: the app and the span, nothing of the data.
  func fileName(locked: Bool) -> String {
    let stem = "OhMyMoney \(range.start.iso)…\(range.end.iso)"
    switch (format, locked) {
    case (.csv, true): return EncryptedExport.fileName(stem)
    case (.csv, false): return stem + ".csv"
    case (.pdf, _): return stem + ".pdf"
    }
  }

  /// The file of the report in a fresh temporary folder, ready to be moved where the owner
  /// says: a PDF (locked with the password when asked), a CSV, or a CSV inside the app's locked
  /// file. The password is forgotten once the file is written.
  func write(
    words: SharedReportWords, appVersion: String, schemaVersion: Int
  ) throws -> URL {
    guard let answer = lock.answer else { throw EncryptedExport.Failure.passwordMissing }
    let report = report
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("shared-report-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { lock.reset() }
    switch (format, answer) {
    case (.pdf, .plain), (.pdf, .locked):
      var password: String?
      if case .locked(let typed) = answer { password = typed }
      guard let data = SharedReportPDF.data(report, words: words, password: password) else {
        throw SharedReportFailure.notDrawn
      }
      let url = folder.appendingPathComponent(fileName(locked: password != nil))
      try data.write(to: url, options: .atomic)
      return url
    case (.csv, .plain):
      let url = folder.appendingPathComponent(fileName(locked: false))
      try report.csv(words.csv).write(to: url, options: .atomic)
      return url
    case (.csv, .locked(let password)):
      let url = folder.appendingPathComponent(fileName(locked: true))
      let file = PersonalDataExport.File(
        name: fileName(locked: false), data: report.csv(words.csv))
      try EncryptedExport.write(
        [file], password: password, to: url, appVersion: appVersion,
        schemaVersion: schemaVersion)
      return url
    }
  }
}

enum SharedReportFailure: Error, Equatable {
  /// The system did not draw the pages.
  case notDrawn
}

/// Where the form takes its data: the snapshot every screen reads, the day and the calendar of
/// the environment.
enum SharedReportScreens {
  @MainActor
  static func model(_ deps: AppDependencies) -> SharedReportModel {
    model(dataset: deps.compute.snapshot?.dataset ?? Dataset(), environment: deps.environment)
  }

  @MainActor
  static func model(dataset: Dataset, environment: AppEnvironment) -> SharedReportModel {
    SharedReportModel(dataset: dataset, today: environment.today, calendar: environment.calendar)
  }
}
