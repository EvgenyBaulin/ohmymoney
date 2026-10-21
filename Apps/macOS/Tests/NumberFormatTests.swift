import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Numbers are written one way in both languages — a comma between the thousands, a point
/// before the fraction — so a figure read on the screen is the figure typed back. Only the
/// words around a number follow the language: «млн» or «M», the space before «%».
final class NumberDisplayTests: XCTestCase {
  private let russian = MoneyFormatter(locale: Locale(identifier: "ru"))
  private let english = MoneyFormatter(locale: Locale(identifier: "en"))
  private let space = "\u{00A0}"
  private let minus = "\u{2212}"

  func testAmountsAreTheSameInBothLanguages() {
    for money in [russian, english] {
      XCTAssertEqual(money.exact(AmountE4(raw: 12_345_000)), "1,234.50\(space)₽")
      XCTAssertEqual(money.exact(AmountE4(raw: 46_250), currency: .usd), "4.625\(space)$")
      XCTAssertEqual(money.exact(AmountE4(whole: 1_234_567)), "1,234,567\(space)₽")
      XCTAssertEqual(money.exact(AmountE4(whole: -250)), "\(minus)250\(space)₽")
      XCTAssertEqual(money.rounded(AmountE4(raw: 12_345_000)), "1,235\(space)₽")
      XCTAssertEqual(money.rubles(12_400), "12,400\(space)₽")
      XCTAssertEqual(money.signedRubles(-3_400), "\(minus)3,400\(space)₽")
      XCTAssertEqual(money.count(1_250), "1,250")
      XCTAssertEqual(money.count(999), "999")
      XCTAssertEqual(money.axis(999_999), "999,999\(space)₽")
    }
  }

  func testTheWordsAroundANumberFollowTheLanguage() {
    XCTAssertEqual(russian.axis(1_234_567), "1.2\(space)млн\(space)₽")
    XCTAssertEqual(english.axis(1_234_567), "1.2M\(space)₽")
    XCTAssertEqual(russian.axis(2_500_000_000), "2.5\(space)млрд\(space)₽")
    XCTAssertEqual(english.axis(2_500_000_000), "2.5B\(space)₽")
    XCTAssertEqual(russian.percent(basisPoints: 3_333), "33.3\(space)%")
    XCTAssertEqual(english.percent(basisPoints: 3_333), "33.3%")
    XCTAssertEqual(russian.signedPercent(basisPoints: 834), "+8.3\(space)%")
    XCTAssertEqual(english.signedPercent(basisPoints: -5_340), "\(minus)53.4%")
    XCTAssertEqual(russian.percent(basisPoints: 123_456, fractionDigits: 0), "1,235\(space)%")
  }

  /// A rate keeps the decimal point in both languages; a share of a debt is a plain number.
  func testRatesAndSharesAreWrittenWithAPoint() {
    for money in [russian, english] {
      XCTAssertEqual(money.rate(Decimal(string: "83.1250")!), "83.125")
      XCTAssertEqual(money.rate(Decimal(string: "81.43215")!), "81.4322")
      XCTAssertEqual(money.rate(Decimal(string: "12.5")!), "12.5")
      XCTAssertEqual(money.number(Decimal(string: "0.5")!), "0.5")
      XCTAssertEqual(money.number(Decimal(1) / Decimal(3)), "0.3333")
    }
  }
}

/// Counts in a sentence — «Удалить 1,250 операций?» — are grouped like every other number;
/// the plural form is still the one of the count.
@MainActor
final class CountTextTests: XCTestCase {
  func testCountsInASentenceAreGroupedInBothLanguages() {
    let environment = AppEnvironment()
    let language = environment.language
    language.choice = .russian
    XCTAssertEqual(
      language.format("bulk.confirmDelete", table: "Transactions", counts: 1_250),
      "Удалить 1,250 операций?")
    XCTAssertEqual(
      language.format("bulk.confirmDelete", table: "Transactions", counts: 1_251),
      "Удалить 1,251 операцию?")
    XCTAssertEqual(
      language.format("bulk.confirmDelete", table: "Transactions", counts: 3),
      "Удалить 3 операции?")
    XCTAssertEqual(
      environment.format("templates.used", table: "Settings", counts: 1_002),
      "использован 1,002 раза")
    XCTAssertEqual(
      language.format("report.contents.database", table: "Settings", counts: 12, 25_000),
      "Таблиц: 12, записей: 25,000")
    XCTAssertEqual(
      AnalyticsText.format("analytics.purchases", environment, count: 1_250), "1,250 покупок")

    language.choice = .english
    XCTAssertEqual(
      language.format("bulk.confirmDelete", table: "Transactions", counts: 1_250),
      "Delete 1,250 operations?")
    XCTAssertEqual(
      language.format("bulk.confirmDelete", table: "Transactions", counts: 1),
      "Delete 1 operation?")
    XCTAssertEqual(
      language.format("transactions.olderHidden", table: "Transactions", counts: 20_000),
      "20,000 earlier operations are not shown yet")
  }
}

/// The fields of amounts: typed as the owner likes, written back the one way on Enter, Tab or
/// leaving the field, and always read back as the amount they show.
@MainActor
final class AmountFieldTextTests: XCTestCase {
  /// The trap of the old fields: an equal split of 37 in eight is 4.625 per part. A Russian
  /// field wrote it «4,625», and a single comma before three digits groups thousands in a
  /// typed amount, so the field would have read it back as 4 625.
  func testAnEqualSplitReadsBackAsItself() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let model = EntryDraftModel(
      references: ReferenceRepository(writer: stack.writer),
      transactions: TransactionRepository(writer: stack.writer), calendar: .utc)
    model.setTotal(AmountE4(whole: 37))
    model.splitEqually(into: 8)
    let share = try XCTUnwrap(model.draft.parts.first?.amount)
    XCTAssertEqual(share, AmountE4(raw: 46_250))

    let shown = AmountField.text(for: share)
    XCTAssertEqual(shown, "4.625")
    XCTAssertEqual(AmountField.amount(from: shown), share)
    XCTAssertEqual(AmountField.settledText(shown), shown, "settling moved a share it shows")
    // What the old field wrote is thousands now.
    XCTAssertEqual(AmountField.amount(from: "4,625"), AmountE4(whole: 4_625))
  }

  func testTheTextIsWrittenBackOnceTheOwnerIsDone() {
    XCTAssertEqual(AmountField.settledText("1500,5"), "1,500.50")
    XCTAssertEqual(AmountField.settledText("1,500"), "1,500")
    XCTAssertEqual(AmountField.settledText("1.500"), "1.50")
    XCTAssertEqual(AmountField.settledText("1 234,56"), "1,234.56")
    XCTAssertEqual(AmountField.settledText("2,5k"), "2,500")
    // A formula becomes what it comes to; the total of an operation keeps the formula itself.
    XCTAssertEqual(AmountField.settledText("(1000+600)/2"), "800")
    XCTAssertEqual(AmountField.settledText("1,500+2,50"), "1,502.50")
    // Nothing typed, or text that does not read yet: left for the owner to finish.
    XCTAssertNil(AmountField.settledText(""))
    XCTAssertNil(AmountField.settledText("1500×"))
    XCTAssertNil(AmountField.settledText("abc"))
    // Written back, the text reads as the same amount.
    for typed in ["1500,5", "0,500", "12,345", "1.234,56", "(1000+600)/2", "3000÷4"] {
      let settled = AmountField.settledText(typed)
      XCTAssertNotNil(settled, typed)
      XCTAssertEqual(
        settled.flatMap(AmountField.amount(from:)), AmountField.amount(from: typed), typed)
    }
  }

  /// Two hundred nines are not an amount at all, never zero.
  func testANumberTooLongIsNoAmount() {
    let nines = String(repeating: "9", count: 200)
    XCTAssertNil(AmountField.amount(from: nines))
    XCTAssertNil(AmountField.settledText(nines))
  }

  /// «Received» of money back: text that does not read is no amount to record, whatever the
  /// field was showing before it — the button is off until the text reads again.
  func testMoneyBackThatDoesNotReadCannotBeSaved() {
    let anya = UUID()
    let part = OwedPart(
      partId: UUID(), transactionId: UUID(),
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 12)),
      debtorPersonId: anya, categoryId: UUID(), forWhom: .friends, forPersonId: nil,
      eventId: nil, amountE4: AmountE4(whole: 1_700), amountRubE4: AmountE4(whole: 1_700),
      currency: .rub, rateProvisional: false, note: "dinner")
    let given = AmountE4(whole: 1_700)
    XCTAssertEqual(ReimbursementSheet.received(given, reads: true), given)
    XCTAssertNil(ReimbursementSheet.received(given, reads: false))
    XCTAssertNil(ReimbursementSheet.received(.zero, reads: true))
    XCTAssertTrue(
      ReimbursementSheet.canRecord(
        closing: [part], chosen: anya, received: ReimbursementSheet.received(given, reads: true)))
    XCTAssertFalse(
      ReimbursementSheet.canRecord(
        closing: [part], chosen: anya, received: ReimbursementSheet.received(given, reads: false)))
  }

  /// A rate keeps the rule of rates — a lone comma is decimal — and is written back with a
  /// point once the owner is done.
  func testARateIsWrittenBackWithAPoint() {
    let rate = Decimal(string: "81.4")!
    XCTAssertEqual(RateField.settledText("81,40", rate: rate), "81.4")
    XCTAssertEqual(RateField.settledText("81,4", rate: rate), "81.4")
    XCTAssertEqual(RateField.settledText("83,125", rate: Decimal(string: "83.125")!), "83.125")
    // Text that is not the rate stays as it is; an empty field stays empty.
    XCTAssertEqual(RateField.settledText("81,", rate: rate), "81,")
    XCTAssertEqual(RateField.settledText("", rate: nil), "")
  }

  /// A formula the line typed is kept with the operation, its numbers written the way the app
  /// writes them.
  func testAFormulaOfTheLineIsKeptCanonically() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let model = EntryDraftModel(
      references: ReferenceRepository(writer: stack.writer),
      transactions: TransactionRepository(writer: stack.writer), calendar: .utc)
    let parser = InputLineParser(vocabulary: .empty, calendar: .utc)
    let today = DateOnly(year: 2026, month: 9, day: 18)
    let parsed = parser.parse("такси 1500,5+2", today: today)
    let amount = try AmountE4(decimal: try XCTUnwrap(parsed.amount))
    model.apply(parsed, amount: amount, today: today)
    XCTAssertEqual(model.draft.amount, AmountE4(raw: 15_025_000))
    XCTAssertEqual(model.draft.amountExpression, "1,500.5+2")
    XCTAssertEqual(parsed.amountToPreview, "1500,5+2")
  }
}

/// A formula saved before a lone comma could group thousands, and still coming to its amount,
/// survives the check on open as it was written. Saved again with the operation, its numbers
/// are written the way the app writes them.
@MainActor
final class OldFormulaEditTests: XCTestCase {
  private static func entry() -> TransactionEntry {
    let moment = Date(timeIntervalSince1970: 1_789_000_000)
    let amount = AmountE4(raw: 35_000)
    let transaction = Transaction(
      kind: .expense, occurredAt: moment, amountE4: amount, amountExpr: "1,5+2",
      amountRubE4: amount, note: "taxi", createdAt: moment, updatedAt: moment)
    let part = TransactionPart(
      transactionId: transaction.id, amountE4: amount, amountRubE4: amount)
    return TransactionEntry(transaction: transaction, parts: [part])
  }

  func testAnEditSavesTheOldFormulaCanonically() throws {
    let entry = Self.entry()
    var draft = TransactionDraft(entry: entry)
    draft.note = "taxi home"
    let edited = try TransactionEditorModel.edited(entry, with: draft, rublesConverter: { $0 })
    XCTAssertEqual(edited.transaction.amountExpr, "1.5+2")
    XCTAssertEqual(edited.transaction.amountE4, AmountE4(raw: 35_000))
  }

  /// The field writes back the amount it shows as soon as the operation is opened. That is not
  /// an edit: the draft stays as it was, so an operation merely looked at has nothing to save.
  func testOpeningAnOldFormulaIsNotAnEdit() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let model = EntryDraftModel(
      references: ReferenceRepository(writer: stack.writer),
      transactions: TransactionRepository(writer: stack.writer), calendar: .utc)
    model.draft = TransactionDraft(entry: Self.entry())
    let opened = model.draft
    model.setTotal(AmountE4(raw: 35_000), typed: "3.50")
    XCTAssertEqual(model.draft, opened)
    XCTAssertEqual(model.draft.amountExpression, "1,5+2")
  }
}

/// The fields themselves, in a window: the text stays as typed while the owner types, and Enter
/// or leaving the field writes it back the one way.
@MainActor
final class AmountFieldRewriteTests: XCTestCase {
  private final class Box { var amounts: [AmountE4] = [.zero, .zero] }

  private struct TwoFields: View {
    let box: Box
    @State private var first: AmountE4
    @State private var second: AmountE4 = .zero

    init(box: Box, first: AmountE4) {
      self.box = box
      _first = State(initialValue: first)
    }

    var body: some View {
      VStack {
        AmountField(amount: $first)
        AmountField(amount: $second)
      }
      .onChange(of: first) { _, value in box.amounts[0] = value }
      .onChange(of: second) { _, value in box.amounts[1] = value }
    }
  }

  private func textFields(in view: NSView) -> [NSTextField] {
    view.subviews.flatMap { subview -> [NSTextField] in
      ((subview as? NSTextField).map { [$0] } ?? []) + textFields(in: subview)
    }
  }

  private func settle(_ seconds: TimeInterval = 0.2) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  private func show(_ first: AmountE4 = .zero, box: Box) throws -> (NSWindow, [NSTextField]) {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: TwoFields(box: box, first: first).appDependencies(.forTests(AppEnvironment())))
    window.makeKeyAndOrderFront(nil)
    settle(0.3)
    let fields = textFields(in: try XCTUnwrap(window.contentView)).filter(\.isEditable)
    XCTAssertEqual(fields.count, 2)
    return (window, fields)
  }

  func testEnterAndLeavingTheFieldWriteTheTextBack() throws {
    let box = Box()
    let (window, fields) = try show(box: box)
    defer {
      window.contentView = nil
      window.close()
    }

    XCTAssertTrue(window.makeFirstResponder(fields[0]))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
    editor.insertText("1500,5", replacementRange: editor.selectedRange())
    settle()
    // Typing is not rewritten under the cursor.
    XCTAssertEqual(editor.string, "1500,5")
    XCTAssertEqual(box.amounts[0], AmountE4(raw: 15_005_000))
    editor.insertNewline(nil)
    settle()
    XCTAssertEqual(fields[0].stringValue, "1,500.50")
    XCTAssertEqual(box.amounts[0], AmountE4(raw: 15_005_000))

    XCTAssertTrue(window.makeFirstResponder(fields[1]))
    let second = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
    second.insertText("(1000+600)/2", replacementRange: second.selectedRange())
    settle()
    // Leaving the field, as Tab does.
    XCTAssertTrue(window.makeFirstResponder(nil))
    settle()
    XCTAssertEqual(fields[1].stringValue, "800")
    XCTAssertEqual(box.amounts[1], AmountE4(whole: 800))
  }

  private final class ReadsBox {
    var reads: [Bool] = []
    var told: [AmountE4] = []
  }

  /// A field that tells whether its text reads, and the amounts it is told.
  private struct ReadingField: View {
    let box: ReadsBox
    @State private var amount = AmountE4(whole: 1_700)
    @State private var reads = true

    var body: some View {
      AmountField(
        amount: $amount, reads: $reads,
        onTyped: { value, _ in
          box.told.append(value)
          amount = value
        }
      )
      .onChange(of: reads) { _, value in box.reads.append(value) }
    }
  }

  /// Text that does not read — «1700+», «abc» — leaves the amount as it was, so the field says
  /// so: the form around it must not save the amount the text no longer shows.
  func testTheFieldSaysWhenItsTextDoesNotRead() throws {
    let box = ReadsBox()
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: ReadingField(box: box).appDependencies(.forTests(AppEnvironment())))
    window.makeKeyAndOrderFront(nil)
    defer {
      window.contentView = nil
      window.close()
    }
    settle(0.3)
    let field = try XCTUnwrap(
      textFields(in: try XCTUnwrap(window.contentView)).first(where: \.isEditable))
    XCTAssertEqual(field.stringValue, "1,700")
    // Showing the amount it was given is not typing.
    box.told = []
    box.reads = []
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
    editor.moveToEndOfDocument(nil)
    editor.insertText("+", replacementRange: editor.selectedRange())
    settle()
    XCTAssertEqual(box.reads, [false])
    XCTAssertEqual(box.told, [], "half-typed text told an amount")
    editor.insertText("300", replacementRange: editor.selectedRange())
    settle()
    XCTAssertEqual(box.reads, [false, true])
    XCTAssertEqual(box.told, [AmountE4(whole: 2_000)])
    // Enter writes the text back; the amount it reads as was told already, not told again.
    editor.insertNewline(nil)
    settle()
    XCTAssertEqual(field.stringValue, "2,000")
    XCTAssertEqual(box.told, [AmountE4(whole: 2_000)])
    XCTAssertEqual(box.reads, [false, true])
  }

  /// An equal split of 37 in eight, shown in a field and confirmed: still 4.625, never 4 625.
  func testASharedAmountSurvivesEnter() throws {
    let box = Box()
    let (window, fields) = try show(AmountE4(raw: 46_250), box: box)
    defer {
      window.contentView = nil
      window.close()
    }
    XCTAssertEqual(fields[0].stringValue, "4.625")
    XCTAssertTrue(window.makeFirstResponder(fields[0]))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor")
    editor.insertNewline(nil)
    settle()
    XCTAssertEqual(fields[0].stringValue, "4.625")
    XCTAssertTrue(window.makeFirstResponder(nil))
    settle()
    XCTAssertEqual(fields[0].stringValue, "4.625")
    // Nothing was typed, so nothing was told: the amount is still the one it was given.
    XCTAssertEqual(box.amounts[0], .zero)
  }
}

/// Formulas saved when a lone comma was always decimal are read again when the database opens —
/// a restore and an import open the database they staged the same way.
@MainActor
final class FormulaRepairOnOpenTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-formulas-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
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

  private static func entry(_ amount: AmountE4, formula: String) -> TransactionEntry {
    let moment = Date(timeIntervalSince1970: 1_789_000_000)
    let transaction = Transaction(
      kind: .expense, occurredAt: moment, amountE4: amount, amountExpr: formula,
      amountRubE4: amount, note: "taxi", createdAt: moment, updatedAt: moment)
    let part = TransactionPart(
      transactionId: transaction.id, amountE4: amount, amountRubE4: amount)
    return TransactionEntry(transaction: transaction, parts: [part])
  }

  func testOpeningDropsAFormulaThatNoLongerComesToItsAmount() async throws {
    // «1,500+2,50» was saved as 4 when a lone comma was always decimal; today it reads 1 502.50.
    let stale = Self.entry(AmountE4(whole: 4), formula: "1,500+2,50")
    let sound = Self.entry(AmountE4(whole: 800), formula: "(1000+600)/2")
    environment = AppEnvironment()
    await environment.start(preparing: {
      let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
      let repository = TransactionRepository(writer: stack.writer)
      try repository.save(stale)
      try repository.save(sound)
      return stack
    })
    let transactions = try XCTUnwrap(environment.transactions)

    let reopenedStale = try XCTUnwrap(try transactions.entry(id: stale.id)?.transaction)
    XCTAssertNil(reopenedStale.amountExpr, "a formula that no longer adds up stayed")
    XCTAssertEqual(reopenedStale.amountE4, AmountE4(whole: 4), "the amount is the truth")
    XCTAssertEqual(
      try transactions.entry(id: sound.id)?.transaction.amountExpr, "(1000+600)/2")
  }
}
