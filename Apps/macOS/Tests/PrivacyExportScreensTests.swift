import AppCore
import AppDatabase
import CoreKit
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// The dialog of «Экспорт копии…», the report of what the app keeps, the journal of openings and
/// the demonstration on training data: their models, their numbers and their words. The service
/// that writes the copy has its own tests (`ExportCopyServiceTests`).
final class PrivacyExportScreensTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 29)

  @MainActor
  private func model(
    attachments: Bool = true, format: ExportCopyRequest.Format = .archive
  ) -> ExportCopyModel {
    ExportCopyModel(
      today: today, calendar: .moscow, attachmentsByDefault: attachments, format: format)
  }

  // MARK: Validation

  @MainActor
  func testAPasswordIsRequiredAndTypedTwice() {
    let form = model()
    XCTAssertEqual(form.problem, .passwordEmpty)
    XCTAssertFalse(form.canSave)
    XCTAssertNil(form.request())
    // Nothing is scolded before the owner has typed anything.
    XCTAssertNil(form.problemShown())

    form.password = "correct horse"
    XCTAssertEqual(form.problem, .passwordMismatch)
    XCTAssertEqual(form.problemShown(), .passwordMismatch)
    XCTAssertNil(form.request())

    form.confirmation = "correct horse"
    XCTAssertNil(form.problem)
    XCTAssertTrue(form.canSave)
    XCTAssertNotNil(form.request())
  }

  @MainActor
  func testAnEmptyPeriodCannotBeSaved() {
    let form = model()
    form.password = "x"
    form.confirmation = "x"
    form.scope = .period
    form.periodStart = ExportCopyModel.date(
      of: DateOnly(year: 2026, month: 5, day: 10), in: .moscow)
    form.periodEnd = ExportCopyModel.date(of: DateOnly(year: 2026, month: 5, day: 1), in: .moscow)
    XCTAssertEqual(form.problem, .periodEmpty)
    XCTAssertNil(form.request())
    // The same days under the whole history are no problem: the period is not asked for.
    form.scope = .whole
    XCTAssertNil(form.problem)
  }

  @MainActor
  func testThePeriodStartsWithTheYearAndEndsToday() {
    let form = model()
    XCTAssertEqual(form.range, DayRange(DateOnly(year: 2026, month: 1, day: 1), today))
  }

  // MARK: The request

  @MainActor
  func testTheFormBecomesTheRequestItHandsToTheService() throws {
    let form = model(attachments: false)
    form.password = "pw"
    form.confirmation = "pw"
    var request = try XCTUnwrap(form.request())
    XCTAssertEqual(request.scope, .whole)
    XCTAssertFalse(request.anonymize)
    XCTAssertFalse(request.includeHidden, "hidden accounts stay out unless the owner says so")
    XCTAssertFalse(request.includeAttachments)
    XCTAssertEqual(request.format, .archive)
    XCTAssertEqual(request.password, "pw")

    form.scope = .period
    form.periodStart = ExportCopyModel.date(of: DateOnly(year: 2026, month: 3, day: 1), in: .moscow)
    form.periodEnd = ExportCopyModel.date(of: DateOnly(year: 2026, month: 3, day: 31), in: .moscow)
    form.anonymize = true
    form.includeHidden = true
    form.includeAttachments = true
    form.format = .csvOnly
    request = try XCTUnwrap(form.request())
    XCTAssertEqual(
      request.scope,
      .period(
        DayRange(DateOnly(year: 2026, month: 3, day: 1), DateOnly(year: 2026, month: 3, day: 31))))
    XCTAssertTrue(request.anonymize)
    XCTAssertTrue(request.includeHidden)
    XCTAssertTrue(request.includeAttachments)
    XCTAssertEqual(request.format, .csvOnly)
  }

  @MainActor
  func testTheAttachmentBoxStartsAsTheArchiveSettingSays() {
    XCTAssertTrue(model(attachments: true).includeAttachments)
    XCTAssertFalse(model(attachments: false).includeAttachments)
  }

  @MainActor
  func testACsvOnlyPresetStartsOnCsv() {
    XCTAssertEqual(model(format: .csvOnly).format, .csvOnly)
  }

  @MainActor
  func testTheFileIsNamedByTheDay() {
    XCTAssertEqual(
      model().fileName(today: today), "OhMyMoney-copy-2026-10-29.\(ArchiveService.fileExtension)")
  }

  // MARK: Preview

  @MainActor
  func testThePreviewNamesWhatWillGoIn() {
    let form = model(attachments: true)
    XCTAssertTrue(form.previewParts.isEmpty, "nothing is said before it is counted")
    form.counts = ExportCopyCounts(
      operations: 12, transfers: 3, operationsLeftOut: 4, transfersLeftOut: 1, hiddenAccounts: 1,
      attachments: 5)
    XCTAssertEqual(
      form.previewParts.map(\.count), [12, 3, 5])
    XCTAssertEqual(form.leftOut, 5)

    form.includeAttachments = false
    XCTAssertEqual(form.previewParts.map(\.count), [12, 3])
    form.includeAttachments = true
    form.format = .csvOnly
    XCTAssertEqual(form.previewParts.map(\.count), [12, 3], "CSV files carry no attachments")
  }

  @MainActor
  func testTheHiddenWarningShowsOnlyWhenHiddenAccountsGoIn() {
    let form = model()
    form.counts = ExportCopyCounts(hiddenAccounts: 2)
    XCTAssertFalse(form.warnsAboutHidden)
    form.includeHidden = true
    XCTAssertTrue(form.warnsAboutHidden)
    form.counts = ExportCopyCounts(hiddenAccounts: 0)
    XCTAssertFalse(form.warnsAboutHidden)
  }

  func testFailuresMapToTheirWords() {
    XCTAssertEqual(ExportCopyModel.Failure(ExportCopyError.passwordMissing), .passwordMissing)
    XCTAssertEqual(ExportCopyModel.Failure(ExportCopyError.anonymizerMissing), .anonymizerMissing)
    XCTAssertEqual(ExportCopyModel.Failure(ExportCopyError.hiddenAccountInUse), .hiddenAccountInUse)
    XCTAssertEqual(ExportCopyModel.Failure(ExportCopyError.periodEmpty), .periodEmpty)
    XCTAssertEqual(ExportCopyModel.Failure(CocoaError(.fileWriteOutOfSpace)), .other)
  }

  // MARK: Counting on a database

  private func seededStack() throws -> (stack: DatabaseStack, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-preview-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    let shown = PaymentMethod(name: "Дебетовая", isDefault: true)
    let other = PaymentMethod(name: "Запасная")
    let secret = PaymentMethod(name: "Сейф", hidden: true)
    let references = ReferenceRepository(writer: stack.writer)
    for account in [shown, other, secret] { try references.save(account) }
    func spend(_ account: PaymentMethod, month: Int, day: Int) throws {
      let moment = CalendarContext.moscow.noon(
        of: DateOnly(year: 2026, month: month, day: day))
      let transaction = CoreKit.Transaction(
        kind: .expense, occurredAt: moment, amountE4: AmountE4(whole: 100),
        paymentMethodId: account.id)
      let part = TransactionPart(transactionId: transaction.id, amountE4: AmountE4(whole: 100))
      try TransactionRepository(writer: stack.writer).insert([
        TransactionEntry(transaction: transaction, parts: [part])
      ])
    }
    try spend(shown, month: 3, day: 10)
    try spend(shown, month: 9, day: 10)
    try spend(secret, month: 9, day: 11)
    try spend(other, month: 9, day: 12)
    let toSecret = Transfer(
      occurredAt: CalendarContext.moscow.noon(of: DateOnly(year: 2026, month: 9, day: 14)),
      fromAccountId: shown.id, fromCurrency: .rub, fromAmountE4: AmountE4(whole: 70),
      toAccountId: secret.id, toCurrency: .rub, toAmountE4: AmountE4(whole: 70))
    let between = Transfer(
      occurredAt: CalendarContext.moscow.noon(of: DateOnly(year: 2026, month: 9, day: 13)),
      fromAccountId: shown.id, fromCurrency: .rub, fromAmountE4: AmountE4(whole: 50),
      toAccountId: other.id, toCurrency: .rub, toAmountE4: AmountE4(whole: 50))
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(transfers: [toSecret, between])))
    return (stack, directory)
  }

  func testThePreviewCountsWhatTheCutsKeep() throws {
    let (stack, directory) = try seededStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let previewer = ExportCopyPreviewer(writer: stack.writer)

    let whole = try previewer.counts(
      for: ExportCopyRequest(includeHidden: true, password: "x"))
    XCTAssertEqual(whole.operations, 4)
    XCTAssertEqual(whole.transfers, 2)
    XCTAssertEqual(whole.accounts, 3)
    XCTAssertEqual(whole.hiddenAccounts, 1)
    XCTAssertEqual(whole.operationsLeftOut, 0)

    let withoutHidden = try previewer.counts(
      for: ExportCopyRequest(includeHidden: false, password: "x"))
    XCTAssertEqual(withoutHidden.operations, 3)
    XCTAssertEqual(withoutHidden.transfers, 1)
    XCTAssertEqual(withoutHidden.accounts, 2)
    XCTAssertEqual(withoutHidden.operationsLeftOut, 1)
    XCTAssertEqual(withoutHidden.transfersLeftOut, 1)

    let september = DayRange(
      DateOnly(year: 2026, month: 9, day: 1), DateOnly(year: 2026, month: 9, day: 30))
    let period = try previewer.counts(
      for: ExportCopyRequest(scope: .period(september), includeHidden: true, password: "x"))
    XCTAssertEqual(period.operations, 3)
    XCTAssertEqual(period.operationsLeftOut, 1)
    XCTAssertEqual(period.transfers, 2)
  }

  func testTheCensusCountsRowsOfEveryTableAndSkipsTheExchangeTables() throws {
    let (stack, directory) = try seededStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rows = try StorageCensus.tableRows(writer: stack.writer)
    XCTAssertEqual(rows["transactions"], 4)
    XCTAssertEqual(rows["transfers"], 2)
    XCTAssertEqual(rows["payment_methods"], 3)
    XCTAssertTrue(rows.keys.allSatisfy { !$0.hasPrefix("sync_") && !$0.hasPrefix("sqlite_") })
  }

  // MARK: What the app keeps

  func testTheFactsAreBuiltFromTheFilesAndTheRows() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-storage-tests-\(UUID().uuidString)")
    let backups = directory.appendingPathComponent("Backups")
    try FileManager.default.createDirectory(
      at: backups.appendingPathComponent("readable"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("finance.sqlite")
    try Data(count: 3_000).write(to: database)
    try Data(count: 500).write(to: URL(fileURLWithPath: database.path + "-wal"))
    try Data(count: 2_000).write(to: backups.appendingPathComponent("a.sqlite"))
    try Data(count: 1_000).write(to: backups.appendingPathComponent("readable/a.csv"))
    let journal = directory.appendingPathComponent("privacy-journal.jsonl")
    try Data(count: 120).write(to: journal)
    let files = [
      AttachedFile(
        ownerKind: .transaction, ownerId: UUID(), contentHash: String(repeating: "a", count: 64),
        fileName: "a.jpg", byteSize: 4_000),
      AttachedFile(
        ownerKind: .asset, ownerId: UUID(), contentHash: String(repeating: "b", count: 64),
        fileName: "b.pdf", byteSize: 6_000),
    ]

    let facts = StorageFactsReader.facts(
      tableRows: ["transactions": 40, "people": 0, "places": 2], databaseURL: database,
      attachments: files, backupCount: 1, backupFolder: backups, journalURL: journal,
      journalCount: 6)
    XCTAssertEqual(facts.databaseBytes, 3_500)
    XCTAssertEqual(facts.attachmentCount, 2)
    XCTAssertEqual(facts.attachmentBytes, 10_000)
    XCTAssertEqual(facts.backupCount, 1)
    XCTAssertEqual(facts.backupBytes, 3_000, "a folder counts everything under it")
    XCTAssertEqual(facts.journalCount, 6)
    XCTAssertEqual(facts.journalBytes, 120)

    let report = StorageReport(facts)
    XCTAssertEqual(report.totalRecords, 42)
    XCTAssertEqual(report.totalBytes, 3_500 + 10_000 + 3_000 + 120)
    XCTAssertEqual(
      report.tables.map(\.name), ["transactions", "places"], "empty tables are left out")
    XCTAssertEqual(report.lines.map(\.section), StorageReport.Section.allCases)
  }

  func testAMissingFileWeighsNothing() {
    let nothing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
    XCTAssertEqual(StorageFactsReader.bytes(ofItemAt: nothing), 0)
    let facts = StorageFactsReader.facts(
      tableRows: [:], databaseURL: nothing, attachments: [], backupCount: 0, backupFolder: nothing,
      journalURL: nil, journalCount: 0)
    XCTAssertEqual(facts, StorageFacts())
  }

  // MARK: The journal

  @MainActor
  func testEveryJournalEventHasWordsAndSoDoTheTerms() {
    let events: [PrivacyJournalEntry.Event] = [
      .opened, .unlocked(method: .touchID), .unlocked(method: .password), .locked, .hiddenShown,
      .exportedCopy, .readOnlyOn, .readOnlyOff,
    ]
    let keys = events.map(PrivacyJournalText.key(for:))
    XCTAssertEqual(Set(keys).count, events.count, "two events never share a sentence")
    for key in keys { assertWords(key) }
  }

  func testTheTermsListsTheCurrentValueToo() {
    XCTAssertEqual(PrivacyJournalText.choices(including: 365), PrivacyJournalText.terms)
    XCTAssertEqual(
      PrivacyJournalText.choices(including: 100), [30, 90, 100, 180, 365, 730, 1825])
  }

  // MARK: Training data

  @MainActor
  func testTrainingDataAreTheTutorialSetAndTheWayBackIsTheRealBooks() {
    XCTAssertTrue(DemoDataMode.isOn(.learn))
    XCTAssertFalse(DemoDataMode.isOn(nil))
    XCTAssertFalse(DemoDataMode.isOn(.sample))
    XCTAssertEqual(DemoDataMode.target(entering: true), .learn)
    XCTAssertNil(DemoDataMode.target(entering: false))
  }

  @MainActor
  func testEnteringAndLeavingAskForTheRelaunchOfTheRightSet() {
    let before = AppRestart.askedInTestHost
    DemoDataMode.enter()
    XCTAssertEqual(AppRestart.askedInTestHost, before + 1)
    XCTAssertEqual(RelaunchCarry.next, ["--data-set", "learn"])
    DemoDataMode.leave()
    XCTAssertEqual(AppRestart.askedInTestHost, before + 2)
    XCTAssertEqual(RelaunchCarry.next, [], "the real books carry no data set")
    RelaunchCarry.next = nil
  }

  // MARK: Words

  /// Every sentence of the screens has words in both languages.
  @MainActor
  func testEveryPrivacyKeyHasWordsInBothLanguages() {
    let keys =
      [
        "privacy.menu.exportCopy", "privacy.menu.storage", "privacy.export.lock",
        "privacy.copy.title", "privacy.copy.password", "privacy.copy.passwordAgain",
        "privacy.copy.showPassword", "privacy.copy.passwordHint", "privacy.copy.scope",
        "privacy.copy.scope.whole", "privacy.copy.scope.period", "privacy.copy.from",
        "privacy.copy.to", "privacy.copy.anonymize", "privacy.copy.anonymize.hint",
        "privacy.copy.hidden", "privacy.copy.hidden.hint", "privacy.copy.hidden.warning",
        "privacy.copy.attachments", "privacy.copy.format", "privacy.copy.format.archive",
        "privacy.copy.format.csv", "privacy.copy.preview.lead", "privacy.copy.preview.counting",
        "privacy.copy.preview.operations", "privacy.copy.preview.transfers",
        "privacy.copy.preview.attachments", "privacy.copy.leftOut", "privacy.copy.originalStays",
        "privacy.copy.working", "privacy.copy.save", "privacy.copy.done",
        "privacy.copy.done.operations", "privacy.copy.done.transfers",
        "privacy.copy.done.attachments", "privacy.copy.done.locked",
        "privacy.copy.problem.passwordEmpty", "privacy.copy.problem.passwordMismatch",
        "privacy.copy.problem.periodEmpty", "privacy.lockedFile.title", "privacy.lockedFile.body",
        "privacy.storage.title", "privacy.storage.footer", "privacy.storage.tables",
        "privacy.storage.total", "privacy.storage.count.records", "privacy.storage.count.files",
        "privacy.storage.count.copies", "privacy.storage.count.lines", "privacy.storage.where",
        "privacy.storage.where.data", "privacy.storage.where.backups",
        "privacy.storage.where.mirror", "privacy.storage.where.footer", "privacy.journal.title",
        "privacy.journal.keep", "privacy.journal.term", "privacy.journal.footer",
        "privacy.journal.empty", "privacy.journal.clear", "privacy.journal.clear.title",
        "privacy.journal.clear.action", "privacy.journal.clear.body", "privacy.settings.screen",
        "privacy.settings.autoHide", "privacy.settings.autoHide.hint", "privacy.settings.readOnly",
        "privacy.settings.readOnly.hint", "privacy.settings.lock", "privacy.settings.knows",
        "privacy.settings.journal", "privacy.settings.storage", "privacy.settings.knows.footer",
        "privacy.settings.hand", "privacy.settings.exportCopy", "privacy.settings.demo",
        "privacy.settings.hand.footer", "privacy.demo.banner", "privacy.demo.banner.hint",
        "privacy.demo.back", "privacy.demo.confirm.title", "privacy.demo.confirm.action",
        "privacy.demo.confirm.body",
      ]
      + ExportCopyModel.Failure.allKeys
      + StorageReport.Section.allCases.map(\.rawValue)
      + StorageSize.Unit.allCases.map(\.rawValue) + [StorageReport.totalKey]
    for key in keys { assertWords(key) }

    let words = SettingsSearch.catalogWords()
    for code in SettingsSearch.languages {
      XCTAssertNotEqual(
        words(.settings("settings.tab.privacy"), code), "settings.tab.privacy", code)
    }
  }

  /// The privacy section is found by its name and by its captions, and holds a symbol and a
  /// colour of its own.
  @MainActor
  func testThePrivacySectionIsInTheSettings() {
    let words = SettingsSearch.catalogWords()
    XCTAssertTrue(SettingsSection.allCases.contains(.privacy))
    for code in SettingsSearch.languages {
      for caption in SettingsSection.privacy.index {
        let found = SettingsSearch.find(words(caption, code), words: words)
        XCTAssertTrue(found.contains { $0.section == .privacy }, "\(caption.key) \(code)")
      }
    }
    XCTAssertEqual(SettingsSection.privacy.titleKey, "settings.tab.privacy")
  }

  @MainActor
  private func assertWords(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
    let words = SettingsSearch.catalogWords()
    for code in SettingsSearch.languages {
      let text = words(.privacyExport(key), code)
      XCTAssertFalse(text.isEmpty || text == key, "\(key) \(code)", file: file, line: line)
    }
  }
}

extension ExportCopyModel.Failure {
  /// Every failure's sentence key.
  static var allKeys: [String] {
    [Self.passwordMissing, .anonymizerMissing, .hiddenAccountInUse, .periodEmpty, .other].map(\.key)
  }
}
