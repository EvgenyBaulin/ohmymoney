import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Money owed to me: the debts of a person gathered on one card, money given back in parts and
/// above the debt, a pledge with the days its reminder shows, a pledge written off as a loss in
/// the category chosen, the polite reminder and its template — each write one step of ⌘Z.
@MainActor
final class DebtsScenarioTestsOwedToMe: DebtsScenarioCase {
  private func person(_ name: String) throws -> Person {
    let person = Person(name: name, relation: .friend)
    try XCTUnwrap(environment.references).save(person)
    return person
  }

  @discardableResult
  private func lend(
    _ whole: Int64, to person: Person?, name: String, daysAgo: Int = 3
  ) async throws -> Debt {
    let debt = Debt(direction: .owedToMe, type: .personal, name: name, personId: person?.id)
    XCTAssertTrue(
      actions.create(
        debt, balance: money(whole), on: today.adding(days: -daysAgo), moneyMovedNow: false))
    try await show()
    return try self.debt(debt.id)
  }

  // MARK: The card of a person

  func testTwoDebtsOfOnePersonAreOneGroupWithTheirTotal() async throws {
    let anna = try person("Anna")
    let first = try await lend(1_000, to: anna, name: "Lunch")
    let second = try await lend(2_500, to: anna, name: "Tickets")
    let group = try XCTUnwrap(
      try snapshot.planning.debts.owedToMe.first { $0.personId == anna.id })
    XCTAssertEqual(Set(group.debts.map(\.id)), [first.id, second.id])
    XCTAssertEqual(group.totalRub, money(3_500))
    XCTAssertEqual(try snapshot.planning.debts.totalOwedToMeRub, money(3_500))
  }

  func testTheLargestGroupComesFirstAndTheOneWithoutAPersonLast() async throws {
    let anna = try person("Anna")
    let boris = try person("Boris")
    try await lend(1_000, to: anna, name: "Small")
    try await lend(9_000, to: boris, name: "Large")
    try await lend(50_000, to: nil, name: "Nobody")
    let groups = try snapshot.planning.debts.owedToMe
    XCTAssertEqual(groups.map(\.personId), [boris.id, anna.id, nil])
  }

  func testTheOldestExpectationIsTheEarliestLineOfAnOpenDebt() async throws {
    let anna = try person("Anna")
    try await lend(1_000, to: anna, name: "Old", daysAgo: 20)
    try await lend(1_000, to: anna, name: "New", daysAgo: 2)
    let group = try XCTUnwrap(
      try snapshot.planning.debts.owedToMe.first { $0.personId == anna.id })
    XCTAssertEqual(group.oldest, today.adding(days: -20))
  }

  func testAPaidBackDebtLeavesThePersonsCard() async throws {
    let anna = try person("Anna")
    let lent = try await lend(1_000, to: anna, name: "Lunch")
    try await pay(lent, 1_000, closing: true)
    XCTAssertNil(try snapshot.planning.debts.owedToMe.first { $0.personId == anna.id })
    XCTAssertTrue(try snapshot.planning.debts.closed.contains { $0.id == lent.id })
  }

  // MARK: Money given back

  func testMoneyBackNamesThePersonOfTheDebt() async throws {
    let anna = try person("Anna")
    let lent = try await lend(3_000, to: anna, name: "Lunch")
    try await pay(lent, 1_000)
    XCTAssertEqual(try payments(of: lent.id).first?.parts.first?.forPersonId, anna.id)
    XCTAssertNil(try payments(of: lent.id).first?.parts.first?.categoryId)
  }

  func testMoneyBackInThreePartsClosesTheDebtOnTheLastOnly() async throws {
    let lent = try await lend(3_000, to: nil, name: "Lunch")
    for index in 0..<3 {
      try await pay(lent, 1_000, closing: true)
      XCTAssertEqual(try debt(lent.id).closed, index == 2)
    }
    XCTAssertEqual(try balance(lent.id), .zero)
    XCTAssertTrue(try entries().allSatisfy { $0.transaction.kind == .reimbursement })
  }

  func testMoneyBackLeftOpenStillClosesWhenItIsAllOfIt() async throws {
    let lent = try await lend(3_000, to: nil, name: "Lunch")
    try await pay(lent, 3_000, closing: false)
    XCTAssertEqual(try balance(lent.id), .zero)
  }

  func testMoneyBackAboveTheDebtLeftOpenIsSurchargeToo() async throws {
    let lent = try await lend(3_000, to: nil, name: "Lunch")
    try await pay(lent, 3_500, closing: false)
    XCTAssertEqual(try balance(lent.id), .zero, "the journal takes only what was owed")
    XCTAssertEqual(
      try entries().filter { $0.transaction.kind == .income }.map(\.transaction.amountE4),
      [money(500)])
  }

  func testTheSurchargeIsOnTheAccountTheMoneyCameTo() async throws {
    let lent = try await lend(3_000, to: nil, name: "Lunch")
    try await pay(lent, 4_000, closing: true, account: cash.id)
    let income = try XCTUnwrap(try entries().first { $0.transaction.kind == .income })
    XCTAssertEqual(income.transaction.paymentMethodId, cash.id)
    let surcharges = try XCTUnwrap(
      try XCTUnwrap(environment.references).category(systemRole: .surcharges, kind: .income))
    XCTAssertEqual(income.parts.first?.categoryId, surcharges.id)
  }

  func testDollarsBackOnADollarDebtCountInDollars() async throws {
    let debt = Debt(direction: .owedToMe, type: .personal, name: "Trip", currency: .usd)
    XCTAssertTrue(
      actions.create(debt, balance: money(200), on: today, moneyMovedNow: false))
    try await show()
    try await pay(try self.debt(debt.id), 50, account: wallet.id)
    XCTAssertEqual(try balance(debt.id), money(150))
    XCTAssertEqual(try snapshot.planning.debts.totalOwedToMeRub, money(13_500))
  }

  // MARK: A pledge

  private func pledgeReminder(_ id: UUID) throws -> DebtReminder? {
    try snapshot.planning.debtReminders.first {
      if case .pledgeDue(let debtId, _, _) = $0 { debtId == id } else { false }
    }
  }

  func testAPledgeIsRemindedOfSevenDaysBeforeItIsDueBack() async throws {
    let start = today
    let returnBy = start.adding(days: 20)
    let pledge = try await makeOwedToMe(owed: 30_000, pledge: true, returnBy: returnBy)
    XCTAssertNil(try pledgeReminder(pledge.id))
    try await move(to: returnBy.adding(days: -8))
    XCTAssertNil(try pledgeReminder(pledge.id))
    try await move(to: returnBy.adding(days: -7))
    XCTAssertEqual(
      try pledgeReminder(pledge.id),
      .pledgeDue(debtId: pledge.id, returnBy: returnBy, overdue: false))
    try await move(to: returnBy)
    XCTAssertEqual(
      try pledgeReminder(pledge.id),
      .pledgeDue(debtId: pledge.id, returnBy: returnBy, overdue: false))
    try await move(to: returnBy.adding(days: 1))
    XCTAssertEqual(
      try pledgeReminder(pledge.id),
      .pledgeDue(debtId: pledge.id, returnBy: returnBy, overdue: true))
  }

  func testAPledgeGivenBackIsRemindedOfNoMore() async throws {
    let pledge = try await makeOwedToMe(
      owed: 30_000, pledge: true, returnBy: today.adding(days: 2))
    XCTAssertNotNil(try pledgeReminder(pledge.id))
    try await pay(pledge, 30_000, closing: true)
    XCTAssertNil(try pledgeReminder(pledge.id))
  }

  func testAPledgeWithoutADayIsNeverReminded() async throws {
    let pledge = try await makeOwedToMe(owed: 30_000, pledge: true, returnBy: nil)
    try await move(to: today.adding(days: 400))
    XCTAssertNil(try pledgeReminder(pledge.id))
  }

  func testAPledgeIsNoExpenseWhileItIsOwed() async throws {
    _ = try await makeOwedToMe(owed: 30_000, pledge: true, returnBy: today.adding(days: 30))
    XCTAssertEqual(try entries(), [])
  }

  func testAPledgePartlyGivenBackIsWrittenOffForTheRest() async throws {
    let pledge = try await makeOwedToMe(
      owed: 30_000, pledge: true, returnBy: today.adding(days: 30))
    try await pay(pledge, 20_000)
    XCTAssertTrue(actions.writeOffPledge(try debt(pledge.id), categoryId: home.id, on: today))
    let loss = try XCTUnwrap(
      try entries().first { $0.transaction.externalId == DebtRules.pledgeLossKey(of: pledge.id) })
    XCTAssertEqual(loss.transaction.amountE4, money(10_000))
    XCTAssertEqual(loss.transaction.creditDebtId, pledge.id)
    XCTAssertTrue(try debt(pledge.id).closed)
    XCTAssertEqual(try balance(pledge.id), .zero)
    let tree = CategoryTree(try categories())
    XCTAssertFalse(AccountBalances.movesMoney(loss, tree: tree), "the money left long ago")
  }

  func testOnlyAPledgeWithSomethingLeftIsWrittenOff() async throws {
    let plain = try await makeOwedToMe(owed: 1_000)
    XCTAssertFalse(actions.writeOffPledge(plain, categoryId: home.id, on: today))
    let pledge = try await makeOwedToMe(
      name: "Deposit", owed: 1_000, pledge: true, returnBy: today)
    try await pay(pledge, 1_000)
    XCTAssertFalse(actions.writeOffPledge(try debt(pledge.id), categoryId: home.id, on: today))
    XCTAssertEqual(
      try entries().filter { $0.transaction.externalId == DebtRules.pledgeLossKey(of: pledge.id) },
      [])
  }

  func testAPledgeWrittenOffIsNotWrittenOffTwice() async throws {
    let pledge = try await makeOwedToMe(owed: 5_000, pledge: true, returnBy: today)
    XCTAssertTrue(actions.writeOffPledge(pledge, categoryId: home.id, on: today))
    XCTAssertFalse(actions.writeOffPledge(try debt(pledge.id), categoryId: home.id, on: today))
    XCTAssertEqual(try entries().count, 1)
  }

  func testTheLossOfAPledgeIsMySpendingOfItsDay() async throws {
    let pledge = try await makeOwedToMe(owed: 5_000, pledge: true, returnBy: today)
    let day = today.adding(days: 3)
    XCTAssertTrue(actions.writeOffPledge(pledge, categoryId: home.id, on: day))
    let loss = try XCTUnwrap(try entries().first)
    XCTAssertEqual(calendar.day(of: loss.transaction.occurredAt), day)
    XCTAssertEqual(loss.transaction.kind, .expense)
  }

  // MARK: The polite reminder

  func testThePoliteReminderFillsTheTemplateAndDropsAPhraseWithoutItsValue() {
    let template = "{name}, please return {amount}[ for {for}]."
    XCTAssertEqual(
      NudgeSheet.text(
        template: template,
        values: NudgeText.Values(name: "Anna", amount: "2,000 ₽", reason: "the tickets")),
      "Anna, please return 2,000 ₽ for the tickets.")
    XCTAssertEqual(
      NudgeSheet.text(
        template: template, values: NudgeText.Values(name: "Anna", amount: "2,000 ₽")),
      "Anna, please return 2,000 ₽.")
  }

  func testTheTemplateOfTheReminderIsOneStepOfUndo() async throws {
    var settings = DebtSettings.standard
    settings.nudgeTemplate = "{name}: {amount}"
    XCTAssertTrue(actions.saveSettings(settings))
    settings.nudgeTemplate = "{name}, {amount} please"
    XCTAssertTrue(actions.saveSettings(settings))
    try await show()
    XCTAssertEqual(try snapshot.dataset.debtSettings.nudgeTemplate, "{name}, {amount} please")
    try await undo()
    XCTAssertEqual(try snapshot.dataset.debtSettings.nudgeTemplate, "{name}: {amount}")
  }

  func testTheNudgeIsOfferedOnAnOpenDebtOwedToMeOnly() async throws {
    let lent = try await makeOwedToMe()
    XCTAssertEqual(DebtMoreAction.offered(for: lent), [.nudge])
    let loan = try await makeLoan()
    XCTAssertFalse(DebtMoreAction.offered(for: loan).contains(.nudge))
  }
}
