import AppCore
import CoreKit
import Foundation
import GRDB

/// What deleting operations dragged along, kept whole so that undo can put every piece of
/// it back.
public struct DeletionEffects: Hashable, Sendable {
  /// The operations the call deleted: those asked for that were still there.
  public var deletedIds: [UUID]
  /// The surplus and the shortfalls of deleted reimbursements, deleted together with them, and
  /// the shortfalls and remainders written off of the parts that went back to waiting.
  public var companionIds: [UUID]
  /// Parts a deleted reimbursement had closed that went back to waiting, and parts whose
  /// shortfall or remainder written off was deleted. Their links stay, so undo only has to
  /// close them again.
  public var reopenedPartIds: [UUID]
  /// The debt movements of deleted debt payments, taken off the debt.
  public var removedDebtEntries: [DebtEntry]
  /// The `sched:<payment>:<due>` keys of deleted «Mark as paid» operations, and the
  /// `transfer:<transfer>:fee` keys of deleted fees, by operation. A deleted operation pays
  /// nothing, so its key is cleared: the unique index would otherwise refuse to pay that due
  /// date again, or to give the transfer a fee again.
  public var releasedExternalIds: [UUID: String]
  /// Scheduled payments whose `next_date` went back to the due date a deleted operation
  /// had paid (`ScheduledRules.reopened`), as they were before.
  public var reopenedPayments: [ScheduledPayment]
  /// The moment each operation the deletion stamped — the deleted ones, their companions and
  /// the purchases whose parts wait again — was last written before it: ⌘Z gives it back, so
  /// bringing an operation back is not a new write of it (the owner's latest rating of a
  /// description is the one written last).
  public var updatedAtBefore: [UUID: Date]
  /// What the counts whose windows the deleted operations left wrote in the same write: `restore`
  /// writes a difference the deletion purged at zero back as the owner left it.
  public var counts: CountsSettled

  public static let none = DeletionEffects()

  public init(
    deletedIds: [UUID] = [],
    companionIds: [UUID] = [],
    reopenedPartIds: [UUID] = [],
    removedDebtEntries: [DebtEntry] = [],
    releasedExternalIds: [UUID: String] = [:],
    reopenedPayments: [ScheduledPayment] = [],
    updatedAtBefore: [UUID: Date] = [:],
    counts: CountsSettled = .none
  ) {
    self.deletedIds = deletedIds
    self.companionIds = companionIds
    self.reopenedPartIds = reopenedPartIds
    self.removedDebtEntries = removedDebtEntries
    self.releasedExternalIds = releasedExternalIds
    self.reopenedPayments = reopenedPayments
    self.updatedAtBefore = updatedAtBefore
    self.counts = counts
  }
}

/// A bulk change given transfers that settle an account in the archive, which no longer lands
/// on the operations it was planned for: one it was to change is left as it is inside the
/// write — changed or deleted elsewhere since —, or one it was to leave alone changes. The
/// transfers count the money of the plan, so nothing of the change is written; the caller
/// plans it again from the rows as they are now.
public struct SettlingPlanOutdated: Error, Hashable, Sendable {
  /// The operations the change would have landed on otherwise than planned, by id.
  public var operationIds: [UUID]

  public init(operationIds: [UUID]) {
    self.operationIds = operationIds
  }
}

/// One operation a bulk change rewrote: as it was inside the write, and as it was written.
public struct ModifiedEntry: Hashable, Sendable {
  public var before: TransactionEntry
  public var after: TransactionEntry

  public init(before: TransactionEntry, after: TransactionEntry) {
    self.before = before
    self.after = after
  }
}

/// A bulk change as it landed: each operation before and after, and what the counts whose
/// windows it moved wrote in the same write.
public struct ModifiedBatch: Hashable, Sendable {
  public var modified: [ModifiedEntry]
  public var counts: CountsSettled

  public init(modified: [ModifiedEntry], counts: CountsSettled = .none) {
    self.modified = modified
    self.counts = counts
  }
}

/// Changing and deleting many operations at once. Every method is one SQLite transaction —
/// all of it lands or none of it does — and sends ids in chunks of `chunkSize`, far below
/// the limit on bound parameters, so «select all» over any history still works.
///
/// Each method has a twin `…InBackground` that does the very same work through
/// `await writer.write` / `writer.read`: the caller's thread is free while SQLite works. The
/// app takes it for a selection of more than a thousand operations, whose write would
/// otherwise freeze the window.
extension TransactionRepository {

  /// Operations by id, deleted ones included, in no particular order.
  public func entries(ids: [UUID]) throws -> [TransactionEntry] {
    try writer.read { db in try Self.entries(ids: ids, db: db) }
  }

  public func entriesInBackground(ids: [UUID]) async throws -> [TransactionEntry] {
    try await writer.read { db in try Self.entries(ids: ids, db: db) }
  }

  /// Changes many operations in one write and returns them as they were before.
  ///
  /// The change is made to the rows as they are **inside** the write, not to a copy read
  /// earlier: the list may lag behind the database — a part written off a moment ago, a
  /// rate refined in the background — and writing an old copy back would quietly undo that.
  /// `transform` returns the operation after the change, or `nil` to leave it alone. A
  /// deleted operation is left alone. Parts must still add up, or nothing is written. An
  /// operation left without an account gets the main one, and one moved onto an account that
  /// does not hold its currency must say what the account was charged
  /// (`AccountWriteError.chargeMissing`) — unless `checkingCharges` is off, which is for ⌘Z
  /// alone: it writes back what the rows were, and a row of the time before accounts moved in
  /// bulk had no charge on the account it goes back to.
  ///
  /// `settlingTransfers` are written in the same write, after the operations: the money the
  /// change leaves on an account in the archive, or takes off it, moved to or from a live
  /// account, so the archived one stays at zero. They were worked out for the change as it was
  /// planned, so they go in only with that change:
  ///
  /// * a change that changes nothing inside the write — every row changed elsewhere since, or
  ///   deleted — writes none of them and is no error;
  /// * with `planned`, the operations the plan changes, the change must land on exactly those:
  ///   when one of them is left as it is inside the write, or another one changes, nothing is
  ///   written and `SettlingPlanOutdated` names them, so the caller plans again from the rows
  ///   as they are now. Without transfers `planned` is not read;
  /// * each transfer is held to the rules of a transfer, the accounts of the operations
  ///   changed — before and after — being the archived sides it may name
  ///   (`TransferRules.validate(_:accounts:allowingArchived:)`); one that may not be written
  ///   refuses the whole change with `SettlingTransferRefusal`.
  ///
  /// `removingTransfers` are deleted in the same write: ⌘Z of such a change takes its
  /// transfers away with it.
  ///
  /// The counts whose windows the operations and transfers left or entered follow the books in
  /// the same write (`modifyReporting`).
  @discardableResult
  public func modify(
    ids: [UUID],
    at instant: Date = Date(),
    checkingCharges: Bool = true,
    settlingTransfers: [Transfer] = [],
    removingTransfers: [UUID] = [],
    planned: Set<UUID>? = nil,
    templates: [UUID: TransactionEntry?] = [:],
    transform: (TransactionEntry) throws -> TransactionEntry?
  ) throws -> [TransactionEntry] {
    try modifyReporting(
      ids: ids, at: instant, checkingCharges: checkingCharges,
      settlingTransfers: settlingTransfers, removingTransfers: removingTransfers,
      planned: planned, templates: templates, transform: transform
    ).before
  }

  /// `modify`, and what the counts it reached wrote in the same write. `templates` are the
  /// operations of the counts as the change being taken back found them
  /// (`CountsSettled.operationsBefore` of that change): a difference it purged at zero comes
  /// back as the owner left it.
  public func modifyReporting(
    ids: [UUID],
    at instant: Date = Date(),
    checkingCharges: Bool = true,
    settlingTransfers: [Transfer] = [],
    removingTransfers: [UUID] = [],
    planned: Set<UUID>? = nil,
    templates: [UUID: TransactionEntry?] = [:],
    transform: (TransactionEntry) throws -> TransactionEntry?
  ) throws -> (before: [TransactionEntry], counts: CountsSettled) {
    let context = liveCounts
    return try writer.write { db in
      let removed = try Self.transfers(ids: removingTransfers, db: db)
      let modified = try Self.modify(
        ids: ids, at: instant, checkingCharges: checkingCharges,
        settlingTransfers: settlingTransfers, removingTransfers: removingTransfers,
        planned: planned, transform: transform, db: db)
      let counts = try Self.settle(
        modified: modified, transfers: removed + (modified.isEmpty ? [] : settlingTransfers),
        context: context, templates: templates, db: db)
      return (modified.map(\.before), counts)
    }
  }

  /// `modify` off the calling thread. It hands back each operation as it was and as it was
  /// written, since a caller that awaits cannot collect the results from inside `transform`.
  public func modifyInBackground(
    ids: [UUID],
    at instant: Date = Date(),
    checkingCharges: Bool = true,
    settlingTransfers: [Transfer] = [],
    removingTransfers: [UUID] = [],
    planned: Set<UUID>? = nil,
    templates: [UUID: TransactionEntry?] = [:],
    transform: @escaping @Sendable (TransactionEntry) throws -> TransactionEntry?
  ) async throws -> [ModifiedEntry] {
    try await modifyReportingInBackground(
      ids: ids, at: instant, checkingCharges: checkingCharges,
      settlingTransfers: settlingTransfers, removingTransfers: removingTransfers,
      planned: planned, templates: templates, transform: transform
    ).modified
  }

  /// `modifyInBackground`, and what the counts it reached wrote in the same write.
  public func modifyReportingInBackground(
    ids: [UUID],
    at instant: Date = Date(),
    checkingCharges: Bool = true,
    settlingTransfers: [Transfer] = [],
    removingTransfers: [UUID] = [],
    planned: Set<UUID>? = nil,
    templates: [UUID: TransactionEntry?] = [:],
    transform: @escaping @Sendable (TransactionEntry) throws -> TransactionEntry?
  ) async throws -> ModifiedBatch {
    let context = liveCounts
    return try await writer.write { db in
      let removed = try Self.transfers(ids: removingTransfers, db: db)
      let modified = try Self.modify(
        ids: ids, at: instant, checkingCharges: checkingCharges,
        settlingTransfers: settlingTransfers, removingTransfers: removingTransfers,
        planned: planned, transform: transform, db: db)
      let counts = try Self.settle(
        modified: modified, transfers: removed + (modified.isEmpty ? [] : settlingTransfers),
        context: context, templates: templates, db: db)
      return ModifiedBatch(modified: modified, counts: counts)
    }
  }

  /// Deletes many operations softly, with everything that hangs on them:
  ///
  /// * a reimbursement takes its surplus and shortfalls along — found by the key they keep
  ///   in `external_id` — and each part it closed goes back to waiting unless the live money
  ///   back still linked to it covers it (within the drift a foreign currency allows,
  ///   `MoneyBack.tolerance`); a part that goes back takes along what was written for it — its
  ///   shortfalls and a remainder written off. The links stay, for undo;
  /// * a shortfall or a remainder written off deleted on its own puts its part back to waiting
  ///   by the same rule: the part is no longer my spending, so it is owed again;
  /// * a payment on a debt takes its movement off the debt.
  ///
  /// A purchase refunds take money back from is refused with `RefundError.purchaseHasRefunds`
  /// unless those refunds are deleted in the same call.
  ///
  /// Operations already deleted are left as they are. Undo is `restore(ids:at:effects:)`
  /// with what this returns.
  ///
  /// With `choose`, what goes is decided inside the write, from the rows as they are then:
  /// it gets the operations asked for, deleted ones included, and returns the ids to delete.
  /// Choosing and deleting in one transaction keeps a write that lands in between from
  /// changing what the choice was made on.
  @discardableResult
  public func softDelete(
    ids: [UUID], at instant: Date = Date(),
    choosing choose: (([TransactionEntry]) throws -> [UUID])? = nil
  ) throws -> DeletionEffects {
    let context = liveCounts
    return try writer.write { db in
      let chosen = try choose.map { try $0(Self.entries(ids: ids, db: db)) } ?? ids
      return try Self.softDeleteSettling(ids: chosen, at: instant, context: context, db: db)
    }
  }

  /// `softDelete` off the calling thread, choosing the same way. Choosing and deleting in one
  /// transaction also queues the whole deletion at once, behind the writes asked for before
  /// it — the app keeps its steps of undo in that order.
  public func softDeleteInBackground(
    ids: [UUID], at instant: Date = Date(),
    choosing choose: (@Sendable ([TransactionEntry]) -> [UUID])? = nil
  ) async throws -> DeletionEffects {
    let context = liveCounts
    return try await writer.write { db in
      let chosen = try choose.map { try $0(Self.entries(ids: ids, db: db)) } ?? ids
      return try Self.softDeleteSettling(ids: chosen, at: instant, context: context, db: db)
    }
  }

  /// Brings deleted operations back together with everything their deletion took along:
  /// the companions return, the reopened parts are closed again — unless they were written
  /// off or closed otherwise since — and the debt movements go back on their debts. Each comes
  /// back with the moment it was last written before the deletion. The counts whose windows
  /// they return to follow the books in the same write; what they wrote comes back.
  @discardableResult
  public func restore(
    ids: [UUID], at instant: Date = Date(), effects: DeletionEffects = .none
  ) throws -> CountsSettled {
    let context = liveCounts
    return try writer.write { db in
      try Self.restoreSettling(ids: ids, at: instant, effects: effects, context: context, db: db)
    }
  }

  @discardableResult
  public func restoreInBackground(
    ids: [UUID], at instant: Date = Date(), effects: DeletionEffects = .none
  ) async throws -> CountsSettled {
    let context = liveCounts
    return try await writer.write { db in
      try Self.restoreSettling(ids: ids, at: instant, effects: effects, context: context, db: db)
    }
  }

  // MARK: The counts these writes reach

  /// `softDelete` and the counts whose windows the deleted operations leave — or whose own
  /// operation was deleted, whose mode follows it —, settled in the same write.
  private static func softDeleteSettling(
    ids: [UUID], at instant: Date, context: LiveCountsContext, db: Database
  ) throws -> DeletionEffects {
    let alive = try entries(ids: ids, db: db).filter { !$0.transaction.isDeleted }
    var effects = try softDelete(ids: ids, at: instant, db: db)
    let touch = try LiveCountsWriter.touch(
      entries: alive.map { ($0, nil) }, calendar: context.calendar, lookups: WriteLookups(),
      db: db)
    effects.counts = try LiveCountsWriter.settle(touch, context: context, db: db)
    return effects
  }

  /// `restore` and the counts whose windows the operations brought back enter again.
  private static func restoreSettling(
    ids: [UUID], at instant: Date, effects: DeletionEffects, context: LiveCountsContext,
    db: Database
  ) throws -> CountsSettled {
    try restore(ids: ids, at: instant, effects: effects, db: db)
    let back = try entries(ids: ids, db: db).filter { !$0.transaction.isDeleted }
    let touch = try LiveCountsWriter.touch(
      entries: back.map { (nil, $0) }, calendar: context.calendar, lookups: WriteLookups(),
      db: db)
    return try LiveCountsWriter.settle(
      touch, context: context, templates: effects.counts.operationsBefore, db: db)
  }

  /// The counts whose windows a bulk change moved operations and transfers out of or into.
  private static func settle(
    modified: [ModifiedEntry], transfers: [Transfer], context: LiveCountsContext,
    templates: [UUID: TransactionEntry?] = [:], db: Database
  ) throws -> CountsSettled {
    let touch = try LiveCountsWriter.touch(
      entries: modified.map { ($0.before, $0.after) }, transfers: transfers,
      calendar: context.calendar, lookups: WriteLookups(), db: db)
    return try LiveCountsWriter.settle(touch, context: context, templates: templates, db: db)
  }

  /// Transfers by id, as they are before a write takes them away.
  private static func transfers(ids: [UUID], db: Database) throws -> [Transfer] {
    var found: [Transfer] = []
    for chunk in distinct(ids).map(\.uuidString).chunked(by: chunkSize) {
      found += try Transfer.fetchAll(db, keys: Array(chunk))
    }
    return found
  }

  // MARK: The bodies, inside a transaction the caller holds

  static func entries(ids: [UUID], db: Database) throws -> [TransactionEntry] {
    var transactions: [CoreKit.Transaction] = []
    for chunk in distinct(ids).chunked(by: chunkSize) {
      transactions += try CoreKit.Transaction
        .filter(chunk.map(\.uuidString).contains(Column("id")))
        .fetchAll(db)
    }
    return try attachParts(to: transactions, db: db)
  }

  static func modify(
    ids: [UUID], at instant: Date, checkingCharges: Bool = true,
    settlingTransfers: [Transfer] = [], removingTransfers: [UUID] = [],
    planned: Set<UUID>? = nil,
    transform: (TransactionEntry) throws -> TransactionEntry?, db: Database
  ) throws -> [ModifiedEntry] {
    var modified: [ModifiedEntry] = []
    let lookups = WriteLookups()
    for chunk in distinct(ids).chunked(by: chunkSize) {
      let transactions = try CoreKit.Transaction
        .filter(chunk.map(\.uuidString).contains(Column("id")))
        .filter(Column("deleted_at") == nil)
        .fetchAll(db)
      for fresh in try attachParts(to: transactions, db: db) {
        guard var changed = try transform(fresh), changed != fresh else { continue }
        guard changed.id == fresh.id, changed.parts.allSatisfy({ $0.transactionId == fresh.id })
        else { throw DatabaseError.notFound }
        guard changed.isBalanced else { throw DatabaseError.unbalancedParts }
        changed.transaction.updatedAt = instant
        changed = try assigningAccount(
          changed, over: fresh, checkingCharge: checkingCharges, lookups: lookups, db: db)
        try refuseUnsoundRefund(changed, over: fresh, db: db)
        try write(changed, over: fresh, db: db)
        modified.append(ModifiedEntry(before: fresh, after: changed))
      }
    }
    for chunk in distinct(removingTransfers).map(\.uuidString).chunked(by: chunkSize) {
      _ = try Transfer.deleteAll(db, keys: Array(chunk))
    }
    // The transfers settle the change as it was planned: none for a change that landed on
    // nothing, and none — nor the change — for one that landed on other operations.
    guard !settlingTransfers.isEmpty, !modified.isEmpty else { return modified }
    if let planned {
      let moved = planned.symmetricDifference(modified.map(\.after.id))
      guard moved.isEmpty else {
        throw SettlingPlanOutdated(operationIds: moved.sorted { $0.uuidString < $1.uuidString })
      }
    }
    _ = try writeSettling(
      settlingTransfers,
      editing: modified.flatMap {
        [$0.before.transaction.paymentMethodId, $0.after.transaction.paymentMethodId]
      }, db: db)
    return modified
  }

  static func softDelete(ids: [UUID], at instant: Date, db: Database) throws -> DeletionEffects {
    var alive: [CoreKit.Transaction] = []
    for chunk in distinct(ids).chunked(by: chunkSize) {
      alive += try CoreKit.Transaction
        .filter(chunk.map(\.uuidString).contains(Column("id")))
        .filter(Column("deleted_at") == nil)
        .fetchAll(db)
    }
    try refuseDeletingRefundedPurchases(alive, db: db)
    var effects = DeletionEffects(deletedIds: alive.map(\.id))
    for transaction in alive { effects.updatedAtBefore[transaction.id] = transaction.updatedAt }
    try mark(effects.deletedIds, deletedAt: instant, at: instant, db: db)

    // Everything asked for is marked first: a reimbursement deleted in the same batch no
    // longer covers a part.
    var reopened: [UUID] = []
    for reimbursement in alive where reimbursement.kind == .reimbursement {
      let companions = try String.fetchAll(
        db,
        sql: """
          SELECT id FROM transactions
          WHERE deleted_at IS NULL AND substr(external_id, 1, ?) = ?
          """,
        arguments: prefixArguments(of: reimbursement.id)
      ).compactMap(UUID.init(uuidString:))
      effects.updatedAtBefore.merge(try stamps(of: companions, db: db)) { first, _ in first }
      try mark(companions, deletedAt: instant, at: instant, db: db)
      effects.companionIds += companions

      let closed = try String.fetchAll(
        db,
        sql: """
          SELECT p.id FROM transaction_parts p
          WHERE p.reimbursement_status = ?
            AND p.id IN (SELECT part_id FROM reimbursement_links WHERE reimbursement_tx_id = ?)
          ORDER BY p.rowid
          """,
        arguments: [ReimbursementStatus.returned.rawValue, reimbursement.id.uuidString]
      ).compactMap(UUID.init(uuidString:))
      for partId in closed where !reopened.contains(partId) {
        if try isShortOfItsMoney(partId, db: db) { reopened.append(partId) }
      }
    }
    // What was written for a part — a shortfall, a remainder written off — deleted on its own
    // leaves the part short of the money that settled it, by the same rule.
    for partId in writtenForParts(alive) where !reopened.contains(partId) {
      guard try isClosed(partId, db: db), try isShortOfItsMoney(partId, db: db) else { continue }
      reopened.append(partId)
    }
    // The purchases whose parts wait again are stamped by the deletion; ⌘Z closes the parts
    // again and gives the purchases back the moment they had.
    effects.updatedAtBefore.merge(
      try stamps(of: operations(ofParts: reopened, db: db), db: db)
    ) { first, _ in first }
    try setStatus(.expected, of: reopened, onlyWhere: .returned, at: instant, db: db)
    effects.reopenedPartIds += reopened
    let written = try liveCompanions(ofParts: reopened, db: db)
    effects.updatedAtBefore.merge(try stamps(of: written, db: db)) { first, _ in first }
    try mark(written, deletedAt: instant, at: instant, db: db)
    effects.companionIds += written

    let payments = alive.filter { $0.debtId != nil }.map(\.id.uuidString)
    for chunk in payments.chunked(by: chunkSize) {
      let request = DebtEntry.filter(chunk.contains(Column("transaction_id")))
      effects.removedDebtEntries += try request.fetchAll(db)
      try request.deleteAll(db)
    }

    try releaseScheduledLinks(of: alive, effects: &effects, db: db)
    return effects
  }

  /// A deleted «Mark as paid» operation pays nothing: its due date is owed again. The key
  /// `sched:<payment>:<due>` is cleared, so the date can be paid anew (the unique index
  /// counts deleted rows too), and the payment's `next_date` goes back to that date when it
  /// was the latest one paid (`ScheduledRules.reopened`).
  ///
  /// The key `transfer:<transfer>:fee` of a deleted fee is cleared the same way, so the
  /// transfer can be given a fee again.
  private static func releaseScheduledLinks(
    of deleted: [CoreKit.Transaction], effects: inout DeletionEffects, db: Database
  ) throws {
    var paid: [(transaction: CoreKit.Transaction, key: String, payment: UUID, due: DateOnly)] = []
    for transaction in deleted {
      guard let key = transaction.externalId else { continue }
      switch OperationLink(externalId: key) {
      case .scheduled(let paymentId, let due):
        paid.append((transaction, key, paymentId, due))
      case .transferFee:
        try db.execute(
          sql: "UPDATE transactions SET external_id = NULL WHERE id = ?",
          arguments: [transaction.id.uuidString])
        effects.releasedExternalIds[transaction.id] = key
      default:
        continue
      }
    }
    // The latest date first: each one goes back only from the date right after it.
    paid.sort { $0.due > $1.due }
    for (transaction, key, paymentId, due) in paid {
      try db.execute(
        sql: "UPDATE transactions SET external_id = NULL WHERE id = ?",
        arguments: [transaction.id.uuidString])
      effects.releasedExternalIds[transaction.id] = key
      guard let payment = try ScheduledPayment.fetchOne(db, key: paymentId.uuidString),
        let reopened = ScheduledRules.reopened(payment, due: due)
      else { continue }
      try reopened.update(db)
      effects.reopenedPayments.append(payment)
    }
  }

  static func restore(
    ids: [UUID], at instant: Date, effects: DeletionEffects, db: Database
  ) throws {
    try mark(distinct(ids + effects.companionIds), deletedAt: nil, at: instant, db: db)
    try setStatus(
      .returned, of: effects.reopenedPartIds, onlyWhere: .expected, at: instant, db: db)
    // Brought back as they were: the moment each was last written before the deletion — the
    // operations brought back and the purchases whose parts close again.
    let stamps = effects.updatedAtBefore.sorted { $0.key.uuidString < $1.key.uuidString }
    for (id, moment) in stamps {
      try db.execute(
        sql: "UPDATE transactions SET updated_at = ? WHERE id = ? AND deleted_at IS NULL",
        arguments: [StoredInstant.databaseValue(moment), id.uuidString])
    }
    for entry in effects.removedDebtEntries {
      // A debt deleted in the meantime took its journal with it; there is nothing to put
      // the movement back on.
      guard try Debt.exists(db, key: entry.debtId.uuidString) else { continue }
      try entry.save(db)
    }
    // The keys come back unless the due date was paid anew in the meantime: then the
    // restored operation stays an ordinary expense rather than a second payment of it. The
    // app never gets here with the date paid anew — paying it is a step of ⌘Z above the
    // deletion, taken back first (PlanningFlowTests) — so this is a caller's fallback only.
    let released = effects.releasedExternalIds.sorted { $0.key.uuidString < $1.key.uuidString }
    for (id, key) in released {
      try db.execute(
        sql: "UPDATE OR IGNORE transactions SET external_id = ? WHERE id = ?",
        arguments: [key, id.uuidString])
    }
    // A payment moves forward again only while it still waits on the date it went back to;
    // the earliest date went back last, so it goes forward first.
    let keys = Set(effects.releasedExternalIds.values)
    for payment in effects.reopenedPayments.reversed() {
      guard var current = try ScheduledPayment.fetchOne(db, key: payment.id.uuidString),
        let due = current.nextDate,
        keys.contains(OperationLink.scheduled(paymentId: payment.id, due: due).externalId)
      else { continue }
      current.nextDate = payment.nextDate
      try current.update(db)
    }
  }

  // MARK: Refunds and money back

  /// Refuses, with `RefundError.purchaseHasRefunds`, to delete a purchase a live refund takes
  /// money back from, unless that refund is deleted too.
  private static func refuseDeletingRefundedPurchases(
    _ deleting: [CoreKit.Transaction], db: Database
  ) throws {
    let purchases = deleting.filter { $0.kind == .expense }.map(\.id.uuidString)
    guard !purchases.isEmpty else { return }
    let going = Set(deleting.map(\.id))
    for chunk in purchases.chunked(by: chunkSize) {
      let marks = databaseQuestionMarks(count: chunk.count)
      let refunds = try String.fetchAll(
        db,
        sql: """
          SELECT DISTINCT r.id FROM transactions r
          JOIN transaction_parts rp ON rp.transaction_id = r.id
          JOIN transaction_parts pp ON pp.id = rp.refund_of_part_id
          WHERE r.deleted_at IS NULL AND r.kind = ? AND pp.transaction_id IN (\(marks))
          """,
        arguments: [TransactionKind.refund.rawValue] + StatementArguments(chunk)
      ).compactMap(UUID.init(uuidString:))
      if refunds.contains(where: { !going.contains($0) }) {
        throw RefundError.purchaseHasRefunds
      }
    }
  }

  /// Whether a closed part is short of its money once the money back deleted is gone: what the
  /// live money back still linked to it gives back falls short of its rubles by more than the
  /// drift allowed when a foreign currency is involved — the part's own, or that of any money
  /// back ever linked to it.
  private static func isShortOfItsMoney(_ partId: UUID, db: Database) throws -> Bool {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT p.amount_rub_e4 AS rubles, t.currency AS currency,
            EXISTS (
              SELECT 1 FROM reimbursement_links l
              JOIN transactions m ON m.id = l.reimbursement_tx_id
              WHERE l.part_id = p.id AND m.currency <> ?) AS foreignBack
          FROM transaction_parts p JOIN transactions t ON t.id = p.transaction_id
          WHERE p.id = ?
          """,
        arguments: [CurrencyCode.rub.code, partId.uuidString])
    else { return false }
    let rubles = AmountE4(raw: row["rubles"] ?? 0)
    let foreign =
      (row["currency"] as String?) != CurrencyCode.rub.code
      || (row["foreignBack"] as Bool? ?? false)
    let covered = try returnedRub(ofPart: partId, db: db)
    return rubles - covered > MoneyBack.tolerance(partRub: rubles, foreignInvolved: foreign)
  }

  /// The parts these operations were written for: a shortfall's
  /// (`reimb:<money back>:shortfall:<part>`) and a remainder written off's
  /// (`writeoff:<part>:<operation>`), in the order of the operations.
  private static func writtenForParts(_ operations: [CoreKit.Transaction]) -> [UUID] {
    var parts: [UUID] = []
    for operation in operations {
      switch OperationLink(externalId: operation.externalId) {
      case .shortfall(_, let part), .remainderWriteOff(let part, _):
        if let id = UUID(uuidString: part), !parts.contains(id) { parts.append(id) }
      default:
        continue
      }
    }
    return parts
  }

  /// Whether the part is settled as returned.
  private static func isClosed(_ partId: UUID, db: Database) throws -> Bool {
    try String.fetchOne(
      db, sql: "SELECT reimbursement_status FROM transaction_parts WHERE id = ?",
      arguments: [partId.uuidString]) == ReimbursementStatus.returned.rawValue
  }

  /// The live operations written for these parts: their shortfalls
  /// (`reimb:<money back>:shortfall:<part>`) and what was left of them and written off
  /// (`writeoff:<part>:<operation>`).
  private static func liveCompanions(ofParts partIds: [UUID], db: Database) throws -> [UUID] {
    var found: [UUID] = []
    for partId in partIds {
      let part = partId.uuidString.lowercased()
      found += try String.fetchAll(
        db,
        sql: """
          SELECT id FROM transactions
          WHERE deleted_at IS NULL
            AND ((substr(external_id, 1, 6) = 'reimb:'
                  AND substr(external_id, -length(?)) = ?)
              OR substr(external_id, 1, length(?)) = ?)
          ORDER BY rowid
          """,
        arguments: [
          ":shortfall:" + part, ":shortfall:" + part, "writeoff:" + part + ":",
          "writeoff:" + part + ":",
        ]
      ).compactMap(UUID.init(uuidString:))
    }
    return distinct(found)
  }

  // MARK: Helpers

  static func distinct(_ ids: [UUID]) -> [UUID] {
    var seen = Set<UUID>()
    return ids.filter { seen.insert($0).inserted }
  }

  /// The operations these parts belong to, each once.
  private static func operations(ofParts partIds: [UUID], db: Database) throws -> [UUID] {
    var found: [UUID] = []
    for chunk in partIds.map(\.uuidString).chunked(by: chunkSize) {
      found += try String.fetchAll(
        db,
        sql: """
          SELECT transaction_id FROM transaction_parts
          WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))
          ORDER BY rowid
          """,
        arguments: StatementArguments(Array(chunk))
      ).compactMap(UUID.init(uuidString:))
    }
    return distinct(found)
  }

  /// The moment each of these operations was last written, as stored.
  private static func stamps(of ids: [UUID], db: Database) throws -> [UUID: Date] {
    var found: [UUID: Date] = [:]
    for chunk in ids.map(\.uuidString).chunked(by: chunkSize) {
      for transaction in try CoreKit.Transaction.fetchAll(db, keys: Array(chunk)) {
        found[transaction.id] = transaction.updatedAt
      }
    }
    return found
  }

  /// Sets or clears `deleted_at`; either way the row was updated at `instant`.
  private static func mark(
    _ ids: [UUID], deletedAt: Date?, at instant: Date, db: Database
  ) throws {
    for chunk in ids.map(\.uuidString).chunked(by: chunkSize) {
      let marks = databaseQuestionMarks(count: chunk.count)
      try db.execute(
        sql: "UPDATE transactions SET deleted_at = ?, updated_at = ? WHERE id IN (\(marks))",
        arguments: [StoredInstant.databaseValue(deletedAt), StoredInstant.databaseValue(instant)]
          + StatementArguments(chunk))
    }
  }

  /// Moves the status of the parts that still have `current`, and stamps their operations
  /// as updated at `instant`.
  private static func setStatus(
    _ status: ReimbursementStatus, of partIds: [UUID], onlyWhere current: ReimbursementStatus,
    at instant: Date, db: Database
  ) throws {
    try stampOperations(ofParts: partIds, whereStatus: current, at: instant, db: db)
    for chunk in partIds.map(\.uuidString).chunked(by: chunkSize) {
      let marks = databaseQuestionMarks(count: chunk.count)
      try db.execute(
        sql: """
          UPDATE transaction_parts SET reimbursement_status = ?
          WHERE reimbursement_status = ? AND id IN (\(marks))
          """,
        arguments: StatementArguments([status.rawValue, current.rawValue])
          + StatementArguments(chunk))
    }
  }

  static func prefixArguments(of reimbursementId: UUID) -> StatementArguments {
    let prefix = ReimbursementCompanions.keyPrefix(of: reimbursementId)
    return [prefix.count, prefix]
  }

  /// Writes a changed operation over the row it was made from. When the parts are the same
  /// ones, only the parts that changed are touched; otherwise they are brought in line the
  /// way `save` does it, which keeps the links of the parts that stay. Returns the refunds in
  /// the bin that let go of a part that went (`replaceParts`).
  @discardableResult
  static func write(
    _ entry: TransactionEntry, over previous: TransactionEntry, db: Database
  ) throws -> [UUID: UUID] {
    try entry.transaction.update(db)
    let old = Dictionary(
      previous.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard Set(entry.parts.map(\.id)) == Set(old.keys) else {
      return try replaceParts(of: entry, db: db)
    }
    for part in entry.parts where old[part.id] != part {
      try part.update(db)
    }
    if entry.parts.map(\.id) != previous.parts.map(\.id) {
      try keepOrder(of: entry.parts, db: db)
    }
    return [:]
  }
}
