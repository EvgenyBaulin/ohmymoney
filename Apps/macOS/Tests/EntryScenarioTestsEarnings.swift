import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Income from the line and what follows it: «смз 15000» files the income under the category
/// taxed as professional income from individuals and shows the tax in grey under the amount —
/// with and without the deduction, on the first and the last day of a year, in dollars at a rate
/// typed by hand —, and an income under «Заработок» (or the category chosen for it) is offered to
/// be allocated, unless it was declined; nothing is offered after an expense.
@MainActor
final class EntryScenarioEarningsTests: EntryScenarioCase {
  private var individuals: CoreKit.Category!
  private var organizations: CoreKit.Category!
  private let on = SelfEmploymentSettings(enabled: true)

  override func setUp() async throws {
    try await super.setUp()
    let selfEmployed = CoreKit.Category(
      parentId: book.earnings.id, kind: .income, name: "Самозанятость")
    organizations = CoreKit.Category(
      parentId: selfEmployed.id, kind: .income, name: "от организаций", sort: 0,
      tax: IncomeTax(rate: 6, npd: true))
    individuals = CoreKit.Category(
      parentId: selfEmployed.id, kind: .income, name: "от физлиц", sort: 1,
      tax: IncomeTax(rate: 4, npd: true))
    for category in [selfEmployed, organizations!, individuals!] {
      try book.references.save(category)
    }
  }

  private func smz(_ line: String, on day: DateOnly? = nil) throws -> EntryDraftModel {
    let model = book.model()
    try book.enter(line, into: model, on: day)
    return model
  }

  private func notice(
    for entry: TransactionEntry, model: EntryDraftModel, said: Bool = false,
    selfEmployment: SelfEmploymentSettings = SelfEmploymentSettings(offered: true),
    allocation: AllocationSettings = .standard
  ) -> EntryLineMessage? {
    EntryAfterSaving.notice(
      for: entry, saidSelfEmployed: said, tree: model.categoryTree,
      selfEmployment: selfEmployment, allocation: allocation, money: book.environment.money)
  }

  // MARK: «смз»

  func testSmzIsIncomeUnderIndividuals() throws {
    let model = try smz("смз 15000")
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertEqual(model.draft.parts.first?.categoryId, individuals.id)
    let entry = try book.save(model)
    XCTAssertEqual(entry.parts.first?.categoryId, individuals.id)
    book.store.undo()
    XCTAssertTrue(try book.entries().isEmpty)
  }

  func testSmzWithANoteKeepsTheNote() throws {
    let model = try smz("смз 15000 логотип")
    XCTAssertEqual(model.draft.note, "логотип")
    XCTAssertTrue(model.lineSaysSelfEmployed)
  }

  func testSmzYesterdayIsIncomeOfYesterday() throws {
    let model = try smz("смз 15000 вчера")
    XCTAssertEqual(book.calendar.day(of: model.draft.occurredAt), book.today.adding(days: -1))
  }

  func testTheTaxOfIndividualsAndOfOrganizations() throws {
    let model = try smz("смз 10000")
    let four = try XCTUnwrap(model.taxEstimate(settings: on, dayRates: .empty, deductionLeft: nil))
    XCTAssertEqual(four.taxE4, AmountE4(whole: 400))
    model.setCategory(organizations.id, forPartAt: 0)
    let six = try XCTUnwrap(model.taxEstimate(settings: on, dayRates: .empty, deductionLeft: nil))
    XCTAssertEqual(six.taxE4, AmountE4(whole: 600))
    XCTAssertEqual(six.rate, 6)
  }

  func testTheDeductionLeftCutsTheRateOfOrganizationsByTwo() throws {
    let model = try smz("смз 10000")
    model.setCategory(organizations.id, forPartAt: 0)
    let cut = try XCTUnwrap(
      model.taxEstimate(settings: on, dayRates: .empty, deductionLeft: AmountE4(whole: 10_000)))
    XCTAssertEqual(cut.rate, 4)
    XCTAssertEqual(cut.taxE4, AmountE4(whole: 400))
  }

  func testTheTaxOfKopecksIsRoundedOnce() throws {
    let model = try smz("смз 1234.56")
    let tax = try XCTUnwrap(model.taxEstimate(settings: on, dayRates: .empty, deductionLeft: nil))
    XCTAssertEqual(tax.taxE4, amount("49.38"))
  }

  func testNoTaxWithSelfEmploymentOff() throws {
    let model = try smz("смз 15000")
    XCTAssertNil(model.taxEstimate(settings: .standard, dayRates: .empty, deductionLeft: nil))
  }

  func testNoTaxOnAnUntaxedIncome() throws {
    let model = book.model()
    try book.enter("+50000 зп", into: model)
    model.setCategory(book.salary.id, forPartAt: 0)
    XCTAssertNil(model.taxEstimate(settings: on, dayRates: .empty, deductionLeft: nil))
  }

  func testATaxInDollarsAtARateTypedByHand() throws {
    let model = try smz("смз 100 usd")
    model.setManualRate("90")
    let tax = try XCTUnwrap(model.taxEstimate(settings: on, dayRates: .empty, deductionLeft: nil))
    XCTAssertEqual(tax.taxE4, AmountE4(whole: 360), "4 % of 9 000 ₽")
  }

  func testTheTaxOnTheLastAndFirstDayOfAYear() throws {
    for day in [DateOnly(year: 2026, month: 12, day: 31), DateOnly(year: 2027, month: 1, day: 1)] {
      let model = try smz("смз 5000", on: day)
      let tax = try XCTUnwrap(
        model.taxEstimate(settings: on, dayRates: .empty, deductionLeft: nil), "\(day)")
      XCTAssertEqual(tax.taxE4, AmountE4(whole: 200), "\(day)")
    }
  }

  // MARK: After the save

  func testSmzWithSelfEmploymentNeverOfferedOffersItOnce() throws {
    let model = try smz("смз 15000")
    let entry = try book.save(model)
    XCTAssertEqual(
      notice(for: entry, model: model, said: true, selfEmployment: .standard),
      .offerSelfEmployment)
    guard case .allocate? = notice(for: entry, model: model, said: true) else {
      return XCTFail("once offered, the income is offered to allocate")
    }
  }

  func testAnIncomeUnderEarningsIsOfferedToAllocate() throws {
    let model = book.model()
    try book.enter("+80000 зарплата", into: model)
    model.setCategory(book.salary.id, forPartAt: 0)
    let entry = try book.save(model)
    guard case .allocate(let id, let text)? = notice(for: entry, model: model) else {
      return XCTFail("no offer")
    }
    XCTAssertEqual(id, entry.id)
    XCTAssertTrue(text.contains("80"), text)
  }

  func testAnIncomeOfAnotherCategoryIsNotOffered() throws {
    let model = book.model()
    try book.enter("+500 кэшбэк", into: model)
    let other = try XCTUnwrap(
      try book.references.categories().first { $0.kind == .income && $0.name == "Cashback" })
    model.setCategory(other.id, forPartAt: 0)
    let entry = try book.save(model)
    XCTAssertNil(notice(for: entry, model: model))
  }

  func testTheCategoryChosenForEarningsIsTheOneOffered() throws {
    let model = book.model()
    try book.enter("+500 кэшбэк", into: model)
    let other = try XCTUnwrap(
      try book.references.categories().first { $0.kind == .income && $0.name == "Cashback" })
    model.setCategory(other.id, forPartAt: 0)
    let entry = try book.save(model)
    let chosen = AllocationSettings(earningsCategoryId: other.id)
    XCTAssertNotNil(notice(for: entry, model: model, allocation: chosen))
    let salary = book.model()
    try book.enter("+80000", into: salary)
    salary.setCategory(book.salary.id, forPartAt: 0)
    let paid = try book.save(salary)
    XCTAssertNil(
      notice(for: paid, model: salary, allocation: chosen), "«Заработок» by name no more")
  }

  func testADeclinedIncomeIsNotOfferedAgain() throws {
    let model = book.model()
    try book.enter("+80000", into: model)
    model.setCategory(book.salary.id, forPartAt: 0)
    let entry = try book.save(model)
    XCTAssertNil(
      notice(for: entry, model: model, allocation: AllocationSettings(declined: [entry.id])))
  }

  func testNothingIsOfferedAfterAnExpense() throws {
    let model = book.model()
    try book.enter("кофе 300", into: model)
    model.setCategory(book.coffeeShops.id, forPartAt: 0)
    let entry = try book.save(model)
    XCTAssertNil(notice(for: entry, model: model, said: true, selfEmployment: .standard))
  }

  func testAnArchivedEarningsIsNoEarnings() throws {
    var archived = book.earnings
    archived.archived = true
    try book.references.save(archived)
    let model = book.model()
    try book.enter("+80000", into: model)
    model.draft.parts[0].categoryId = book.salary.id
    let entry = try book.save(model)
    XCTAssertNil(notice(for: entry, model: model))
  }
}
