import AppCore
import XCTest

@testable import OhMyMoney

/// The rows of the table of «Операции»: days newest first, within a day the income side (money
/// people gave back included) before the spending side (refunds included) and the transfers
/// after them, months shown three at a time across the turn of a year, a split as one row with
/// its numbered parts, and the selection reaching operations and transfers, never parts.
@MainActor
final class OperationsScenarioListingTests: XCTestCase {
  private let calendar = CalendarContext.utc
  private let food = CoreKit.Category(kind: .expense, name: "Еда")
  private let fun = CoreKit.Category(kind: .expense, name: "Кино")
  private let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  private let main = PaymentMethod(name: "Основной", currency: .rub, isDefault: true)
  private let spare = PaymentMethod(name: "Запасной", currency: .rub)
  private let anna = Person(name: "Аня")

  private func at(_ day: DateOnly, _ hour: Int = 12) -> Date {
    calendar.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3600))
  }

  private func entry(
    _ note: String?, on day: DateOnly, hour: Int = 12, kind: TransactionKind = .expense,
    whole: Int64 = 100, parts: [PartDraft]? = nil, currency: CurrencyCode = .rub,
    cashback: Money? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: kind, occurredAt: at(day, hour), currency: currency, amount: AmountE4(whole: whole),
      note: note, paymentMethodId: main.id, cashback: cashback)
    if let parts {
      draft.parts = parts
    } else {
      draft.normalizeSinglePart()
      draft.parts[0].categoryId = (kind == .income ? salary : food).id
    }
    return try draft.materialize(now: at(day, hour))
  }

  private func transfer(on day: DateOnly, hour: Int = 15) -> Transfer {
    Transfer(
      occurredAt: at(day, hour), fromAccountId: main.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 1_000), toAccountId: spare.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 1_000), note: nil, createdAt: at(day, hour),
      updatedAt: at(day, hour))
  }

  private func listing(
    _ entries: [TransactionEntry], transfers: [Transfer] = []
  ) -> TransactionListing {
    TransactionListing.build(matching: .none, in: ledger(entries, transfers: transfers))
  }

  private func ledger(_ entries: [TransactionEntry], transfers: [Transfer] = []) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: [food, fun, salary], people: [anna],
        paymentMethods: [main, spare], transfers: transfers),
      calendar: calendar)
  }

  private func split(on day: DateOnly, categories: [CoreKit.Category]) throws -> TransactionEntry {
    try entry(
      "receipt", on: day, whole: Int64(100 * categories.count),
      parts: categories.map { PartDraft(categoryId: $0.id, amount: AmountE4(whole: 100)) })
  }

  // MARK: Days and sides

  func testDaysComeNewestFirst() throws {
    let monday = try entry("a", on: DateOnly(year: 2026, month: 5, day: 4))
    let friday = try entry("b", on: DateOnly(year: 2026, month: 5, day: 8))
    let wednesday = try entry("c", on: DateOnly(year: 2026, month: 5, day: 6))
    let days = listing([monday, friday, wednesday]).sections.map(\.day.day)
    XCTAssertEqual(days, [8, 6, 4])
  }

  /// «Операции» are divided by days and nothing else (owner, 15.10): income, spending and the
  /// transfers of a day stand in one list by time, newest first, and the day's header adds
  /// them up.
  func testTheTableHasOneSectionADayWhateverTheKinds() throws {
    let day = DateOnly(year: 2026, month: 5, day: 4)
    let lunch = try entry("lunch", on: day, hour: 13)
    let pay = try entry("pay", on: day, hour: 9, kind: .income, whole: 5_000)
    let other = try entry("other", on: DateOnly(year: 2026, month: 5, day: 3), hour: 10)
    let built = listing([lunch, pay, other], transfers: [transfer(on: day)])
    XCTAssertEqual(built.days.map(\.day.day), [4, 3])
    let first = built.days[0]
    XCTAssertEqual(first.rows.count, 3, "income, spending and the transfer of the day together")
    XCTAssertEqual(
      first.rows.map(\.occurredAt), first.rows.map(\.occurredAt).sorted(by: >),
      "newest first, whatever the kind")
    XCTAssertEqual(first.totals.income, AmountE4(whole: 5_000))
    XCTAssertFalse(first.totals.isEmpty)
  }

  func testWithinADayIncomeComesBeforeSpendingAndTransfersAfter() throws {
    let day = DateOnly(year: 2026, month: 5, day: 4)
    let lunch = try entry("lunch", on: day, hour: 13)
    let pay = try entry("pay", on: day, hour: 9, kind: .income, whole: 5_000)
    let sides = listing([lunch, pay], transfers: [transfer(on: day)]).sections.map(\.side)
    XCTAssertEqual(sides, [.income, .expenses, .transfers])
  }

  func testMoneyGivenBackIsListedWithTheIncome() throws {
    let day = DateOnly(year: 2026, month: 5, day: 4)
    let back = try entry(
      "back", on: day, kind: .reimbursement,
      parts: [PartDraft(amount: AmountE4(whole: 100), forPersonId: anna.id)])
    let sections = listing([back]).sections
    XCTAssertEqual(sections.map(\.side), [.income])
  }

  func testARefundIsListedWithTheSpending() throws {
    let day = DateOnly(year: 2026, month: 5, day: 4)
    let refund = try entry("refund", on: day, kind: .refund)
    XCTAssertEqual(listing([refund]).sections.map(\.side), [.expenses])
  }

  func testAnOperationAtMidnightIsOnItsOwnDay() throws {
    let late = try entry("late", on: DateOnly(year: 2026, month: 5, day: 4), hour: 23)
    let early = try entry("early", on: DateOnly(year: 2026, month: 5, day: 5), hour: 0)
    let sections = listing([late, early]).sections
    XCTAssertEqual(sections.map(\.day.day), [5, 4])
    XCTAssertEqual(sections[0].rows.map(\.transactionId), [early.id])
  }

  func testOperationsOfADayAreInTheOrderTheyWereFound() throws {
    let day = DateOnly(year: 2026, month: 5, day: 4)
    let first = try entry("first", on: day, hour: 9)
    let second = try entry("second", on: day, hour: 18)
    let book = ledger([first, second])
    let built = TransactionListing.build([second.id, first.id], ledger: book)
    XCTAssertEqual(built.sections[0].rows.map(\.transactionId), [second.id, first.id])
  }

  func testATransferOnADayOfItsOwnComesInItsPlace() throws {
    let newer = transfer(on: DateOnly(year: 2026, month: 5, day: 10))
    let older = transfer(on: DateOnly(year: 2026, month: 5, day: 1))
    let middle = try entry("x", on: DateOnly(year: 2026, month: 5, day: 5))
    let sections = listing([middle], transfers: [newer, older]).sections
    XCTAssertEqual(sections.map(\.day.day), [10, 5, 1])
    XCTAssertEqual(sections.map(\.side), [.transfers, .expenses, .transfers])
  }

  func testTransfersAddUpToNothing() {
    let sections = listing([], transfers: [transfer(on: DateOnly(year: 2026, month: 5, day: 1))])
      .sections
    XCTAssertEqual(sections.first?.totals, .zero)
  }

  func testTheSectionsOfADayHaveTheirOwnIds() throws {
    let day = DateOnly(year: 2026, month: 5, day: 4)
    let lunch = try entry("lunch", on: day)
    let pay = try entry("pay", on: day, kind: .income)
    let ids = listing([lunch, pay], transfers: [transfer(on: day)]).sections.map(\.id)
    XCTAssertEqual(Set(ids).count, 3)
    XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("2026-05-04.") })
  }

  // MARK: What the selection reaches

  func testTheTransfersAreSelectableButAreNotOperations() throws {
    let day = DateOnly(year: 2026, month: 5, day: 4)
    let lunch = try entry("lunch", on: day)
    let move = transfer(on: day)
    let shown = listing([lunch], transfers: [move])
    XCTAssertEqual(shown.visibleIds, [lunch.id, move.id])
    XCTAssertEqual(shown.transferIds, [move.id])
    XCTAssertEqual(shown.operationCount, 1)
    XCTAssertEqual(shown.row(of: move.id), .transfer(move.id))
    XCTAssertEqual(shown.row(of: lunch.id), .transaction(lunch.id))
  }

  func testAnIdListedTwiceIsOneRow() throws {
    let lunch = try entry("lunch", on: DateOnly(year: 2026, month: 5, day: 4))
    let built = TransactionListing.build([lunch.id, lunch.id], ledger: ledger([lunch]))
    XCTAssertEqual(built.sections.flatMap(\.rows).count, 1)
  }

  func testAnIdTheDataDoesNotHaveIsLeftOut() throws {
    let lunch = try entry("lunch", on: DateOnly(year: 2026, month: 5, day: 4))
    let built = TransactionListing.build([UUID(), lunch.id], ledger: ledger([lunch]))
    XCTAssertEqual(built.visibleIds, [lunch.id])
  }

  func testAPartStandsForItsOperationAndIsNeverSelectedItself() throws {
    let receipt = try split(on: DateOnly(year: 2026, month: 5, day: 4), categories: [food, fun])
    let shown = listing([receipt])
    let part = receipt.parts[1].id
    XCTAssertEqual(shown.partOwners[part], receipt.id)
    XCTAssertEqual(shown.owners(of: [.part(part)]), [receipt.id])
    XCTAssertTrue(TransactionListing.operations(in: [.part(part)]).isEmpty)
    XCTAssertEqual(
      TransactionListing.operations(in: [.part(part), .transaction(receipt.id)]), [receipt.id])
  }

  func testAnOperationOfOnePartListsNoParts() throws {
    let lunch = try entry("lunch", on: DateOnly(year: 2026, month: 5, day: 4))
    let shown = listing([lunch])
    XCTAssertTrue(shown.partOwners.isEmpty)
    XCTAssertNil(shown.sections[0].rows[0].parts)
    XCTAssertEqual(shown.sections[0].rows[0].partCount, 1)
  }

  func testAPartOfAnUnknownOperationStandsForNothing() {
    XCTAssertTrue(TransactionListing.empty.owners(of: [.part(UUID())]).isEmpty)
  }

  // MARK: A split

  func testASplitIsOneRowWithItsPartsNumbered() throws {
    let receipt = try split(
      on: DateOnly(year: 2026, month: 5, day: 4), categories: [food, fun, food])
    let row = listing([receipt]).sections[0].rows[0]
    XCTAssertEqual(row.partCount, 3)
    XCTAssertEqual(row.parts?.map(\.partNumber), [1, 2, 3])
    XCTAssertEqual(row.parts?.map(\.id), receipt.parts.map { .part($0.id) })
    XCTAssertTrue(row.parts?.allSatisfy { $0.transactionId == receipt.id } ?? false)
  }

  func testASplitOfDifferentCategoriesShowsSeveral() throws {
    let receipt = try split(on: DateOnly(year: 2026, month: 5, day: 4), categories: [food, fun])
    XCTAssertEqual(listing([receipt]).sections[0].rows[0].category, .several)
  }

  func testASplitOfOneCategoryShowsIt() throws {
    let receipt = try split(on: DateOnly(year: 2026, month: 5, day: 4), categories: [food, food])
    guard case .one(let path) = listing([receipt]).sections[0].rows[0].category else {
      return XCTFail("one category expected")
    }
    XCTAssertEqual(path, CategoryPath(food.id, tree: CategoryTree([food])))
  }

  func testThePartsOfASplitAddUpToItsAmount() throws {
    let receipt = try split(
      on: DateOnly(year: 2026, month: 5, day: 4), categories: [food, fun, food, fun])
    let row = listing([receipt]).sections[0].rows[0]
    XCTAssertEqual(AmountE4.sum(row.parts?.map(\.amount) ?? []), row.amount)
  }

  // MARK: Months at a time

  func testMonthsComeNewestFirstAcrossTheYear() throws {
    let entries = try [
      entry("nov", on: DateOnly(year: 2025, month: 11, day: 3)),
      entry("jan", on: DateOnly(year: 2026, month: 1, day: 2)),
      entry("dec", on: DateOnly(year: 2025, month: 12, day: 31)),
    ]
    let months = listing(entries).months
    XCTAssertEqual(
      months,
      [
        DateOnly(year: 2026, month: 1, day: 1).monthKey,
        DateOnly(year: 2025, month: 12, day: 1).monthKey,
        DateOnly(year: 2025, month: 11, day: 1).monthKey,
      ])
  }

  func testTheNewestMonthAloneKeepsOnlyItsRows() throws {
    let january = try entry("jan", on: DateOnly(year: 2026, month: 1, day: 2))
    let december = try entry("dec", on: DateOnly(year: 2025, month: 12, day: 31))
    let move = transfer(on: DateOnly(year: 2025, month: 12, day: 30))
    let shown = listing([january, december], transfers: [move]).latestMonths(1)
    XCTAssertEqual(shown.visibleIds, [january.id])
    XCTAssertTrue(shown.transferIds.isEmpty)
    XCTAssertEqual(shown.months.count, 1)
  }

  func testMoreMonthsThanThereAreIsTheWholeListing() throws {
    let january = try entry("jan", on: DateOnly(year: 2026, month: 1, day: 2))
    let full = listing([january])
    let shown = full.latestMonths(TransactionListing.monthsPerPage)
    XCTAssertEqual(shown.visibleIds, full.visibleIds)
    XCTAssertEqual(shown.sections.count, full.sections.count)
  }

  func testNoMonthsIsAnEmptyListing() throws {
    let january = try entry("jan", on: DateOnly(year: 2026, month: 1, day: 2))
    let december = try entry("dec", on: DateOnly(year: 2025, month: 12, day: 31))
    let shown = listing([january, december]).latestMonths(0)
    XCTAssertTrue(shown.isEmpty)
    XCTAssertTrue(shown.visibleIds.isEmpty)
  }

  func testAPageOfMonthsKeepsThePartsOfItsSplits() throws {
    let receipt = try split(on: DateOnly(year: 2026, month: 3, day: 4), categories: [food, fun])
    let old = try split(on: DateOnly(year: 2025, month: 3, day: 4), categories: [food, fun])
    let shown = listing([receipt, old]).latestMonths(1)
    XCTAssertEqual(Set(shown.partOwners.keys), Set(receipt.parts.map(\.id)))
  }

  func testThreeMonthsArePerPage() {
    XCTAssertEqual(TransactionListing.monthsPerPage, 3)
  }

  // MARK: What a row says

  func testATitleOfSeveralLinesReadsAsOne() {
    XCTAssertEqual(
      RowTitle.resolve(note: "  кофе\n\n  с собой  ", category: nil, kind: .expense),
      .note("кофе с собой"))
  }

  func testABlankDescriptionGivesWayToTheCategoryThenTheKind() {
    let path = CategoryPath(food.id, tree: CategoryTree([food]))
    XCTAssertEqual(
      RowTitle.resolve(note: " \n ", category: path, kind: .expense),
      path.map(RowTitle.category))
    XCTAssertEqual(RowTitle.resolve(note: nil, category: nil, kind: .refund), .kind(.refund))
  }

  func testACellOfThePartsIsOneSeveralOrNone() {
    XCTAssertEqual(RowCell<Int>.of([]), .none)
    XCTAssertEqual(RowCell<Int>.of([nil, nil]), .none)
    XCTAssertEqual(RowCell<Int>.of([4, 4]), .one(4))
    XCTAssertEqual(RowCell<Int>.of([4, 5]), .several)
    XCTAssertEqual(RowCell<Int>.of([4, nil]), .several)
  }

  func testTheOwedMarkWaitsWhileAnyPartWaits() throws {
    let day = DateOnly(year: 2026, month: 5, day: 4)
    let receipt = try entry(
      "dinner", on: day, whole: 200,
      parts: [
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 100), reimbursable: true,
          debtorPersonId: anna.id, reimbursementStatus: .returned),
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 100), reimbursable: true,
          debtorPersonId: anna.id, reimbursementStatus: .expected),
      ])
    XCTAssertEqual(TransactionListing.owedMark(of: receipt), .expected)
    var settled = receipt
    settled.parts[1].reimbursementStatus = .writtenOff
    XCTAssertEqual(TransactionListing.owedMark(of: settled), .returned)
    settled.parts[0].reimbursementStatus = .writtenOff
    XCTAssertEqual(TransactionListing.owedMark(of: settled), .writtenOff)
  }

  func testOnlyAPurchaseCarriesTheOwedMark() throws {
    let day = DateOnly(year: 2026, month: 5, day: 4)
    let refund = try entry(
      "ticket back", on: day, kind: .refund,
      parts: [
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 100), reimbursable: true,
          debtorPersonId: anna.id)
      ])
    XCTAssertNil(TransactionListing.owedMark(of: refund))
    let mine = try entry("mine", on: day)
    XCTAssertNil(TransactionListing.owedMark(of: mine))
  }

  func testACashbackOfZeroIsNotShown() throws {
    let day = DateOnly(year: 2026, month: 5, day: 4)
    let none = try entry("none", on: day, cashback: Money(amount: .zero, currency: .rub))
    let some = try entry(
      "some", on: day, hour: 13, cashback: Money(amount: AmountE4(whole: 5), currency: .rub))
    let rows = listing([none, some]).sections[0].rows
    XCTAssertNil(rows.first { $0.transactionId == none.id }?.cashback)
    XCTAssertEqual(rows.first { $0.transactionId == some.id }?.cashback?.amount, AmountE4(whole: 5))
  }

  func testARowInAnotherCurrencyKeepsItsCurrency() throws {
    let day = DateOnly(year: 2026, month: 5, day: 4)
    let euros = try entry("museum", on: day, whole: 20, currency: .eur)
    let row = listing([euros]).sections[0].rows[0]
    XCTAssertEqual(row.currency, .eur)
    XCTAssertEqual(row.amount, AmountE4(whole: 20))
  }
}
