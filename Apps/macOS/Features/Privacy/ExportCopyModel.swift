import AppCore
import AppDatabase
import CoreKit
import Foundation
import Observation

/// The state of the «Экспорт копии» dialog and everything it decides without a view: whether the
/// form can be saved and why not, the request it hands to `ExportCopyService`, the sentence that
/// says what will go in. The original is never changed by anything here.
@MainActor
@Observable
final class ExportCopyModel {
  enum ScopeChoice: String, CaseIterable, Sendable {
    case whole
    case period
  }

  /// Why the form cannot be saved yet. The dialog says it in words next to the field.
  enum Problem: Equatable, Sendable {
    case passwordEmpty
    case passwordMismatch
    case periodEmpty
  }

  /// Where the dialog is.
  enum Stage: Equatable {
    case editing
    case working
    case done(ExportCopyReport)
    case failed(Failure)
  }

  /// What went wrong, as a key of the catalog the dialog reads.
  enum Failure: Equatable, Sendable {
    case passwordMissing
    case anonymizerMissing
    case hiddenAccountInUse
    case periodEmpty
    case other

    init(_ error: any Error) {
      switch error as? ExportCopyError {
      case .passwordMissing: self = .passwordMissing
      case .anonymizerMissing: self = .anonymizerMissing
      case .hiddenAccountInUse: self = .hiddenAccountInUse
      case .periodEmpty: self = .periodEmpty
      case nil: self = .other
      }
    }

    var key: String {
      switch self {
      case .passwordMissing: "privacy.copy.error.passwordMissing"
      case .anonymizerMissing: "privacy.copy.error.anonymizerMissing"
      case .hiddenAccountInUse: "privacy.copy.error.hiddenInUse"
      case .periodEmpty: "privacy.copy.error.periodEmpty"
      case .other: "privacy.copy.error.other"
      }
    }
  }

  var password = ""
  var confirmation = ""
  var showsPassword = false
  var scope: ScopeChoice = .whole
  var periodStart: Date
  var periodEnd: Date
  var anonymize = false
  /// «Включая скрытые»: off by default, so a copy for somebody else never carries a hidden
  /// account unless the owner says so.
  var includeHidden = false
  var includeAttachments: Bool
  var format: ExportCopyRequest.Format = .archive
  var stage: Stage = .editing
  /// What the copy would hold now; `nil` until counted.
  var counts: ExportCopyCounts?

  private let calendar: CalendarContext

  init(
    today: DateOnly, calendar: CalendarContext = .system, attachmentsByDefault: Bool = true,
    format: ExportCopyRequest.Format = .archive
  ) {
    self.calendar = calendar
    self.includeAttachments = attachmentsByDefault
    self.format = format
    let start = DateOnly(year: today.year, month: 1, day: 1)
    self.periodStart = Self.date(of: start, in: calendar)
    self.periodEnd = Self.date(of: today, in: calendar)
  }

  // MARK: Reading the form

  var range: DayRange {
    DayRange(calendar.day(of: periodStart), calendar.day(of: periodEnd))
  }

  /// The first thing that stops the copy, or `nil` when it can be made.
  var problem: Problem? {
    if password.isEmpty { return .passwordEmpty }
    if password != confirmation { return .passwordMismatch }
    if scope == .period, range.isEmpty { return .periodEmpty }
    return nil
  }

  var canSave: Bool { problem == nil && stage != .working }

  /// The words under the fields while the form is incomplete; empty fields are not scolded
  /// before the owner has typed anything.
  func problemShown() -> Problem? {
    switch problem {
    case .passwordEmpty where password.isEmpty && confirmation.isEmpty: nil
    default: problem
    }
  }

  /// The request for `ExportCopyService.export`; `nil` while the form cannot be saved.
  /// «Только CSV» has no database in it, so the attached files are not carried along with it.
  func request() -> ExportCopyRequest? {
    guard problem == nil else { return nil }
    return ExportCopyRequest(
      scope: scope == .whole ? .whole : .period(range), anonymize: anonymize,
      includeHidden: includeHidden, includeAttachments: includeAttachments, password: password,
      format: format)
  }

  /// The request as it stands, for counting what would go in: the password does not matter to the
  /// counts and may still be empty.
  func countingRequest() -> ExportCopyRequest {
    ExportCopyRequest(
      scope: scope == .whole ? .whole : .period(range), anonymize: anonymize,
      includeHidden: includeHidden, includeAttachments: includeAttachments, password: "-",
      format: format)
  }

  /// The two files the sheet may name, as the Mac names an export.
  func fileName(today: DateOnly) -> String {
    "OhMyMoney-copy-\(today.iso).\(ArchiveService.fileExtension)"
  }

  // MARK: Making the copy

  /// The file made and waiting for the owner to say where it goes.
  private(set) var pending: (report: ExportCopyReport, url: URL)?

  /// Makes the copy in a temporary place, away from the main thread (the key derivation is slow),
  /// and leaves it waiting in `pending`. The live database and its files are not touched.
  func prepare(
    with service: ExportCopyService, settings: [String: String], today: DateOnly
  ) async {
    guard let request = request() else { return }
    stage = .working
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-copy-out-\(UUID().uuidString)", isDirectory: true)
    let url = folder.appendingPathComponent(fileName(today: today))
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let report = try await Task.detached(priority: .userInitiated) {
        try service.export(request, to: url, settings: settings)
      }.value
      pending = (report, url)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      stage = .failed(Failure(error))
    }
  }

  /// The owner chose a place and the file went there.
  func moved(to destination: URL) {
    guard let pending else { return }
    let report = ExportCopyReport(
      url: destination, operations: pending.report.operations,
      transfers: pending.report.transfers, accounts: pending.report.accounts,
      operationsLeftOut: pending.report.operationsLeftOut,
      transfersLeftOut: pending.report.transfersLeftOut,
      accountsLeftOut: pending.report.accountsLeftOut, attachments: pending.report.attachments,
      encrypted: pending.report.encrypted)
    discardTemporary()
    stage = .done(report)
  }

  /// The owner stepped back from the place: the copy is taken away and the form stays as it was.
  func cancelled() {
    discardTemporary()
    stage = .editing
  }

  private func discardTemporary() {
    if let pending { try? FileManager.default.removeItem(at: pending.url.deletingLastPathComponent()) }
    pending = nil
  }

  // MARK: Preview

  /// The pieces of «Войдёт: N операций, M переводов; вложений K»: a key and its count each, in
  /// the order of the sentence. A part with nothing in it is left out, the first two are not.
  struct PreviewPart: Equatable {
    let key: String
    let count: Int
  }

  var previewParts: [PreviewPart] {
    guard let counts else { return [] }
    var parts = [
      PreviewPart(key: "privacy.copy.preview.operations", count: counts.operations),
      PreviewPart(key: "privacy.copy.preview.transfers", count: counts.transfers),
    ]
    if includeAttachments, counts.attachments > 0, format == .archive {
      parts.append(
        PreviewPart(key: "privacy.copy.preview.attachments", count: counts.attachments))
    }
    return parts
  }

  /// What the cuts take out, for the line «не войдёт»: operations and transfers.
  var leftOut: Int {
    guard let counts else { return 0 }
    return counts.operationsLeftOut + counts.transfersLeftOut
  }

  /// The hidden accounts exist and go into the copy: the dialog warns.
  var warnsAboutHidden: Bool {
    includeHidden && (counts?.hiddenAccounts ?? 0) > 0
  }

  // MARK: Dates

  static func date(of day: DateOnly, in calendar: CalendarContext) -> Date {
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = calendar.timeZone
    return gregorian.date(
      from: DateComponents(
        timeZone: calendar.timeZone, year: day.year, month: day.month, day: day.day, hour: 12))
      ?? Date()
  }
}
