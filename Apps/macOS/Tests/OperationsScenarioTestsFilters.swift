import AppCore
import XCTest

@testable import OhMyMoney

/// The filters and the search of «Операции» over a small synthetic history: the period at the
/// edges of a month, a year and a leap February, income by the month it is for, the type and
/// the categories it leaves, people as the ones paid for and the ones owing, the status of a
/// part paid for somebody else, and the search through every name an operation carries — in
/// either case and with «ё» read as «е».
@MainActor
final class OperationsScenarioFiltersTests: XCTestCase {
  private let calendar = CalendarContext.utc
  private let food = CoreKit.Category(kind: .expense, name: "Еда")
  private lazy var coffee = CoreKit.Category(parentId: food.id, kind: .expense, name: "Кофе")
  private let fun = CoreKit.Category(kind: .expense, name: "Развлечения")
  private let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  private let anna = Person(name: "Аня")
  private let boris = Person(name: "Борис")
  private let shop = Place(name: "Ёлочный базар")
  private let trip = Event(
    name: "Поездка", startDate: DateOnly(year: 2026, month: 3, day: 1),
    endDate: DateOnly(year: 2026, month: 3, day: 9))
  private let main = PaymentMethod(name: "Основной", currency: .rub, isDefault: true)
  private let spare = PaymentMethod(name: "Запасной", currency: .rub)
  private lazy var card = PaymentCard(accountId: main.id, name: "Мир")

  // MARK: Helpers

  private func at(_ day: DateOnly, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
  }

  private func entry(
    _ note: String, on day: DateOnly, hour: Int = 12, minute: Int = 0,
    kind: TransactionKind = .expense, whole: Int64 = 100, category: CoreKit.Category? = nil,
    placeId: UUID? = nil, account: PaymentMethod? = nil, cardId: UUID? = nil,
    period: MonthKey? = nil, parts: [PartDraft]? = nil, expression: String? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: kind, occurredAt: at(day, hour, minute), amount: AmountE4(whole: whole),
      amountExpression: expression, note: note, placeId: placeId,
      paymentMethodId: (account ?? main).id, periodMonth: period, cardId: cardId)
    if let parts {
      draft.parts = parts
    } else {
      draft.normalizeSinglePart()
      draft.parts[0].categoryId = (category ?? (kind == .income ? salary : food)).id
    }
    // The operation records the zone it was made in; the history is read in UTC here.
    return try draft.materialize(now: at(day, hour, minute), timeZone: calendar.timeZone)
  }

  private func ledger(_ entries: [TransactionEntry], transfers: [Transfer] = []) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: [food, coffee, fun, salary], people: [anna, boris],
        places: [shop], events: [trip], paymentMethods: [main, spare], transfers: transfers,
        cards: [card]),
      calendar: calendar)
  }

  private func found(
    _ filters: TransactionFilters, today: DateOnly, in ledger: Ledger
  ) -> Set<UUID> {
    Set(filters.entryFilter(today: today).apply(to: ledger))
  }

  private func searched(_ text: String, in ledger: Ledger) -> Set<UUID> {
    Set(EntryFilter(text: text).apply(to: ledger))
  }

  // MARK: The period

  func testThisMonthTakesItsFirstAndLastMinuteAndNothingAround() throws {
    let today = DateOnly(year: 2026, month: 5, day: 15)
    let before = try entry(
      "before", on: DateOnly(year: 2026, month: 4, day: 30), hour: 23, minute: 59)
    let first = try entry("first", on: DateOnly(year: 2026, month: 5, day: 1), hour: 0)
    let last = try entry("last", on: DateOnly(year: 2026, month: 5, day: 31), hour: 23, minute: 59)
    let after = try entry("after", on: DateOnly(year: 2026, month: 6, day: 1), hour: 0)
    var filters = TransactionFilters(today: today)
    filters.period = .thisMonth
    XCTAssertEqual(
      found(filters, today: today, in: ledger([before, first, last, after])), [first.id, last.id])
  }

  func testLastMonthInJanuaryIsTheDecemberBefore() throws {
    let today = DateOnly(year: 2027, month: 1, day: 3)
    let december = try entry("december", on: DateOnly(year: 2026, month: 12, day: 31))
    let november = try entry("november", on: DateOnly(year: 2026, month: 11, day: 30))
    let january = try entry("january", on: DateOnly(year: 2027, month: 1, day: 1))
    var filters = TransactionFilters(today: today)
    filters.period = .lastMonth
    XCTAssertEqual(
      found(filters, today: today, in: ledger([december, november, january])), [december.id])
  }

  func testThisYearTakesNewYearsDayAndNewYearsEve() throws {
    let today = DateOnly(year: 2026, month: 7, day: 1)
    let eveBefore = try entry("eve 2025", on: DateOnly(year: 2025, month: 12, day: 31), hour: 23)
    let newYear = try entry("new year", on: DateOnly(year: 2026, month: 1, day: 1), hour: 0)
    let eve = try entry("eve", on: DateOnly(year: 2026, month: 12, day: 31), hour: 23)
    var filters = TransactionFilters(today: today)
    filters.period = .thisYear
    XCTAssertEqual(
      found(filters, today: today, in: ledger([eveBefore, newYear, eve])), [newYear.id, eve.id])
  }

  func testACustomRangeTakesItsDaysInEitherOrder() throws {
    let today = DateOnly(year: 2026, month: 5, day: 20)
    let a = try entry("a", on: DateOnly(year: 2026, month: 5, day: 4))
    let b = try entry("b", on: DateOnly(year: 2026, month: 5, day: 6))
    let c = try entry("c", on: DateOnly(year: 2026, month: 5, day: 8))
    let book = ledger([a, b, c])
    var filters = TransactionFilters(today: today)
    filters.period = .custom
    filters.customStart = DateOnly(year: 2026, month: 5, day: 7)
    filters.customEnd = DateOnly(year: 2026, month: 5, day: 4)
    XCTAssertEqual(found(filters, today: today, in: book), [a.id, b.id])
    swap(&filters.customStart, &filters.customEnd)
    XCTAssertEqual(found(filters, today: today, in: book), [a.id, b.id])
  }

  func testACustomRangeOfOneDayTakesThatDayFromMidnightToMidnight() throws {
    let today = DateOnly(year: 2026, month: 5, day: 20)
    let day = DateOnly(year: 2026, month: 5, day: 10)
    let midnight = try entry("midnight", on: day, hour: 0)
    let late = try entry("late", on: day, hour: 23, minute: 59)
    let next = try entry("next", on: DateOnly(year: 2026, month: 5, day: 11), hour: 0)
    var filters = TransactionFilters(today: today)
    filters.period = .custom
    filters.customStart = day
    filters.customEnd = day
    XCTAssertEqual(
      found(filters, today: today, in: ledger([midnight, late, next])), [midnight.id, late.id])
  }

  func testTheLeapDayIsInFebruaryOfALeapYear() throws {
    let today = DateOnly(year: 2028, month: 3, day: 2)
    let leap = try entry("leap", on: DateOnly(year: 2028, month: 2, day: 29))
    let march = try entry("march", on: DateOnly(year: 2028, month: 3, day: 1))
    var filters = TransactionFilters(today: today)
    filters.period = .lastMonth
    XCTAssertEqual(found(filters, today: today, in: ledger([leap, march])), [leap.id])
    filters.period = .custom
    filters.customStart = DateOnly(year: 2028, month: 2, day: 28)
    filters.customEnd = DateOnly(year: 2028, month: 3, day: 1)
    XCTAssertEqual(found(filters, today: today, in: ledger([leap, march])), [leap.id, march.id])
  }

  func testIncomeFallsInTheMonthItIsFor() throws {
    let today = DateOnly(year: 2026, month: 5, day: 15)
    let paidForApril = try entry(
      "salary", on: DateOnly(year: 2026, month: 5, day: 2), kind: .income, whole: 50_000,
      period: DateOnly(year: 2026, month: 4, day: 1).monthKey)
    let book = ledger([paidForApril])
    var filters = TransactionFilters(today: today)
    filters.period = .thisMonth
    XCTAssertTrue(found(filters, today: today, in: book).isEmpty)
    filters.period = .lastMonth
    XCTAssertEqual(found(filters, today: today, in: book), [paidForApril.id])
  }

  func testACustomRangeTakesIncomeByItsDay() throws {
    let today = DateOnly(year: 2026, month: 5, day: 15)
    let paidForApril = try entry(
      "salary", on: DateOnly(year: 2026, month: 5, day: 2), kind: .income, whole: 50_000,
      period: DateOnly(year: 2026, month: 4, day: 1).monthKey)
    var filters = TransactionFilters(today: today)
    filters.period = .custom
    filters.customStart = DateOnly(year: 2026, month: 5, day: 1)
    filters.customEnd = DateOnly(year: 2026, month: 5, day: 3)
    XCTAssertEqual(found(filters, today: today, in: ledger([paidForApril])), [paidForApril.id])
  }

  func testAllTimeTakesEveryYear() throws {
    let today = DateOnly(year: 2026, month: 5, day: 15)
    let old = try entry("old", on: DateOnly(year: 2019, month: 1, day: 1))
    let future = try entry("future", on: DateOnly(year: 2027, month: 12, day: 31))
    let filters = TransactionFilters(today: today)
    XCTAssertNil(filters.period(today: today))
    XCTAssertEqual(found(filters, today: today, in: ledger([old, future])), [old.id, future.id])
  }

  func testTheCustomRangeStartsAsThisMonthSoFar() {
    let filters = TransactionFilters(today: DateOnly(year: 2026, month: 2, day: 17))
    XCTAssertEqual(filters.customStart, DateOnly(year: 2026, month: 2, day: 1))
    XCTAssertEqual(filters.customEnd, DateOnly(year: 2026, month: 2, day: 17))
  }

  // MARK: The type and the categories

  func testIncomeAsTheTypeDropsAnExpenseCategoryAndItsSubcategory() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 5, day: 1))
    filters.setCategory(food.id)
    filters.subcategoryId = coffee.id
    filters.setKind(.income, tree: [food, coffee, salary])
    XCTAssertNil(filters.entryFilter(today: filters.customEnd).categoryId)
    XCTAssertNil(filters.subcategoryId)
  }

  func testARefundAsTheTypeKeepsAnExpenseCategory() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 5, day: 1))
    filters.setCategory(food.id)
    filters.subcategoryId = coffee.id
    filters.setKind(.refund, tree: [food, coffee, salary])
    XCTAssertEqual(filters.entryFilter(today: filters.customEnd).categoryId, food.id)
    XCTAssertEqual(filters.subcategoryId, coffee.id)
  }

  func testAnyTypeKeepsTheCategory() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 5, day: 1))
    filters.setKind(.income, tree: [food, salary])
    filters.setCategory(salary.id)
    filters.setKind(nil, tree: [food, salary])
    XCTAssertEqual(filters.entryFilter(today: filters.customEnd).categoryId, salary.id)
  }

  func testChoosingTheSameCategoryKeepsTheSubcategory() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 5, day: 1))
    filters.setCategory(food.id)
    filters.subcategoryId = coffee.id
    filters.setCategory(food.id)
    XCTAssertEqual(filters.subcategoryId, coffee.id)
    filters.setCategory(nil)
    XCTAssertNil(filters.subcategoryId)
  }

  func testTheCategoriesOnOfferFollowTheType() {
    let tree = [food, coffee, fun, salary]
    XCTAssertEqual(
      TransactionFilters.filterCategories(tree, kind: nil).map(\.id), [food.id, fun.id, salary.id])
    XCTAssertEqual(
      TransactionFilters.filterCategories(tree, kind: .income).map(\.id), [salary.id])
    XCTAssertEqual(
      TransactionFilters.filterCategories(tree, kind: .reimbursement).map(\.id), [food.id, fun.id])
  }

  func testACategoryFindsItsSubcategoriesAndASubcategoryOnlyItself() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let bread = try entry("bread", on: day, category: food)
    let latte = try entry("latte", on: day, category: coffee)
    let cinema = try entry("cinema", on: day, category: fun)
    let book = ledger([bread, latte, cinema])
    var filters = TransactionFilters(today: day)
    filters.setCategory(food.id)
    XCTAssertEqual(found(filters, today: day, in: book), [bread.id, latte.id])
    filters.subcategoryId = coffee.id
    XCTAssertEqual(found(filters, today: day, in: book), [latte.id])
  }

  func testASplitIsFoundByTheCategoryOfAnyPart() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let split = try entry(
      "split", on: day, whole: 300,
      parts: [
        PartDraft(categoryId: food.id, amount: AmountE4(whole: 200)),
        PartDraft(categoryId: fun.id, amount: AmountE4(whole: 100)),
      ])
    let book = ledger([split])
    var filters = TransactionFilters(today: day)
    filters.setCategory(fun.id)
    XCTAssertEqual(found(filters, today: day, in: book), [split.id])
    filters.setCategory(food.id)
    XCTAssertEqual(found(filters, today: day, in: book), [split.id])
  }

  func testASplitIsListedOnceWhateverItsPartsMatch() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let split = try entry(
      "split", on: day, whole: 300,
      parts: [
        PartDraft(categoryId: food.id, amount: AmountE4(whole: 100)),
        PartDraft(categoryId: coffee.id, amount: AmountE4(whole: 100)),
        PartDraft(categoryId: food.id, amount: AmountE4(whole: 100)),
      ])
    var filters = TransactionFilters(today: day)
    filters.setCategory(food.id)
    XCTAssertEqual(filters.entryFilter(today: day).apply(to: ledger([split])), [split.id])
  }

  func testTheTypeTellsAPurchaseFromItsRefund() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let purchase = try entry("kettle", on: day)
    let refund = try entry("kettle back", on: day, hour: 13, kind: .refund, whole: 40)
    let book = ledger([purchase, refund])
    var filters = TransactionFilters(today: day)
    filters.setKind(.refund, tree: [food])
    XCTAssertEqual(found(filters, today: day, in: book), [refund.id])
    filters.setKind(.expense, tree: [food])
    XCTAssertEqual(found(filters, today: day, in: book), [purchase.id])
  }

  // MARK: People, places, events, accounts, quality, status

  func testAPersonIsFoundAsTheOnePaidForAndAsTheOneOwing() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let gift = try entry(
      "gift", on: day,
      parts: [
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 100), forWhom: .friends,
          forPersonId: anna.id)
      ])
    let owed = try entry(
      "owed", on: day,
      parts: [
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 100), reimbursable: true,
          debtorPersonId: anna.id)
      ])
    let other = try entry(
      "other", on: day,
      parts: [
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 100), forWhom: .friends,
          forPersonId: boris.id)
      ])
    var filters = TransactionFilters(today: day)
    filters.personId = anna.id
    XCTAssertEqual(
      found(filters, today: day, in: ledger([gift, owed, other])), [gift.id, owed.id])
  }

  func testTheGroupForWhomFindsOnlyItsParts() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let family = try entry(
      "family", on: day,
      parts: [PartDraft(categoryId: food.id, amount: AmountE4(whole: 100), forWhom: .family)])
    let mine = try entry("mine", on: day)
    var filters = TransactionFilters(today: day)
    filters.forWhom = .family
    XCTAssertEqual(found(filters, today: day, in: ledger([family, mine])), [family.id])
    filters.forWhom = .me
    XCTAssertEqual(found(filters, today: day, in: ledger([family, mine])), [mine.id])
  }

  func testThePlaceAndTheEventFilterTheirOperations() throws {
    let day = DateOnly(year: 2026, month: 3, day: 4)
    let atShop = try entry("tree", on: day, placeId: shop.id)
    let onTrip = try entry(
      "hotel", on: day,
      parts: [PartDraft(categoryId: fun.id, amount: AmountE4(whole: 100), eventId: trip.id)])
    let book = ledger([atShop, onTrip])
    var filters = TransactionFilters(today: day)
    filters.placeId = shop.id
    XCTAssertEqual(found(filters, today: day, in: book), [atShop.id])
    filters.placeId = nil
    filters.eventId = trip.id
    XCTAssertEqual(found(filters, today: day, in: book), [onTrip.id])
  }

  func testAnAccountFindsEveryCardOfItAndACardOnlyItself() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let byCard = try entry("card", on: day, cardId: card.id)
    let byAccount = try entry("account", on: day)
    let spareOne = try entry("spare", on: day, account: spare)
    let book = ledger([byCard, byAccount, spareOne])
    var filters = TransactionFilters(today: day)
    filters.setAccountOrCard(main.id, cards: [card])
    XCTAssertEqual(found(filters, today: day, in: book), [byCard.id, byAccount.id])
    filters.setAccountOrCard(card.id, cards: [card])
    XCTAssertEqual(filters.paymentMethodId, main.id)
    XCTAssertEqual(found(filters, today: day, in: book), [byCard.id])
    filters.setAccountOrCard(spare.id, cards: [card])
    XCTAssertNil(filters.cardId)
    XCTAssertEqual(found(filters, today: day, in: book), [spareOne.id])
  }

  func testTheQualityFilterFindsTheRatedParts() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let bad = try entry(
      "bad", on: day,
      parts: [
        PartDraft(
          categoryId: fun.id, quality: .bad, qualitySource: .manual,
          amount: AmountE4(whole: 100))
      ])
    let good = try entry(
      "good", on: day,
      parts: [
        PartDraft(
          categoryId: food.id, quality: .good, qualitySource: .manual,
          amount: AmountE4(whole: 100))
      ])
    var filters = TransactionFilters(today: day)
    filters.quality = .bad
    XCTAssertEqual(found(filters, today: day, in: ledger([bad, good])), [bad.id])
  }

  func testTheStatusFindsOnlyPurchasesPaidForSomebodyElse() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let owed = try entry(
      "owed", on: day,
      parts: [
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 100), reimbursable: true,
          debtorPersonId: boris.id)
      ])
    let mine = try entry("mine", on: day)
    var filters = TransactionFilters(today: day)
    filters.status = .expected
    XCTAssertEqual(found(filters, today: day, in: ledger([owed, mine])), [owed.id])
    filters.status = .returned
    XCTAssertTrue(found(filters, today: day, in: ledger([owed, mine])).isEmpty)
  }

  func testEveryFilterTogetherNarrowsToTheOneOperation() throws {
    let day = DateOnly(year: 2026, month: 3, day: 4)
    let target = try entry(
      "target", on: day, placeId: shop.id, cardId: card.id,
      parts: [
        PartDraft(
          categoryId: coffee.id, quality: .bad, qualitySource: .manual,
          amount: AmountE4(whole: 100), forWhom: .friends, forPersonId: anna.id, eventId: trip.id)
      ])
    let near = try entry("target", on: day, placeId: shop.id, cardId: card.id)
    var filters = TransactionFilters(today: day)
    filters.period = .thisMonth
    filters.setKind(.expense, tree: [food, coffee])
    filters.setCategory(food.id)
    filters.subcategoryId = coffee.id
    filters.quality = .bad
    filters.forWhom = .friends
    filters.personId = anna.id
    filters.placeId = shop.id
    filters.eventId = trip.id
    filters.setAccountOrCard(card.id, cards: [card])
    filters.search = "target"
    XCTAssertEqual(filters.activeCount, 10)
    XCTAssertEqual(found(filters, today: day, in: ledger([target, near])), [target.id])
  }

  // MARK: Counting and resetting

  func testAnAccountAndItsCardCountAsOneFilter() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 5, day: 1))
    filters.setAccountOrCard(card.id, cards: [card])
    XCTAssertEqual(filters.activeCount, 1)
    XCTAssertEqual(filters.accountOrCard, card.id)
  }

  func testCustomDaysCountForResetOnlyWhileTheRangeIsChosen() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 5, day: 10))
    filters.customStart = DateOnly(year: 2026, month: 1, day: 1)
    XCTAssertFalse(filters.canReset, "the days of a range not chosen are not a filter")
    filters.period = .custom
    XCTAssertTrue(filters.canReset)
    filters.reset()
    XCTAssertEqual(filters.period, .allTime)
    XCTAssertEqual(filters.customStart, DateOnly(year: 2026, month: 1, day: 1))
    XCTAssertEqual(filters.customEnd, DateOnly(year: 2026, month: 5, day: 10))
  }

  func testTheSearchAloneCanBeReset() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 5, day: 10))
    filters.search = "кофе"
    XCTAssertEqual(filters.activeCount, 0)
    XCTAssertTrue(filters.canReset)
    filters.reset()
    XCTAssertEqual(filters.search, "")
  }

  func testTheSearchIsTrimmedForTheCore() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 5, day: 10))
    filters.search = "   кофе  "
    XCTAssertEqual(filters.entryFilter(today: filters.customEnd).text, "кофе")
  }

  func testEveryPeriodHasATitleInBothLanguages() {
    for period in TransactionFilters.PeriodChoice.allCases {
      for language in ["ru", "en"] {
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj")
          .flatMap(Bundle.init(path:))
        let title = bundle?.localizedString(
          forKey: period.titleKey, value: nil, table: "Transactions")
        XCTAssertNotEqual(title, period.titleKey, "\(period) \(language)")
      }
    }
  }

  // MARK: What stays chosen when the data changes

  func testACategoryArchivedSinceIsDropped() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 5, day: 10))
    filters.setCategory(fun.id)
    var archived = fun
    archived.archived = true
    filters.keep(within: FilterChoices(Dataset(categories: [food, archived])))
    XCTAssertNil(filters.entryFilter(today: filters.customEnd).categoryId)
  }

  func testASubcategoryArchivedSinceIsDroppedAndItsParentKept() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 5, day: 10))
    filters.setCategory(food.id)
    filters.subcategoryId = coffee.id
    var archived = coffee
    archived.archived = true
    filters.keep(within: FilterChoices(Dataset(categories: [food, archived])))
    XCTAssertEqual(filters.entryFilter(today: filters.customEnd).categoryId, food.id)
    XCTAssertNil(filters.subcategoryId)
  }

  func testAnAccountArchivedSinceIsDroppedWithItsCard() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 5, day: 10))
    filters.setAccountOrCard(card.id, cards: [card])
    var archived = main
    archived.archived = true
    let choices = FilterChoices(Dataset(paymentMethods: [archived, spare], cards: [card]))
    XCTAssertFalse(choices.paymentMethods.contains { $0.id == main.id })
    XCTAssertTrue(choices.cards.isEmpty, "the cards of an archived account are not offered")
    filters.keep(within: choices)
    XCTAssertNil(filters.paymentMethodId)
    XCTAssertNil(filters.cardId)
    XCTAssertEqual(filters.activeCount, 0)
  }

  func testKeepingWithinTheSameChoicesChangesNothing() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 3, day: 5))
    filters.setCategory(food.id)
    filters.subcategoryId = coffee.id
    filters.personId = anna.id
    filters.placeId = shop.id
    filters.eventId = trip.id
    filters.setAccountOrCard(card.id, cards: [card])
    let before = filters
    filters.keep(
      within: FilterChoices(
        Dataset(
          categories: [food, coffee], people: [anna], places: [shop], events: [trip],
          paymentMethods: [main], cards: [card])))
    XCTAssertEqual(filters, before)
  }

  func testAPersonDeletedSinceIsDropped() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 3, day: 5))
    filters.personId = anna.id
    filters.keep(within: FilterChoices(Dataset(people: [boris])))
    XCTAssertNil(filters.personId)
  }

  // MARK: The search

  func testTheSearchFindsTheNameOfThePlaceWithYoAsE() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let tree = try entry("ель", on: day, placeId: shop.id)
    let book = ledger([tree])
    XCTAssertEqual(searched("елочный", in: book), [tree.id])
    XCTAssertEqual(searched("ЁЛОЧНЫЙ БАЗАР", in: book), [tree.id])
  }

  func testTheSearchFindsTheParentOfASubcategory() throws {
    let latte = try entry("latte", on: DateOnly(year: 2026, month: 5, day: 5), category: coffee)
    let book = ledger([latte])
    XCTAssertEqual(searched("еда", in: book), [latte.id])
    XCTAssertEqual(searched("кофе", in: book), [latte.id])
  }

  func testTheSearchFindsTheAmountAsWrittenInACSV() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    var draft = TransactionDraft(
      occurredAt: at(day), amount: try AmountE4(decimal: Decimal(string: "1234.5")!), note: "x",
      paymentMethodId: main.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = food.id
    let odd = try draft.materialize()
    let other = try entry("y", on: day, whole: 99)
    let book = ledger([odd, other])
    XCTAssertEqual(searched("1234.5", in: book), [odd.id])
    XCTAssertEqual(searched("1234", in: book), [odd.id])
  }

  func testTheSearchFindsTheExpressionTyped() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let shared = try entry("dinner", on: day, whole: 800, expression: "(1000+600)/2")
    XCTAssertEqual(searched("1000+600", in: ledger([shared])), [shared.id])
  }

  func testTheSearchFindsPeopleEventsAccountsAndCards() throws {
    let day = DateOnly(year: 2026, month: 3, day: 4)
    let full = try entry(
      "x", on: day, cardId: card.id,
      parts: [
        PartDraft(
          categoryId: fun.id, amount: AmountE4(whole: 100), forWhom: .friends,
          forPersonId: boris.id, eventId: trip.id)
      ])
    let book = ledger([full])
    for word in ["борис", "поездка", "основной", "мир", "развлечения"] {
      XCTAssertEqual(searched(word, in: book), [full.id], word)
    }
  }

  func testTheSearchFindsTheNoteOfAPart() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let split = try entry(
      "receipt", on: day, whole: 200,
      parts: [
        PartDraft(categoryId: food.id, amount: AmountE4(whole: 100), note: "Молоко"),
        PartDraft(categoryId: food.id, amount: AmountE4(whole: 100), note: "Хлеб"),
      ])
    XCTAssertEqual(searched("хлеб", in: ledger([split])), [split.id])
  }

  func testEveryWordMustBeFoundSomewhere() throws {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let latte = try entry("латте", on: day, category: coffee, placeId: shop.id)
    let book = ledger([latte])
    XCTAssertEqual(searched("латте базар кофе", in: book), [latte.id])
    XCTAssertTrue(searched("латте пицца", in: book).isEmpty)
  }

  func testWordsSeparatedByTabsAndNewLinesAreWordsToo() throws {
    let latte = try entry("латте", on: DateOnly(year: 2026, month: 5, day: 5), placeId: shop.id)
    XCTAssertEqual(searched("латте\tбазар\nелочный", in: ledger([latte])), [latte.id])
  }

  func testTheSearchFindsAPartOfAWord() throws {
    let latte = try entry("капучино", on: DateOnly(year: 2026, month: 5, day: 5))
    XCTAssertEqual(searched("пучи", in: ledger([latte])), [latte.id])
  }

  func testTheSearchIsNewestFirst() throws {
    let old = try entry("кофе", on: DateOnly(year: 2025, month: 1, day: 5))
    let new = try entry("кофе", on: DateOnly(year: 2026, month: 5, day: 5))
    let middle = try entry("кофе", on: DateOnly(year: 2025, month: 9, day: 5))
    XCTAssertEqual(
      EntryFilter(text: "кофе").apply(to: ledger([old, new, middle])), [new.id, middle.id, old.id])
  }

  func testADeletedOperationIsNeverFound() throws {
    var gone = try entry("кофе", on: DateOnly(year: 2026, month: 5, day: 5))
    gone.transaction.deletedAt = at(DateOnly(year: 2026, month: 5, day: 6))
    let kept = try entry("кофе", on: DateOnly(year: 2026, month: 5, day: 4))
    XCTAssertEqual(searched("кофе", in: ledger([gone, kept])), [kept.id])
  }

  func testAnEmptyHistoryFindsNothingWhateverTheFilters() {
    var filters = TransactionFilters(today: DateOnly(year: 2026, month: 5, day: 5))
    filters.search = "кофе"
    filters.period = .thisYear
    XCTAssertTrue(found(filters, today: filters.customEnd, in: ledger([])).isEmpty)
    XCTAssertTrue(TransactionListing.build(matching: .none, in: ledger([])).isEmpty)
  }

  func testTheSearchFindsTransfersByTheirAccounts() {
    let day = DateOnly(year: 2026, month: 5, day: 5)
    let move = Transfer(
      occurredAt: at(day), fromAccountId: main.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 500), toAccountId: spare.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 500), note: nil, createdAt: at(day), updatedAt: at(day))
    let book = ledger([], transfers: [move])
    XCTAssertEqual(
      TransactionListing.transfers(matching: EntryFilter(text: "запасной"), in: book).map(\.id),
      [move.id])
    XCTAssertTrue(
      TransactionListing.transfers(matching: EntryFilter(text: "кофе"), in: book).isEmpty)
  }
}
