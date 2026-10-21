import Foundation
import GRDB

/// What the dry run of an update says about an error: its kind and its codes, never its message
/// or its details, which can quote a path, a file name or a row of the owner's data.
public enum DryRunText {
  /// How far down the chain of underlying errors the advice looks.
  private static let chainDepth = 4

  /// «SQLite 19», «stopped at 0005_cards (SQLite 19)», «NSCocoaErrorDomain 257
  /// (NSPOSIXErrorDomain 1)» — the domain and code of the error and of the error under it.
  public static func describe(_ error: any Error) -> String {
    if let failure = error as? DatabaseStack.MigrationFailure {
      return "stopped at \(failure.migration ?? "?") (\(describe(failure.underlying)))"
    }
    if let sqlite = error as? GRDB.DatabaseError {
      return "SQLite \(sqlite.extendedResultCode.rawValue)"
    }
    let error = error as NSError
    var text = "\(error.domain) \(error.code)"
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      text += " (\(underlying.domain) \(underlying.code))"
    }
    return text
  }

  /// One sentence of advice when the chain of the error says why it happened, else nil. A
  /// refusal by the privacy protection of macOS (`EPERM`, or a Cocoa «no permission» without a
  /// POSIX cause) is lifted by Full Disk Access for the app the command runs in; `EACCES` is the
  /// file's own permissions.
  public static func hint(for error: any Error) -> String? {
    var cocoaRefusal = false
    for error in chain(of: error) {
      if error.domain == NSPOSIXErrorDomain {
        if error.code == Int(EPERM) { return privacy }
        if error.code == Int(EACCES) { return permissions }
      }
      if error.domain == NSCocoaErrorDomain,
        error.code == NSFileReadNoPermissionError || error.code == NSFileWriteNoPermissionError
      {
        cocoaRefusal = true
      }
    }
    return cocoaRefusal ? privacy : nil
  }

  static let privacy =
    "macOS privacy protection kept this program out of another app's data. Turn on Full Disk"
    + " Access for the app you run this in (System Settings → Privacy & Security → Full Disk"
    + " Access; «Системные настройки → Конфиденциальность и безопасность → Полный доступ к"
    + " диску»), quit and reopen it, and run the command again."

  static let permissions = "the file's permissions do not let this user read it."

  /// The error and the errors under it, the outermost first.
  private static func chain(of error: any Error) -> [NSError] {
    var result: [NSError] = []
    var current: NSError? =
      (error as? DatabaseStack.MigrationFailure).map { $0.underlying as NSError }
      ?? error as NSError
    while let error = current, result.count < chainDepth {
      result.append(error)
      current = error.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return result
  }
}
