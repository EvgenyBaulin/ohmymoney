import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Это было до сверки?» from the entry line (C5): every count of the day is asked about, oldest
/// first; an answer remembered for a count («Больше не спрашивать для этой сверки») is used
/// without a question; a newer count of the day, never answered, asks.
@MainActor
final class EntryCountAnswerTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let card = PaymentMethod(name: "Card", isDefault: true)
  private let calendar = CalendarContext.utc
  private var day: DateOnly { DateOnly(year: 2026, month: 9, day: 19) }
  /// The setup of the morning and the sheet of the evening: two counts of one day.
  private let setupCount = Reconciliation(
    date: DateOnly(year: 2026, month: 9, day: 19), actualTotalRubE4: .zero, kind: .opening)
  private let sheetCount = Reconciliation(
    date: DateOnly(year: 2026, month: 9, day: 19), actualTotalRubE4: .zero, kind: .accounts)

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(card)
  }

  private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    calendar.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
  }

  private func balances(now: Date) -> AccountBalances {
    var morning = setupCount
    morning.reconciledAt = at(9)
    var evening = sheetCount
    evening.reconciledAt = at(21)
    return AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:],
      reconciliations: [morning, evening],
      balances: [
        ReconciledBalance(
          reconciliationId: morning.id, accountId: card.id, currency: .rub,
          actualE4: AmountE4(whole: 10_000)),
        ReconciledBalance(
          reconciliationId: evening.id, accountId: card.id, currency: .rub,
          actualE4: AmountE4(whole: 9_700), expectedE4: AmountE4(whole: 10_000),
          differenceE4: AmountE4(whole: -300), recordsDifference: true),
      ],
      accounts: [card], tree: CategoryTree(), now: now, calendar: calendar)
  }

  /// A coffee of that day typed at 22:00.
  private func coffee() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: calendar)
    model.reload()
    let parsed = InputLineParser(vocabulary: .empty, calendar: calendar).parse(
      "coffee 250", today: day)
    model.apply(parsed, amount: AmountE4(whole: 250), today: day)
    model.setPaymentMethod(card.id)
    model.draft.occurredAt = at(22)
    return model
  }

  func testTwoCountsOfTheDayAreAskedInTurn() throws {
    let model = coffee()
    guard
      case .ask(let questions) = model.countAsk(
        savedAt: at(22, 5), balances: balances(now: at(22, 5)), remembered: [:])
    else { return XCTFail("the counts of the day are asked about") }
    XCTAssertEqual(questions.counts, [at(9), at(21)])
    XCTAssertEqual(questions.count, at(9))
    XCTAssertEqual(questions.reconciliation, setupCount.id)
    // «Нет» asks about the evening; «Да» there puts the coffee between the two.
    guard case .ask(let evening) = questions.answer(wasBefore: false) else {
      return XCTFail("«Нет» asks about 21:00")
    }
    XCTAssertEqual(evening.count, at(21))
    guard case .stamp(let stamp) = evening.answer(wasBefore: true) else {
      return XCTFail("«Да» stamps")
    }
    XCTAssertEqual(stamp, at(20, 59).addingTimeInterval(59))
    model.stampCount(stamp)
    XCTAssertEqual(model.draft.occurredAt, stamp)
    guard
      case .none = model.countAsk(
        savedAt: at(22, 5), balances: balances(now: at(22, 5)), remembered: [:])
    else { return XCTFail("the save that goes on asks nothing more") }
  }

  /// «Нет, после» remembered for the evening's count answers both counts: nothing is asked, and
  /// the coffee is saved after them at its own moment.
  func testARememberedAnswerIsUsedSilently() throws {
    let model = coffee()
    guard
      case .answered(let stamp) = model.countAsk(
        savedAt: at(22, 5), balances: balances(now: at(22, 5)),
        remembered: [sheetCount.id: false])
    else { return XCTFail("a remembered answer asks nothing") }
    XCTAssertEqual(stamp, at(22))
  }

  /// An answer remembered for the morning's count only: the evening's, newer, asks.
  func testANewerReconciliationAsksAgain() throws {
    let model = coffee()
    guard
      case .ask(let questions) = model.countAsk(
        savedAt: at(22, 5), balances: balances(now: at(22, 5)),
        remembered: [setupCount.id: false])
    else { return XCTFail("the newer count is asked about") }
    XCTAssertEqual(questions.count, at(21))
    XCTAssertEqual(questions.reconciliation, sheetCount.id)
  }
}
