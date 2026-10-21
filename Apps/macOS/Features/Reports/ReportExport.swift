import AppCore
import Foundation
import UniformTypeIdentifiers

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(UIKit)
  import UIKit
#endif

/// «Выгрузить CSV…» of the Reports window: the table on screen — exactly its lines and whole
/// rubles — as the core's `ReportCSV`, which `pandas.read_csv` reads with no parameters.
///
/// The order is that of every export of the app: first the warning that the file carries
/// personal data (`FileCommands.confirmPersonalData`), then the save panel — which also
/// gives the sandbox access to the one file the owner named — then the file. A failure is
/// told to the owner in words of the interface, never swallowed.
@MainActor
enum ReportExport {
  /// Why the file was not written, for the words of the alert — from the Reports catalog, in
  /// the language of the interface. The system's own description is never shown: it is in the
  /// language of the Mac, not of the app, and it names the file. The reason is read from the
  /// codes of the error; the journal has its type and code. No case carries a path, a name or
  /// an amount.
  enum Failure: String, Error, Equatable, CaseIterable {
    /// The folder does not let the app write into it.
    case noPermission
    /// No room left on the disk, or in the owner's quota on it.
    case diskFull
    /// A disk mounted read-only.
    case readOnly
    /// Anything else: a folder that went away meanwhile, a disk that was ejected.
    case other

    /// Words of the Reports catalog under «Не удалось сохранить CSV».
    var messageKey: String {
      switch self {
      case .noPermission: "reports.export.failed.noPermission"
      case .diskFull: "reports.export.failed.diskFull"
      case .readOnly: "reports.export.failed.readOnly"
      case .other: "reports.export.failedUnknown"
      }
    }

    /// The reason the system gave, by its codes: Foundation's own or the POSIX ones, and an
    /// error that wraps another is read through to the one inside.
    nonisolated init(of error: Error) {
      let error = error as NSError
      switch (error.domain, error.code) {
      case (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
        (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)):
        self = .noPermission
      case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
        (NSPOSIXErrorDomain, Int(ENOSPC)), (NSPOSIXErrorDomain, Int(EDQUOT)):
        self = .diskFull
      case (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError), (NSPOSIXErrorDomain, Int(EROFS)):
        self = .readOnly
      default:
        if let inner = error.userInfo[NSUnderlyingErrorKey] as? Error {
          self.init(of: inner)
        } else {
          self = .other
        }
      }
    }
  }

  #if !os(macOS)
    /// Saving a table is a file exporter of the screen on iPhone; nothing happens here.
    static func run(model: ReportsModel, environment: AppEnvironment, compute: ComputeStore) async {
    }
  #endif
  #if os(macOS)
    static func run(model: ReportsModel, environment: AppEnvironment, compute: ComputeStore) async {
      guard FileCommands.confirmPersonalData(environment) else { return }
      let panel = NSSavePanel()
      panel.nameFieldStringValue = ReportFileName.make(for: model.request)
      panel.allowedContentTypes = [.commaSeparatedText]
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      guard panel.runModal() == .OK, let url = panel.url else { return }

      let names = ReportsText.csvNames(for: model, environment)
      let table = model.table
      do {
        try await compute.compute {
          try write(table, names: names, to: url)
        }
      } catch {
        report(error, environment)
      }
    }
  #endif

  /// The CSV of a table with the names the table showed.
  nonisolated static func data(_ table: ReportTable, names: [ReportKey: String]) -> Data {
    ReportCSV.data(table, label: { names[$0] ?? $0.description })
  }

  /// Writes the file whole or not at all: a failed write leaves no half of a table behind.
  /// The start and the result are in the journal («экспорт: начало, результат, размер файла,
  /// число записей»), a failure with its reason and the error's type and code — never the
  /// path or the system's words about it.
  nonisolated static func write(
    _ table: ReportTable, names: [ReportKey: String], to url: URL
  ) throws {
    AppLog.info("reports.export.started", .archive, "a table of Reports is being saved as CSV")
    let data = data(table, names: names)
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      let failure = Failure(of: error)
      AppLog.error(
        "reports.export.failed", .archive, "the table was not saved; no part of it is left",
        [
          LogPair("reason", .token(failure.rawValue)),
          LogPair("error", .error(error)),
          LogPair("code", .count((error as NSError).code)),
        ])
      throw failure
    }
    AppLog.info(
      "reports.export.done", .archive, "a table of Reports was saved",
      [
        LogPair("rows", .count(ArchiveOpener.countCSVRows(data))),
        LogPair("bytes", .bytes(data.count)),
      ])
  }

  /// «Не удалось сохранить CSV» and why — a folder without permission, a full disk — in
  /// words of the interface.
  #if os(macOS)
    private static func report(_ error: Error, _ environment: AppEnvironment) {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = ReportsText.t("reports.export.failed", environment)
      alert.informativeText = ReportsText.t(
        (error as? Failure ?? .other).messageKey, environment)
      alert.addButton(withTitle: environment.language("action.ok"))
      alert.runModal()
    }
  #endif
}
