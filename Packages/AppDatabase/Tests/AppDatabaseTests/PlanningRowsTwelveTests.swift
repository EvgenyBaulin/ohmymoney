import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The rows the cards brought to the planning — the cards and their cashback rules — and what
/// the deletions of accounts, categories, events, debts and goals do to them: every one is one
/// write and one step of ⌘Z, and ⌘Z gives back the database it found, value for value.
@Suite("Cards, rules and the deletions around them are one step of ⌘Z")
struct PlanningRowsTwelveTests {
  let at = Date(timeIntervalSince1970: 1_789_900_000)

  func tables(_ stack: DatabaseStack) throws -> [String: ExactTable] {
    try stack.writer.read { db in try ExactTables.read(db) }
  }

  /// One expense of 1 000 rubles on `account`, naming `card` and put into `goal` when given.
  func operation(
    on account: UUID?, card: UUID? = nil, goal: UUID? = nil, category: UUID? = nil,
    amount: Int64 = 1_000
  ) -> TransactionEntry {
    let transaction = CoreKit.Transaction(
      kind: .expense, occurredAt: at, amountE4: AmountE4(whole: amount), paymentMethodId: account,
      createdAt: at, updatedAt: at, cardId: card)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: transaction.id, categoryId: category, amountE4: AmountE4(whole: amount),
          goalId: goal)
      ])
  }

  func rule(
    _ account: UUID, card: UUID? = nil, category: UUID? = nil, month: MonthKey? = nil,
    percentE4: Int64 = 15_000
  ) -> CashbackRule {
    CashbackRule(
      accountId: account, cardId: card, categoryId: category, month: month,
      percent: CashbackPercent(e4: percentE4) ?? .zero)
  }

  // MARK: Cards and rules

  @Test func aCardAndItsRulesAreOneStep() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let before = try tables(stack)
    let account = references.paymentMethod.id
    let card = PaymentCard(accountId: account, name: "Virtual", aliases: ["virt"], sort: 1)
    let rules = [
      rule(account, card: card.id, category: references.category.id),
      rule(account, card: card.id, month: MonthKey(year: 2026, month: 9), percentE4: 50_000),
    ]
    let undo = try repository.apply(
      PlanningChange(upsert: PlanningRows(cards: [card], cashbackRules: rules)))
    #expect(undo.inserted.cards == [card.id])
    #expect(undo.inserted.cashbackRules == rules.map(\.id))
    let written = try stack.writer.read { db in
      (try PaymentCard.fetchAll(db), try CashbackRule.order(Column.rowID).fetchAll(db))
    }
    #expect(written.0 == [card])
    #expect(written.1 == rules)

    // An edit of both is one step too, and ⌘Z gives the first version back.
    var renamed = card
    renamed.name = "Virtual 2"
    var raised = rules[0]
    raised.percent = CashbackPercent(e4: 20_000) ?? .zero
    let afterFirst = try tables(stack)
    let edit = try repository.apply(
      PlanningChange(upsert: PlanningRows(cards: [renamed], cashbackRules: [raised])))
    #expect(edit.before.cards == [card])
    #expect(edit.before.cashbackRules == [rules[0]])
    try repository.revert(edit)
    #expect(try tables(stack) == afterFirst)

    try repository.revert(undo)
    #expect(try tables(stack) == before)
  }

  /// A card an operation — in the bin too — or a scheduled payment names is archived, never
  /// deleted: undoing the operation's deletion would bring it back naming nothing.
  @Test func aUsedCardIsRefused() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let account = references.paymentMethod.id
    let paid = PaymentCard(accountId: account, name: "Paid")
    let binned = PaymentCard(accountId: account, name: "Binned")
    let scheduled = PaymentCard(accountId: account, name: "Scheduled")
    let free = PaymentCard(accountId: account, name: "Free")
    _ = try repository.apply(
      PlanningChange(upsert: PlanningRows(cards: [paid, binned, scheduled, free])))
    let transactions = TransactionRepository(writer: stack.writer)
    try transactions.save(operation(on: account, card: paid.id))
    let gone = operation(on: account, card: binned.id)
    try transactions.save(gone)
    try transactions.softDelete(id: gone.id, at: at)
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          scheduled: [
            ScheduledPayment(
              name: "Music", amountE4: AmountE4(whole: 299), paymentMethodId: account,
              cardId: scheduled.id)
          ])))

    for card in [paid, binned, scheduled] {
      #expect(throws: PlanningWriteError.referencedByOperations(card.id)) {
        try repository.apply(PlanningChange(delete: PlanningRowIDs(cards: [card.id])))
      }
    }
    let undo = try repository.apply(PlanningChange(delete: PlanningRowIDs(cards: [free.id])))
    #expect(undo.before.cards == [free])
    #expect(try stack.writer.read { db in try PaymentCard.fetchCount(db) } == 3)
  }

  @Test func deletingACardKeepsItsRulesForUndo() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let account = references.paymentMethod.id
    let card = PaymentCard(accountId: account, name: "Old")
    let rules = [
      rule(account, card: card.id), rule(account, card: card.id, category: references.category.id),
    ]
    let accountRule = rule(account, percentE4: 10_000)
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(cards: [card], cashbackRules: rules + [accountRule])))
    let before = try tables(stack)

    let undo = try repository.apply(PlanningChange(delete: PlanningRowIDs(cards: [card.id])))
    #expect(Set(undo.before.cashbackRules) == Set(rules))
    #expect(
      try stack.writer.read { db in try CashbackRule.fetchAll(db) } == [accountRule])
    try repository.revert(undo)
    #expect(try tables(stack) == before)
  }

  // MARK: What goes with an account, a category, an event

  /// An account nothing moved money on goes with its cards and every rule on it, and an income
  /// expected on it lets go of it; ⌘Z brings back all of it, in its place.
  @Test func deletingAnAccountTakesItsCardsAndRulesAndUndoBringsThemBack() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let spare = PaymentMethod(name: "Spare", kind: .card, currency: .rub)
    let card = PaymentCard(accountId: spare.id, name: "Spare card")
    let expected = ExpectedIncome(
      name: "Refund of the deposit", totalE4: AmountE4(whole: 5_000), paymentMethodId: spare.id)
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          expected: [expected], paymentMethods: [spare], cards: [card],
          cashbackRules: [
            rule(spare.id, card: card.id, category: references.category.id),
            rule(references.paymentMethod.id),
          ])))
    // The rule of the account itself, while it had no card, stays next to the card's.
    _ = try repository.apply(
      PlanningChange(upsert: PlanningRows(cashbackRules: [rule(spare.id, percentE4: 5_000)])))
    let before = try tables(stack)
    #expect(try AccountRepository(writer: stack.writer).usage(of: spare.id).isUsed == false)

    let undo = try repository.apply(
      PlanningChange(delete: PlanningRowIDs(paymentMethods: [spare.id])))
    let after = try stack.writer.read { db in
      (
        try PaymentCard.fetchCount(db),
        try CashbackRule.fetchAll(db).map(\.accountId),
        try ExpectedIncome.fetchOne(db, key: expected.id.uuidString)?.paymentMethodId
      )
    }
    #expect(after.0 == 0)
    #expect(after.1 == [references.paymentMethod.id])
    #expect(after.2 == nil)
    #expect(undo.before.cards == [card])
    #expect(undo.before.cashbackRules.count == 2)
    #expect(undo.before.expected == [expected])

    try repository.revert(undo)
    #expect(try tables(stack) == before)
  }

  @Test func deletingACategoryTakesItsRulesAndUndoBringsThemBack() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let account = references.paymentMethod.id
    let travel = CoreKit.Category(kind: .expense, name: "Travel")
    let hotels = CoreKit.Category(parentId: travel.id, kind: .expense, name: "Hotels")
    let card = PaymentCard(accountId: account, name: "Travel card")
    let rules = [
      rule(account, card: card.id, category: hotels.id, percentE4: 100_000),
      rule(account, card: card.id, category: travel.id, month: MonthKey(year: 2026, month: 9)),
      rule(account, card: card.id),
    ]
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(categories: [travel, hotels], cards: [card], cashbackRules: rules)))
    let before = try tables(stack)

    let undo = try repository.apply(
      PlanningChange(delete: PlanningRowIDs(categories: [travel.id, hotels.id])))
    #expect(try stack.writer.read { db in try CashbackRule.fetchAll(db) } == [rules[2]])
    #expect(Set(undo.before.cashbackRules) == Set(rules.prefix(2)))
    try repository.revert(undo)
    #expect(try tables(stack) == before)
  }

  /// An event a payment belongs to lets the payment go when the planning deletes it — the
  /// payment stays, outside any event — and ⌘Z ties it back.
  @Test func deletingAnEventLetsItsPaymentsGoAndUndoTiesThemBack() throws {
    let stack = try TestSupport.makeStack()
    _ = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let wedding = Event(
      name: "Wedding", kind: .other, startDate: DateOnly(year: 2026, month: 10, day: 1),
      endDate: DateOnly(year: 2026, month: 10, day: 2), budgetE4: AmountE4(whole: 100_000))
    let venue = ScheduledPayment(
      name: "Venue", amountE4: AmountE4(whole: 30_000), eventId: wedding.id)
    let flowers = ScheduledPayment(
      name: "Flowers", amountE4: AmountE4(whole: 5_000), eventId: wedding.id)
    _ = try repository.apply(
      PlanningChange(upsert: PlanningRows(events: [wedding], scheduled: [venue, flowers])))
    let before = try tables(stack)

    let undo = try repository.apply(PlanningChange(delete: PlanningRowIDs(events: [wedding.id])))
    let payments = try repository.scheduled()
    #expect(payments.count == 2)
    #expect(payments.allSatisfy { $0.eventId == nil })
    #expect(Set(undo.before.scheduled) == [venue, flowers])
    try repository.revert(undo)
    #expect(try tables(stack) == before)
    #expect(try repository.scheduled().allSatisfy { $0.eventId == wedding.id })
  }

  /// A debt deleted is a debt written with the moment of its deletion; ⌘Z takes the moment
  /// back, and the dataset puts it apart while it is deleted.
  @Test func aDebtDeletedAndUndone() async throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let before = try tables(stack)
    var deleted = references.debt
    deleted.deletedAt = at
    let undo = try repository.apply(PlanningChange(upsert: PlanningRows(debts: [deleted])))
    #expect(undo.before.debts == [references.debt])
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    #expect(!dataset.debts.contains { $0.id == deleted.id })
    #expect(dataset.deletedDebts.map(\.id) == [deleted.id])
    #expect(dataset.deletedDebts.first?.deletedAt == at)

    try repository.revert(undo)
    #expect(try tables(stack) == before)
    let back = try await DatasetRepository(writer: stack.writer).load(version: 0)
    #expect(back.debts.contains { $0.id == deleted.id })
    #expect(back.deletedDebts.isEmpty)
  }

  // MARK: A goal deleted with the parts put into it

  /// Two contributions to a goal, one of them in the bin, and one to another goal.
  func goalBook() throws -> (
    stack: DatabaseStack, goal: Goal, other: Goal, parts: [UUID], otherPart: UUID
  ) {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let goal = Goal(name: "Old trip", targetE4: AmountE4(whole: 50_000), archived: true)
    let other = Goal(name: "Car", targetE4: AmountE4(whole: 500_000))
    let repository = PlanningRepository(writer: stack.writer)
    _ = try repository.apply(PlanningChange(upsert: PlanningRows(goals: [goal, other])))
    let account = references.paymentMethod.id
    let live = operation(on: account, goal: goal.id, category: references.category.id)
    let binned = operation(
      on: account, goal: goal.id, category: references.category.id, amount: 400)
    let elsewhere = operation(on: account, goal: other.id, category: references.category.id)
    let transactions = TransactionRepository(writer: stack.writer)
    try transactions.insert([live, binned, elsewhere])
    try transactions.softDelete(id: binned.id, at: at)
    return (
      stack, goal, other, [live.parts[0].id, binned.parts[0].id], elsewhere.parts[0].id
    )
  }

  func goalOfParts(_ ids: [UUID], _ stack: DatabaseStack) throws -> [UUID?] {
    try stack.writer.read { db in
      try ids.map { id in
        try TransactionPart.fetchOne(db, key: id.uuidString)?.goalId
      }
    }
  }

  @Test func aGoalDeletedWithUnlinkingLetsItsPartsGo() throws {
    let book = try goalBook()
    let repository = PlanningRepository(writer: book.stack.writer)
    let money = try book.stack.writer.read { db in
      try Row.fetchAll(db, sql: "SELECT id, amount_e4, category_id FROM transaction_parts")
    }
    let undo = try repository.apply(
      PlanningChange(
        delete: PlanningRowIDs(goals: [book.goal.id]),
        unlinking: PlanningRowIDs(goals: [book.goal.id])))
    #expect(try goalOfParts(book.parts, book.stack) == [nil, nil])
    #expect(try goalOfParts([book.otherPart], book.stack) == [book.other.id])
    let goals = try ReferenceRepository(writer: book.stack.writer).goals(includeArchived: true)
    #expect(!goals.contains { $0.id == book.goal.id })
    #expect(goals.contains { $0.id == book.other.id })
    #expect(undo.cleared.map(\.referencedId) == [book.goal.id, book.goal.id])
    #expect(Set(undo.cleared.map(\.rowId)) == Set(book.parts.map(\.uuidString)))
    // Only the goal: the money and the category of every part stay.
    let after = try book.stack.writer.read { db in
      try Row.fetchAll(db, sql: "SELECT id, amount_e4, category_id FROM transaction_parts")
    }
    #expect(after == money)
  }

  /// ⌘Z puts the goal back first and the parts' links after it: a link written before its goal
  /// would point at nothing.
  @Test func undoSetsTheLinksBackAfterTheGoal() throws {
    let book = try goalBook()
    let repository = PlanningRepository(writer: book.stack.writer)
    let before = try tables(book.stack)
    let undo = try repository.apply(
      PlanningChange(
        delete: PlanningRowIDs(goals: [book.goal.id]),
        unlinking: PlanningRowIDs(goals: [book.goal.id])))
    try repository.revert(undo)
    #expect(try goalOfParts(book.parts, book.stack) == [book.goal.id, book.goal.id])
    #expect(try tables(book.stack) == before)
  }

  @Test func aGoalDeletedWithoutUnlinkingIsStillRefused() throws {
    let book = try goalBook()
    let repository = PlanningRepository(writer: book.stack.writer)
    let before = try tables(book.stack)
    #expect(throws: PlanningWriteError.referencedByOperations(book.goal.id)) {
      try repository.apply(PlanningChange(delete: PlanningRowIDs(goals: [book.goal.id])))
    }
    // Letting go of links to anything but goals is not something a change can ask.
    #expect(throws: PlanningWriteError.unsupportedUnlinking) {
      try repository.apply(
        PlanningChange(
          delete: PlanningRowIDs(goals: [book.goal.id]),
          unlinking: PlanningRowIDs(events: [UUID()], goals: [book.goal.id])))
    }
    #expect(try tables(book.stack) == before)
  }

  /// A part given another goal between the deletion and its ⌘Z is the owner's choice: it keeps
  /// it; the others come back to the goal.
  @Test func aLinkChangedSinceIsLeftAlone() throws {
    let book = try goalBook()
    let repository = PlanningRepository(writer: book.stack.writer)
    let undo = try repository.apply(
      PlanningChange(
        delete: PlanningRowIDs(goals: [book.goal.id]),
        unlinking: PlanningRowIDs(goals: [book.goal.id])))
    try book.stack.writer.write { db in
      try db.execute(
        sql: "UPDATE transaction_parts SET goal_id = ? WHERE id = ?",
        arguments: [book.other.id.uuidString, book.parts[0].uuidString])
    }
    try repository.revert(undo)
    #expect(try goalOfParts(book.parts, book.stack) == [book.other.id, book.goal.id])
  }
}
