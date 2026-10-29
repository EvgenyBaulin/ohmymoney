import AppCore
import CoreKit
import Foundation

/// A single table or report, locked with a password: the same container a copy is packed in
/// (PBKDF2-HMAC-SHA256 and AES-256-GCM, `ExportCopyService`), holding the one CSV file. It is
/// what «Зашифровать» does for a report, so nothing that leaves the Mac as a table has to leave in
/// the open. The file is read back with the password before it is handed over.
enum LockedFileExport {
  enum Failure: Error, Equatable {
    case passwordMissing
  }

  /// Writes `csv` under the name `table` inside the container and returns nothing but success.
  static func write(
    csv: Data, table: String, password: String, to url: URL, appVersion: String,
    schemaVersion: Int, now: Date = Date(),
    cipher: any ArchiveCipher = CryptoKitArchiveCipher(),
    iterations: Int = EncryptionHeader.recommendedIterations
  ) throws {
    guard !password.isEmpty else { throw Failure.passwordMissing }
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: appVersion, schemaVersion: schemaVersion,
        createdAt: CalendarContext.system.day(of: now), platform: "macOS", rowCounts: [:]))
    try builder.add(path: ArchivePaths.csv(table: table), data: csv)
    var random = SecureRandomSource()
    let data = try builder.build(
      password: password, cipher: cipher, random: &random, iterations: iterations)
    try data.write(to: url, options: .atomic)
    do {
      _ = try ArchiveOpener.open(
        try Data(contentsOf: url), password: password, cipher: cipher,
        supportedSchemaVersion: schemaVersion)
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }
}

#if os(macOS)
  import AppKit

  /// The question «a password for the file?» of a locked export: typed twice, never empty. Nil
  /// when the owner stepped back.
  @MainActor
  enum LockedExportPassword {
    static func ask(_ environment: AppEnvironment) -> String? {
      func t(_ key: String) -> String { environment.language(key, table: "PrivacyExport") }
      while true {
        let alert = NSAlert()
        alert.messageText = t("privacy.lockedFile.title")
        alert.informativeText = t("privacy.lockedFile.body")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        field.placeholderString = t("privacy.copy.password")
        let again = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        again.placeholderString = t("privacy.copy.passwordAgain")
        field.nextKeyView = again
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        fields.addSubview(field)
        fields.addSubview(again)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: environment.language("action.save"))
        alert.addButton(withTitle: environment.language("action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard !field.stringValue.isEmpty else {
          tell(t("privacy.copy.problem.passwordEmpty"))
          continue
        }
        guard field.stringValue == again.stringValue else {
          tell(t("privacy.copy.problem.passwordMismatch"))
          continue
        }
        return field.stringValue
      }
    }

    private static func tell(_ message: String) {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = message
      alert.runModal()
    }
  }
#endif
