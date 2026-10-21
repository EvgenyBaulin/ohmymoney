import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The rows of the Transactions table, built from the ledger the way the window builds them
/// off the main thread: sections, totals, parts, the ids a selection may hold, and what names
/// a row without a description.
final class TransactionTableTests: XCTestCase {
  private let food = CoreKit.Category(kind: .expense, name: "Food")
  private lazy var coffee = CoreKit.Category(parentId: food.id, kind: .expense, name: "Coffee")
  private let fees = CoreKit.Category(kind: .expense, name: "Fees", quality: .bad)
  private let salary = CoreKit.Category(kind: .income, name: "Salary")
  private let anna = Person(name: "Anna")

  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private var yesterday: DateOnly { today.adding(days: -1) }

  private func moment(_ day: DateOnly, hour: Int) -> Date {
    CalendarContext.utc.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3600))
  }

  /// One operation with one part per amount; `configure` shapes the parts.
  private func entry(
    _ kind: TransactionKind, _ amounts: [Int64], on day: DateOnly, hour: Int,
    note: String? = nil, category: UUID? = nil,
    configure: (inout [TransactionPart]) -> Void = { _ in }
  ) -> TransactionEntry {
    let id = UUID()
    var parts = amounts.map {
      TransactionPart(
        transactionId: id, categoryId: category,
        quality: kind.hasQuality ? .neutral : nil, qualitySource: kind.hasQuality ? .category : nil,
        amountE4: AmountE4(whole: $0))
    }
    configure(&parts)
    let when = moment(day, hour: hour)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: when,
        amountE4: AmountE4(whole: amounts.reduce(0, +)), note: note, createdAt: when,
        updatedAt: when),
      parts: parts)
  }

  private func ledger(_ entries: [TransactionEntry]) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: [food, coffee, fees, salary], people: [anna]),
      calendar: .utc)
  }

  private func listing(
    _ entries: [TransactionEntry], filter: EntryFilter = .none
  )
    -> TransactionListing
  {
    let ledger = ledger(entries)
    return TransactionListing.build(filter.apply(to: ledger), ledger: ledger)
  }

  // MARK: - Sections

  /// Newest day first; inside a day its income — money given back among it — then its
  /// spending; inside a side, newest first.
  func testSectionsGoByDayAndSideNewestFirst() {
    let pay = entry(.income, [100_000], on: today, hour: 10, note: "Salary", category: salary.id)
    let back = entry(.reimbursement, [700], on: today, hour: 12) { parts in
      parts[0].forPersonId = self.anna.id
    }
    let coffeeToday = entry(.expense, [250], on: today, hour: 9, category: coffee.id)
    let groceries = entry(.expense, [1_800], on: yesterday, hour: 18, category: food.id)

    let found = listing([groceries, coffeeToday, pay, back])

    XCTAssertEqual(
      found.sections.map(\.id),
      ["\(today.iso).income", "\(today.iso).expenses", "\(yesterday.iso).expenses"])
    XCTAssertEqual(found.sections[0].rows.map(\.transactionId), [back.id, pay.id])
    XCTAssertEqual(found.sections[1].rows.map(\.transactionId), [coffeeToday.id])
    XCTAssertEqual(found.visibleIds, [pay.id, back.id, coffeeToday.id, groceries.id])
  }

  /// Money given back is listed with the income but never added to it: the header of the
  /// side says it apart, as `RowTotals` keeps it.
  func testTheIncomeHeaderLeavesMoneyGivenBackOutOfTheIncome() {
    let pay = entry(.income, [100_000], on: today, hour: 10, category: salary.id)
    let back = entry(.reimbursement, [700], on: today, hour: 12)
    let coffeeToday = entry(.expense, [250], on: today, hour: 9, category: coffee.id)

    let found = listing([pay, back, coffeeToday])
    let income = found.sections[0].totals
    XCTAssertEqual(income.income, AmountE4(whole: 100_000))
    XCTAssertEqual(income.moneyReturned, AmountE4(whole: 700))
    XCTAssertEqual(income.myExpenses, .zero)
    XCTAssertEqual(found.sections[1].totals.myExpenses, AmountE4(whole: 250))
    XCTAssertEqual(found.sections[1].totals.income, .zero)
  }

  // MARK: - Parts and ids

  /// A split is one row with its parts under it, each with an id of its own; an operation
  /// of one part has no children, so no disclosure triangle is drawn.
  func testASplitListsItsPartsAsChildren() throws {
    let order = entry(.expense, [2_500, 250], on: today, hour: 11, note: "Order") { parts in
      parts[0].categoryId = self.food.id
      parts[1].categoryId = self.fees.id
      parts[1].quality = .bad
    }
    let plain = entry(.expense, [300], on: today, hour: 9, category: food.id)

    let rows = listing([order, plain]).sections[0].rows
    let split = try XCTUnwrap(rows.first { $0.transactionId == order.id })
    XCTAssertEqual(split.id, .transaction(order.id))
    XCTAssertFalse(split.isPart)
    XCTAssertEqual(split.partCount, 2)
    XCTAssertEqual(split.category, .several)
    XCTAssertEqual(split.quality, .several)
    let parts = try XCTUnwrap(split.parts)
    XCTAssertEqual(parts.map(\.id), order.parts.map { RowID.part($0.id) })
    XCTAssertEqual(parts.map(\.partNumber), [1, 2])
    XCTAssertTrue(parts.allSatisfy(\.isPart))
    XCTAssertTrue(parts.allSatisfy { $0.transactionId == order.id && $0.parts == nil })
    XCTAssertEqual(parts[1].quality, .one(.bad))
    XCTAssertEqual(parts[0].category, .one(CategoryPath(names: ["Food"])))

    let single = try XCTUnwrap(rows.first { $0.transactionId == plain.id })
    XCTAssertNil(single.parts)
    XCTAssertEqual(single.category, .one(CategoryPath(names: ["Food"])))
  }

  /// The selection holds operations only; a part stands for its operation where a click on
  /// it acts — a double click, the menu.
  func testRowIdsMapToOperations() {
    let order = entry(.expense, [2_500, 250], on: today, hour: 11, category: food.id)
    let plain = entry(.expense, [300], on: today, hour: 9, category: food.id)
    let found = listing([order, plain])
    let part = RowID.part(order.parts[1].id)

    XCTAssertEqual(
      TransactionListing.operations(in: [.transaction(plain.id), part]), [plain.id])
    XCTAssertEqual(found.owners(of: [part]), [order.id])
    XCTAssertEqual(found.owners(of: [.transaction(plain.id), part]), [plain.id, order.id])
    XCTAssertEqual(found.partOwners.count, 2, "only the parts of a split are rows")
  }

  /// A part of a purchase paid for somebody else says who owes it and what became of the
  /// money; a friend's ticket taken back in a refund is about the friend but waits for
  /// nothing.
  func testAPartPaidForSomebodyElseSaysWhoOwesItAndWhatBecameOfIt() throws {
    let dinner = entry(.expense, [1_600, 1_600], on: today, hour: 20, note: "Dinner") { parts in
      for index in parts.indices { parts[index].categoryId = self.food.id }
      parts[1].forWhom = .friends
      parts[1].reimbursable = true
      parts[1].debtorPersonId = self.anna.id
      parts[1].reimbursementStatus = .expected
    }
    let refund = entry(.refund, [700], on: today, hour: 9, category: food.id) { parts in
      parts[0].forWhom = .friends
      parts[0].reimbursable = true
      parts[0].debtorPersonId = self.anna.id
      parts[0].reimbursementStatus = .expected
    }

    let rows = listing([dinner, refund]).sections.flatMap(\.rows)
    let split = try XCTUnwrap(rows.first { $0.transactionId == dinner.id })
    XCTAssertEqual(split.owedMark, .expected)
    XCTAssertEqual(split.forWhom, .several)
    XCTAssertEqual(split.parts?[0].forWhom, .one(.value(.me)))
    XCTAssertEqual(split.parts?[1].forWhom, .one(.owed(by: "Anna", .expected)))

    let taken = try XCTUnwrap(rows.first { $0.transactionId == refund.id })
    XCTAssertNil(taken.owedMark)
    XCTAssertEqual(taken.forWhom, .one(.value(.friends)))
  }

  /// The table shows the newest months first, a few at a time: the operations and parts of
  /// the months not shown are not among those a selection may hold.
  func testTheNewestMonthsComeFirst() {
    let september = entry(.expense, [100], on: today, hour: 9, category: food.id)
    let august = entry(
      .expense, [150, 50], on: DateOnly(year: 2026, month: 8, day: 31), hour: 9,
      category: food.id)
    let augustIncome = entry(
      .income, [1_000], on: DateOnly(year: 2026, month: 8, day: 3), hour: 9, category: salary.id)
    let june = entry(
      .expense, [300, 30], on: DateOnly(year: 2026, month: 6, day: 1), hour: 9, category: food.id)
    let found = listing([june, augustIncome, august, september])
    let months = [MonthKey(year: 2026, month: 9), MonthKey(year: 2026, month: 8)]

    XCTAssertEqual(found.months, months + [MonthKey(year: 2026, month: 6)])
    let page = found.latestMonths(2)
    XCTAssertEqual(page.months, months)
    XCTAssertEqual(page.visibleIds, [september.id, august.id, augustIncome.id])
    XCTAssertEqual(Set(page.partOwners.keys), Set(august.parts.map(\.id)))
    XCTAssertEqual(page.sections.map(\.id), found.sections.prefix(3).map(\.id))
    XCTAssertEqual(found.latestMonths(3).visibleIds, found.visibleIds)
    XCTAssertEqual(found.latestMonths(12).operationCount, 4)
    XCTAssertTrue(found.latestMonths(0).isEmpty)
  }

  // MARK: - «Show more» while the data changes

  /// «Show more» pressed while a filtering of new data runs, the filtering landing last. It
  /// was cut for the months shown when it started: the table shows its new data at once and
  /// is cut again for the months asked for, and the page «Show more» cut from the old data
  /// is dropped when it lands — it would bring deleted operations back to the table.
  func testAFilteringLandingAfterShowMoreIsCutAgainForTheMonthsAskedFor() throws {
    let entries = (2...9).map { month in
      entry(.expense, [100], on: DateOnly(year: 2026, month: month, day: 1), hour: 9)
    }
    let before = listing(entries)
    let after = listing(Array(entries.dropLast()))
    var pages = TransactionPages()
    XCTAssertNil(pages.land(found: before, page: before.latestMonths(3), cutFor: 3))

    // The data changes; its filtering starts with the months shown now.
    let months = pages.monthsShown
    // «Show more» meanwhile.
    let more = try XCTUnwrap(pages.showMore())
    XCTAssertEqual(pages.monthsShown, 6)
    // The filtering lands.
    let again = try XCTUnwrap(
      pages.land(found: after, page: after.latestMonths(months), cutFor: months),
      "the page is to be cut again for the months asked for")
    XCTAssertEqual(again.months, 6)
    XCTAssertEqual(pages.shown?.visibleIds, after.latestMonths(3).visibleIds)
    // The page «Show more» cut from the old data lands, and is dropped.
    XCTAssertFalse(pages.land(before.latestMonths(more.months), for: more))
    XCTAssertEqual(pages.shown?.visibleIds, after.latestMonths(3).visibleIds)
    // The page cut again lands.
    XCTAssertTrue(pages.land(again.listing.latestMonths(again.months), for: again))
    XCTAssertEqual(pages.shown?.visibleIds, after.latestMonths(6).visibleIds)
    XCTAssertFalse(pages.shown?.visibleIds.contains(entries[7].id) ?? true)
  }

  /// «Show more» pressed before a filtering of new data starts: the filtering is cut for the
  /// months asked for and lands first, and the page cut from the old data comes too late.
  /// A new filter starts from the newest months again, and a page cut for more of them is
  /// dropped too.
  func testAPageCutFromAnOlderListingIsDropped() throws {
    let entries = (2...9).map { month in
      entry(.expense, [100], on: DateOnly(year: 2026, month: month, day: 1), hour: 9)
    }
    let before = listing(entries)
    let after = listing(Array(entries.dropLast()))
    var pages = TransactionPages()
    XCTAssertNil(pages.land(found: before, page: before.latestMonths(3), cutFor: 3))

    let more = try XCTUnwrap(pages.showMore())
    XCTAssertNil(pages.land(found: after, page: after.latestMonths(6), cutFor: 6))
    XCTAssertFalse(pages.land(before.latestMonths(more.months), for: more))
    XCTAssertEqual(pages.shown?.visibleIds, after.latestMonths(6).visibleIds)

    let evenMore = try XCTUnwrap(pages.showMore())
    pages.startOver()
    XCTAssertFalse(pages.land(after.latestMonths(evenMore.months), for: evenMore))
    XCTAssertEqual(pages.monthsShown, TransactionListing.monthsPerPage)
    XCTAssertEqual(pages.shown?.visibleIds, after.latestMonths(6).visibleIds)
  }

  /// Select everything, then narrow the filter: only what is still listed stays selected.
  @MainActor
  func testTheSelectionNarrowsToWhatIsListed() {
    let pay = entry(.income, [100_000], on: today, hour: 10, category: salary.id)
    let coffeeToday = entry(.expense, [250], on: today, hour: 9, category: coffee.id)
    let groceries = entry(.expense, [1_800], on: yesterday, hour: 18, category: food.id)
    let entries = [pay, coffeeToday, groceries]
    let actions = OperationActions()
    actions.selection = listing(entries).visibleIds

    actions.keep(only: listing(entries, filter: EntryFilter(kind: .expense)).visibleIds)
    XCTAssertEqual(actions.selection, [coffeeToday.id, groceries.id])
    actions.keep(only: listing(entries, filter: EntryFilter(text: "nothing")).visibleIds)
    XCTAssertEqual(actions.selection, [])
  }

  // MARK: - What names a row

  /// Its description; without one, its category in the secondary style — never a dash —
  /// and without a category, its kind.
  func testARowWithoutADescriptionIsNamedByItsCategory() {
    let tree = CategoryTree([food, coffee, fees, salary])
    let described = entry(.expense, [250], on: today, hour: 9, note: "Latte", category: coffee.id)
    let blank = entry(.expense, [250], on: today, hour: 9, note: "  ", category: coffee.id)
    let bare = entry(.expense, [250], on: today, hour: 9)
    let back = entry(.reimbursement, [700], on: today, hour: 9)

    XCTAssertEqual(RowTitle.of(described, tree: tree), .note("Latte"))
    XCTAssertEqual(
      RowTitle.of(blank, tree: tree), .category(CategoryPath(names: ["Food", "Coffee"])))
    XCTAssertEqual(CategoryPath(names: ["Food", "Coffee"]).text, "Food › Coffee")
    XCTAssertEqual(RowTitle.of(bare, tree: tree), .kind(.expense))
    XCTAssertEqual(RowTitle.of(back, tree: tree), .kind(.reimbursement))
    XCTAssertTrue(RowTitle.of(described, tree: tree).isNote)
    XCTAssertFalse(RowTitle.of(blank, tree: tree).isNote)
  }

  /// A split without a description is named by the first part that has a category; a
  /// retired category is marked so.
  func testASplitIsNamedByItsFirstCategorisedPart() {
    var archived = coffee
    archived.archived = true
    let tree = CategoryTree([food, archived, fees])
    let order = entry(.expense, [100, 200], on: today, hour: 9) { parts in
      parts[1].categoryId = self.coffee.id
    }
    XCTAssertEqual(
      RowTitle.of(order, tree: tree),
      .category(CategoryPath(names: ["Food", "Coffee"], archived: true)))
    // An id the dictionary no longer has names nothing.
    XCTAssertNil(CategoryPath(UUID(), tree: tree))
  }
}

/// The rules of the filters of the sidebar.
final class TransactionFiltersTests: XCTestCase {
  private let groceries = CoreKit.Category(kind: .expense, name: "Groceries")
  private lazy var fruit = CoreKit.Category(
    parentId: groceries.id, kind: .expense, name: "Fruit")
  private let salary = CoreKit.Category(kind: .income, name: "Salary")
  private lazy var tree = [groceries, fruit, salary]
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  /// The type narrows the categories to its kind; a category of the other kind goes with
  /// its subcategory, one of the same kind stays.
  func testTheTypeDropsACategoryOfTheOtherKind() {
    var filters = TransactionFilters(today: today)
    filters.setCategory(groceries.id)
    filters.subcategoryId = fruit.id

    filters.setKind(.refund, tree: tree)
    XCTAssertEqual(filters.categoryId, groceries.id, "a refund files among the spending ones")
    XCTAssertEqual(filters.subcategoryId, fruit.id)

    filters.setKind(.income, tree: tree)
    XCTAssertNil(filters.categoryId)
    XCTAssertNil(filters.subcategoryId)
    XCTAssertEqual(filters.kind, .income)
    XCTAssertEqual(
      TransactionFilters.filterCategories(tree, kind: filters.kind).map(\.id), [salary.id])
  }

  /// Another category drops the subcategory; choosing the same one again keeps it.
  func testAnotherCategoryDropsTheSubcategory() {
    var filters = TransactionFilters(today: today)
    filters.setCategory(groceries.id)
    filters.subcategoryId = fruit.id
    filters.setCategory(groceries.id)
    XCTAssertEqual(filters.subcategoryId, fruit.id)
    filters.setCategory(salary.id)
    XCTAssertNil(filters.subcategoryId)
    filters.setCategory(nil)
    XCTAssertNil(filters.categoryId)
  }

  /// «Reset» takes the filters and the search back to this month with nothing chosen; the
  /// days of a custom range count only while that is the period.
  func testResetBringsEverythingBack() {
    var filters = TransactionFilters(today: today)
    XCTAssertFalse(filters.canReset)
    filters.customStart = DateOnly(year: 2026, month: 1, day: 1)
    XCTAssertFalse(filters.canReset, "a custom day alone changes nothing on screen")
    filters.period = .custom
    filters.setKind(.expense, tree: tree)
    filters.quality = .bad
    filters.status = .expected
    filters.search = "coffee"
    XCTAssertTrue(filters.canReset)

    filters.reset()
    XCTAssertFalse(filters.canReset)
    XCTAssertEqual(filters.period, .allTime, "the whole history, as «Операции» opens")
    XCTAssertNil(filters.kind)
    XCTAssertNil(filters.quality)
    XCTAssertNil(filters.status)
    XCTAssertEqual(filters.search, "")
    XCTAssertEqual(filters.customStart, DateOnly(year: 2026, month: 1, day: 1))
    XCTAssertEqual(filters.entryFilter(today: today), EntryFilter())
  }

  /// A value chosen in the sidebar and archived since — in Settings, or by a restore — is no
  /// longer offered: its picker shows «Any», so the table must not stay filtered by it. A place,
  /// a person and an event are the exception: the archive keeps them in their operations, so the
  /// filter still offers them.
  func testAValueArchivedAfterItWasChosenStopsFilteringButAPlacePersonAndEventStay() {
    let cafe = Place(name: "Cafe")
    let anya = Person(name: "Anya")
    let card = PaymentMethod(name: "Card")
    let trip = Event(
      name: "Trip", startDate: DateOnly(year: 2026, month: 9, day: 1),
      endDate: DateOnly(year: 2026, month: 9, day: 5))
    var filters = TransactionFilters(today: today)
    filters.setCategory(groceries.id)
    filters.subcategoryId = fruit.id
    filters.placeId = cafe.id
    filters.personId = anya.id
    filters.paymentMethodId = card.id
    filters.eventId = trip.id

    // Everything still live: nothing changes.
    filters.keep(
      within: FilterChoices(
        Dataset(
          categories: tree, people: [anya], places: [cafe], events: [trip],
          paymentMethods: [card])))
    XCTAssertEqual(filters.categoryId, groceries.id)
    XCTAssertEqual(filters.subcategoryId, fruit.id)
    XCTAssertEqual(filters.placeId, cafe.id)

    // The subcategory archived: the category stays, the subcategory goes.
    var archivedFruit = fruit
    archivedFruit.archived = true
    filters.keep(
      within: FilterChoices(
        Dataset(
          categories: [groceries, archivedFruit, salary], people: [anya], places: [cafe],
          events: [trip], paymentMethods: [card])))
    XCTAssertEqual(filters.categoryId, groceries.id)
    XCTAssertNil(filters.subcategoryId)

    // The category and every other value archived: all of them go but the place, the person
    // and the event.
    var archivedGroceries = groceries
    archivedGroceries.archived = true
    var archived = (cafe, anya, card, trip)
    archived.0.archived = true
    archived.1.archived = true
    archived.2.archived = true
    archived.3.archived = true
    filters.keep(
      within: FilterChoices(
        Dataset(
          categories: [archivedGroceries, archivedFruit, salary], people: [archived.1],
          places: [archived.0], events: [archived.3], paymentMethods: [archived.2])))
    XCTAssertNil(filters.categoryId)
    // An archived place, person and event stay in their operations and in the filter, which
    // goes on finding them.
    XCTAssertEqual(filters.placeId, cafe.id)
    XCTAssertEqual(filters.personId, anya.id)
    XCTAssertNil(filters.paymentMethodId)
    XCTAssertEqual(filters.eventId, trip.id)
    XCTAssertEqual(
      filters.entryFilter(today: today),
      EntryFilter(personId: anya.id, placeId: cafe.id, eventId: trip.id))
  }

  /// Each period as the core reads it; a custom range in either order; the search trimmed.
  func testThePeriodsAndTheSearchAsTheCoreReadsThem() {
    var filters = TransactionFilters(today: today)
    XCTAssertNil(filters.period(today: today), "the whole history at first")
    filters.period = .thisMonth
    XCTAssertEqual(filters.period(today: today), .month(today.monthKey))
    filters.period = .lastMonth
    XCTAssertEqual(filters.period(today: today), .month(today.monthKey.previous))
    filters.period = .thisYear
    XCTAssertEqual(filters.period(today: today), .year(2026))
    filters.period = .allTime
    XCTAssertNil(filters.period(today: today))
    filters.period = .custom
    filters.customStart = DateOnly(year: 2026, month: 9, day: 10)
    filters.customEnd = DateOnly(year: 2026, month: 9, day: 2)
    XCTAssertEqual(
      filters.period(today: today),
      .days(
        DayRange(DateOnly(year: 2026, month: 9, day: 2), DateOnly(year: 2026, month: 9, day: 10))))

    filters.search = "  bar nord "
    filters.status = .writtenOff
    filters.personId = UUID()
    let filter = filters.entryFilter(today: today)
    XCTAssertEqual(filter.text, "bar nord")
    XCTAssertEqual(filter.reimbursementStatus, .writtenOff)
    XCTAssertEqual(filter.personId, filters.personId)
  }
}

/// The time and the amount always fit their columns (the live run of 19 September: at 48 pt
/// the time read «1…»). A column of the table never goes below its minimum, and the text it
/// holds is measured here in the font the cell draws it with.
@MainActor
final class TransactionColumnWidthTests: XCTestCase {
  private let digits = NSFont.monospacedDigitSystemFont(
    ofSize: NSFont.systemFontSize, weight: .regular)

  private func width(_ text: String) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: digits]).width)
  }

  func testTheTimeFitsItsColumnAfterTheDisclosureTriangle() {
    for time in ["00:00", "23:59", "18:48"] {
      XCTAssertGreaterThanOrEqual(
        TransactionColumnWidths.time, width(time) + TransactionColumnWidths.timeInset, time)
    }
  }

  func testAnAmountOfMillionsFitsItsColumnInBothLanguages() throws {
    let amount = try AmountE4(decimal: Decimal(string: "1234567.89")!)
    for code in ["ru", "en"] {
      let text = MoneyFormatter(locale: Locale(identifier: code)).exact(amount)
      XCTAssertGreaterThanOrEqual(
        TransactionColumnWidths.amount, width(text) + TransactionColumnWidths.amountInset, text)
    }
  }
}

/// «All time» of the large sample (about 20 000 operations over two years, the set of the
/// performance suites): the filtering and the rows of the table, timed the way the window
/// makes them off the main thread. They run in every `make test` — no test is skipped on the
/// author's Mac — and print their numbers for reference only: a Debug build says little about
/// the app's speed, the budgets are `make bench`'s. The output carries times and counts only,
/// never an amount.
final class TransactionTableMeasurementTests: XCTestCase {
  private static let endingOn = DateOnly(year: 2026, month: 9, day: 18)

  /// The large sample and its ledger, built once for both measurements.
  private static let ledger: Ledger = {
    let set = SampleDataGenerator(seed: 20_260_918).generate(
      months: SampleDataGenerator.largeSetMonths, endingOn: endingOn, calendar: .moscow,
      language: "en", density: SampleDataGenerator.largeSetDensity)
    return Ledger(
      dataset: Dataset(
        entries: set.entries, links: set.links, categories: set.categories, people: set.people,
        places: set.places, events: set.events, paymentMethods: set.paymentMethods,
        debts: set.debts, goals: set.goals),
      calendar: .moscow)
  }()

  func testAllTimeOfTheLargeSample() throws {
    let endingOn = Self.endingOn
    let ledger = Self.ledger

    let cases: [(String, EntryFilter)] = [
      ("all time", EntryFilter()),
      ("this month", EntryFilter(period: .month(endingOn.monthKey))),
      ("all time, search «coffee»", EntryFilter(text: "coffee")),
      ("all time, bad", EntryFilter(quality: .bad)),
    ]
    for (name, filter) in cases {
      var filtering: [Duration] = []
      var building: [Duration] = []
      var rows = 0
      var sections = 0
      for run in 0..<6 {
        let clock = ContinuousClock()
        var ids: [UUID] = []
        let filtered = clock.measure { ids = filter.apply(to: ledger) }
        var listing = TransactionListing.empty
        let built = clock.measure { listing = TransactionListing.build(ids, ledger: ledger) }
        // The first run warms up.
        guard run > 0 else { continue }
        filtering.append(filtered)
        building.append(built)
        rows = listing.operationCount
        sections = listing.sections.count
      }
      filtering.sort()
      building.sort()
      print(
        "bench · transactions \(name): \(rows) operations, \(sections) sections;"
          + " filter median \(filtering[2]), max \(filtering[4]);"
          + " rows median \(building[2]), max \(building[4])")
      XCTAssertGreaterThan(rows, 0)
    }
  }

  /// The table itself on «All time»: laid out in a window off screen, one row selected,
  /// everything selected, then jumps down the history — what SwiftUI's `Table` does with the
  /// sections of three months, as the window shows them first, and with all of them. Rough,
  /// since it is not the screen, but it tells a table that copes from one that does not; the
  /// numbers are why the window shows a few months at a time.
  @MainActor
  func testTheTableOfAllTime() throws {
    let ledger = Self.ledger
    let found = TransactionListing.build(EntryFilter().apply(to: ledger), ledger: ledger)
    for months in [TransactionListing.monthsPerPage, found.months.count] {
      measureTable(found.latestMonths(months), label: "\(months) months")
    }
  }

  @MainActor
  private func measureTable(_ listing: TransactionListing, label: String) {
    let environment = AppEnvironment()
    let clock = ContinuousClock()
    // Made once: new stores on every render would read as a change of the environment and
    // redraw every cell, which the window never does.
    let deps = AppDependencies.forTests(environment)
    func table(selecting selection: Set<UUID>) -> AnyView {
      AnyView(
        TransactionsTable(
          deps: deps, listing: listing, selection: .constant(selection),
          menu: { _ in EmptyView() }, primaryAction: { _ in }, deleteAction: { _ in }
        )
        .appDependencies(deps)
        .frame(width: 1_100, height: 700))
    }
    let host = NSHostingView(rootView: table(selecting: []))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 700), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = host
    func settle() {
      host.layoutSubtreeIfNeeded()
      host.display()
      for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    let first = clock.measure { settle() }
    let firstId = listing.sections[0].rows[0].transactionId
    let one = clock.measure {
      host.rootView = table(selecting: [firstId])
      settle()
    }
    let all = clock.measure {
      host.rootView = table(selecting: listing.visibleIds)
      settle()
    }
    var jumps: [Duration] = []
    if let tableView = Self.tableView(in: host) {
      for fraction in [0.25, 0.5, 0.75, 1.0] {
        let row = min(tableView.numberOfRows - 1, Int(Double(tableView.numberOfRows) * fraction))
        jumps.append(
          clock.measure {
            tableView.scrollRowToVisible(row)
            settle()
          })
      }
    }
    print(
      "bench · transactions table, \(label): \(listing.sections.count) sections,"
        + " \(listing.operationCount) operations; first layout \(first), one row selected \(one),"
        + " all selected \(all), jumps \(jumps) (each with 50 ms of settling)")
    window.contentView = nil
  }

  @MainActor
  private static func tableView(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for subview in view.subviews {
      if let found = tableView(in: subview) { return found }
    }
    return nil
  }
}
