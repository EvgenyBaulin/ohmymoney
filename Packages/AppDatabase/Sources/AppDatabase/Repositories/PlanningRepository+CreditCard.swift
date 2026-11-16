import AppCore
import CoreKit
import Foundation
import GRDB

/// What giving a card its own debit or credit account did, for ⌘Z: the operations as they were,
/// and the rows of the tables the planning does not write that moved with the card.
public struct CardConversionUndo: Hashable, Sendable {
  /// The operations that went to the credit card, live and in the bin.
  public var movedOperationIds: [UUID]
  /// The operations that stayed and now name the archived card left on the former account.
  public var leftOperationIds: [UUID]
  /// The account the card was under: what moved goes back to it.
  var formerAccountId: UUID
  /// Every operation the conversion wrote, as it was before.
  var operationsBefore: [CoreKit.Transaction]
  /// Rows of `bank_conditions` and `cashback_offers` that went with the card: table, id.
  var movedRows: [MovedCardRow]
}

/// A row of a table the planning does not write that named the card and went with it.
struct MovedCardRow: Hashable, Sendable {
  var table: String
  var id: String
}

extension PlanningChange {
  /// A card given its own debit or credit account, as one step of
  /// ⌘Z: the account is written, the card moves to it and the former account lets go of it
  /// as its main card; then `convertingCard` moves what the card paid, as the plan chose.
  public static func cardConversion(
    _ plan: CreditCardConversionPlan, at instant: Date
  ) -> PlanningChange {
    var change = PlanningChange(
      upsert: PlanningRows(paymentMethods: [plan.account, plan.former], cards: [plan.card]),
      at: instant)
    change.convertingCard = plan
    return change
  }
}

extension PlanningRepository {
  /// Moves to the credit card of `plan` what goes with its card, inside the write of the change,
  /// once the credit card is written and the card is on it:
  ///
  /// 1. every operation naming the card — in the bin too — that `plan.moves` lets go is on the
  ///    credit card; a live one is stamped as updated at `instant`, as an edit is;
  /// 2. every other operation naming the card names the archived card left on the former
  ///    account (`plan.leftCard`, written only then) and keeps the moment it was last written:
  ///    no operation ever names a card of another account;
  /// 3. its scheduled payments and cashback rules — the card's own — are the credit card's, and
  ///    so are its bank conditions and the cashback offers made for it.
  ///
  /// `entries` gets the live moved operations as they were and as they are, for the counts of
  /// both accounts.
  static func convertCard(
    _ plan: CreditCardConversionPlan, at instant: Date, calendar: CalendarContext,
    journal: inout UndoJournal, db: Database
  ) throws -> (
    undo: CardConversionUndo, moved: [(before: TransactionEntry, after: TransactionEntry)]
  ) {
    let cardId = plan.card.id.uuidString
    guard
      try String.fetchOne(
        db, sql: "SELECT payment_method_id FROM cards WHERE id = ?", arguments: [cardId])
        == plan.account.id.uuidString
    else { throw AccountWriteError.cardOfAnotherAccount }

    let naming = try CoreKit.Transaction
      .filter(Column("card_id") == cardId)
      .order(Column.rowID)
      .fetchAll(db)
    let moving = naming.filter { plan.moves($0, calendar: calendar) }
    let staying = naming.filter { !plan.moves($0, calendar: calendar) }
    let liveMoving = moving.filter { !$0.isDeleted }.map(\.id)
    let entriesBefore = try TransactionRepository.entries(ids: liveMoving, db: db)

    if !staying.isEmpty { try journal.upsert([plan.leftCard], db: db) }
    // Only the link moves for these, as in a merge of cards: nothing the owner wrote changed.
    for var row in staying {
      row.cardId = plan.leftCard.id
      try row.update(db)
    }
    for var row in moving {
      row.paymentMethodId = plan.account.id
      if !row.isDeleted { row.updatedAt = instant }
      try row.update(db)
    }

    try journal.keepRows(ScheduledPayment.self, where: "card_id", is: plan.card.id, db: db)
    try journal.keepRows(CashbackRule.self, where: "card_id", is: plan.card.id, db: db)
    for table in ["scheduled_payments", "cashback_rules"] {
      try db.execute(
        sql: "UPDATE \(table) SET payment_method_id = ? WHERE card_id = ?",
        arguments: [plan.account.id.uuidString, cardId])
    }
    var movedRows: [MovedCardRow] = []
    for table in ["bank_conditions", "cashback_offers"] {
      let ids = try String.fetchAll(
        db, sql: "SELECT id FROM \(table) WHERE card_id = ? ORDER BY rowid", arguments: [cardId])
      movedRows += ids.map { MovedCardRow(table: table, id: $0) }
      try db.execute(
        sql: "UPDATE \(table) SET payment_method_id = ? WHERE card_id = ?",
        arguments: [plan.account.id.uuidString, cardId])
    }

    let entriesAfter = try TransactionRepository.entries(ids: liveMoving, db: db)
    let pairs = entriesBefore.compactMap { before in
      entriesAfter.first { $0.id == before.id }.map { (before: before, after: $0) }
    }
    let undo = CardConversionUndo(
      movedOperationIds: moving.map(\.id), leftOperationIds: staying.map(\.id),
      formerAccountId: plan.former.id,
      operationsBefore: staying + moving, movedRows: movedRows)
    return (undo, pairs)
  }

  /// Puts back what `convertCard` did, once the card is on the former account again (the rows
  /// of the change are written back before): the operations as they were, the bank conditions
  /// and offers on the former account. The scheduled payments and the rules come back with the
  /// rows the journal kept; the left card and the credit card go with the rows the change added.
  static func revertCardConversion(_ undo: CardConversionUndo, db: Database) throws {
    for row in undo.operationsBefore {
      // An operation purged since has nothing left to be written over.
      guard try CoreKit.Transaction.exists(db, key: row.id.uuidString) else { continue }
      try row.update(db)
    }
    for row in undo.movedRows {
      try db.execute(
        sql: "UPDATE \(row.table) SET payment_method_id = ? WHERE id = ?",
        arguments: [undo.formerAccountId.uuidString, row.id])
    }
  }
}
