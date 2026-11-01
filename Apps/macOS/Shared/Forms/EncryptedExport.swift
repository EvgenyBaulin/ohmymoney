import AppCore
import CoreKit
import Foundation
import UniformTypeIdentifiers

/// «Зашифровать» in front of the export of a table — «Отчёты», «Итог поездки», «Банкам за год».
/// The box is on every time the question is asked: nothing remembers that the owner took it off
/// last time, so a table never leaves in the open by habit. With the box on, the password is typed
/// twice and must not be empty; two different strings are not taken, since a typo would lock the
/// file for good. Swift compares the two by canonical equivalence, the rule the key follows too: it
/// is derived from the NFC form of the password.
///
/// The password lives here only while the question is open; `reset()` forgets it, and it is never
/// written to the journal or to the settings.
struct EncryptedExportForm: Equatable, Sendable {
  /// Why the export cannot go on yet, in words of the PrivacyExport catalog («Экспорт копии» says
  /// the same).
  enum Problem: Equatable, Sendable {
    case passwordEmpty
    case passwordMismatch

    var messageKey: String {
      switch self {
      case .passwordEmpty: "privacy.copy.problem.passwordEmpty"
      case .passwordMismatch: "privacy.copy.problem.passwordMismatch"
      }
    }
  }

  /// What the owner chose.
  enum Answer: Equatable, Sendable {
    /// The CSV as it always was.
    case plain
    /// One locked file with the CSV inside.
    case locked(password: String)
  }

  /// The words of the box, in the Reports catalog.
  static let boxKey = "export.encrypt"

  var encrypt = true
  var password = ""
  var confirmation = ""

  /// The first thing that stops the export, or nil when it can go on.
  var problem: Problem? {
    guard encrypt else { return nil }
    if password.isEmpty { return .passwordEmpty }
    if password != confirmation { return .passwordMismatch }
    return nil
  }

  /// The words under the fields; empty fields are not scolded before the owner typed anything.
  func problemShown() -> Problem? {
    if problem == .passwordEmpty, password.isEmpty, confirmation.isEmpty { return nil }
    return problem
  }

  /// The choice, or nil while the form cannot go on.
  var answer: Answer? {
    guard problem == nil else { return nil }
    return encrypt ? .locked(password: password) : .plain
  }

  /// Back to the box on and empty fields: the password is forgotten.
  mutating func reset() { self = EncryptedExportForm() }
}

/// The locked file of a table export: the container a copy is packed in («Экспорт копии» — the
/// transfer archive's own scheme, PBKDF2-HMAC-SHA256 with 600 000 rounds over the NFC password and
/// AES-256-GCM), with the CSV files inside under `data/csv/`, and the extension of an archive. It is
/// read back with the password before anybody is told it is ready.
enum EncryptedExport {
  enum Failure: Error, Equatable {
    case passwordMissing
    case noFiles
  }

  static let fileExtension = ArchiveService.fileExtension

  /// The type the exporter writes: the archive's own, by its extension. Only the Mac declares it;
  /// on the phone the system makes a type for the extension.
  static var contentType: UTType {
    UTType(filenameExtension: fileExtension, conformingTo: .data) ?? .data
  }

  /// «trip-turkey» → «trip-turkey.ohmymoneyarchive».
  static func fileName(_ stem: String) -> String { stem + "." + fileExtension }

  static var platform: String {
    #if os(macOS)
      "macOS"
    #else
      "iOS"
    #endif
  }

  /// The table name of a CSV inside the container: the file's name without «.csv», which the
  /// container's path adds back.
  static func table(of file: PersonalDataExport.File) -> String {
    let name = file.name
    return name.lowercased().hasSuffix(".csv") ? String(name.dropLast(4)) : name
  }

  /// The files sealed with the password and opened again with it: the bytes come back only once
  /// they are known to open.
  static func lockedData(
    _ files: [PersonalDataExport.File], password: String, appVersion: String,
    schemaVersion: Int, now: Date = Date(),
    cipher: any ArchiveCipher = CryptoKitArchiveCipher(),
    iterations: Int = EncryptionHeader.recommendedIterations
  ) throws -> Data {
    guard !password.isEmpty else { throw Failure.passwordMissing }
    guard !files.isEmpty else { throw Failure.noFiles }
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: appVersion, schemaVersion: schemaVersion,
        createdAt: CalendarContext.system.day(of: now), platform: platform, rowCounts: [:]))
    for file in files {
      try builder.add(path: ArchivePaths.csv(table: table(of: file)), data: file.data)
    }
    var random = SecureRandomSource()
    let data = try builder.build(
      password: password, cipher: cipher, random: &random, iterations: iterations)
    _ = try read(data, password: password, schemaVersion: schemaVersion, cipher: cipher)
    return data
  }

  /// The locked file at `url`, whole or not at all, read back from the disk with the password; a
  /// file that does not read is taken away again. Start, size and failure are in the journal —
  /// counts and the error's type, never a name, a path or the password.
  static func write(
    _ files: [PersonalDataExport.File], password: String, to url: URL, appVersion: String,
    schemaVersion: Int, now: Date = Date(),
    cipher: any ArchiveCipher = CryptoKitArchiveCipher(),
    iterations: Int = EncryptionHeader.recommendedIterations
  ) throws {
    AppLog.info(
      "export.locked.started", .archive, "a table is being saved locked with a password",
      [LogPair("files", .count(files.count))])
    var removed: Bool?
    do {
      let data = try lockedData(
        files, password: password, appVersion: appVersion, schemaVersion: schemaVersion,
        now: now, cipher: cipher, iterations: iterations)
      try data.write(to: url, options: .atomic)
      do {
        _ = try read(
          try Data(contentsOf: url), password: password, schemaVersion: schemaVersion,
          cipher: cipher)
      } catch {
        removed = (try? FileManager.default.removeItem(at: url)) != nil
        throw error
      }
      AppLog.info(
        "export.locked.done", .archive, "the locked table was written and read back",
        [LogPair("files", .count(files.count)), LogPair("bytes", .bytes(data.count))])
    } catch {
      var pairs = [LogPair("error", .error(error))]
      if let removed { pairs.append(LogPair("removed", .flag(removed))) }
      AppLog.error(
        "export.locked.failed", .archive, "the locked table was not written, or did not read back",
        pairs)
      throw error
    }
  }

  /// The CSV files of a locked file, opened with the password; a wrong one throws.
  static func read(
    _ data: Data, password: String, schemaVersion: Int,
    cipher: any ArchiveCipher = CryptoKitArchiveCipher()
  ) throws -> [PersonalDataExport.File] {
    let opened = try ArchiveOpener.open(
      data, password: password, cipher: cipher, supportedSchemaVersion: schemaVersion)
    return opened.csvTables.compactMap { table in
      opened.csv(table: table).map { PersonalDataExport.File(name: table + ".csv", data: $0) }
    }
  }
}

#if os(macOS)
  import AppKit

  /// The Mac's question in front of a table export: the warning that the file carries names and
  /// amounts, the box «Зашифровать» (on) and the password twice. A problem is said and the
  /// question asked again with what was typed; nil when the owner stepped back.
  @MainActor
  enum EncryptedExportPrompt {
    static func ask(_ environment: AppEnvironment) -> EncryptedExportForm.Answer? {
      var form = EncryptedExportForm()
      while true {
        let alert = NSAlert()
        alert.messageText = environment.language("export.warning.title", table: "Settings")
        alert.informativeText = environment.language("export.warning.body", table: "Settings")
        let fields = Fields(form: form, environment: environment)
        alert.accessoryView = fields.view
        alert.window.initialFirstResponder = fields.password
        alert.addButton(withTitle: environment.language("action.export"))
        alert.addButton(withTitle: environment.language("action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        form = fields.form
        if let answer = form.answer { return answer }
        if let problem = form.problem {
          let warning = NSAlert()
          warning.alertStyle = .warning
          warning.messageText = environment.language(problem.messageKey, table: "PrivacyExport")
          warning.runModal()
        }
      }
    }

    /// The panel that says the file is being locked — the key derivation takes seconds — and the
    /// closure that takes it away.
    static func showProgress(_ environment: AppEnvironment) -> () -> Void {
      let panel = ArchiveProgressPanel.show(
        environment.language("export.locked.working", table: "Reports"))
      return { panel.close() }
    }

    /// The box and the two fields; the fields are off while the box is.
    @MainActor private final class Fields: NSObject {
      let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 104))
      let box: NSButton
      let password = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
      let again = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))

      init(form: EncryptedExportForm, environment: AppEnvironment) {
        box = NSButton(
          checkboxWithTitle: environment.language(EncryptedExportForm.boxKey, table: "Reports"),
          target: nil, action: nil)
        super.init()
        box.frame = NSRect(x: 0, y: 82, width: 260, height: 20)
        box.state = form.encrypt ? .on : .off
        box.target = self
        box.action = #selector(toggled)
        box.setAccessibilityIdentifier("export.encrypt")
        password.placeholderString = environment.language(
          "privacy.copy.password", table: "PrivacyExport")
        password.stringValue = form.password
        password.setAccessibilityIdentifier("export.encrypt.password")
        again.placeholderString = environment.language(
          "privacy.copy.passwordAgain", table: "PrivacyExport")
        again.stringValue = form.confirmation
        again.setAccessibilityIdentifier("export.encrypt.passwordAgain")
        password.nextKeyView = again
        // Only the app opens the locked file: the owner knows before sending it to anybody.
        let note = NSTextField(
          labelWithString: environment.language("export.encrypt.note", table: "Reports"))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 18, y: 60, width: 242, height: 18)
        note.lineBreakMode = .byTruncatingTail
        view.addSubview(box)
        view.addSubview(note)
        view.addSubview(password)
        view.addSubview(again)
        toggled()
      }

      var form: EncryptedExportForm {
        EncryptedExportForm(
          encrypt: box.state == .on, password: password.stringValue,
          confirmation: again.stringValue)
      }

      @objc private func toggled() {
        password.isEnabled = box.state == .on
        again.isEnabled = box.state == .on
      }
    }
  }
#endif
