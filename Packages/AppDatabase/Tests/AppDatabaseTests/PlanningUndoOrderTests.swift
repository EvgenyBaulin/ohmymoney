import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// ⌘Z gives a removed row back its place in every list read in the order the rows were made:
/// the limits, the transfers, the reconciliations, the lines of a journal. Rows removed together
/// come back each at its own place, whatever order the change named them in.
@Suite("Undo gives removed rows back their places")
struct PlanningUndoOrderTests {
  private func stack() throws -> (DatabaseStack, ReferenceFixture) {
    let stack = try TestSupport.makeStack()
    return (stack, try TestSupport.seedReferences(stack))
  }

  /// Two limits deleted in one change, the later one named first: ⌘Z lists them as they were,
  /// the older first — not swapped because each came back at the place the other one took.
  @Test func twoLimitsDeletedTogetherComeBackInTheirOrder() throws {
    let (stack, references) = try stack()
    let planning = PlanningRepository(writer: stack.writer)
    let first = Budget(
      scope: .category, categoryId: references.category.id, amountE4: AmountE4(whole: 100))
    let second = Budget(scope: .badTotal, amountE4: AmountE4(whole: 200))
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(budgets: [first, second])))
    #expect(try planning.budgets().map(\.id) == [first.id, second.id])

    let undo = try planning.apply(
      PlanningChange(delete: PlanningRowIDs(budgets: [second.id, first.id])))
    #expect(try planning.budgets().isEmpty)
    try planning.revert(undo)

    #expect(try planning.budgets().map(\.id) == [first.id, second.id])
  }

  /// The links a deletion let go of come back once every row is back: a template and a part of
  /// an operation pointed at a category and a goal deleted in one change, and ⌘Z points them at
  /// the two again — the goal is written back after the category, the links after both.
  @Test func linksLetGoOfComeBackAfterTheRowsTheyPointAt() throws {
    let (stack, references) = try stack()
    let planning = PlanningRepository(writer: stack.writer)
    let hobby = CoreKit.Category(kind: .expense, name: "Hobby")
    let guitar = Goal(name: "Guitar", targetE4: AmountE4(whole: 30_000))
    _ = try planning.apply(
      PlanningChange(upsert: PlanningRows(categories: [hobby], goals: [guitar])))
    let template = Template(text: "strings 900", categoryId: hobby.id)
    try ReferenceRepository(writer: stack.writer).save(template)
    var draft = TransactionDraft(
      occurredAt: Date(timeIntervalSince1970: 1_789_900_000), amount: AmountE4(whole: 900),
      paymentMethodId: references.paymentMethod.id)
    draft.normalizeSinglePart()
    draft.parts[0].goalId = guitar.id
    draft.parts[0].categoryId = references.category.id
    let contribution = try draft.materialize()
    try TransactionRepository(writer: stack.writer).save(contribution)
    let before = try stack.writer.read { db in try ExactTables.read(db) }

    let undo = try planning.apply(
      PlanningChange(
        delete: PlanningRowIDs(categories: [hobby.id], goals: [guitar.id]),
        unlinking: PlanningRowIDs(goals: [guitar.id])))
    #expect(Set(undo.cleared.map(\.referencedId)) == [hobby.id, guitar.id])
    try planning.revert(undo)
    #expect(try stack.writer.read { db in try ExactTables.read(db) } == before)
  }

  /// The same for three lines of one day of a debt's journal, deleted in a shuffled order: they
  /// come back in the order they were written, which is the order of that day.
  @Test func journalLinesOfOneDayComeBackInTheirOrder() throws {
    let (stack, references) = try stack()
    let planning = PlanningRepository(writer: stack.writer)
    let day = DateOnly(year: 2026, month: 9, day: 1)
    let lines = (1...3).map { index in
      DebtEntry(
        debtId: references.debt.id, date: day, amountE4: AmountE4(whole: Int64(index * 10)),
        kind: .adjustment)
    }
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(debtEntries: lines)))
    let undo = try planning.apply(
      PlanningChange(delete: PlanningRowIDs(debtEntries: [lines[2].id, lines[0].id, lines[1].id])))
    try planning.revert(undo)

    let book = try planning.book()
    #expect(
      book.debtEntries.filter { $0.debtId == references.debt.id }.map(\.id) == lines.map(\.id))
  }

  /// Transfers deleted together in reverse order come back in the order they were made, for
  /// transfers of one moment the order the day list shows them in.
  @Test func transfersDeletedTogetherComeBackInTheirOrder() throws {
    let (stack, references) = try stack()
    let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    try ReferenceRepository(writer: stack.writer).save(cash)
    let planning = PlanningRepository(writer: stack.writer)
    let moment = Date(timeIntervalSince1970: 1_789_000_000)
    let transfers = (1...3).map { index in
      Transfer(
        occurredAt: moment, fromAccountId: references.paymentMethod.id, fromCurrency: .rub,
        fromAmountE4: AmountE4(whole: Int64(index)), toAccountId: cash.id, toCurrency: .rub,
        toAmountE4: AmountE4(whole: Int64(index)), createdAt: moment, updatedAt: moment)
    }
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(transfers: transfers)))
    let undo = try planning.apply(
      PlanningChange(delete: PlanningRowIDs(transfers: transfers.map(\.id).reversed())))
    try planning.revert(undo)

    let order = try stack.writer.read { db in
      try Transfer.order(Column("occurred_at"), Column.rowID).fetchAll(db).map(\.id)
    }
    #expect(order == transfers.map(\.id))
  }

  /// A split of three parts, and the operation as it was, whole.
  private func split(
    _ stack: DatabaseStack, _ references: ReferenceFixture
  ) throws -> TransactionEntry {
    let id = UUID()
    let moment = Date(timeIntervalSince1970: 1_789_000_000)
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: moment, amountE4: AmountE4(whole: 600),
        paymentMethodId: references.paymentMethod.id, createdAt: moment, updatedAt: moment),
      parts: (1...3).map { index in
        TransactionPart(
          transactionId: id, categoryId: references.category.id,
          amountE4: AmountE4(whole: Int64(index * 100)), note: "part \(index)")
      })
    return try TransactionRepository(writer: stack.writer).save(entry)
  }

  /// The split without its first part, the money of it moved to the second.
  private func withoutTheFirstPart(_ entry: TransactionEntry) -> TransactionEntry {
    var edited = entry
    let dropped = edited.parts.removeFirst()
    edited.parts[0].amountE4 += dropped.amountE4
    edited.parts[0].amountRubE4 += dropped.amountRubE4
    return edited
  }

  /// A planning change that rewrote a split without its first part is taken back: the part
  /// comes back first in the split, where it was — the parts are read in the order they were
  /// written, which is the order of the split.
  @Test func aPartARewriteDroppedComesBackAtItsPlaceInTheSplit() throws {
    let (stack, references) = try stack()
    let entry = try split(stack, references)
    let planning = PlanningRepository(writer: stack.writer)

    let undo = try planning.apply(PlanningChange(rewritten: [withoutTheFirstPart(entry)]))
    try planning.revert(undo)

    let back = try #require(try TransactionRepository(writer: stack.writer).entry(id: entry.id))
    #expect(back.parts.map(\.id) == entry.parts.map(\.id))
    #expect(back.parts == entry.parts)
  }

  /// The same for an edit taken back by writing the operation as it was: the parts are in the
  /// order the operation gives them.
  @Test func anOperationWrittenBackAsItWasHasItsPartsInTheirOrder() throws {
    let (stack, references) = try stack()
    let entry = try split(stack, references)
    let transactions = TransactionRepository(writer: stack.writer)

    try transactions.save(withoutTheFirstPart(entry))
    try transactions.save(entry)

    let back = try #require(try transactions.entry(id: entry.id))
    #expect(back.parts.map(\.id) == entry.parts.map(\.id))
  }

  /// An operation a change deleted and ⌘Z brought back keeps the moment it was last written
  /// before the deletion: bringing a row back is not a new write of it, and «the last rating by
  /// hand» is found by that stamp — the owner's answer.
  @Test func anOperationBroughtBackKeepsItsUpdateMoment() throws {
    let (stack, references) = try stack()
    let entry = try split(stack, references)
    let planning = PlanningRepository(writer: stack.writer)
    let undoMoment = Date(timeIntervalSince1970: 1_795_000_000)
    let stored = try #require(
      try TransactionRepository(writer: stack.writer).entry(id: entry.id)
    ).transaction.updatedAt

    let undo = try planning.apply(
      PlanningChange(softDeleted: [entry.id], at: Date(timeIntervalSince1970: 1_792_000_000)))
    #expect(undo.deletion.updatedAtBefore[entry.id] == stored)
    try planning.revert(undo, at: undoMoment)

    let back = try #require(try TransactionRepository(writer: stack.writer).entry(id: entry.id))
    #expect(back.transaction.deletedAt == nil)
    #expect(back.transaction.updatedAt == stored)
    #expect(back.transaction.updatedAt != undoMoment)
  }
}
