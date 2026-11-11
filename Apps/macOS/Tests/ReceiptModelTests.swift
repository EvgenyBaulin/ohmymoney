import AppCore
import AppDatabase
import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest

@testable import OhMyMoney

/// «Чек по QR» against a real database: the proposal for a receipt, the write, one ⌘Z back.
/// Synthetic operations only.
@MainActor
final class ReceiptModelTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var dataset: Dataset?
  private var unknown: CoreKit.Category!

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-receipt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning, spending: environment.spendingRules,
      year: environment.yearPlan, subscriptions: environment.subscriptionBooks,
      savedViews: environment.savedViews, imports: environment.statementImports)
    // The starter categories already carry the system «Не помню» (one per role and kind).
    unknown = try XCTUnwrap(
      try environment.references?.category(systemRole: .unknown, kind: .expense))
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: Helpers

  private func reload() async throws {
    dataset = try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer)
      .load(version: 1)
  }

  private func model() async throws -> ReceiptModel {
    try await reload()
    return ReceiptModel(
      environment: environment, store: store, dataset: { [unowned self] in self.dataset })
  }

  /// A purchase of `rubles` on `day` of October 2026 at `hour`:00 Moscow time, noted `note`.
  @discardableResult
  private func purchase(
    _ note: String, rubles: Decimal, day: Int, hour: Int = 12
  ) throws
    -> TransactionEntry
  {
    let amount = try AmountE4(decimal: rubles)
    let id = UUID()
    let moment = CalendarContext.moscow.moment(
      DateOnly(year: 2026, month: 10, day: day), hour: hour, minute: 0)
    let entry = TransactionEntry(
      transaction: CoreKit.Transaction(
        id: id, kind: .expense, occurredAt: moment, amountE4: amount, note: note,
        timeZoneId: nil),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: unknown.id, categorySource: .manual, amountE4: amount)
      ])
    XCTAssertTrue(store.save(entry))
    return entry
  }

  private func live() throws -> [TransactionEntry] {
    let repository = try XCTUnwrap(environment.transactions)
    return try repository.entries(
      from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSinceNow: 86_400 * 3_650)
    ).filter { !$0.transaction.isDeleted }
  }

  // MARK: Tests

  func testASameSumOperationGetsTheTimeOfTheReceiptAndOneUndoTakesItBack() async throws {
    let coffee = try purchase("Кофе", rubles: 250, day: 29)
    try purchase("Хлеб", rubles: 40, day: 29)
    let model = try await model()
    model.read(payload: "t=20261029T183245&s=250.00&n=1")
    XCTAssertEqual(model.stage, .found)
    XCTAssertTrue(model.isSupplementing)
    XCTAssertEqual(model.chosenId, coffee.id)
    XCTAssertEqual(model.title(of: coffee.id), "Кофе")
    XCTAssertTrue(model.question(for: coffee.id).contains("Кофе"))
    XCTAssertTrue(model.question(for: coffee.id).contains("18:32"))

    XCTAssertTrue(model.confirm())
    XCTAssertEqual(model.stage, .done(.timeAdded("18:32")))
    let written = try XCTUnwrap(live().first { $0.id == coffee.id })
    let zone = CalendarContext.moscow
    XCTAssertEqual(zone.timeOfDay(written.transaction.occurredAt), TimeOfDay(hour: 18, minute: 32))
    XCTAssertEqual(
      zone.day(of: written.transaction.occurredAt), DateOnly(year: 2026, month: 10, day: 29))
    XCTAssertEqual(try live().count, 2, "nothing was added")

    store.undo()
    let back = try XCTUnwrap(live().first { $0.id == coffee.id })
    XCTAssertEqual(back.transaction.occurredAt, coffee.transaction.occurredAt)
  }

  func testTheNeighbouringDayCountsAndSeveralOperationsCanBeChosenFrom() async throws {
    let near = try purchase("Вчера", rubles: 99.5, day: 28)
    let other = try purchase("Сегодня", rubles: 99.5, day: 29)
    let model = try await model()
    model.read(payload: "t=20261029T1000&s=99,50&n=1")
    XCTAssertEqual(model.choices.map(\.id), [other.id, near.id])
    model.chosenId = near.id
    XCTAssertTrue(model.confirm())
    let written = try XCTUnwrap(live().first { $0.id == near.id })
    // The receipt's 10:00 on the 29th goes to the operation of the 28th: its day moves with it.
    XCTAssertEqual(
      CalendarContext.moscow.day(of: written.transaction.occurredAt),
      DateOnly(year: 2026, month: 10, day: 29))
  }

  /// A tip makes the owner's sum differ from the receipt's: the operation is offered, never
  /// chosen for the owner, and once picked it gets the time like an exact match.
  func testANearSumIsOfferedAndTakenOnlyWhenPicked() async throws {
    let dinner = try purchase("Ужин", rubles: 1_300, day: 29, hour: 19)
    let model = try await model()
    model.read(payload: "t=20261029T183245&s=1250.00&n=1")
    XCTAssertFalse(model.isSupplementing, "not taken for the receipt's own")
    XCTAssertEqual(model.similar.map(\.id), [dinner.id])
    XCTAssertNil(model.chosenId)

    model.useSimilar(dinner.id)
    XCTAssertTrue(model.isSupplementing)
    XCTAssertEqual(model.chosenId, dinner.id)
    XCTAssertTrue(model.confirm())
    let written = try XCTUnwrap(live().first { $0.id == dinner.id })
    XCTAssertEqual(
      CalendarContext.moscow.timeOfDay(written.transaction.occurredAt),
      TimeOfDay(hour: 18, minute: 32))
    XCTAssertEqual(
      written.transaction.amountE4, dinner.transaction.amountE4, "the sum is the owner's")
  }

  func testNothingFittingGivesANewOperationWithTheReceiptsFacts() async throws {
    try purchase("Другая сумма", rubles: 251, day: 29)
    let model = try await model()
    model.read(payload: "t=20261029T183200&s=250.00&n=1")
    XCTAssertFalse(model.isSupplementing)
    XCTAssertTrue(model.canCreate)
    XCTAssertTrue(model.newOperationText.contains("18:32"))
    XCTAssertTrue(model.confirm())
    XCTAssertEqual(model.stage, .done(.created))
    let all = try live()
    XCTAssertEqual(all.count, 2)
    let made = try XCTUnwrap(all.first { $0.transaction.note == nil })
    XCTAssertEqual(made.transaction.amountE4.raw, 2_500_000)
    XCTAssertEqual(made.transaction.kind, .expense)
    XCTAssertEqual(made.parts.first?.categoryId, unknown.id)
    XCTAssertEqual(
      environment.calendar.timeOfDay(made.transaction.occurredAt),
      TimeOfDay(hour: 18, minute: 32))
    store.undo()
    XCTAssertEqual(try live().count, 1)
  }

  func testTheOwnerCanSayItIsAnotherPurchaseAndGoBack() async throws {
    let coffee = try purchase("Кофе", rubles: 250, day: 29)
    let model = try await model()
    model.read(payload: "t=20261029T183200&s=250.00&n=1")
    model.makeNew()
    XCTAssertFalse(model.isSupplementing)
    XCTAssertTrue(model.canCreate)
    model.backToFound()
    XCTAssertTrue(model.isSupplementing)
    XCTAssertEqual(model.chosenId, coffee.id)
  }

  func testARefundReceiptIsNeverMadeUpOutOfThinAir() async throws {
    try purchase("Кофе", rubles: 250, day: 29)
    let model = try await model()
    model.read(payload: "t=20261029T183200&s=250.00&n=2")
    XCTAssertEqual(model.stage, .found)
    XCTAssertTrue(model.receipt?.isRefund == true)
    XCTAssertFalse(model.isSupplementing, "a purchase is not a refund")
    XCTAssertFalse(model.canCreate)
    XCTAssertFalse(model.confirm())
    XCTAssertEqual(try live().count, 1)
  }

  func testWithoutTheDontRememberCategoryNothingIsWrittenAndTheScreenSaysWhy() async throws {
    var archived = try XCTUnwrap(unknown)
    archived.archived = true
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(categories: [archived]))))
    let model = try await model()
    model.read(payload: "t=20261029T183200&s=250.00&n=1")
    XCTAssertFalse(model.confirm())
    XCTAssertEqual(model.stage, .failed(.noCategory))
    XCTAssertEqual(try live().count, 0)
  }

  func testRubbishAndOtherCodesChangeNothing() async throws {
    let model = try await model()
    model.read(payload: "https://example.com")
    XCTAssertEqual(model.stage, .notReceipt)
    model.pictureUnreadable()
    XCTAssertEqual(model.stage, .noCode)
    XCTAssertFalse(model.confirm())
    model.reset()
    XCTAssertEqual(model.stage, .waiting)
    XCTAssertEqual(try live().count, 0)
  }

  func testAnImageWithoutQRKeepsItsBytesForScreenshotSearch() async throws {
    let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 300))
    let data = try XCTUnwrap(
      CIContext().pngRepresentation(
        of: image, format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB()))
    let model = try await model()
    await model.read(data: data, filename: "screenshot.png")
    XCTAssertEqual(model.stage, .noCode)
    XCTAssertEqual(model.photo?.data, data)
    XCTAssertEqual(model.photo?.filename, "screenshot.png")
    XCTAssertTrue(try live().isEmpty)
  }

  func testAnOperationDeletedMeanwhileIsNotBroughtBack() async throws {
    let coffee = try purchase("Кофе", rubles: 250, day: 29)
    let model = try await model()
    model.read(payload: "t=20261029T183200&s=250.00&n=1")
    XCTAssertTrue(store.delete(id: coffee.id))
    XCTAssertFalse(model.confirm())
    XCTAssertEqual(model.stage, .failed(.gone))
    XCTAssertEqual(try live().count, 0)
  }

  // MARK: One receipt, one operation

  private static let receiptText =
    "t=20261029T183200&s=250.00&fn=9999078900001111&i=42&fp=123456789&n=1"
  /// The same receipt as its paper prints it: the document number and the sign with zeros.
  private static let paperText =
    "t=20261029T183200&s=250.00&fn=9999078900001111&i=0000000042&fp=0123456789&n=1"

  func testTheSameReceiptReadTwiceIsRecordedOnceAndShowsTheOperation() async throws {
    let first = try await model()
    first.read(payload: Self.receiptText)
    XCTAssertTrue(first.confirm())
    XCTAssertEqual(first.stage, .done(.created))
    let made = try XCTUnwrap(live().first)
    XCTAssertEqual(made.transaction.receipt?.fiscalDrive, "9999078900001111")
    XCTAssertEqual(made.transaction.receipt?.documentNumber, "42")
    XCTAssertEqual(made.transaction.receipt?.fiscalSign, "123456789")
    XCTAssertEqual(made.transaction.receipt?.operation, 1)

    // A second scan right away: the lists have not caught up yet, the database has.
    let second = ReceiptModel(
      environment: environment, store: store, dataset: { [unowned self] in self.dataset })
    second.read(payload: Self.paperText)
    XCTAssertEqual(second.stage, .alreadyRecorded(made.id))
    XCTAssertFalse(second.confirm(), "nothing is written for a receipt already recorded")
    XCTAssertTrue(second.alreadyRecordedText(made.id).contains("29"))
    XCTAssertEqual(try live().count, 1)
  }

  func testTheTimeOfAReceiptAndItsNumbersGoTogetherAndOneUndoTakesBothBack() async throws {
    let coffee = try purchase("Кофе", rubles: 250, day: 29)
    let model = try await model()
    model.read(payload: Self.receiptText)
    XCTAssertTrue(model.isSupplementing)
    XCTAssertTrue(model.confirm())
    let written = try XCTUnwrap(live().first { $0.id == coffee.id })
    XCTAssertEqual(written.transaction.receipt?.documentNumber, "42")

    let again = try await self.model()
    again.read(payload: Self.receiptText)
    XCTAssertEqual(again.stage, .alreadyRecorded(coffee.id))
    XCTAssertEqual(again.title(of: coffee.id), "Кофе")

    store.undo()
    XCTAssertNil(try XCTUnwrap(live().first { $0.id == coffee.id }).transaction.receipt)
  }

  func testAnOperationOfAnotherReceiptIsNotGivenThisOnesTime() async throws {
    let coffee = try purchase("Кофе", rubles: 250, day: 29)
    let first = try await model()
    first.read(payload: Self.receiptText)
    XCTAssertTrue(first.confirm())
    // The next document of the same bar, the same sum: another purchase.
    let next = try await model()
    next.read(
      payload: "t=20261029T190000&s=250.00&fn=9999078900001111&i=43&fp=555555555&n=1")
    XCTAssertEqual(next.stage, .found)
    XCTAssertFalse(next.isSupplementing, "the coffee already holds another receipt")
    XCTAssertTrue(next.canCreate)
    XCTAssertNotEqual(next.chosenId, coffee.id)
  }

  func testAReceiptWhoseOperationWasDeletedMayBeRecordedAgain() async throws {
    let first = try await model()
    first.read(payload: Self.receiptText)
    XCTAssertTrue(first.confirm())
    let made = try XCTUnwrap(live().first)
    XCTAssertTrue(store.delete(id: made.id))
    let again = try await model()
    again.read(payload: Self.receiptText)
    XCTAssertEqual(again.stage, .found)
    XCTAssertTrue(again.confirm())
    XCTAssertEqual(try live().count, 1)
  }

  func testARefundOfASaleNeverBecomesAPurchase() async throws {
    try purchase("Покупка", rubles: 1_000, day: 29)
    let model = try await model()
    for sum in ["600.00", "100.00"] {
      model.reset()
      model.read(payload: "t=20261029T2200&s=\(sum)&fn=9999000000000002&i=7&fp=111&n=2")
      XCTAssertEqual(model.stage, .found)
      XCTAssertFalse(model.isSupplementing)
      XCTAssertEqual(model.newDraft?.kind, .refund)
      XCTAssertTrue(model.similar.isEmpty, "the purchase of 1000 is not offered for a refund")
      XCTAssertFalse(model.confirm())
    }
    XCTAssertEqual(try live().map(\.transaction.kind), [.expense])
  }

  func testAPDFReceiptIsReadThroughTheSheetsModel() async throws {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(Self.receiptText.utf8)
    let output = try XCTUnwrap(filter.outputImage)
      .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
    let canvas = output.extent.insetBy(dx: -40, dy: -40)
    let code = try XCTUnwrap(
      CIContext().createCGImage(
        output.composited(over: CIImage(color: .white).cropped(to: canvas)), from: canvas))
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = try XCTUnwrap(
      CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
    for page in 1...2 {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(box)
      if page == 2 { context.draw(code, in: CGRect(x: 40, y: 40, width: 200, height: 200)) }
      context.endPDFPage()
    }
    context.closePDF()
    let model = try await model()
    await model.read(data: data as Data, filename: "Чек.pdf")
    XCTAssertEqual(model.stage, .found)
    XCTAssertEqual(model.receipt?.numbers?.documentNumber, "42")
  }

  // MARK: Printed text

  private let printedFiscal = [
    "КАССОВЫЙ ЧЕК", "Приход", "ИТОГ 250.00", "29.10.2026 18:32:45", "ФН 9960440300000000",
    "ФД 12345", "ФП 2345678901",
  ]

  func testPrintedFiscalReceiptIsProposedForCheckingAndSupplementsTheOperation() async throws {
    let coffee = try purchase("Кофе", rubles: 250, day: 29)
    let model = try await model()
    model.read(printedLines: printedFiscal)
    XCTAssertEqual(model.stage, .found)
    XCTAssertEqual(model.printedKind, .fiscal)
    XCTAssertEqual(model.checkNoteKey, "receipt.check.printed")
    XCTAssertFalse(model.numbersText.isEmpty)
    XCTAssertEqual(model.chosenId, coffee.id)
    XCTAssertTrue(model.confirm())
    let written = try XCTUnwrap(live().first { $0.id == coffee.id })
    XCTAssertEqual(written.transaction.receipt?.documentNumber, "12345")
    // The same receipt read from its QR code afterwards is already recorded.
    model.reset()
    model.read(payload: "t=20261029T183245&s=250.00&fn=9960440300000000&i=12345&fp=2345678901&n=1")
    XCTAssertEqual(model.stage, .alreadyRecorded(coffee.id))
  }

  func testQRCodeNeedsNoCheckNote() async throws {
    let model = try await model()
    model.read(payload: "t=20261029T1832&s=250.00&n=1")
    XCTAssertNil(model.checkNoteKey)
    XCTAssertNil(model.printedKind)
  }

  func testSlipGivesSumAndTimeWithoutANumberAndForeignCurrencyIsKept() async throws {
    let model = try await model()
    model.read(printedLines: [
      "TERMINAL 1", "VISA", "SALE", "AMOUNT AZN 23.50", "RRN 1", "29/10/2026 14:05",
    ])
    XCTAssertEqual(model.stage, .found)
    XCTAssertEqual(model.printedKind, .slip)
    XCTAssertEqual(model.checkNoteKey, "receipt.check.slip")
    XCTAssertEqual(model.receipt?.currency, CurrencyCode("AZN"))
    XCTAssertNil(model.receipt?.numbers)
    XCTAssertTrue(model.confirm())
    let created = try XCTUnwrap(live().first)
    XCTAssertEqual(created.transaction.currency, CurrencyCode("AZN"))
    XCTAssertEqual(created.transaction.amountE4.raw, 235_000)
    XCTAssertNil(created.transaction.receipt)
  }

  func testBillIsToldToWaitAndWritesNothing() async throws {
    let model = try await model()
    model.read(printedLines: ["Guest bill", "Total 120.00 AZN", "29.10.2026 20:10"])
    XCTAssertEqual(model.stage, .bill)
    XCTAssertNil(model.receipt)
    XCTAssertFalse(model.confirm())
    XCTAssertEqual(try live().count, 0)
  }

  func testUnreadableTextKeepsTheQRMessage() async throws {
    let model = try await model()
    model.read(printedLines: ["hello"], otherwise: .notReceipt)
    XCTAssertEqual(model.stage, .notReceipt)
    model.read(printedLines: [])
    XCTAssertEqual(model.stage, .noCode)
  }

  func testPrintedFiscalWithBadNumbersHasNoKey() async throws {
    let model = try await model()
    model.read(printedLines: ["КАССОВЫЙ ЧЕК", "ИТОГ 250.00", "29.10.2026 18:32", "ФН 123", "ФД 1", "ФП 2"])
    XCTAssertEqual(model.stage, .found)
    XCTAssertEqual(model.checkNoteKey, "receipt.check.numbers")
    XCTAssertNil(model.receipt?.numbers)
  }
}
