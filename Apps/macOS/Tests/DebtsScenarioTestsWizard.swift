import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Новый долг» step by step, every kind: what each step lets through, the debt each kind is
/// saved as, «Как это будет» against the dues the saved debt really has, and the save itself
/// written the way the wizard writes it — one step of ⌘Z.
@MainActor
final class DebtsScenarioTestsWizard: DebtsScenarioCase {
  private func model() -> DebtWizardModel {
    var model = DebtWizardModel(today: today, currency: .rub)
    model.account = card.id
    return model
  }

  /// What «Сохранить» of the wizard writes for `model`.
  @discardableResult
  private func save(_ model: DebtWizardModel) async throws -> Debt? {
    let before = Set(try debts().map(\.id))
    let written: Bool
    if model.kind.isPurchase {
      written = actions.createPurchase(model.purchase)
    } else {
      let debt = model.debt()
      written = actions.create(
        debt, balance: model.amount, on: model.day, moneyMovedNow: model.moneyMoved,
        account: model.account, at: noon(model.day),
        costs: model.kind.isLoan ? model.debtCosts(debtId: debt.id) : [])
    }
    try await show()
    guard written else { return nil }
    return try debts().first { !before.contains($0.id) }
  }

  private func saved(_ model: DebtWizardModel) async throws -> Debt {
    let debt = try await save(model)
    return try XCTUnwrap(debt)
  }

  // MARK: The kinds

  func testTheKindsSayWhichWayTheMoneyIsOwed() {
    let owedToMe: Set<DebtWizardKind> = [.owedToMe, .pledge]
    for kind in DebtWizardKind.allCases {
      XCTAssertEqual(kind.direction, owedToMe.contains(kind) ? .owedToMe : .iOwe, kind.rawValue)
    }
    XCTAssertEqual(DebtWizardKind.allCases.filter(\.isLoan), [.loan, .mortgage, .education])
    XCTAssertEqual(DebtWizardKind.allCases.filter(\.isPurchase), [.instalments, .purchase])
    XCTAssertEqual(Set(DebtWizardKind.allCases.map(\.symbol)).count, DebtWizardKind.allCases.count)
  }

  func testTheDebtOfEachKindHasItsType() {
    var model = model()
    model.name = "X"
    model.amount = money(1_000)
    let types: [DebtWizardKind: DebtType] = [
      .loan: .loan, .mortgage: .loan, .education: .loan, .instalments: .installment,
      .purchase: .installment, .creditCard: .creditCard, .personIOwe: .personal,
      .owedToMe: .personal, .pledge: .personal,
    ]
    for (kind, type) in types {
      model.kind = kind
      XCTAssertEqual(model.debt().type, type, kind.rawValue)
      XCTAssertTrue(model.debt().termsReviewed, kind.rawValue)
    }
  }

  // MARK: The steps

  func testANameOfSpacesOrASumOfNothingDoesNotLeaveTheSecondStep() {
    var model = model()
    model.kind = .personIOwe
    model.name = "   "
    model.amount = money(100)
    XCTAssertFalse(model.canLeave(.amount))
    model.name = "Brother"
    model.amount = .zero
    XCTAssertFalse(model.canLeave(.amount))
    model.amount = money(100)
    XCTAssertTrue(model.canLeave(.amount))
  }

  func testALoanNeedsAPaymentATermOrAGracePeriod() {
    var model = model()
    model.kind = .loan
    model.rateText = "12"
    model.monthly = money(5_000)
    XCTAssertFalse(model.canLeave(.payments), "with a rate, how the bank counts a payment")
    model.schedule.order = .allToDebt
    XCTAssertTrue(model.canLeave(.payments))
    model.monthly = .zero
    XCTAssertFalse(model.canLeave(.payments))
    model.monthly = money(5_000)
    XCTAssertTrue(model.canLeave(.payments))
    model.monthly = .zero
    model.schedule.byTerm = true
    model.schedule.months = 24
    XCTAssertTrue(model.canLeave(.payments))
  }

  func testAnInstalmentPlanNeedsBetweenTwoAndAHundredAndTwentyParts() {
    var model = model()
    model.kind = .instalments
    model.categoryId = home.id
    for (parts, allowed) in [(1, false), (2, true), (120, true), (121, false)] {
      model.parts = parts
      XCTAssertEqual(model.canLeave(.payments), allowed, "\(parts) parts")
    }
  }

  func testAPurchaseOnCreditNeedsItsCategory() {
    var model = model()
    model.kind = .purchase
    XCTAssertFalse(model.canLeave(.payments))
    model.categoryId = home.id
    XCTAssertTrue(model.canLeave(.payments))
  }

  func testAPersonsDebtAndAPledgeHaveNothingToAskAboutPayments() {
    var model = model()
    for kind in [DebtWizardKind.personIOwe, .owedToMe, .pledge, .creditCard] {
      model.kind = kind
      XCTAssertTrue(model.canLeave(.payments), kind.rawValue)
      XCTAssertTrue(model.canLeave(.preview), kind.rawValue)
    }
  }

  // MARK: What the model starts with

  func testOnThe31stThePaymentDayStartsOnThe28th() async throws {
    try await move(to: DateOnly(year: 2027, month: 1, day: 31))
    let model = model()
    XCTAssertEqual(model.paymentDay, 28)
    XCTAssertEqual(model.returnBy, DateOnly(year: 2027, month: 2, day: 28))
    XCTAssertEqual(model.day, today)
  }

  func testAMortgageIsTwentyYearsByTermWithoutAGracePeriod() {
    var model = model()
    model.choose(.mortgage, today: today, language: environment.language)
    XCTAssertTrue(model.schedule.byTerm)
    XCTAssertEqual(model.schedule.months, 240)
    XCTAssertFalse(model.schedule.hasGrace)
  }

  func testTheEducationLoanKeepsANameTyped() {
    var model = model()
    model.name = "University"
    model.choose(.education, today: today, language: environment.language)
    XCTAssertEqual(model.name, "University")
    XCTAssertTrue(model.schedule.hasGrace)
    XCTAssertFalse(model.debt().paymentsAreExpenses)
    var unnamed = self.model()
    unnamed.choose(.education, today: today, language: environment.language)
    XCTAssertFalse(unnamed.name.isEmpty, "the preset names it")
  }

  // MARK: The debt a kind is saved as

  func testAPersonsDebtWithAMonthlySumIsPaidOnItsDay() {
    var model = model()
    model.kind = .personIOwe
    model.monthly = money(1_000)
    model.paymentDay = 12
    XCTAssertEqual(model.debt().monthlyPaymentE4, money(1_000))
    XCTAssertEqual(model.debt().paymentDay, 12)
    model.monthly = .zero
    XCTAssertNil(model.debt().monthlyPaymentE4)
    XCTAssertNil(model.debt().paymentDay)
  }

  func testMoneyOwedToMeIsNeverAnExpense() {
    var model = model()
    model.kind = .owedToMe
    XCTAssertFalse(model.debt().paymentsAreExpenses)
    model.kind = .personIOwe
    XCTAssertTrue(model.debt().paymentsAreExpenses)
  }

  func testTheNoticeOfADayIsStoredAsNone() {
    var model = model()
    model.kind = .loan
    model.monthly = money(5_000)
    XCTAssertNil(model.debt().prepayNoticeDays)
    model.noticeDays = 5
    XCTAssertEqual(model.debt().prepayNoticeDays, 5)
  }

  func testTheRateAndTheFullCostReadWithAComma() {
    var model = model()
    model.kind = .loan
    model.monthly = money(5_000)
    model.rateText = "19,9"
    model.pskText = "27,4"
    XCTAssertEqual(model.debt().interestRate, Decimal(string: "19.9"))
    XCTAssertEqual(model.debt().psk, Decimal(string: "27.4"))
  }

  func testOnlyCostsWithAnAmountAreKeptAndOnlyOnceInTheLoan() {
    var model = model()
    model.costs = [
      .init(kind: .insurance, amount: money(1_000), every: .once, inLoan: true),
      .init(kind: .fee, amount: .zero, every: .once, inLoan: false),
      .init(kind: .other, amount: money(100), every: .monthly, inLoan: true),
    ]
    let costs = model.debtCosts(debtId: UUID())
    XCTAssertEqual(costs.map(\.kind), [.insurance, .other])
    XCTAssertEqual(costs.map(\.inLoan), [true, false])
    XCTAssertEqual(costs.map(\.day), [today, today])
    XCTAssertEqual(costs.map(\.sort), [0, 1])
  }

  // MARK: «Как это будет» and what is saved

  func testThePreviewOfAPlanOnADayOfTheMonthIsTheDuesOfThePlanSaved() async throws {
    try await move(to: DateOnly(year: 2027, month: 1, day: 20))
    var model = model()
    model.kind = .instalments
    model.name = "Phone"
    model.amount = money(12_000)
    model.categoryId = home.id
    model.everyTwoWeeks = false
    model.paymentDay = 31
    model.parts = 3
    let preview = model.preview(calendar: calendar)
    let plan = try await saved(model)
    let dues = try dues(plan.id)
    XCTAssertEqual(preview.rows.map(\.due), (0..<3).map(dues.due))
    XCTAssertEqual(preview.rows.map(\.payment), (0..<3).map { dues.amount(ofDue: $0) })
  }

  func testThePreviewOfAPlanEveryTwoWeeksIsTheDuesOfThePlanSaved() async throws {
    var model = model()
    model.kind = .instalments
    model.name = "Phone"
    model.amount = money(10_000)
    model.markup = money(1_000)
    model.categoryId = home.id
    model.parts = 6
    let preview = model.preview(calendar: calendar)
    let plan = try await saved(model)
    let dues = try dues(plan.id)
    XCTAssertEqual(preview.rows.map(\.due), (0..<6).map(dues.due))
    XCTAssertEqual(preview.rows.map(\.payment), (0..<6).map { dues.amount(ofDue: $0) })
    XCTAssertEqual(preview.rows.last?.balanceAfter, .zero)
    XCTAssertEqual(try balance(plan.id), money(11_000))
  }

  func testThePreviewOfALoanStartsOnTheFirstDueOfTheLoanSaved() async throws {
    var model = model()
    model.kind = .loan
    model.name = "Bank"
    model.amount = money(120_000)
    model.rateText = "12"
    model.schedule.order = .allToDebt
    model.monthly = money(11_000)
    model.paymentDay = 5
    let preview = model.preview(calendar: calendar)
    let loan = try await saved(model)
    XCTAssertEqual(preview.rows.first?.due, try dues(loan.id).firstDue)
    XCTAssertEqual(preview.rows.first?.payment, money(11_000))
    XCTAssertEqual(preview.rows.last?.balanceAfter, .zero)
    XCTAssertGreaterThan(preview.interest.raw, 0)
  }

  func testAFeeHeldBackFromTheLoanIsInThePreviewAndInTheDebt() async throws {
    var model = model()
    model.kind = .loan
    model.name = "Bank"
    model.amount = money(100_000)
    model.rateText = "10"
    model.monthly = money(10_000)
    model.costs = [.init(kind: .fee, amount: money(2_000), every: .once, inLoan: true)]
    let preview = model.preview(calendar: calendar)
    var plain = model
    plain.costs = []
    XCTAssertGreaterThan(preview.payments, plain.preview(calendar: calendar).payments)
    let loan = try await saved(model)
    XCTAssertEqual(try balance(loan.id), money(102_000))
  }

  func testThePreviewOfAPurchaseOnCreditEndsWithWhatIsLeft() {
    var model = model()
    model.kind = .purchase
    model.amount = money(10_000)
    model.monthly = money(3_000)
    let preview = model.preview(calendar: calendar)
    XCTAssertEqual(
      preview.rows.map(\.payment), [money(3_000), money(3_000), money(3_000), money(1_000)])
    XCTAssertEqual(preview.payments, money(10_000))
    model.monthly = .zero
    XCTAssertEqual(model.preview(calendar: calendar).rows, [])
  }

  func testAPersonsDebtHasNoScheduleToPreview() {
    var model = model()
    model.kind = .owedToMe
    model.amount = money(700)
    let preview = model.preview(calendar: calendar)
    XCTAssertEqual(preview.rows, [])
    XCTAssertEqual(preview.payments, money(700))
    XCTAssertNil(preview.cost)
  }

  func testAPledgeSavedIsRemindedWhenItIsDue() async throws {
    var model = model()
    model.choose(.pledge, today: today, language: environment.language)
    model.name = "Bike rental"
    model.amount = money(5_000)
    model.returnBy = today.adding(days: 3)
    let pledge = try await saved(model)
    XCTAssertTrue(pledge.pledge)
    XCTAssertEqual(pledge.direction, .owedToMe)
    XCTAssertTrue(
      try snapshot.planning.debtReminders.contains(
        .pledgeDue(debtId: pledge.id, returnBy: today.adding(days: 3), overdue: false)))
  }

  func testMoneyLentNowFromTheWizardIsCashOnTheAccount() async throws {
    var model = model()
    model.kind = .owedToMe
    model.name = "Brother"
    model.amount = money(2_000)
    model.moneyMoved = true
    model.account = cash.id
    let lent = try await saved(model)
    let line = try XCTUnwrap(try journal(lent.id).first)
    XCTAssertEqual(line.kind, .borrowed)
    XCTAssertEqual(line.paymentMethodId, cash.id)
    XCTAssertEqual(line.occurredAt, noon(today))
  }

  func testAnEducationLoanSavedIsNotAnExpenseAndHasItsGracePeriod() async throws {
    var model = model()
    model.choose(.education, today: today, language: environment.language)
    model.amount = money(300_000)
    XCTAssertFalse(model.canLeave(.payments), "the preset still asks how the bank counts")
    model.schedule.order = .interestFirst
    XCTAssertTrue(model.canLeave(.payments))
    let loan = try await saved(model)
    XCTAssertFalse(loan.paymentsAreExpenses)
    XCTAssertNotNil(loan.grace)
    XCTAssertTrue(loan.hasDues)
    XCTAssertNil(loan.loansSubcategoryId, "its payments are not expenses")
  }

  func testOneUndoTakesAWizardsLoanAndItsCostsAway() async throws {
    var model = model()
    model.kind = .loan
    model.name = "Bank"
    model.amount = money(100_000)
    model.rateText = "10"
    model.monthly = money(10_000)
    model.costs = [.init(kind: .insurance, amount: money(3_000), every: .once, inLoan: false)]
    _ = try await saved(model)
    XCTAssertEqual(try entries().count, 1)
    try await undo()
    XCTAssertEqual(try debts(), [])
    XCTAssertEqual(try entries(), [])
    XCTAssertEqual(try snapshot.dataset.debtCosts, [])
  }
}
