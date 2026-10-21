import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The quick line of the form at the side: the first Return only shows what will be written,
/// the second writes; what it read stays in the fields for «Изменить».
@MainActor
final class QuickEntryTests: XCTestCase {
  func testReturnShowsTheCardAndOnlyTheSecondWrites() {
    var flow = QuickEntryFlow()
    XCTAssertEqual(flow.submit(lineIsReadable: true), .confirm)
    XCTAssertTrue(flow.confirming)
    XCTAssertEqual(flow.submit(lineIsReadable: true), .save)
    XCTAssertFalse(flow.confirming)
  }

  func testAnUnreadableLineIsRefusedWithoutACard() {
    var flow = QuickEntryFlow()
    XCTAssertEqual(flow.submit(lineIsReadable: false), .refuse)
    XCTAssertFalse(flow.confirming)
  }

  /// A change of the line, «Изменить» or Esc take the card away: the next Return asks again.
  func testChangingTheLineAsksAgain() {
    var flow = QuickEntryFlow()
    _ = flow.submit(lineIsReadable: true)
    flow.dismiss()
    XCTAssertEqual(flow.submit(lineIsReadable: true), .confirm)
  }

  func testTheCardSaysWhatWillBeWrittenAndTheFieldsHoldIt() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    let groceries = CoreKit.Category(kind: .expense, name: "Продукты", quality: .neutral)
    try references.save(groceries)
    try references.save(PaymentMethod(name: "Сбер", isDefault: true))
    let model = EntryDraftModel(
      references: references, transactions: TransactionRepository(writer: stack.writer),
      calendar: .utc)
    model.assisted = false
    model.reload()
    let today = DateOnly(year: 2026, month: 10, day: 7)
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc).parse("кофе 300", today: today)
    model.apply(parsed, amount: AmountE4(whole: 300), today: today)
    model.prepareForPanel(today: today)
    model.setCategory(groceries.id, forPartAt: 0)
    // «Изменить»: the fields below hold what the line read.
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 300))
    XCTAssertEqual(model.draft.note, "кофе")
    let summary = QuickEntrySummary.text(of: model, environment: AppEnvironment())
    XCTAssertTrue(summary.hasPrefix("кофе, "), summary)
    XCTAssertTrue(summary.contains("Продукты") && summary.contains("Сбер"), summary)
  }

  func testSuggestionsAreTheLatestLikeTheLine() throws {
    var coffee = TransactionDraft(
      kind: .expense, occurredAt: Date(), amount: AmountE4(whole: 250), note: "кофе у дома")
    coffee.normalizeSinglePart()
    var tea = coffee
    tea.note = "чай"
    let entries = [try coffee.materialize(), try tea.materialize()]
    let money = AppEnvironment().money
    XCTAssertEqual(
      QuickEntrySuggestions.lines(typed: "коф", entries: entries, money: money).count, 1)
    XCTAssertTrue(QuickEntrySuggestions.lines(typed: "", entries: entries, money: money).isEmpty)
  }

  /// «ко»: the latest expenses whose words begin so, newest first, each line once and three at
  /// most; income and other words are not offered.
  func testSuggestionsAreTheNewestExpensesOnceAndThreeAtMost() throws {
    func entry(
      _ note: String, _ whole: Int64, kind: TransactionKind = .expense
    ) throws
      -> TransactionEntry
    {
      var draft = TransactionDraft(
        kind: kind, occurredAt: Date(), amount: AmountE4(whole: whole), note: note)
      draft.normalizeSinglePart()
      return try draft.materialize()
    }
    // Oldest first, as the dataset holds them.
    let entries = [
      try entry("кофе", 100), try entry("компот", 90), try entry("кофе", 300),
      try entry("кофе", 300), try entry("корм", 500), try entry("коврик", 700),
      try entry("кофе", 999, kind: .income), try entry("чай", 50),
    ]
    let lines = QuickEntrySuggestions.lines(
      typed: "ко", entries: entries, money: AppEnvironment().money)
    XCTAssertEqual(lines.count, 3, "\(lines)")
    XCTAssertTrue(lines[0].hasPrefix("коврик"), "\(lines)")
    XCTAssertTrue(lines[1].hasPrefix("корм"), "\(lines)")
    XCTAssertTrue(lines[2].hasPrefix("кофе 300"), "\(lines)")
    XCTAssertFalse(lines.contains { $0.contains("999") }, "income is not offered")
  }
}
