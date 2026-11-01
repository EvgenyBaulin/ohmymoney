import AppCore
import Foundation

#if canImport(AppKit)
  import AppKit
#endif

/// «Выгрузить…» of «Итог поездки»: the four CSV files of `TripSummaryCSV`. First the warning that
/// the files carry personal data (the settlement names people) with the box «Зашифровать», on
/// every time (`EncryptedExportPrompt`). Locked, the four go into one file of the archive's
/// container where the owner names it. Plain, they go into a folder the owner chooses — which
/// also gives the sandbox access to it —, then, if files with these names are there, the question
/// whether to replace them (decision 0098), then the files; each is written whole or not at all,
/// and the result is told in words, a failure included.
@MainActor
enum TripSummaryExport {
  /// What the export did.
  enum Outcome: Equatable {
    case written(files: Int)
    case failed
  }

  #if !os(macOS)
    /// The iPhone screen hands the files to a file exporter instead of asking in panels.
    static func run(files: [TripSummaryCSV.File], stem: String, environment: AppEnvironment) {}
  #endif

  #if os(macOS)
    /// `stem` names the locked file («trip-turkey-summer»).
    static func run(files: [TripSummaryCSV.File], stem: String, environment: AppEnvironment) {
      guard let answer = EncryptedExportPrompt.ask(environment) else { return }
      switch answer {
      case .plain:
        runPlain(files, environment)
      case .locked(let password):
        runLocked(files, stem: stem, password: password, environment)
      }
    }

    /// The four CSV files into a folder, as before the box existed.
    private static func runPlain(_ files: [TripSummaryCSV.File], _ environment: AppEnvironment) {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.allowsMultipleSelection = false
      panel.message = TravelText.t("travel.export.title", environment)
      panel.prompt = TravelText.t("travel.export.choose", environment)
      guard panel.runModal() == .OK, let directory = panel.url else { return }
      let replaced = replacing(files, in: directory)
      guard replaced == 0 || confirmReplacing(replaced, environment) else { return }
      tell(write(files, to: directory), environment)
    }

    /// One locked file holding the four, where the owner names it; the save panel asks itself
    /// before it replaces a file. The lock is made away from the main thread.
    private static func runLocked(
      _ files: [TripSummaryCSV.File], stem: String, password: String,
      _ environment: AppEnvironment
    ) {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = EncryptedExport.fileName(stem)
      panel.allowedContentTypes = [EncryptedExport.contentType]
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      panel.message = TravelText.t("travel.export.title", environment)
      guard panel.runModal() == .OK, let url = panel.url else { return }
      let csv = files.map { PersonalDataExport.File(name: $0.name, data: $0.data) }
      let version = AppEnvironment.appVersion
      let schema = environment.stack?.applied.onDisk ?? 0
      let working = EncryptedExportPrompt.showProgress(environment)
      Task { @MainActor in
        let written = await Task.detached(priority: .userInitiated) {
          (try? EncryptedExport.write(
            csv, password: password, to: url, appVersion: version, schemaVersion: schema)) != nil
        }.value
        working()
        tell(written ? .written(files: 1) : .failed, environment)
      }
    }

    private static func tell(_ outcome: Outcome, _ environment: AppEnvironment) {
      let alert = NSAlert()
      switch outcome {
      case .written(let count):
        alert.messageText = TravelText.format("travel.export.done", environment, count)
      case .failed:
        alert.alertStyle = .warning
        alert.messageText = TravelText.t("travel.export.failed", environment)
      }
      alert.addButton(withTitle: environment.language("action.ok"))
      alert.runModal()
    }
  #endif

  /// How many of the files are in the folder already.
  static func replacing(_ files: [TripSummaryCSV.File], in directory: URL) -> Int {
    files.count {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.name).path)
    }
  }

  /// The files, each whole or not at all; the first failure stops the export.
  static func write(_ files: [TripSummaryCSV.File], to directory: URL) -> Outcome {
    AppLog.info("travel.export.started", .archive, "the summary of a trip is being saved as CSV")
    do {
      for file in files {
        try file.data.write(to: directory.appendingPathComponent(file.name), options: .atomic)
      }
    } catch {
      let failure = ReportExport.Failure(of: error)
      AppLog.error(
        "travel.export.failed", .archive, "the summary of a trip was not saved",
        [LogPair("reason", .token(failure.rawValue)), LogPair("error", .error(error))])
      return .failed
    }
    AppLog.info(
      "travel.export.done", .archive, "the summary of a trip was saved",
      [LogPair("files", .count(files.count))])
    return .written(files: files.count)
  }

  #if os(macOS)
    private static func confirmReplacing(_ count: Int, _ environment: AppEnvironment) -> Bool {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = TravelText.format("travel.export.replace.title", environment, count)
      alert.informativeText = TravelText.t("travel.export.replace.body", environment)
      alert.addButton(withTitle: TravelText.t("travel.export.replace.action", environment))
      alert.addButton(withTitle: environment.language("action.cancel"))
      return alert.runModal() == .alertFirstButtonReturn
    }
  #endif
}
