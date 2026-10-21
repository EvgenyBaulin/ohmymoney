import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The rows the credits and the allocation of income brought are rows of the planning: the sums
/// of dues typed from a bank, the costs of a loan, the rules of allocation, the custom
/// currencies, the new terms of a debt, an account, a goal, a category and a transfer, and the
/// main card of an account — each written in one write and one step of ⌘Z, and ⌘Z gives back
/// the database it found, value for value. What a deletion cascades to comes back with it.
@Suite("The rows of the credits and the allocation are one step of ⌘Z")
struct Credit19PlanningUndoTests {
  func tables(_ stack: DatabaseStack) throws -> [String: ExactTable] {
    try stack.writer.read { db in try ExactTables.read(db) }
  }

  /// An account with a card, a loan, a goal and an income category to hang the new rows on.
  struct Book {
    var account = PaymentMethod(name: "Т-Банк", kind: .card)
    var other = PaymentMethod(name: "Сбер", kind: .card)
    var card: PaymentCard
    var loan = Debt(direction: .iOwe, type: .loan, name: "Кредит", interestRate: 19)
    var goal = Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000))
    var income = CoreKit.Category(kind: .income, name: "Самозанятость")

    init() {
      card = PaymentCard(accountId: account.id, name: "Black")
    }
  }

  func book(_ stack: DatabaseStack) throws -> Book {
    let book = Book()
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(
          categories: [book.income], goals: [book.goal], debts: [book.loan],
          paymentMethods: [book.account, book.other], cards: [book.card])))
    return book
  }

  @Test func theNewRowsAreOneStepEach() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let book = try book(stack)
    let step = DebtInstalmentStep(debtId: book.loan.id, fromIndex: 2, amountE4: AmountE4(whole: 9))
    let cost = DebtCost(
      debtId: book.loan.id, kind: .fee, amountE4: AmountE4(whole: 3_000),
      day: DateOnly(year: 2026, month: 10, day: 1))
    let rule = AllocationRule(target: .goal(book.goal.id), amount: .percent(10))
    let cushion = AllocationRule(target: .cushion(book.other.id), amount: .percent(5), sort: 1)
    let currency = CustomCurrency(code: CurrencyCode("TTH"), name: "Tether")
    let rows: [PlanningRows] = [
      PlanningRows(debtInstalments: [step]),
      PlanningRows(debtCosts: [cost]),
      PlanningRows(allocationRules: [rule, cushion]),
      PlanningRows(customCurrencies: [currency]),
      PlanningRows(
        debtInstalments: [step], debtCosts: [cost], allocationRules: [rule],
        customCurrencies: [currency]),
    ]
    for upsert in rows {
      let before = try tables(stack)
      let undo = try repository.apply(PlanningChange(upsert: upsert))
      #expect(undo.inserted.debtInstalments == upsert.debtInstalments.map(\.id))
      #expect(undo.inserted.debtCosts == upsert.debtCosts.map(\.id))
      #expect(undo.inserted.allocationRules == upsert.allocationRules.map(\.id))
      #expect(undo.inserted.customCurrencies == upsert.customCurrencies.map(\.code))
      try stack.writer.read { (db: Database) throws in
        #expect(try DebtInstalmentStep.fetchAll(db) == upsert.debtInstalments)
        #expect(try DebtCost.fetchAll(db) == upsert.debtCosts)
        #expect(try AllocationRule.fetchAll(db) == upsert.allocationRules)
        #expect(try CustomCurrency.fetchAll(db) == upsert.customCurrencies)
      }
      try repository.revert(undo)
      #expect(try tables(stack) == before)
    }
  }

  /// A row written over and a row deleted come back as they were, at their rowids.
  @Test func anEditAndADeletionComeBack() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let book = try book(stack)
    let steps = (0..<3).map {
      DebtInstalmentStep(debtId: book.loan.id, fromIndex: $0, amountE4: AmountE4(whole: 10))
    }
    let cost = DebtCost(
      debtId: book.loan.id, kind: .insurance, amountE4: AmountE4(whole: 45_000),
      day: DateOnly(year: 2026, month: 10, day: 1))
    let rule = AllocationRule(
      target: .account(book.other.id), amount: .fixed(AmountE4(whole: 5), .usd))
    let currency = CustomCurrency(code: CurrencyCode("TTH"), name: "Tether")
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          debtInstalments: steps, debtCosts: [cost], allocationRules: [rule],
          customCurrencies: [currency])))
    let before = try tables(stack)
    var edited = steps[1]
    edited.amountE4 = AmountE4(whole: 11)
    var editedCost = cost
    editedCost.every = .yearly
    var editedRule = rule
    editedRule.active = false
    var editedCurrency = currency
    editedCurrency.archived = true
    let undo = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          debtInstalments: [edited], debtCosts: [editedCost], allocationRules: [editedRule],
          customCurrencies: [editedCurrency]),
        delete: PlanningRowIDs(debtInstalments: [steps[0].id])))
    #expect(undo.before.debtInstalments.map(\.id) == [steps[1].id, steps[0].id])
    #expect(undo.before.customCurrencies == [currency])
    try repository.revert(undo)
    #expect(try tables(stack) == before)

    let gone = try repository.apply(
      PlanningChange(
        delete: PlanningRowIDs(
          debtCosts: [cost.id], allocationRules: [rule.id],
          customCurrencies: [currency.code])))
    try stack.writer.read { (db: Database) throws in
      #expect(try DebtCost.fetchCount(db) == 0)
      #expect(try AllocationRule.fetchCount(db) == 0)
      #expect(try CustomCurrency.fetchCount(db) == 0)
    }
    try repository.revert(gone)
    #expect(try tables(stack) == before)
  }

  /// Deleting a debt takes its sums of dues and its costs along, a goal its rule of allocation,
  /// an account the rules that send money to it, a card the mark of the main card: all of them
  /// come back with ⌘Z.
  @Test func whatADeletionCascadesToComesBack() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let book = try book(stack)
    var account = book.account
    account.mainCardId = book.card.id
    let step = DebtInstalmentStep(debtId: book.loan.id, fromIndex: 0, amountE4: AmountE4(whole: 9))
    let cost = DebtCost(
      debtId: book.loan.id, kind: .fee, amountE4: AmountE4(whole: 3_000),
      day: DateOnly(year: 2026, month: 10, day: 1))
    let rule = AllocationRule(target: .goal(book.goal.id), amount: .percent(10))
    let toAccount = AllocationRule(
      target: .account(book.other.id), amount: .percent(3), sort: 1)
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          paymentMethods: [account], debtInstalments: [step], debtCosts: [cost],
          allocationRules: [rule, toAccount])))
    try stack.writer.read { (db: Database) throws in
      #expect(
        try PaymentMethod.fetchOne(db, key: account.id.uuidString)?.mainCardId == book.card.id)
    }
    let before = try tables(stack)
    let undo = try repository.apply(
      PlanningChange(
        delete: PlanningRowIDs(
          goals: [book.goal.id], debts: [book.loan.id], paymentMethods: [book.other.id],
          cards: [book.card.id])))
    try stack.writer.read { (db: Database) throws in
      #expect(try DebtInstalmentStep.fetchCount(db) == 0)
      #expect(try DebtCost.fetchCount(db) == 0)
      #expect(try AllocationRule.fetchCount(db) == 0)
      #expect(try PaymentMethod.fetchOne(db, key: account.id.uuidString)?.mainCardId == nil)
    }
    try repository.revert(undo)
    #expect(try tables(stack) == before)
  }

  /// An account written with its main card and its new card in one change: the account goes in
  /// first and takes the card once it is there; ⌘Z takes both away.
  @Test func anAccountTakesItsMainCardInTheSameStep() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let before = try tables(stack)
    var account = PaymentMethod(name: "Альфа", kind: .card)
    let card = PaymentCard(accountId: account.id, name: "Альфа")
    account.mainCardId = card.id
    account.credit = CreditCardTerms(
      limitE4: AmountE4(whole: 100_000), grace: .fromPurchase(days: 100),
      purchaseRate: Decimal(string: "34.9"))
    let undo = try repository.apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [account], cards: [card])))
    try stack.writer.read { (db: Database) throws in
      #expect(try PaymentMethod.fetchOne(db, key: account.id.uuidString) == account)
    }
    try repository.revert(undo)
    #expect(try tables(stack) == before)
  }

  /// The new terms of the rows that were there — a debt, an account, a goal, a category, a
  /// journal line, a transfer — and the settings of 1.9 are written over and given back.
  @Test func theNewTermsOfOlderRowsComeBack() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let book = try book(stack)
    let line = DebtEntry(debtId: book.loan.id, amountE4: AmountE4(whole: -1_000), kind: .payment)
    let transfer = Transfer(
      occurredAt: Date(timeIntervalSince1970: 1_790_000_000), fromAccountId: book.account.id,
      fromCurrency: .rub, fromAmountE4: AmountE4(whole: 10), toAccountId: book.other.id,
      toCurrency: .rub, toAmountE4: AmountE4(whole: 10),
      createdAt: Date(timeIntervalSince1970: 1_790_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
    _ = try repository.apply(
      PlanningChange(upsert: PlanningRows(debtEntries: [line], transfers: [transfer])))
    let before = try tables(stack)
    var loan = book.loan
    loan.psk = Decimal(string: "21.5")
    loan.prepayAnyDay = false
    loan.prepayNoticeDays = 5
    loan.plannedPrepay = PlannedPrepay(
      day: DateOnly(year: 2026, month: 12, day: 1), amountE4: AmountE4(whole: 50_000))
    loan.inLadder = false
    loan.termsReviewed = true
    var account = book.account
    account.mainCardId = book.card.id
    account.credit = CreditCardTerms(
      limitE4: AmountE4(whole: 150_000), grace: .statement(day: 5, payDays: 25))
    var goal = book.goal
    goal.accountId = book.other.id
    goal.transfersOnContribution = true
    var income = book.income
    income.tax = IncomeTax(rate: 4, npd: true)
    var prepaid = line
    prepaid.prepay = .term
    var allocated = transfer
    allocated.externalId = "alloc:\(UUID().uuidString):\(UUID().uuidString)"
    var settings: [String: String?] = [:]
    settings.merge(SelfEmploymentSettings(enabled: true).storedValues) { $1 }
    settings.merge(AllocationSettings(monthRestTarget: .cushion).storedValues) { $1 }
    settings.merge(DebtSettings(nudgeTemplate: "{имя}").storedValues) { $1 }
    let undo = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          categories: [income], goals: [goal], debts: [loan], debtEntries: [prepaid],
          paymentMethods: [account], transfers: [allocated]),
        settings: settings))
    try stack.writer.read { (db: Database) throws in
      #expect(try Debt.fetchOne(db, key: loan.id.uuidString) == loan)
      #expect(try PaymentMethod.fetchOne(db, key: account.id.uuidString) == account)
      #expect(try Goal.fetchOne(db, key: goal.id.uuidString) == goal)
      #expect(try CoreKit.Category.fetchOne(db, key: income.id.uuidString) == income)
      #expect(try DebtEntry.fetchOne(db, key: line.id.uuidString) == prepaid)
      #expect(try Transfer.fetchOne(db, key: transfer.id.uuidString) == allocated)
    }
    try repository.revert(undo)
    #expect(try tables(stack) == before)
  }

  /// An account a goal keeps its money on is used: the planning refuses to delete it.
  @Test func anAccountAGoalIsKeptOnIsNotDeleted() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let book = try book(stack)
    var goal = book.goal
    goal.accountId = book.other.id
    _ = try repository.apply(PlanningChange(upsert: PlanningRows(goals: [goal])))
    #expect(throws: PlanningWriteError.referencedByOperations(book.other.id)) {
      try repository.apply(PlanningChange(delete: PlanningRowIDs(paymentMethods: [book.other.id])))
    }
  }
}
