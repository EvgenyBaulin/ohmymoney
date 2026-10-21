import AppCore
import CoreKit
import Foundation
import GRDB

/// The rows of a debt owed to me that a money back writes with itself, when part of the money
/// repays the debt of the person who gave it: the lines of the journal — each pointing at the
/// operation that repaid —, and the debt itself when the repayment closes it.
public struct DebtSettling: Hashable, Sendable {
  public var lines: [DebtEntry]
  public var debts: [Debt]

  public init(lines: [DebtEntry] = [], debts: [Debt] = []) {
    self.lines = lines
    self.debts = debts
  }

  public static let none = DebtSettling()

  public var isEmpty: Bool { lines.isEmpty && debts.isEmpty }
}

/// Everything recording one money back wrote, so that one ⌘Z takes it all back
/// (`TransactionRepository.revertMoneyBack`).
public struct MoneyBackWrite: Hashable, Sendable {
  /// The money back, its surplus and its shortfalls.
  public var created: [UUID]
  /// The parts it closed.
  public var closedPartIds: [UUID]
  /// Its links.
  public var links: [UUID]
  /// The purchases repriced at a rate typed in the sheet, as they were.
  public var repricedBefore: [TransactionEntry]
  /// Their refunds that followed them, as they were.
  public var refundsBefore: [TransactionEntry]
  /// The money that had come back for the repriced parts, balanced again.
  public var settlement: SettlementWrite
  /// What the counts whose windows the money back reached wrote in the same write — the money
  /// that came onto an account, a purchase charged anew: the lists lay it over what they show,
  /// and ⌘Z writes a difference it took to zero back as the owner left it.
  public var counts: CountsSettled
  /// The moment each purchase whose part it closed was last written before it: ⌘Z gives it
  /// back, so taking the money back is no new write of the purchase (the owner's latest hand
  /// rating of a description is the one written last).
  public var updatedAtBefore: [UUID: Date]
  /// The lines of a debt's journal it wrote (`DebtSettling`): ⌘Z takes them away.
  public var debtLines: [UUID]
  /// The debts it closed, as they were: ⌘Z opens them again.
  public var debtsBefore: [Debt]

  public init(
    created: [UUID] = [], closedPartIds: [UUID] = [], links: [UUID] = [],
    repricedBefore: [TransactionEntry] = [], refundsBefore: [TransactionEntry] = [],
    settlement: SettlementWrite = .empty, counts: CountsSettled = .none,
    updatedAtBefore: [UUID: Date] = [:], debtLines: [UUID] = [], debtsBefore: [Debt] = []
  ) {
    self.created = created
    self.closedPartIds = closedPartIds
    self.links = links
    self.repricedBefore = repricedBefore
    self.refundsBefore = refundsBefore
    self.settlement = settlement
    self.counts = counts
    self.updatedAtBefore = updatedAtBefore
    self.debtLines = debtLines
    self.debtsBefore = debtsBefore
  }

  /// Every operation the money back wrote or wrote over, by id: itself, its surplus and
  /// shortfalls, the purchases repriced, their refunds, the surpluses and the owner's own
  /// spending balanced again.
  var touchedIds: [UUID] {
    created + repricedBefore.map(\.id) + refundsBefore.map(\.id)
      + settlement.operationsBefore.map(\.id) + settlement.createdOperations
  }
}

/// The parts a purchase paid for somebody else: what is still owed, the money back that settles
/// them, and writing off what never comes back.
extension TransactionRepository {
  /// Parts that are still waiting to come back — the "Owed to me" list — each with what came
  /// back for it already and what is left: money back may cover only some of a part.
  ///
  /// Only purchases with a part that can still be waiting for are read: `owedToMe` would
  /// pass over every other operation, and there is no point in mapping the whole history
  /// for it.
  public func owedParts() throws -> [OwedPart] {
    let (entries, links) = try writer.read { db -> ([TransactionEntry], [ReimbursementLink]) in
      let entries = try Self.entries(
        where: """
          deleted_at IS NULL AND kind = ?
            AND id IN (
              SELECT transaction_id FROM transaction_parts
              WHERE reimbursable = 1
                AND (reimbursement_status IS NULL OR reimbursement_status = ?))
          """,
        arguments: [TransactionKind.expense.rawValue, ReimbursementStatus.expected.rawValue],
        db: db)
      let links = try ReimbursementLink.fetchAll(
        db,
        sql: """
          SELECT l.* FROM reimbursement_links l
          JOIN transactions t ON t.id = l.reimbursement_tx_id
          JOIN transaction_parts p ON p.id = l.part_id
          WHERE t.deleted_at IS NULL AND p.reimbursable = 1
            AND (p.reimbursement_status IS NULL OR p.reimbursement_status = ?)
          ORDER BY l.rowid
          """,
        arguments: [ReimbursementStatus.expected.rawValue])
      return (entries, links)
    }
    return MyExpensesRule.owedToMe(entries: entries, links: links)
  }

  /// Writes the result of a reimbursement: the links, the new statuses and, when the
  /// money did not match, the extra income or expense the rules produced.
  ///
  /// The parts were read when the sheet opened, and each of them may have stopped waiting
  /// since — its purchase deleted from another window or taken back by ⌘Z, the part written
  /// off or closed by another reimbursement, or more of it came back meanwhile. Such a part is
  /// refused inside the write with `ReimbursementError.partNoLongerOwed`, and nothing is
  /// written: a link to it would count the money as returned with nothing behind it, and the
  /// links of a part never come to more than what was left of it.
  ///
  /// `repricing` — purchase → the rate typed for it in the sheet: before anything else, each
  /// such purchase is written again at that rate (`PurchaseRate.repriced`, its day's date in
  /// `calendar`), its refunds follow it (`RefundRules.following`) and the money that already
  /// came back for its parts is balanced again (`settle`, with `settlement`'s words) — for the
  /// parts this money back neither links nor closes: the plan for those was made on the repriced
  /// part, and closes it itself (a part 10 ₽ short of the money that came back before, within
  /// the drift, is closed by the plan, not twice). A purchase gone meanwhile, or no longer a
  /// purchase, refuses the whole write with `partNoLongerOwed`.
  ///
  /// The reimbursement and the operations it brings are given an account like any other
  /// (`assigningAccount`). The counts whose windows the money that came, or a purchase charged
  /// anew, reached follow the books in the same write (`MoneyBackWrite.counts`).
  ///
  /// With `debt` — part of the money repays the debt owed to me by the person who gave it, the
  /// operation of that repayment being one of `extra` — the lines of the journal and the closing
  /// of the debt land in the same write (`DebtSettling`). Returns everything written, so that
  /// one ⌘Z takes it all back (`revertMoneyBack`).
  @discardableResult
  public func apply(
    _ outcome: ReimbursementOutcome,
    reimbursement: TransactionEntry,
    extra: [TransactionEntry] = [],
    debt: DebtSettling = .none,
    repricing: [UUID: Decimal] = [:],
    settlement: SettlementSetting = SettlementSetting(surplusNote: nil),
    calendar: CalendarContext = .system,
    at instant: Date = Date()
  ) throws -> MoneyBackWrite {
    guard reimbursement.isBalanced else { throw DatabaseError.unbalancedParts }
    // The surplus and the shortfalls are operations like any other: their parts have to
    // add up too, or the totals would never match again.
    guard extra.allSatisfy(\.isBalanced) else { throw DatabaseError.unbalancedParts }
    let context = liveCounts
    return try writer.write { db in
      var write = MoneyBackWrite()
      // Read before anything is written, a repriced purchase's included: ⌘Z gives them back.
      write.updatedAtBefore = try Self.stamps(ofOperationsOfParts: outcome.closedPartIds, db: db)
      let planned = Set(outcome.closedPartIds + outcome.links.map(\.partId))
      for (purchaseId, rate) in repricing.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
        guard let fresh = try Self.entry(id: purchaseId, db: db), !fresh.transaction.isDeleted,
          fresh.transaction.kind == .expense
        else { throw ReimbursementError.partNoLongerOwed(purchaseId) }
        var repriced = try PurchaseRate.repriced(
          fresh, rate: rate, day: calendar.day(of: fresh.transaction.occurredAt))
        guard repriced != fresh else { continue }
        repriced.transaction.updatedAt = instant
        try Self.write(repriced, over: fresh, db: db)
        write.repricedBefore.append(fresh)
        write.refundsBefore += try Self.followingRefunds(of: repriced, at: instant, db: db)
        write.settlement = write.settlement.merged(
          with: try Self.settle(
            partIds: repriced.parts.filter { $0.reimbursable && !planned.contains($0.id) }
              .map(\.id),
            rublesBefore: Dictionary(
              fresh.parts.map { ($0.id, $0.amountRubE4) }, uniquingKeysWith: { first, _ in first }),
            setting: settlement, at: instant, db: db))
      }
      var checked: Set<UUID> = []
      for partId in outcome.closedPartIds + outcome.links.map(\.partId)
      where checked.insert(partId).inserted {
        guard try Self.isOwed(partId: partId, db: db) else {
          throw ReimbursementError.partNoLongerOwed(partId)
        }
      }
      var linked: [UUID: AmountE4] = [:]
      for link in outcome.links { linked[link.partId, default: .zero] += link.amountE4 }
      for (partId, amount) in linked {
        guard amount <= (try Self.remainingRub(ofPart: partId, db: db)) else {
          throw ReimbursementError.partNoLongerOwed(partId)
        }
      }
      let written = try Self.assigningAccount(reimbursement, db: db)
      try written.transaction.save(db)
      try Self.replaceParts(of: written, db: db)
      write.created.append(written.id)
      for entry in extra {
        let companion = try Self.assigningAccount(entry, db: db)
        try companion.transaction.save(db)
        try Self.replaceParts(of: companion, db: db)
        write.created.append(companion.id)
      }
      // The debt the money repays: its journal lines point at the operations just written, and
      // a debt the repayment closes is kept as it was for ⌘Z.
      for closed in debt.debts {
        if let before = try Debt.fetchOne(db, key: closed.id.uuidString) {
          write.debtsBefore.append(before)
        }
        try closed.save(db)
      }
      for line in debt.lines {
        try line.save(db)
        write.debtLines.append(line.id)
      }
      for link in outcome.links {
        try link.insert(db)
        write.links.append(link.id)
      }
      for partId in outcome.closedPartIds {
        try db.execute(
          sql: "UPDATE transaction_parts SET reimbursement_status = ? WHERE id = ?",
          arguments: [ReimbursementStatus.returned.rawValue, partId.uuidString])
      }
      write.closedPartIds = outcome.closedPartIds
      try Self.stampOperations(ofParts: outcome.closedPartIds, at: instant, db: db)
      let now = try Self.entries(ids: write.touchedIds, db: db)
      let touch = try LiveCountsWriter.touch(
        entries: (write.repricedBefore + write.refundsBefore + write.settlement.operationsBefore)
          .map { ($0, nil) } + now.map { (nil, $0) },
        calendar: context.calendar, lookups: WriteLookups(), db: db)
      write.counts = try LiveCountsWriter.settle(touch, context: context, now: instant, db: db)
      return write
    }
  }

  /// Takes a money back written by `apply` back in one write: the money back, its surplus and
  /// its shortfalls go for good (their links with them), the parts it closed wait again, the
  /// money that came back earlier is as it was, and every purchase repriced in the sheet is back
  /// at its old rate with its refunds. Parts that stopped waiting meanwhile for another reason
  /// are not reopened: only a part still `returned` is. The counts whose windows it all moves
  /// out of or back into follow the books in the same write, and a difference the money back
  /// took to zero comes back as the owner left it.
  @discardableResult
  public func revertMoneyBack(
    _ write: MoneyBackWrite, at instant: Date = Date()
  ) throws -> CountsSettled {
    let context = liveCounts
    return try writer.write { db in
      let standing = try Self.entries(ids: write.touchedIds, db: db)
      // The lines of a debt's journal go first: their operations' deletion would only let them
      // go, with nothing to point at. A debt the money back closed is open again.
      for chunk in write.debtLines.map(\.uuidString).chunked(by: Self.chunkSize) {
        try db.execute(
          sql:
            "DELETE FROM debt_entries WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))",
          arguments: StatementArguments(chunk))
      }
      for before in write.debtsBefore { try before.save(db) }
      _ = try CoreKit.Transaction.deleteAll(db, keys: write.created.map(\.uuidString))
      let reopening = try write.closedPartIds.filter {
        try String.fetchOne(
          db, sql: "SELECT reimbursement_status FROM transaction_parts WHERE id = ?",
          arguments: [$0.uuidString]) == ReimbursementStatus.returned.rawValue
      }
      for partId in reopening {
        try db.execute(
          sql: "UPDATE transaction_parts SET reimbursement_status = ? WHERE id = ?",
          arguments: [ReimbursementStatus.expected.rawValue, partId.uuidString])
      }
      // A purchase whose part waits again gets back the moment it had before the money back;
      // one the write did not keep the moment of is stamped as updated now.
      let purchases = try Self.stamps(ofOperationsOfParts: reopening, db: db).keys
      for id in purchases.sorted(by: { $0.uuidString < $1.uuidString }) {
        try db.execute(
          sql: "UPDATE transactions SET updated_at = ? WHERE id = ?",
          arguments: [
            StoredInstant.databaseValue(write.updatedAtBefore[id] ?? instant), id.uuidString,
          ])
      }
      try Self.revert(write.settlement, db: db)
      for entry in write.refundsBefore + write.repricedBefore {
        guard let current = try Self.entry(id: entry.id, db: db) else { continue }
        try Self.write(entry, over: current, db: db)
      }
      let back = try Self.entries(ids: write.touchedIds, db: db)
      let touch = try LiveCountsWriter.touch(
        entries: standing.map { ($0, nil) } + back.map { (nil, $0) },
        calendar: context.calendar, lookups: WriteLookups(), db: db)
      return try LiveCountsWriter.settle(
        touch, context: context, now: instant, templates: write.counts.operationsBefore, db: db)
    }
  }

  /// How far a part has come back is a fact about its operation, like any field of it: the
  /// operation was updated when a reimbursement closed the part, when deleting that
  /// reimbursement reopened it (and ⌘Z closed it again), and when it was written off.
  /// `status` narrows it to the parts whose status is that one, read before the status moves.
  static func stampOperations(
    ofParts partIds: [UUID], whereStatus status: ReimbursementStatus? = nil, at instant: Date,
    db: Database
  ) throws {
    let condition = status == nil ? "" : "reimbursement_status = ? AND "
    let statusArgument = status.map { StatementArguments([$0.rawValue]) } ?? []
    for chunk in partIds.map(\.uuidString).chunked(by: chunkSize) {
      let marks = databaseQuestionMarks(count: chunk.count)
      try db.execute(
        sql: """
          UPDATE transactions SET updated_at = ?
          WHERE id IN (
            SELECT transaction_id FROM transaction_parts WHERE \(condition)id IN (\(marks)))
          """,
        arguments: [StoredInstant.databaseValue(instant)] + statusArgument
          + StatementArguments(chunk))
    }
  }

  /// The moment each operation these parts belong to was last written, as stored.
  private static func stamps(
    ofOperationsOfParts partIds: [UUID], db: Database
  ) throws -> [UUID: Date] {
    var found: [UUID: Date] = [:]
    for chunk in partIds.map(\.uuidString).chunked(by: chunkSize) {
      let marks = databaseQuestionMarks(count: chunk.count)
      let operations = try CoreKit.Transaction.fetchAll(
        db,
        sql: """
          SELECT * FROM transactions
          WHERE id IN (SELECT transaction_id FROM transaction_parts WHERE id IN (\(marks)))
          """,
        arguments: StatementArguments(chunk))
      for operation in operations { found[operation.id] = operation.updatedAt }
    }
    return found
  }

  /// Whether a part still waits for its money, by the same condition as `owedParts()`: a
  /// part «for somebody else» of a live purchase, neither returned nor written off, with
  /// something left of it.
  private static func isOwed(partId: UUID, db: Database) throws -> Bool {
    let waits =
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS (
            SELECT 1 FROM transaction_parts p
            JOIN transactions t ON t.id = p.transaction_id
            WHERE p.id = ? AND t.deleted_at IS NULL AND t.kind = ? AND p.reimbursable = 1
              AND (p.reimbursement_status IS NULL OR p.reimbursement_status = ?))
          """,
        arguments: [
          partId.uuidString, TransactionKind.expense.rawValue,
          ReimbursementStatus.expected.rawValue,
        ]) ?? false
    return try waits && remainingRub(ofPart: partId, db: db).raw > 0
  }

  /// What live money back gave back for a part, in rubles.
  static func returnedRub(ofPart partId: UUID, db: Database) throws -> AmountE4 {
    AmountE4(
      raw: try Int64.fetchOne(
        db,
        sql: """
          SELECT COALESCE(SUM(l.amount_e4), 0) FROM reimbursement_links l
          JOIN transactions t ON t.id = l.reimbursement_tx_id
          WHERE l.part_id = ? AND t.deleted_at IS NULL
          """,
        arguments: [partId.uuidString]) ?? 0)
  }

  /// What is left of a part: its rubles less what live money back gave back for it.
  static func remainingRub(ofPart partId: UUID, db: Database) throws -> AmountE4 {
    let rubles = AmountE4(
      raw: try Int64.fetchOne(
        db, sql: "SELECT amount_rub_e4 FROM transaction_parts WHERE id = ?",
        arguments: [partId.uuidString]) ?? 0)
    return rubles - (try returnedRub(ofPart: partId, db: db))
  }

  /// Writing a part off: it stops waiting and becomes my spending.
  ///
  /// The sheet offers the parts it read when it opened. One that stopped waiting since —
  /// closed by a reimbursement, written off, its purchase deleted — is refused inside the
  /// write with `ReimbursementError.partNoLongerOwed`, as `apply` refuses it: a closed part
  /// written off would leave its link counting money for a part given up on. A part some money
  /// already came back for is refused with `ReimbursementError.partlyReturned`: only what is
  /// left of it is written off (`writeOffRemainder`).
  public func writeOffPart(id: UUID, at instant: Date = Date()) throws {
    _ = try writer.write { db in
      guard try Self.isOwed(partId: id, db: db) else {
        throw ReimbursementError.partNoLongerOwed(id)
      }
      guard try Self.returnedRub(ofPart: id, db: db).isZero else {
        throw ReimbursementError.partlyReturned(id)
      }
      try db.execute(
        sql: "UPDATE transaction_parts SET reimbursement_status = ? WHERE id = ?",
        arguments: [ReimbursementStatus.writtenOff.rawValue, id.uuidString])
      try Self.stampOperations(ofParts: [id], at: instant, db: db)
    }
  }

  /// «Списать остаток»: what is left of a part some money already came back for becomes my
  /// spending, and the part is settled — in one write.
  ///
  /// `companion` is the operation `MoneyBack.remainderWriteOff` made from the part as the
  /// sheet read it; its amount is worked out again here from the part as it is now — what is
  /// left of it in rubles —, and it gets the key `writeoff:<part>:<its id>`, a line of the
  /// books. The part becomes `returned`.
  ///
  /// Refused with `ReimbursementError.partNoLongerOwed` when the part stopped waiting, and
  /// with `.nothingReturnedYet` when no money came back for it: then the whole part is written
  /// off (`writeOffPart`). Returns the operation as written.
  @discardableResult
  public func writeOffRemainder(
    partId: UUID, companion: TransactionEntry, at instant: Date = Date()
  ) throws -> TransactionEntry {
    try writer.write { db in
      guard try Self.isOwed(partId: partId, db: db) else {
        throw ReimbursementError.partNoLongerOwed(partId)
      }
      guard try Self.returnedRub(ofPart: partId, db: db).raw > 0 else {
        throw ReimbursementError.nothingReturnedYet(partId)
      }
      let remaining = try Self.remainingRub(ofPart: partId, db: db)
      var entry = companion
      entry.transaction.kind = .expense
      entry.transaction.currency = .rub
      entry.transaction.amountE4 = remaining
      entry.transaction.amountExpr = nil
      entry.transaction.rate = nil
      entry.transaction.rateDate = nil
      entry.transaction.rateSource = nil
      entry.transaction.rateProvisional = false
      entry.transaction.amountRubE4 = remaining
      entry.transaction.accountCurrency = nil
      entry.transaction.accountAmountE4 = nil
      entry.transaction.externalId = MoneyBack.writeOffKey(part: partId, operation: entry.id)
      entry.transaction.createdAt = instant
      entry.transaction.updatedAt = instant
      entry.transaction.deletedAt = nil
      guard var first = entry.parts.first else { throw DatabaseError.unbalancedParts }
      first.transactionId = entry.id
      first.amountE4 = remaining
      first.amountRubE4 = remaining
      first.reimbursable = false
      first.reimbursementStatus = nil
      first.debtorPersonId = nil
      first.refundOfPartId = nil
      entry.parts = [first]
      entry = try Self.assigningAccount(entry, db: db)
      try entry.transaction.insert(db)
      for part in entry.parts { try part.insert(db) }
      try db.execute(
        sql: "UPDATE transaction_parts SET reimbursement_status = ? WHERE id = ?",
        arguments: [ReimbursementStatus.returned.rawValue, partId.uuidString])
      try Self.stampOperations(ofParts: [partId], at: instant, db: db)
      return entry
    }
  }
}
