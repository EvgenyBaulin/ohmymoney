import AppCore
import AppDatabase
import Foundation

/// «Собрать отчёт о проблеме…»: one zip the owner can hand over.
///
/// What goes in it is fixed and shown before it is written, because the whole point of the
/// file is that it can be given to somebody else. So it carries the journal, versions, counts
/// and settings — and not one amount, name or description.
struct ProblemReport: Sendable {
  /// What the owner is shown before the file is saved, and what `README.txt` repeats inside.
  struct Contents: Sendable, Equatable {
    var journalFiles: Int
    var journalDays: Int
    var tables: Int
    var rows: Int
    var settings: Int
    var crashReport: Bool
    /// `nil` when the check could not be run: no database open, or the check itself threw.
    var integrityCheckPassed: Bool?
    /// The journal's file could not be opened: no files, and the list says why.
    var journalUnavailable = false

    /// The line of the list about `PRAGMA integrity_check` (`Settings`): its result, not only
    /// that it is in the file.
    var integrityKey: String {
      switch integrityCheckPassed {
      case true?: "report.contents.integrity.passed"
      case false?: "report.contents.integrity.failed"
      case nil: "report.contents.integrity.notRun"
      }
    }
  }

  /// Journals older than this are left out («журналы за последние 7 дней»).
  static let journalDays = 7

  /// The files of the journal that go into a report: the live one, which is being written
  /// now, and every rotated one written to in the last `journalDays` days. The rotation keeps
  /// five files, and a lightly used app fills them over months — taking them all made the
  /// «за последние 7 дней» of the list and of the README untrue. A file is taken whole: its
  /// first lines may be older than the week, and that is the price of never cutting the stack
  /// of an error in half.
  static func journals(_ files: [URL], now: Date) -> [URL] {
    let since =
      Calendar.current.date(byAdding: .day, value: -journalDays, to: now)
      ?? now.addingTimeInterval(-TimeInterval(journalDays) * 86_400)
    return files.enumerated().compactMap { index, file in
      // `files` is newest first, and the first is the live file.
      if index == 0 { return file }
      let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
      guard let modified, modified >= since else { return nil }
      return file
    }
  }

  var appVersion: String
  var buildVersion: String
  var systemVersion: String
  var distribution: String
  var language: String
  var schemaVersion: Int
  var databaseBytes: Int
  /// `nil` when the check could not be run — above all when the database did not open, the
  /// likeliest reason to gather a report. Said as `not-run`, never as `failed`: a reader must
  /// not go after a corruption nobody tested for.
  var integrityCheckPassed: Bool?
  var rowCounts: [String: Int]
  var firstOperation: String?
  var lastOperation: String?
  var settings: [String: String]
  var lastRun: [String: Int]
  var standIns: [String]
  var lastSessionWasInterrupted: Bool
  /// What the application is built on, by name: `grdb`, `sqlite`, and `sparkle` in the build
  /// that updates itself («версии зависимостей»).
  var dependencies: [String: String] = [:]
  /// The code of the error the journal's file could not be opened with (`Logbook.openFailure`):
  /// a report without journal files says why it has none.
  var journalFailure: Int?

  /// The journal files to carry, newest first, and the crash report the owner picked.
  var journals: [URL] = []
  var crashReport: URL?

  var contents: Contents {
    Contents(
      journalFiles: journals.count, journalDays: Self.journalDays,
      tables: rowCounts.count, rows: rowCounts.values.reduce(0, +), settings: settings.count,
      crashReport: crashReport != nil, integrityCheckPassed: integrityCheckPassed,
      journalUnavailable: journalFailure != nil)
  }

  /// The zip. Built with the archive's own writer — it is written, proved by its tests and
  /// brings no dependency with it.
  func zipped(now: Date = Date()) throws -> Data {
    var zip = ZipWriter()
    try zip.add(path: "README.txt", text: readme(now: now))
    try zip.add(path: "versions.txt", text: versions())
    try zip.add(path: "database.txt", text: database())
    try zip.add(path: "settings.txt", text: settingsText())
    try zip.add(path: "pipeline.txt", text: pipeline())
    for journal in journals {
      let name = journal.lastPathComponent
      let data: Data
      do {
        data = try Data(contentsOf: journal)
      } catch {
        // The list shown before saving counted it, so it is never left out without a word:
        // rolled away since the list was gathered, or out of the app's reach.
        let code = (error as NSError).code
        AppLog.warning(
          "report.journalUnreadable", .app, "a journal file could not be read into a report",
          [LogPair("file", .token(name)), LogPair("code", .count(code))])
        try zip.add(
          path: "logs/\(name).unreadable.txt",
          text: "\(name) could not be read when the report was saved (error \(code))\n")
        continue
      }
      try zip.add(path: "logs/\(name)", data: data)
    }
    if let crashReport, let data = try? Data(contentsOf: crashReport) {
      try zip.add(path: "crash/\(crashReport.lastPathComponent)", data: data)
    }
    return try zip.finish()
  }

  /// What the file is, what is in it and what is not, in the language of the interface the
  /// report was gathered in (`language`) — from the String Catalog, as every text of the app.
  /// The names of the files are the files' own.
  private func readme(now: Date) -> String {
    let bundle =
      Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
      ?? .main
    let locale = Locale(identifier: language)
    func text(_ key: String, _ arguments: any CVarArg...) -> String {
      let format = bundle.localizedString(forKey: key, value: nil, table: "Settings")
      return arguments.isEmpty
        ? format : String(format: format, locale: locale, arguments: arguments)
    }
    var lines = [
      text("report.readme.title"),
      text("report.readme.gathered", LogLine.stamp(now, in: .current)),
      "",
      text("report.readme.inside"),
      "  logs/         " + text("report.readme.logs", Self.journalDays),
      "  versions.txt  " + text("report.readme.versions"),
      "  database.txt  " + text("report.readme.database"),
      "  settings.txt  " + text("report.readme.settings"),
      "  pipeline.txt  " + text("report.readme.pipeline"),
    ]
    if crashReport != nil { lines.append("  crash/        " + text("report.readme.crash")) }
    lines += [
      "",
      text("report.readme.notInside"),
      "  " + text("report.readme.never"),
      "",
      text("report.readme.why"),
    ]
    return lines.joined(separator: "\n") + "\n"
  }

  private func versions() -> String {
    var lines = [
      "app \(appVersion)",
      "build \(buildVersion)",
      "os \(systemVersion)",
      "distribution \(distribution)",
      "language \(language)",
      "schema \(schemaVersion)",
    ]
    for name in dependencies.keys.sorted() { lines.append("\(name) \(dependencies[name] ?? "")") }
    lines.append("lastSessionWasInterrupted \(lastSessionWasInterrupted ? "yes" : "no")")
    if let journalFailure {
      // Only the system log has the lines of this session: Console, subsystem of the bundle id.
      lines.append("journalUnavailable error \(journalFailure)")
    }
    return lines.joined(separator: "\n")
  }

  private func database() -> String {
    var lines = [
      "bytes \(databaseBytes)",
      "integrityCheck \(integrityCheckPassed.map { $0 ? "ok" : "failed" } ?? "not-run")",
      "firstOperation \(firstOperation ?? "-")",
      "lastOperation \(lastOperation ?? "-")",
      "",
      "rows by table:",
    ]
    for name in rowCounts.keys.sorted() { lines.append("  \(name) \(rowCounts[name] ?? 0)") }
    return lines.joined(separator: "\n")
  }

  private func settingsText() -> String {
    settings.keys.sorted().map { "\($0) \(settings[$0] ?? "")" }.joined(separator: "\n")
  }

  private func pipeline() -> String {
    var lines = [
      "the last run of the pipeline, milliseconds by step (a step that did not succeed in it"
        + " is not listed):"
    ]
    for step in lastRun.keys.sorted() { lines.append("  \(step) \(lastRun[step] ?? 0)") }
    guard !standIns.isEmpty else { return lines.joined(separator: "\n") }
    lines.append("")
    lines.append("views shown without the app's dependencies (a defect):")
    for reader in standIns.sorted() { lines.append("  \(reader)") }
    return lines.joined(separator: "\n")
  }
}
