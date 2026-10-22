import AppCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File menu: exporting the data as CSV and moving everything to another Mac in a single
/// archive. Every one of these opens a panel, so the sandbox gets access to the folder the
/// owner actually picked.
struct FileCommands: Commands {
  let environment: AppEnvironment
  let store: TransactionsStore

  var body: some Commands {
    CommandGroup(after: .saveItem) {
      Button(environment.language("action.export")) {
        exportCSV()
      }

      Button(environment.language("archive.export", table: "Settings")) {
        exportArchive()
      }

      Button(environment.language("archive.import", table: "Settings")) {
        importArchive()
      }
      .keyboardShortcut("o", modifiers: [.command, .shift])

      Divider()
      Button(environment.language("import.menu", table: "Import")) {
        environment.statementImportRequest = StatementImportRequest(urls: [])
      }
    }
  }

  /// Also the «Export» button of the main window's toolbar.
  func exportCSV() {
    guard let csvExport = environment.csvExport else { return }
    guard Self.confirmPersonalData(environment) else { return }
    guard let directory = chooseDirectory() else { return }
    // The names of the export files are fixed; files under them are replaced only once the
    // owner has said so, as a save panel asks before it replaces one.
    let replaced = csvExport.filesItWouldReplace(in: directory)
    guard replaced.isEmpty || confirmReplacing(replaced.count) else { return }
    let outcome = Self.exportCSV(with: csvExport, to: directory)
    let alert = NSAlert()
    switch outcome {
    case .written(let files):
      alert.messageText = environment.format(outcome.messageKey, table: "Settings", files)
    case .failed:
      alert.alertStyle = .warning
      alert.messageText = environment.language(outcome.messageKey, table: "Settings")
      alert.informativeText = environment.language("export.failed.body", table: "Settings")
    }
    alert.runModal()
  }

  private func confirmReplacing(_ count: Int) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = environment.format("export.replace.title", table: "Settings", count)
    alert.informativeText = environment.language("export.replace.body", table: "Settings")
    alert.addButton(withTitle: environment.language("export.replace.action", table: "Settings"))
    alert.addButton(withTitle: environment.language("action.cancel"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// What the CSV export tells the owner: how many files it wrote, or that it did not finish.
  /// It is never silent — the owner was warned, chose a folder and will trust what is in it.
  enum CSVExportOutcome: Equatable {
    case written(files: Int)
    case failed

    /// Words of the Settings catalog; `written` is a plural entry taking the count.
    var messageKey: String {
      switch self {
      case .written: "export.done"
      case .failed: "export.failed"
      }
    }
  }

  /// The export itself, apart from its panels so a test can run it. The service writes the
  /// failure in the journal and leaves the folder as it was (`CSVExportService.export`).
  nonisolated static func exportCSV(
    with service: CSVExportService, to directory: URL
  ) -> CSVExportOutcome {
    do {
      return .written(files: try service.export(to: directory).count)
    } catch {
      return .failed
    }
  }

  private func exportArchive() {
    guard let archives = environment.archives, !ArchiveProgressPanel.isShowing else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue =
      "OhMyMoney-\(environment.today.iso).\(ArchiveService.fileExtension)"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }

    // A password is optional, and leaving it empty is a decision the owner takes
    // knowingly: the archive then carries names and amounts in the open.
    guard
      let password = Self.newPassword(
        ask: askForNewPassword, mismatch: reportPasswordMismatch,
        confirmNoPassword: confirmNoPassword)
    else { return }

    let settings = environment.portableSettings()
    let environment = environment
    let progress = ArchiveProgressPanel.show(
      environment.language("archive.export.working", table: "Settings"))
    Task { @MainActor in
      let written = await Self.exportArchive(
        with: archives, to: url, password: password, settings: settings)
      progress.close()
      Self.report(written ? "archive.export.done" : "archive.export.failed", in: environment)
    }
  }

  /// The export after its panels, apart from them so a test can run it. The service writes a
  /// failure in the journal.
  ///
  /// The work runs away from the main thread: the key derivation (600 000 rounds of a
  /// pure-Swift HMAC), the digests over the whole database and the read-back took seconds, and
  /// on the main thread the whole app stood still meanwhile.
  static func exportArchive(
    with archives: ArchiveService, to url: URL, password: String?, settings: [String: String]
  ) async -> Bool {
    await Task.detached(priority: .userInitiated) {
      (try? archives.exportArchive(to: url, password: password, settings: settings)) != nil
    }.value
  }

  /// What the owner typed for the password of a new archive.
  enum NewPasswordAnswer: Equatable {
    /// Cancel: the export stops there.
    case cancelled
    /// The password field and the field that repeats it.
    case typed(String, again: String)
  }

  /// Returns the password the archive is locked with, an empty string for "no password" once
  /// the owner confirmed the warning, or nil if the owner stepped back out of the export.
  ///
  /// The password is typed twice, and two different strings are not taken: the check after
  /// the export opens the archive with the very string it was written with, so a typo would
  /// pass it and lock the archive for good. The owner is told and asked again. Swift compares
  /// the two by canonical equivalence, the rule the key follows too: it is derived from the
  /// NFC form of the password (`EncryptionHeader.passwordBytes`).
  static func newPassword(
    ask: () -> NewPasswordAnswer, mismatch: () -> Void, confirmNoPassword: () -> Bool
  ) -> String? {
    while case .typed(let password, let again) = ask() {
      guard password == again else {
        mismatch()
        continue
      }
      guard password.isEmpty else { return password }
      return confirmNoPassword() ? "" : nil
    }
    return nil
  }

  private func askForNewPassword() -> NewPasswordAnswer {
    let alert = NSAlert()
    alert.messageText = environment.language("archive.password.title", table: "Settings")
    alert.informativeText = environment.language("archive.password.body", table: "Settings")
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
    field.placeholderString = environment.language("archive.password.field", table: "Settings")
    let again = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    again.placeholderString = environment.language("archive.password.again", table: "Settings")
    field.nextKeyView = again
    let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
    fields.addSubview(field)
    fields.addSubview(again)
    alert.accessoryView = fields
    alert.window.initialFirstResponder = field
    alert.addButton(withTitle: environment.language("action.save"))
    alert.addButton(withTitle: environment.language("action.cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
    return .typed(field.stringValue, again: again.stringValue)
  }

  private func reportPasswordMismatch() {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = environment.language("archive.password.mismatch", table: "Settings")
    alert.informativeText = environment.language(
      "archive.password.mismatch.body", table: "Settings")
    alert.runModal()
  }

  private func confirmNoPassword() -> Bool {
    let warning = NSAlert()
    warning.alertStyle = .warning
    warning.messageText = environment.language("archive.noPassword.title", table: "Settings")
    warning.informativeText = environment.language("archive.noPassword.body", table: "Settings")
    warning.addButton(withTitle: environment.language("action.save"))
    warning.addButton(withTitle: environment.language("action.cancel"))
    return warning.runModal() == .alertFirstButtonReturn
  }

  private func importArchive() {
    guard let archives = environment.archives, let backups = environment.backups,
      !ArchiveProgressPanel.isShowing
    else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Self.importArchive(
      from: url, archives: archives, backups: backups, questions: .alerts(environment))
  }

  /// The steps of the menu after its open panel, apart from it so a test can run them. They
  /// are the steps of a double click after its confirmation (`ArchiveImportFlow.run`).
  @discardableResult
  static func importArchive(
    from url: URL, archives: ArchiveService, backups: BackupService,
    questions: ArchiveImportFlow.Questions
  ) -> Task<Void, Never>? {
    ArchiveImportFlow.run(url, archives: archives, backups: backups, questions: questions)
  }

  /// Tells the owner which of the checks failed, instead of one message for everything.
  nonisolated static func messageKey(for error: Error) -> String {
    ArchiveImportFlow.messageKey(for: error)
  }

  private static func report(_ key: String, in environment: AppEnvironment) {
    let alert = NSAlert()
    alert.messageText = environment.language(key, table: "Settings")
    alert.runModal()
  }

  private func chooseDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
  }

  /// The files carry names of people and amounts; the owner is told before they leave. Every
  /// export asks this very question: the CSV of the File menu and a table of Reports.
  static func confirmPersonalData(_ environment: AppEnvironment) -> Bool {
    let alert = NSAlert()
    alert.messageText = environment.language("export.warning.title", table: "Settings")
    alert.informativeText = environment.language("export.warning.body", table: "Settings")
    alert.addButton(withTitle: environment.language("action.export"))
    alert.addButton(withTitle: environment.language("action.cancel"))
    return alert.runModal() == .alertFirstButtonReturn
  }
}
