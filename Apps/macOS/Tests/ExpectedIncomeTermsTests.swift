import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// An income that comes several times a month — the parents' 25,000 on the 15th and 25,000 on
/// the last day — is made in one form as several recurring incomes, one for each term: each is
/// due, received and linked on its own.
final class ExpectedIncomeTermsTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 4)
  private let category = UUID()
  private let account = UUID()
  private let person = UUID()

  private func parents(due: DateOnly? = nil) -> ExpectedIncome {
    ExpectedIncome(
      name: "Parents", categoryId: category, personId: person, kind: .recurring,
      totalE4: AmountE4(whole: 25_000), currency: .rub,
      dueDate: due ?? DateOnly(year: 2026, month: 10, day: 15), freq: .monthly, partsExpected: 1,
      paymentMethodId: account)
  }

  /// The 15th and the last day, 25,000 each: the second term is a copy of the first on the last
  /// day of the month, and it keeps «последний день» as the day of its rule.
  func testTheLastDayTermIsACopyOnTheLastDayOfTheMonth() {
    let extra = parents().terms(
      [IncomeTerm(day: 31, amountE4: AmountE4(whole: 25_000))], today: today)
    XCTAssertEqual(extra.count, 1)
    let second = extra[0]
    XCTAssertEqual(second.name, "Parents")
    XCTAssertEqual(second.kind, .recurring)
    XCTAssertEqual(second.freq, .monthly)
    XCTAssertEqual(second.dueDate, DateOnly(year: 2026, month: 10, day: 31))
    XCTAssertEqual(second.day, 31)
    XCTAssertEqual(second.totalE4, AmountE4(whole: 25_000))
    XCTAssertEqual(second.categoryId, category)
    XCTAssertEqual(second.personId, person)
    XCTAssertEqual(second.paymentMethodId, account)
    XCTAssertEqual(second.currency, .rub)
    XCTAssertFalse(second.closed)
    XCTAssertNotEqual(second.id, parents().id)
  }

  /// A term has its own amount.
  func testATermHasItsOwnAmount() {
    let extra = parents().terms(
      [IncomeTerm(day: 31, amountE4: AmountE4(whole: 10_000))], today: today)
    XCTAssertEqual(extra.first?.totalE4, AmountE4(whole: 10_000))
  }

  /// A day that has passed in the month of the first due date starts the next month: the 2nd,
  /// asked on 15 October, is 2 November.
  func testADayThatHasPassedStartsNextMonth() {
    let extra = parents().terms(
      [IncomeTerm(day: 2, amountE4: AmountE4(whole: 1_000))], today: today)
    XCTAssertEqual(extra.first?.dueDate, DateOnly(year: 2026, month: 11, day: 2))
    XCTAssertEqual(extra.first?.day, 2)
  }

  /// The same day as the first term is a second payment of that day.
  func testTheSameDayStaysInTheMonth() {
    let extra = parents().terms(
      [IncomeTerm(day: 15, amountE4: AmountE4(whole: 1_000))], today: today)
    XCTAssertEqual(extra.first?.dueDate, DateOnly(year: 2026, month: 10, day: 15))
  }

  /// A short month clips the day: the 30th in February is 28 February, the last day is the 28th,
  /// and a rule of the 31st stays a rule of the last day.
  func testAShortMonthClipsTheDay() {
    let february = parents(due: DateOnly(year: 2026, month: 2, day: 10))
    let extra = february.terms(
      [
        IncomeTerm(day: 30, amountE4: AmountE4(whole: 1)),
        IncomeTerm(day: 31, amountE4: AmountE4(whole: 2)),
      ], today: today)
    XCTAssertEqual(
      extra.map(\.dueDate),
      [
        DateOnly(year: 2026, month: 2, day: 28), DateOnly(year: 2026, month: 2, day: 28),
      ])
    XCTAssertEqual(extra.map(\.day), [30, 31])
  }

  /// With no due date the first one is today's month.
  func testWithoutADueDateTheMonthIsTodays() {
    var base = parents()
    base.dueDate = nil
    let extra = base.terms([IncomeTerm(day: 31, amountE4: AmountE4(whole: 1))], today: today)
    XCTAssertEqual(extra.first?.dueDate, DateOnly(year: 2026, month: 10, day: 31))
  }

  /// Three more terms at most — four a month.
  func testAtMostThreeMoreTermsAreMade() {
    let terms = (1...6).map { IncomeTerm(day: $0 * 5, amountE4: AmountE4(whole: Int64($0))) }
    let extra = parents().terms(terms, today: today)
    XCTAssertEqual(extra.count, ExpectedIncome.maxExtraTerms)
    XCTAssertEqual(ExpectedIncome.maxExtraTerms, 3)
    XCTAssertEqual(extra.map(\.totalE4), [1, 2, 3].map { AmountE4(whole: Int64($0)) })
  }

  /// A term with no amount makes nothing: an income of zero cannot be saved.
  func testATermWithoutAnAmountMakesNothing() {
    let extra = parents().terms(
      [
        IncomeTerm(day: 31, amountE4: .zero),
        IncomeTerm(day: 20, amountE4: AmountE4(whole: 5)),
      ], today: today)
    XCTAssertEqual(extra.count, 1)
    XCTAssertEqual(extra.first?.day, 20)
  }

  /// Terms are only for an income by the month.
  func testOnlyAMonthlyIncomeHasTerms() {
    var weekly = parents()
    weekly.freq = .weekly
    XCTAssertTrue(
      weekly.terms([IncomeTerm(day: 31, amountE4: AmountE4(whole: 1))], today: today).isEmpty)
    var oneOff = parents()
    oneOff.kind = .oneOff
    XCTAssertTrue(
      oneOff.terms([IncomeTerm(day: 31, amountE4: AmountE4(whole: 1))], today: today).isEmpty)
  }

  /// Saved together the terms are written in one change: one ⌘Z takes all of them away.
  @MainActor
  func testTheTermsAreSavedInOneStepOfUndo() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)
    let store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer), references: references, planning: planning)
    let deps = AppDependencies(
      environment: AppEnvironment(), store: store,
      compute: ComputeStore(calendar: .utc, rebuildsInline: true))

    let source = CoreKit.Category(kind: .income, name: "Transfers", quality: .neutral)
    try references.save(source)
    let parents = Person(name: "Parents", relation: .family)
    try references.save(parents)
    let account = PaymentMethod(name: "Card", isDefault: true)
    try references.save(account)

    var first = self.parents()
    first.categoryId = source.id
    first.personId = parents.id
    first.paymentMethodId = account.id
    let all =
      [first] + first.terms([IncomeTerm(day: 31, amountE4: AmountE4(whole: 25_000))], today: today)
    XCTAssertEqual(all.count, 2)
    XCTAssertTrue(PlanningActions(deps).save(all))
    let stored = try planning.expected()
    XCTAssertEqual(stored.count, 2)
    XCTAssertEqual(
      Set(stored.map(\.dueDate)),
      [DateOnly(year: 2026, month: 10, day: 15), DateOnly(year: 2026, month: 10, day: 31)])
    store.undo()
    XCTAssertTrue(try planning.expected().isEmpty, "one step took both")
    XCTAssertFalse(store.canUndo)
  }
}
