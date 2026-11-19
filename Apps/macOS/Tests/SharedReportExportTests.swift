import AppCore
import CoreGraphics
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// «Отчёт для другого человека…»: the form starts on the previous month with every visible account,
/// a hidden account goes only when shown and ticked, the PDF has the pages the lines need and is
/// locked by its password, and a locked table reads back with it.
@MainActor
final class SharedReportExportTests: XCTestCase {
  private let calendar = CalendarContext.moscow
  private let today = DateOnly(year: 2026, month: 11, day: 15)
  private let card = PaymentMethod(name: "Card")
  private let secret = PaymentMethod(name: "Secret", hidden: true)
  private let food = CoreKit.Category(kind: .expense, name: "Food")
  private let salary = CoreKit.Category(kind: .income, name: "Salary")

  private func dataset(lines: Int) throws -> Dataset {
    var entries: [TransactionEntry] = []
    for index in 0..<lines {
      var draft = TransactionDraft(
        kind: .expense,
        occurredAt: calendar.noon(of: DateOnly(year: 2026, month: 10, day: 1 + index % 28)),
        amount: AmountE4(whole: Int64(100 + index)))
      draft.paymentMethodId = index.isMultiple(of: 5) ? secret.id : card.id
      draft.note = "Line \(index)"
      draft.parts = [PartDraft(categoryId: food.id, amount: AmountE4(whole: Int64(100 + index)))]
      entries.append(try draft.materialize())
    }
    return Dataset(
      entries: entries, categories: [food, salary], paymentMethods: [card, secret])
  }

  private func words(_ report: SharedReport) -> SharedReportWords {
    let environment = AppEnvironment()
    return SharedReportWords.make(environment, report: report)
  }

  func testTheFormStartsOnThePreviousMonthWithTheVisibleAccounts() throws {
    let model = SharedReportModel(dataset: try dataset(lines: 10), today: today, calendar: calendar)
    XCTAssertEqual(
      model.range,
      DayRange(DateOnly(year: 2026, month: 10, day: 1), DateOnly(year: 2026, month: 10, day: 31)))
    XCTAssertEqual(model.accounts, [card.id])
    XCTAssertEqual(model.categories, [food.id, salary.id])
    XCTAssertEqual(model.report.lines.count, 8, "the hidden account's two lines stay out")
    XCTAssertFalse(model.warnsAboutHidden)
    // Ticked while hidden from the list, it still does not go.
    model.accounts.insert(secret.id)
    XCTAssertEqual(model.report.lines.count, 8)
    model.showsHidden = true
    XCTAssertTrue(model.warnsAboutHidden)
    XCTAssertEqual(model.report.lines.count, 10)
  }

  func testSavingNeedsAPasswordTwiceWhileEncryptIsOn() throws {
    let model = SharedReportModel(dataset: try dataset(lines: 3), today: today, calendar: calendar)
    XCTAssertTrue(model.lock.encrypt, "«Зашифровать» is on every time")
    XCTAssertFalse(model.canSave)
    model.lock.password = "pw"
    model.lock.confirmation = "pw"
    XCTAssertTrue(model.canSave)
    model.categories = []
    XCTAssertFalse(model.canSave)
  }

  func testAPasswordOutsideLatinOneBlocksOnlyThePDF() throws {
    let model = SharedReportModel(dataset: try dataset(lines: 3), today: today, calendar: calendar)
    model.lock.password = "секрет"
    model.lock.confirmation = "секрет"
    XCTAssertTrue(model.pdfPasswordNeedsLatin, "the hint shows under the field")
    XCTAssertFalse(model.canSave, "a PDF cannot be locked with it")
    model.format = .csv
    XCTAssertFalse(model.pdfPasswordNeedsLatin)
    XCTAssertTrue(model.canSave, "the locked table takes any password")
    model.format = .pdf
    model.lock.password = "secret-1"
    model.lock.confirmation = "secret-1"
    XCTAssertFalse(model.pdfPasswordNeedsLatin)
    XCTAssertTrue(model.canSave)
    model.lock.encrypt = false
    model.lock.password = "секрет"
    XCTAssertFalse(model.pdfPasswordNeedsLatin, "no password is used when not encrypting")
  }

  func testThePDFHasThePagesOfItsLinesAndOpensOnlyWithThePassword() throws {
    let model = SharedReportModel(
      dataset: try dataset(lines: 120), today: today, calendar: calendar)
    model.showsHidden = true
    model.accounts.insert(secret.id)
    let report = model.report
    let pages = SharedReportPDF.pages(of: report)
    XCTAssertGreaterThan(pages.count, 1)
    let plain = try XCTUnwrap(SharedReportPDF.data(report, words: words(report)))
    let document = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: plain as CFData)!))
    XCTAssertEqual(document.numberOfPages, pages.count)
    XCTAssertFalse(document.isEncrypted)

    let locked = try XCTUnwrap(
      SharedReportPDF.data(report, words: words(report), password: "secret-1"))
    let closed = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: locked as CFData)!))
    XCTAssertTrue(closed.isEncrypted)
    XCTAssertFalse(closed.unlockWithPassword("wrong"))
    XCTAssertTrue(closed.unlockWithPassword("secret-1"))
    XCTAssertEqual(closed.numberOfPages, pages.count)
    XCTAssertFalse(locked.range(of: Data("Line 1".utf8)) != nil, "no text in the open")
  }

  /// The PDF format's own encryption takes a Latin-1 password only: the system refuses to start
  /// a locked document with a Cyrillic one, so the writer answers nil, never an open file.
  func testAPDFPasswordOutsideLatinOneIsRefusedNotWrittenOpen() throws {
    let model = SharedReportModel(dataset: try dataset(lines: 3), today: today, calendar: calendar)
    let report = model.report
    XCTAssertNil(SharedReportPDF.data(report, words: words(report), password: "секрет"))
    XCTAssertNotNil(SharedReportPDF.data(report, words: words(report), password: "secret-1"))
  }

  func testATableWithAPasswordGoesIntoTheLockedFileAndReadsBack() throws {
    let model = SharedReportModel(dataset: try dataset(lines: 4), today: today, calendar: calendar)
    model.format = .csv
    model.showsNotes = false
    model.lock.password = "pw"
    model.lock.confirmation = "pw"
    let report = model.report
    // Few rounds: the key derivation of the real count takes minutes in a debug build.
    let url = try model.write(
      words: words(report), appVersion: "2.16.0", schemaVersion: 30, iterations: 1_000)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    XCTAssertEqual(url.pathExtension, EncryptedExport.fileExtension)
    XCTAssertTrue(model.lock.password.isEmpty, "the password is forgotten once written")
    let files = try EncryptedExport.read(
      try Data(contentsOf: url), password: "pw", schemaVersion: 30)
    let text = String(decoding: try XCTUnwrap(files.first).data, as: UTF8.self)
    XCTAssertFalse(text.contains("Line"), "descriptions left out")
    XCTAssertTrue(url.lastPathComponent.hasPrefix("OhMyMoney 2026-10-01…2026-10-31"))
  }

  func testWithoutThePasswordTheTableIsAPlainCSV() throws {
    let model = SharedReportModel(dataset: try dataset(lines: 2), today: today, calendar: calendar)
    model.format = .csv
    model.lock.encrypt = false
    let report = model.report
    let url = try model.write(words: words(report), appVersion: "2.16.0", schemaVersion: 30)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    XCTAssertEqual(url.pathExtension, "csv")
    let rows = try CSVReader.rows(from: try Data(contentsOf: url))
    // Line 0 is on the hidden account and stays out: the header, its line, one category total.
    XCTAssertEqual(report.lines.count, 1)
    XCTAssertEqual(rows.count, 1 + report.lines.count + report.totals.count)
  }

  func testThePreviewWritesATemporaryPDFAndDiscardsIt() throws {
    let model = SharedReportModel(dataset: try dataset(lines: 4), today: today, calendar: calendar)
    model.lock.encrypt = false
    XCTAssertTrue(model.canPreview)

    let report = model.report
    let url = try model.writePreview(
      words: words(report), appVersion: "2.16.0", schemaVersion: 30)
    defer { SharedReportModel.discard(url) }

    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(url.pathExtension, "pdf")
    let data = try Data(contentsOf: url)
    XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
    let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
    XCTAssertNotNil(CGPDFDocument(provider))
    XCTAssertFalse(model.lock.encrypt)
    XCTAssertTrue(
      url.deletingLastPathComponent().lastPathComponent
        .hasPrefix(SharedReportModel.folderPrefix))

    SharedReportModel.discard(url)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testThePreviewIsNotLockedAndTheLockStaysOnForSaving() throws {
    let model = SharedReportModel(dataset: try dataset(lines: 3), today: today, calendar: calendar)
    model.lock.encrypt = true
    let url = try model.writePreview(
      words: words(model.report), appVersion: "2.16.0", schemaVersion: 30)
    defer { SharedReportModel.discard(url) }
    let data = try Data(contentsOf: url)
    let document = try XCTUnwrap(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
    XCTAssertFalse(document.isEncrypted)
    XCTAssertTrue(model.lock.encrypt)
    XCTAssertTrue(model.canPreview)
  }

  func testOnlyAPDFCanBePreviewed() throws {
    let model = SharedReportModel(dataset: try dataset(lines: 2), today: today, calendar: calendar)
    model.lock.encrypt = false
    model.format = .csv
    XCTAssertFalse(model.canPreview)
    XCTAssertThrowsError(
      try model.writePreview(
        words: words(model.report), appVersion: "2.16.0", schemaVersion: 30)
    ) { error in
      XCTAssertEqual(error as? SharedReportFailure, .previewRequiresPDF)
    }
  }

  func testPreviewButtonIsAccessibleAndHasWordsInRussianAndEnglish() throws {
    XCTAssertEqual(SharedReportView.previewButtonIdentifier, "sharedReport.preview.button")
    let key = "sharedReport.preview.action"
    for (code, expected) in [("ru", "Посмотреть"), ("en", "Preview")] {
      let bundle = try XCTUnwrap(
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)))
      XCTAssertEqual(
        bundle.localizedString(forKey: key, value: nil, table: "Utilities"), expected, code)
    }
  }
}
