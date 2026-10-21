import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// Two questions asked before a new operation is written: «Такая же уже записана — добавить
/// ещё?» for what repeats an operation of the last five minutes, and «Запись или план?» for an
/// operation dated after today. Each is asked once, and an answer of «записать» is kept until
/// the operation is saved.
@MainActor
final class EntryAskTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private var host: EntryHost?
  /// The day of the model's own clock: a new draft is dated now.
  private var today: DateOnly { CalendarContext.utc.day(of: Date()) }
  private var inAWeek: Date {
    CalendarContext.utc.noon(of: CalendarContext.utc.adding(days: 7, to: today))
  }

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(PaymentMethod(name: "Card", isDefault: true))
  }

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  private func makeModel(editing: Bool = false) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: editing)
    model.reload()
    return model
  }

  /// An operation written `ago` seconds ago, with the date of today.
  @discardableResult
  private func write(
    _ amount: Int64, note: String = "coffee", ago: TimeInterval = 30,
    in repository: TransactionRepository? = nil, category: UUID? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(amount: AmountE4(whole: amount), note: note)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = category
    var entry = try draft.materialize()
    entry.transaction.createdAt = Date().addingTimeInterval(-ago)
    try (repository ?? transactions).save(entry)
    return entry
  }

  // MARK: A repeat

  func testTheModelNamesWhatWasJustWrittenWithTheSameAmount() throws {
    let written = try write(250)
    let model = makeModel()
    model.setTotal(AmountE4(whole: 250))
    XCTAssertEqual(model.repeatedOperation()?.id, written.id)
    model.setTotal(AmountE4(whole: 251))
    XCTAssertNil(model.repeatedOperation(), "another amount")
  }

  func testWhatWasWrittenLongAgoIsNoRepeat() throws {
    try write(250, ago: 3_600)
    let model = makeModel()
    model.setTotal(AmountE4(whole: 250))
    XCTAssertNil(model.repeatedOperation())
  }

  /// «Добавить» is kept for the operation being saved — the counts of its day may be asked about
  /// after the question — and forgotten with it.
  func testAConfirmedRepeatIsNotAskedAgainUntilTheNextOperation() throws {
    try write(250)
    let model = makeModel()
    model.setTotal(AmountE4(whole: 250))
    XCTAssertNotNil(model.repeatedOperation())
    model.repeatConfirmed = true
    XCTAssertNil(model.repeatedOperation())
    model.reset()
    model.setTotal(AmountE4(whole: 250))
    XCTAssertNotNil(model.repeatedOperation(), "the next operation asks again")
  }

  func testASavedOperationIsNeverAskedAboutARepeat() throws {
    let written = try write(250)
    let model = makeModel(editing: true)
    model.draft = TransactionDraft(entry: written)
    XCTAssertNil(model.repeatedOperation())
  }

  // MARK: A date ahead

  func testAnOperationAheadMayBecomeAPlanAndIsAskedOnce() throws {
    let model = makeModel()
    model.setTotal(AmountE4(whole: 2_500))
    XCTAssertNil(model.planAhead(today: today), "dated today")
    model.setDate(inAWeek, today: today)
    XCTAssertEqual(model.planAhead(today: today), .payment)
    model.draft.kind = .income
    XCTAssertEqual(model.planAhead(today: today), .income)
    model.aheadAnswered = true
    XCTAssertNil(model.planAhead(today: today), "answered once")
    model.reset()
    model.setTotal(AmountE4(whole: 2_500))
    model.setDate(inAWeek, today: today)
    XCTAssertEqual(model.planAhead(today: today), .payment, "the next operation asks again")
  }

  func testASavedOperationAheadIsNeverAskedAboutAPlan() throws {
    let model = makeModel(editing: true)
    var draft = TransactionDraft(
      occurredAt: inAWeek, amount: AmountE4(whole: 100), note: "sofa")
    draft.normalizeSinglePart()
    model.draft = draft
    XCTAssertNil(model.planAhead(today: today))
  }

  /// The plan is named by the note of the operation, else by its category.
  func testThePlanIsNamedByTheNoteElseTheCategory() throws {
    let food = CoreKit.Category(kind: .expense, name: "Food", quality: .neutral)
    try references.save(food)
    let model = makeModel()
    model.reload()
    model.setTotal(AmountE4(whole: 100))
    model.draft.note = "  sofa  "
    XCTAssertEqual(model.planName, "sofa")
    model.draft.note = nil
    XCTAssertNil(model.planName, "no note, no category")
    model.setCategory(food.id, forPartAt: 0)
    XCTAssertEqual(model.planName, "Food")
  }

  // MARK: In the window

  /// The sheet a question of the bar puts on the window, once it is there.
  private func sheet(of host: EntryHost, seconds: TimeInterval = 3) -> NSWindow? {
    let deadline = Date().addingTimeInterval(seconds)
    while host.window.attachedSheet == nil, Date() < deadline { host.settle(0.05) }
    return host.window.attachedSheet
  }

  /// Presses a button of the dialog. The save goes on a moment after the dialog is gone, in a
  /// task of the main actor: it runs only while the test waits, so the test does.
  private func click(_ title: String, in sheet: NSWindow, host: EntryHost) async throws {
    let buttons = host.views(of: NSButton.self, in: sheet.contentView)
    let button = try XCTUnwrap(
      buttons.first { $0.title == title }, "no «\(title)» among \(buttons.map(\.title))")
    button.performClick(nil)
    let deadline = Date().addingTimeInterval(3)
    while host.window.attachedSheet != nil, Date() < deadline { host.settle(0.05) }
    try await Task.sleep(for: .milliseconds(800))
    host.settle(0.2)
  }

  /// A line that repeats what was written a moment ago asks before it writes again: «Не
  /// добавлять» leaves the line as it was, «Добавить» writes.
  func testARepeatIsAskedAboutBeforeItIsWrittenAgain() async throws {
    let host = try await EntryHost { environment in
      let cafe = try EntryHost.history("coffee", in: environment)
      try self.write(250, ago: 20, in: environment.transactions!, category: cafe.id)
    }
    self.host = host
    let editor = try host.type("coffee 250", into: try host.line())
    editor.insertNewline(nil)
    host.settle(0.3)
    let asked = try XCTUnwrap(sheet(of: host), "the question was not asked")
    XCTAssertEqual(try host.transactions.count(), 2, "nothing is written before the answer")
    try await click(
      host.environment.language("entry.repeat.skip", table: "Entry"), in: asked, host: host)
    XCTAssertEqual(try host.transactions.count(), 2, "«Не добавлять» writes nothing")
    XCTAssertEqual(try host.line().stringValue, "coffee 250", "the line is as it was")

    XCTAssertTrue(host.window.makeFirstResponder(try host.line()))
    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    host.settle(0.3)
    let again = try XCTUnwrap(sheet(of: host), "the question is asked again")
    try await click(
      host.environment.language("entry.repeat.add", table: "Entry"), in: again, host: host)
    XCTAssertEqual(try host.transactions.count(), 3, "«Добавить» writes the repeat")
  }

  /// Another amount is no repeat: written at once, nothing asked.
  func testAnotherAmountIsWrittenAtOnce() async throws {
    let host = try await EntryHost { environment in
      let cafe = try EntryHost.history("coffee", in: environment)
      try self.write(250, ago: 20, in: environment.transactions!, category: cafe.id)
    }
    self.host = host
    let editor = try host.type("coffee 251", into: try host.line())
    editor.insertNewline(nil)
    host.settle(0.3)
    XCTAssertNil(host.window.attachedSheet)
    XCTAssertEqual(try host.transactions.count(), 3)
  }

  /// A line with a date after today asks whether it is a record or a plan; «Записать как есть»
  /// writes the operation on that date, and does not ask again after the repeat question.
  func testARecordDatedAheadIsWrittenAsItIs() async throws {
    let host = try await EntryHost { environment in
      try EntryHost.history("sofa", in: environment)
    }
    self.host = host
    let editor = try host.type("sofa 250 31.12.2030", into: try host.line())
    editor.insertNewline(nil)
    host.settle(0.3)
    let asked = try XCTUnwrap(sheet(of: host), "the question was not asked")
    XCTAssertEqual(try host.transactions.count(), 1, "nothing is written before the answer")
    try await click(
      host.environment.language("entry.ahead.record", table: "Entry"), in: asked, host: host)
    let saved = try host.transactions.recentEntries(limit: 5)
    XCTAssertEqual(saved.count, 2)
    XCTAssertEqual(saved.first?.transaction.amountE4, AmountE4(whole: 250))
    XCTAssertTrue(try host.planning.scheduled().isEmpty)
  }

  /// «Запланировать платёж» writes a payment of one date instead of the operation, and the line
  /// is cleared: one step of ⌘Z takes the plan away.
  func testAPlanIsWrittenInsteadOfTheOperation() async throws {
    let host = try await EntryHost { environment in
      try EntryHost.history("sofa", in: environment)
    }
    self.host = host
    let editor = try host.type("sofa 250 31.12.2030", into: try host.line())
    editor.insertNewline(nil)
    host.settle(0.3)
    let asked = try XCTUnwrap(sheet(of: host), "the question was not asked")
    try await click(
      host.environment.language("entry.ahead.planPayment", table: "Entry"), in: asked, host: host)
    XCTAssertEqual(try host.transactions.count(), 1, "no operation was written")
    let plans = try host.planning.scheduled()
    XCTAssertEqual(plans.count, 1)
    XCTAssertEqual(plans.first?.name, "sofa")
    XCTAssertEqual(plans.first?.amountE4, AmountE4(whole: 250))
    XCTAssertEqual(plans.first?.nextDate, DateOnly(year: 2030, month: 12, day: 31))
    XCTAssertEqual(try host.line().stringValue, "", "the line is cleared")
    XCTAssertTrue(host.store.canUndo)
    host.store.undo()
    host.settle(0.3)
    XCTAssertTrue(try host.planning.scheduled().isEmpty, "one step of ⌘Z took the plan away")
  }
}
