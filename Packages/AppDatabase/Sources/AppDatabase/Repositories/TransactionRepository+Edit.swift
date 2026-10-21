import AppCore
import CoreKit
import Foundation
import GRDB

/// One operation edited on its own — in the inspector or the edit sheet — and what the edit
/// moved with it, as it was before: everything undo needs to put it all back, since undoing
/// an edit writes the whole earlier state.
public struct EditedEntry: Hashable, Sendable {
  /// The operation as it was inside the write, before the edit.
  public var before: TransactionEntry
  /// The operation as the edit wrote it.
  public var after: TransactionEntry
  /// Journal lines of the operation the edit rewrote or took away, as they were.
  public var journalBefore: [DebtEntry]
  /// Journal lines the edit added.
  public var journalAdded: [UUID]
  /// The rowid each line of `journalBefore` had: a line taken away and given back returns to
  /// its place among the lines of its day, not last.
  public var journalRowIDs: [UUID: Int64]
  /// Links of reimbursements to the parts the edit took away: a link goes with its part
  /// (`ON DELETE CASCADE`), and the part given back by undo needs it — or deleting the
  /// reimbursement would never open the part again.
  public var removedLinks: [ReimbursementLink]
  /// Refunds in the bin that let go of a part the edit took away, refund part → purchase part:
  /// undo gives the part back and ties them to it again, so undoing their deletion later brings
  /// them back to their purchase.
  public var releasedRefunds: [UUID: UUID]
  /// The transfers written with the edit to keep an account in the archive at zero: undo
  /// deletes them.
  public var settlingTransfers: [UUID]
  /// The money that had come back for the parts whose rubles the edit changed, balanced again
  /// (`MoneyBackSettlement`): undo puts it back.
  public var settlement: SettlementWrite
  /// The refunds of the purchase that followed its new rate or rubles, as they were and as
  /// written (`RefundRules.following`).
  public var refundsBefore: [TransactionEntry]
  public var refundsWritten: [TransactionEntry]
  /// What the counts whose windows the edit reached wrote in the same write — the operations of
  /// their differences as written and as they were —: the lists lay them over what they show,
  /// and undo writes a difference the edit took to zero back as the owner left it.
  public var counts: CountsSettled

  public init(
    before: TransactionEntry, after: TransactionEntry, journalBefore: [DebtEntry] = [],
    journalAdded: [UUID] = [], journalRowIDs: [UUID: Int64] = [:],
    removedLinks: [ReimbursementLink] = [], releasedRefunds: [UUID: UUID] = [:],
    settlingTransfers: [UUID] = [], settlement: SettlementWrite = .empty,
    refundsBefore: [TransactionEntry] = [], refundsWritten: [TransactionEntry] = [],
    counts: CountsSettled = .none
  ) {
    self.before = before
    self.after = after
    self.journalBefore = journalBefore
    self.journalAdded = journalAdded
    self.journalRowIDs = journalRowIDs
    self.removedLinks = removedLinks
    self.releasedRefunds = releasedRefunds
    self.settlingTransfers = settlingTransfers
    self.settlement = settlement
    self.refundsBefore = refundsBefore
    self.refundsWritten = refundsWritten
    self.counts = counts
  }

  /// Whether the edit moved a debt.
  public var movedDebts: Bool { !journalBefore.isEmpty || !journalAdded.isEmpty }

  /// Whether the edit, or its undo, wrote more than the operation — journal lines, links,
  /// transfers, money back balanced again, refunds that followed —, so the data the app shows
  /// has to be read again rather than laid over.
  public var reachesBeyondTheOperation: Bool {
    movedDebts || !removedLinks.isEmpty || !settlingTransfers.isEmpty || !settlement.isEmpty
      || !refundsBefore.isEmpty
  }
}

/// A transfer given to an edit to keep an account in the archive at zero that may not be
/// written as it is (`TransferRules.validate`). Nothing of the edit is written then.
public struct SettlingTransferRefusal: Error, Hashable, Sendable {
  public var transferId: UUID
  public var issue: TransferIssue

  public init(transferId: UUID, issue: TransferIssue) {
    self.transferId = transferId
    self.issue = issue
  }
}

/// What became of `TransactionRepository.edit`.
public enum EditResult: Hashable, Sendable {
  /// The operation is deleted or was never there: nothing was written.
  case gone
  /// The edit changes nothing in the row as it is now.
  case unchanged
  case edited(EditedEntry)
}

extension TransactionRepository {

  /// Edits one operation in one write, together with the journal lines that point at it.
  ///
  /// `transform` gets the operation as it is inside the write — the row the edit is laid over
  /// (`TransactionEntry.rebased(onto:)`) — and returns it edited, or `nil` to leave it. The row
  /// is stamped with `instant`. An operation that moves a debt — a payment, money lent or
  /// borrowed, a purchase on credit — takes its journal line along
  /// (`DebtRules.journal(of:afterEditing:into:debts:calendar:)`): the days of the lines are
  /// days of `calendar`, the one the entry line dates them by.
  ///
  /// What a reimbursement worked out — its links, the parts it closed, its surplus and
  /// shortfalls — is not edited in place (`OperationEditRule`), and neither is what a refund or
  /// money back that covered only some of a part leans on (`LinkedEditRefusal`). A refund is
  /// held to the part it takes back from (`refuseUnsoundRefund`). An operation left without an
  /// account gets the main one, and one moved onto an account that does not hold its currency
  /// must say what it was charged (`AccountWriteError.chargeMissing`). A part taken away lets
  /// go of the refunds in the bin that took back from it, and undo ties them back.
  ///
  /// A purchase whose rate or rubles the edit changed takes its refunds along
  /// (`RefundRules.following`: their stored rubles and rate), and the money that already came
  /// back for its parts is balanced again (`MoneyBackSettlement`: links, surplus, shortfall —
  /// `settlement` gives the words of a surplus written anew), both in the same write and the
  /// same undo.
  ///
  /// `settlingTransfers` are written in the same write, after the edit and under all its
  /// rules: the money an edit of the past of an account in the archive leaves on it, or takes
  /// off it, moved to or from a live account, so the archived one stays at zero. The account of
  /// the operation, before and after the edit, is the one archived side they may name
  /// (`TransferRules.validate(_:accounts:allowingArchived:)`); undo deletes them with the edit.
  /// An edit that changes nothing writes none of them.
  ///
  /// The counts whose windows the operation left or entered — or its refunds, the money back
  /// balanced again, its journal lines and those transfers — follow the books in the same write
  /// (`EditedEntry.counts`): an edit that moves a purchase to another day changes the
  /// differences of the counts on both sides, and one ⌘Z takes all of it back.
  ///
  /// Throws what `transform` throws, `EditRefusal`, `LinkedEditRefusal` or `RefundError` when
  /// the edit may not be written, `SettlingTransferRefusal` when one of the transfers may not,
  /// and `DatabaseError.unbalancedParts` when the parts do not add up; nothing is written then.
  public func edit(
    id: UUID, at instant: Date = Date(), calendar: CalendarContext,
    settlingTransfers: [Transfer] = [],
    settlement: SettlementSetting = SettlementSetting(surplusNote: nil),
    transform: (TransactionEntry) throws -> TransactionEntry?
  ) throws -> EditResult {
    let context = liveCounts
    return try writer.write { db in
      try Self.edit(
        id: id, at: instant, calendar: calendar, settlingTransfers: settlingTransfers,
        settlement: settlement, transform: transform, context: context, db: db)
    }
  }

  /// Takes an edit back in one write: the operation as it was, its journal lines as they
  /// were — the lines the edit added go, the ones it changed or took away come back —, the
  /// links of the parts it took away, the refunds in the bin that let go of them, no
  /// transfer the edit wrote with it, its refunds as they were and the money back of its parts
  /// as it was. A line whose debt is gone since, or a link whose reimbursement is, has nothing
  /// to come back to.
  ///
  /// The counts whose windows it all moves in or out of follow the books in the same write, and
  /// a difference the edit took to zero comes back as the owner left it
  /// (`EditedEntry.counts.operationsBefore`). A difference of a count given back while another
  /// operation holds its key — the one made again under the id derived from the count after
  /// this one went at zero — takes the place of that other one, which goes for good: a count
  /// has one operation.
  @discardableResult
  public func revert(_ edit: EditedEntry) throws -> CountsSettled {
    guard edit.before.isBalanced else { throw DatabaseError.unbalancedParts }
    let context = liveCounts
    return try writer.write { db in
      // What stands now, for the counts: everything the undo is about to write over or take.
      let standing = try Self.standing(of: edit, db: db)
      try Self.clearTwin(of: edit.before, db: db)
      _ = try Transfer.deleteAll(db, keys: edit.settlingTransfers.map(\.uuidString))
      try edit.before.transaction.save(db)
      try Self.replaceParts(of: edit.before, db: db)
      for refund in edit.refundsBefore {
        guard let current = try Self.entry(id: refund.id, db: db) else { continue }
        try Self.write(refund, over: current, db: db)
      }
      try Self.revert(edit.settlement, db: db)
      try Self.relink(edit.releasedRefunds, db: db)
      _ = try DebtEntry.deleteAll(db, keys: edit.journalAdded.map(\.uuidString))
      for line in edit.journalBefore {
        guard try Debt.exists(db, key: line.debtId.uuidString) else { continue }
        try line.save(db)
        guard let rowID = edit.journalRowIDs[line.id] else { continue }
        // `OR IGNORE`: a rowid another line took meanwhile leaves this one last, nothing more.
        try db.execute(
          sql: "UPDATE OR IGNORE debt_entries SET rowid = ? WHERE id = ? AND rowid <> ?",
          arguments: [rowID, line.id.uuidString, rowID])
      }
      for link in edit.removedLinks {
        guard try CoreKit.Transaction.exists(db, key: link.reimbursementTxId.uuidString),
          try TransactionPart.exists(db, key: link.partId.uuidString)
        else { continue }
        try link.save(db)
      }
      let written = try Self.entries(ids: standing.ids, db: db)
      let lines = try DebtEntry.filter(Column("transaction_id") == edit.before.id.uuidString)
        .fetchAll(db)
      let touch = try LiveCountsWriter.touch(
        entries: standing.operations.map { ($0, nil) } + written.map { (nil, $0) },
        transfers: standing.transfers, lines: standing.lines + lines,
        calendar: context.calendar, lookups: WriteLookups(), db: db)
      return try LiveCountsWriter.settle(
        touch, context: context, templates: edit.counts.operationsBefore, db: db)
    }
  }

  /// What an edit's undo is about to write over or take away, as it stands: the operation, its
  /// refunds, the money back balanced with it, its journal lines and the transfers written with
  /// it — each counts on the windows it stands in.
  private static func standing(
    of edit: EditedEntry, db: Database
  ) throws -> (
    ids: [UUID], operations: [TransactionEntry], transfers: [Transfer], lines: [DebtEntry]
  ) {
    let ids =
      [edit.before.id] + edit.refundsBefore.map(\.id)
      + edit.settlement.operationsBefore.map(\.id) + edit.settlement.createdOperations
    let operations = try entries(ids: ids, db: db)
    let transfers = try Transfer.fetchAll(db, keys: edit.settlingTransfers.map(\.uuidString))
    let lines = try DebtEntry.filter(Column("transaction_id") == edit.before.id.uuidString)
      .fetchAll(db)
    return (ids, operations, transfers, lines)
  }

  /// A difference of a count comes back under the id it had: any other operation holding its
  /// key (`reconcile:<reconciliation>:<count>`) — live or in the bin — goes for good first, with
  /// its journal lines and links, or the unique key would refuse the undo. Nothing for any other
  /// operation.
  static func clearTwin(of entry: TransactionEntry, db: Database) throws {
    guard let key = entry.transaction.externalId,
      case .reconciledBalance = OperationLink(externalId: key)
    else { return }
    let twins = try String.fetchAll(
      db, sql: "SELECT id FROM transactions WHERE external_id = ? AND id <> ?",
      arguments: [key, entry.id.uuidString]
    ).compactMap(UUID.init(uuidString:))
    try LiveCountsWriter.purge(twins, db: db)
  }

  static func edit(
    id: UUID, at instant: Date, calendar: CalendarContext, settlingTransfers: [Transfer] = [],
    settlement: SettlementSetting = SettlementSetting(surplusNote: nil),
    transform: (TransactionEntry) throws -> TransactionEntry?,
    context: LiveCountsContext = .standard, db: Database
  ) throws -> EditResult {
    guard let fresh = try entry(id: id, db: db), !fresh.transaction.isDeleted else {
      return .gone
    }
    guard var changed = try transform(fresh), changed != fresh else { return .unchanged }
    guard changed.id == fresh.id, changed.parts.allSatisfy({ $0.transactionId == fresh.id })
    else { throw DatabaseError.notFound }
    guard changed.isBalanced else { throw DatabaseError.unbalancedParts }
    if let refusal = OperationEditRule.refusal(
      editing: fresh, into: changed, facts: try editFacts(fresh, changed, db: db))
    {
      throw refusal
    }
    changed.transaction.updatedAt = instant
    changed = try assigningAccount(changed, over: fresh, db: db)
    try refuseUnsoundRefund(changed, over: fresh, db: db)

    let lines = try DebtEntry.filter(Column("transaction_id") == id.uuidString)
      .order(Column.rowID)
      .fetchAll(db)
    let journal = try DebtRules.journal(
      of: lines, afterEditing: fresh.transaction, into: changed.transaction,
      debts: try debts(of: [fresh.transaction, changed.transaction], db: db), calendar: calendar)

    let kept = Set(changed.parts.map(\.id))
    let removedParts = fresh.parts.map(\.id).filter { !kept.contains($0) }
    let removedLinks =
      try ReimbursementLink
      .filter(removedParts.map(\.uuidString).contains(Column("part_id")))
      .order(Column.rowID)
      .fetchAll(db)

    let released = try write(changed, over: fresh, db: db)

    // A purchase at a new rate or with new rubles: its refunds follow it, and the money that
    // came back for its parts is balanced again.
    var refundsBefore: [TransactionEntry] = []
    var refundsWritten: [TransactionEntry] = []
    var settled = SettlementWrite.empty
    if changed.transaction.kind == .expense, fresh.transaction.kind == .expense {
      refundsBefore = try followingRefunds(of: changed, at: instant, db: db)
      for refund in refundsBefore {
        if let written = try entry(id: refund.id, db: db) { refundsWritten.append(written) }
      }
      let old = Dictionary(
        fresh.parts.map { ($0.id, $0.amountRubE4) }, uniquingKeysWith: { first, _ in first })
      settled = try settle(
        partIds: changed.parts.filter { $0.reimbursable && old[$0.id] != $0.amountRubE4 }
          .map(\.id),
        rublesBefore: old, setting: settlement, at: instant, db: db)
    }

    let existing = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
    var edited = EditedEntry(
      before: fresh, after: changed, removedLinks: removedLinks, releasedRefunds: released,
      settlement: settled, refundsBefore: refundsBefore, refundsWritten: refundsWritten)
    for line in journal.upsert {
      if let old = existing[line.id] {
        edited.journalBefore.append(old)
      } else {
        edited.journalAdded.append(line.id)
      }
    }
    for lineId in journal.delete {
      if let old = existing[lineId] { edited.journalBefore.append(old) }
    }
    for line in edited.journalBefore {
      edited.journalRowIDs[line.id] = try Int64.fetchOne(
        db, sql: "SELECT rowid FROM debt_entries WHERE id = ?", arguments: [line.id.uuidString])
    }
    for line in journal.upsert { try line.save(db) }
    _ = try DebtEntry.deleteAll(db, keys: journal.delete.map(\.uuidString))
    edited.settlingTransfers = try writeSettling(
      settlingTransfers,
      editing: [fresh.transaction.paymentMethodId, changed.transaction.paymentMethodId], db: db)

    // Everything the edit moved, as it was and as it is: the operation, its refunds, the
    // surpluses and the owner's own spending on its parts, its journal lines, the transfers.
    let moved: [(before: TransactionEntry?, after: TransactionEntry?)] =
      [(fresh, changed)] + refundsBefore.map { ($0, nil) } + refundsWritten.map { (nil, $0) }
      + settled.operationsBefore.map { ($0, nil) } + settled.written.map { (nil, $0) }
    let touch = try LiveCountsWriter.touch(
      entries: moved, transfers: settlingTransfers,
      lines: edited.journalBefore + journal.upsert, calendar: context.calendar,
      lookups: WriteLookups(), db: db)
    edited.counts = try LiveCountsWriter.settle(touch, context: context, now: instant, db: db)
    return .edited(edited)
  }

  /// Writes the transfers that keep an account in the archive at zero, each held to the rules
  /// of a transfer, the archived accounts among `editing` — those whose past the write changed
  /// — allowed. Returns their ids.
  static func writeSettling(
    _ transfers: [Transfer], editing accounts: [UUID?], db: Database
  ) throws -> [UUID] {
    guard !transfers.isEmpty else { return [] }
    let all = try PaymentMethod.fetchAll(db)
    let allowed = Set(accounts.compactMap { $0 })
    for transfer in transfers {
      if let issue = TransferRules.validate(transfer, accounts: all, allowingArchived: allowed) {
        throw SettlingTransferRefusal(transferId: transfer.id, issue: issue)
      }
      try transfer.insert(db)
    }
    return transfers.map(\.id)
  }

  /// What only the database knows about the operation being edited: whether it is a
  /// reimbursement that settled parts, the live money back that reached each of its parts, what
  /// the live refunds took back from each of them, and — for the purchase parts it takes back
  /// from — what is left of them to refund, its own refunds not counted. For the difference of a
  /// count, the categories of the app it may not go to.
  static func editFacts(
    _ before: TransactionEntry, _ after: TransactionEntry, db: Database
  ) throws -> EditFacts {
    var facts = EditFacts(settles: try settles(before.transaction, db: db))
    if OperationEditRule.isReconcileDifference(before.transaction) {
      let categories = try CoreKit.Category.fetchAll(db)
      let tree = CategoryTree(categories)
      facts.systemCategories = Set(
        categories.map(\.id).filter { tree.systemRole(of: $0) != nil })
    }
    let parts = before.parts.map(\.id.uuidString)
    if !parts.isEmpty {
      let marks = databaseQuestionMarks(count: parts.count)
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT l.part_id AS part, SUM(l.amount_e4) AS amount FROM reimbursement_links l
          JOIN transactions t ON t.id = l.reimbursement_tx_id
          WHERE t.deleted_at IS NULL AND l.part_id IN (\(marks))
          GROUP BY l.part_id
          """,
        arguments: StatementArguments(parts))
      {
        guard let part = RowMapping.optionalUUID(row, "part") else { continue }
        facts.linkedRubByPart[part] = AmountE4(raw: row["amount"] ?? 0)
      }
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT p.refund_of_part_id AS part, SUM(p.amount_e4) AS amount
          FROM transaction_parts p JOIN transactions t ON t.id = p.transaction_id
          WHERE t.deleted_at IS NULL AND t.kind = ? AND p.refund_of_part_id IN (\(marks))
          GROUP BY p.refund_of_part_id
          """,
        arguments: [TransactionKind.refund.rawValue] + StatementArguments(parts))
      {
        guard let part = RowMapping.optionalUUID(row, "part") else { continue }
        facts.refundedByPart[part] = AmountE4(raw: row["amount"] ?? 0)
      }
    }
    let targets = Set((before.parts + after.parts).compactMap(\.refundOfPartId))
    for target in targets.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT p.amount_e4 AS amount, t.currency AS currency FROM transaction_parts p
            JOIN transactions t ON t.id = p.transaction_id
            WHERE p.id = ? AND t.deleted_at IS NULL AND t.kind = ?
            """,
          arguments: [target.uuidString, TransactionKind.expense.rawValue])
      else { continue }
      let others =
        try Int64.fetchOne(
          db,
          sql: """
            SELECT COALESCE(SUM(p.amount_e4), 0) FROM transaction_parts p
            JOIN transactions t ON t.id = p.transaction_id
            WHERE t.deleted_at IS NULL AND t.kind = ? AND p.refund_of_part_id = ?
              AND t.id <> ?
            """,
          arguments: [
            TransactionKind.refund.rawValue, target.uuidString, before.id.uuidString,
          ]) ?? 0
      facts.refundOf[target] = RefundableRemainder(
        remaining: AmountE4(raw: row["amount"] ?? 0) - AmountE4(raw: others),
        currency: CurrencyCode(row["currency"] ?? CurrencyCode.rub.code))
    }
    return facts
  }

  /// Whether a reimbursement closed parts — a link of its own — or left a live surplus or
  /// shortfall, found by the key in `external_id`.
  private static func settles(_ transaction: CoreKit.Transaction, db: Database) throws -> Bool {
    guard transaction.kind == .reimbursement else { return false }
    let links =
      try ReimbursementLink
      .filter(Column("reimbursement_tx_id") == transaction.id.uuidString)
      .fetchCount(db)
    if links > 0 { return true }
    let companion = try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS (
          SELECT 1 FROM transactions WHERE deleted_at IS NULL AND substr(external_id, 1, ?) = ?)
        """,
      arguments: prefixArguments(of: transaction.id))
    return companion ?? false
  }

  /// The debts these operations point at, by id.
  private static func debts(
    of transactions: [CoreKit.Transaction], db: Database
  ) throws -> [UUID: Debt] {
    let ids = Set(transactions.flatMap { [$0.debtId, $0.creditDebtId] }.compactMap { $0 })
    guard !ids.isEmpty else { return [:] }
    let debts = try Debt.fetchAll(db, keys: ids.map(\.uuidString))
    return Dictionary(debts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
}
