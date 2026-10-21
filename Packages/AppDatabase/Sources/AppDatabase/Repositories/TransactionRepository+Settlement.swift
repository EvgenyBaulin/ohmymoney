import AppCore
import CoreKit
import Foundation
import GRDB

/// What a re-balancing of money back writes that only the interface knows: the words of a
/// surplus it creates.
public struct SettlementSetting: Hashable, Sendable {
  /// «Излишек возврата» in the interface language; `nil` leaves a new surplus without a note.
  public var surplusNote: String?

  public init(surplusNote: String?) {
    self.surplusNote = surplusNote
  }
}

/// How much re-balancing money back changed, for the journal: counts only.
public struct SettlementCounts: Hashable, Sendable {
  /// Parts whose links, status or companions changed.
  public var parts: Int
  /// Surpluses written anew, rewritten, deleted or brought back from the bin.
  public var surpluses: Int
  /// The owner's own spending on the parts rewritten or deleted.
  public var companions: Int
  /// Money over the parts that stayed drift because the database has no Surcharges category.
  public var surplusesWithoutCategory: Int

  public init(
    parts: Int = 0, surpluses: Int = 0, companions: Int = 0, surplusesWithoutCategory: Int = 0
  ) {
    self.parts = parts
    self.surpluses = surpluses
    self.companions = companions
    self.surplusesWithoutCategory = surplusesWithoutCategory
  }

  public var isEmpty: Bool {
    parts == 0 && surpluses == 0 && companions == 0 && surplusesWithoutCategory == 0
  }

  public static func + (left: SettlementCounts, right: SettlementCounts) -> SettlementCounts {
    SettlementCounts(
      parts: left.parts + right.parts, surpluses: left.surpluses + right.surpluses,
      companions: left.companions + right.companions,
      surplusesWithoutCategory: left.surplusesWithoutCategory + right.surplusesWithoutCategory)
  }
}

/// What re-balancing money back wrote, as it was before — for undo — and as written — for the
/// lists. Empty when nothing had to change.
public struct SettlementWrite: Hashable, Sendable {
  /// The links whose rubles changed, as they were.
  public var linksBefore: [ReimbursementLink]
  /// The parts whose status changed → the status stored before (`nil`: none stored).
  public var statusesBefore: [UUID: ReimbursementStatus?]
  /// The surpluses and the owner's own spending on the parts (shortfalls, remainders written
  /// off) that were rewritten, deleted or brought back from the bin, as they were.
  public var operationsBefore: [TransactionEntry]
  /// The surpluses written for the first time.
  public var createdOperations: [UUID]
  /// The surpluses and companions as written.
  public var written: [TransactionEntry]
  /// How much changed, for the journal.
  public var counts: SettlementCounts

  public init(
    linksBefore: [ReimbursementLink] = [], statusesBefore: [UUID: ReimbursementStatus?] = [:],
    operationsBefore: [TransactionEntry] = [], createdOperations: [UUID] = [],
    written: [TransactionEntry] = [], counts: SettlementCounts = SettlementCounts()
  ) {
    self.linksBefore = linksBefore
    self.statusesBefore = statusesBefore
    self.operationsBefore = operationsBefore
    self.createdOperations = createdOperations
    self.written = written
    self.counts = counts
  }

  public static let empty = SettlementWrite()

  public var isEmpty: Bool {
    linksBefore.isEmpty && statusesBefore.isEmpty && operationsBefore.isEmpty
      && createdOperations.isEmpty
  }

  /// This write followed by `later`: what came first stays what it was before both.
  func merged(with later: SettlementWrite) -> SettlementWrite {
    var merged = self
    let links = Set(linksBefore.map(\.id))
    merged.linksBefore += later.linksBefore.filter { !links.contains($0.id) }
    for (part, status) in later.statusesBefore where merged.statusesBefore[part] == nil {
      merged.statusesBefore[part] = status
    }
    let operations = Set(operationsBefore.map(\.id)).union(createdOperations)
    merged.operationsBefore += later.operationsBefore.filter { !operations.contains($0.id) }
    merged.createdOperations += later.createdOperations.filter { !operations.contains($0) }
    let written = Set(later.written.map(\.id))
    merged.written = self.written.filter { !written.contains($0.id) } + later.written
    merged.counts = counts + later.counts
    return merged
  }
}

extension TransactionRepository {
  /// Balances again the money back of every part among `partIds` that has live links, after its
  /// rubles changed (`MoneyBackSettlement`), inside the caller's write: the links, the status of
  /// the part, the surplus of each money back — rewritten, deleted below a kopeck, brought back
  /// from the bin (its key is unique among deleted rows too) or written anew — and the owner's
  /// own spending on the part. A surplus needs the system Surcharges category; without one the
  /// money over stays drift and only the links move (`counts.surplusesWithoutCategory`).
  ///
  /// `rublesBefore` — part → its rubles before they changed: the links of money back in the
  /// part's own currency follow the new rubles in proportion (`MoneyBackSettlement`); a part
  /// missing there keeps those links as they are.
  static func settle(
    partIds: [UUID], rublesBefore: [UUID: AmountE4] = [:], setting: SettlementSetting,
    at instant: Date, db: Database
  ) throws -> SettlementWrite {
    var write = SettlementWrite()
    var moneyBacks: [UUID: MoneyBackSettlement.MoneyBackState] = [:]
    var backRows: [UUID: CoreKit.Transaction] = [:]
    for partId in distinct(partIds) {
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT p.amount_rub_e4 AS rubles, p.reimbursable AS reimbursable,
              p.reimbursement_status AS status, t.currency AS currency,
              EXISTS (
                SELECT 1 FROM reimbursement_links l
                JOIN transactions m ON m.id = l.reimbursement_tx_id
                WHERE l.part_id = p.id AND m.currency <> ?) AS foreignBack
            FROM transaction_parts p JOIN transactions t ON t.id = p.transaction_id
            WHERE p.id = ? AND t.deleted_at IS NULL AND t.kind = ?
            """,
          arguments: [
            CurrencyCode.rub.code, partId.uuidString, TransactionKind.expense.rawValue,
          ]),
        (row["reimbursable"] as Bool?) == true
      else { continue }
      let links = try ReimbursementLink.fetchAll(
        db,
        sql: """
          SELECT l.* FROM reimbursement_links l
          JOIN transactions m ON m.id = l.reimbursement_tx_id
          WHERE l.part_id = ? AND m.deleted_at IS NULL
          ORDER BY l.rowid
          """,
        arguments: [partId.uuidString])
      guard !links.isEmpty else { continue }
      for link in links where moneyBacks[link.reimbursementTxId] == nil {
        guard
          let back = try CoreKit.Transaction.fetchOne(db, key: link.reimbursementTxId.uuidString)
        else { continue }
        backRows[back.id] = back
        let surplus = try liveOperation(
          keyed: ReimbursementCompanions.surplusKey(of: back.id), db: db)
        moneyBacks[back.id] = MoneyBackSettlement.MoneyBackState(
          id: back.id, occurredAt: back.occurredAt, currency: back.currency,
          amountE4: back.amountE4, amountRubE4: back.amountRubE4,
          surplusRubE4: surplus?.transaction.amountRubE4 ?? .zero)
      }
      let companions = try companionEntries(ofPart: partId, db: db)
      let stored = (row["status"] as String?).flatMap(ReimbursementStatus.init(rawValue:))
      let state = MoneyBackSettlement.PartState(
        partId: partId, amountRubE4: AmountE4(raw: row["rubles"] ?? 0),
        status: stored ?? .expected,
        foreignInvolved: (row["currency"] as String?) != CurrencyCode.rub.code
          || (row["foreignBack"] as Bool? ?? false),
        links: links.map {
          MoneyBackSettlement.Link(
            id: $0.id, moneyBackId: $0.reimbursementTxId, amountRubE4: $0.amountE4)
        },
        companions: companions.map {
          MoneyBackSettlement.Companion(id: $0.id, amountRubE4: $0.transaction.amountRubE4)
        },
        currency: (row["currency"] as String?).map(CurrencyCode.init) ?? .rub,
        previousAmountRubE4: rublesBefore[partId])
      let outcome = MoneyBackSettlement.settle(state, moneyBacks: moneyBacks)
      guard !outcome.isUnchanged else { continue }
      write.counts.parts += 1

      if outcome.status != outcome.statusBefore {
        if write.statusesBefore[partId] == nil { write.statusesBefore[partId] = .some(stored) }
        try db.execute(
          sql: "UPDATE transaction_parts SET reimbursement_status = ? WHERE id = ?",
          arguments: [outcome.status.rawValue, partId.uuidString])
      }
      for link in links {
        guard let amount = outcome.links[link.id] else { continue }
        if !write.linksBefore.contains(where: { $0.id == link.id }) {
          write.linksBefore.append(link)
        }
        try db.execute(
          sql: "UPDATE reimbursement_links SET amount_e4 = ? WHERE id = ?",
          arguments: [amount.raw, link.id.uuidString])
      }
      for companion in companions {
        guard let rubles = outcome.companions[companion.id] else { continue }
        var next = companion
        if rubles.raw < MoneyBack.crumb.raw {
          next.transaction.deletedAt = instant
        } else {
          next.transaction.amountE4 = rubles
          next.transaction.amountRubE4 = rubles
          next.transaction.amountExpr = nil
          if next.transaction.accountCurrency == .rub { next.transaction.accountAmountE4 = rubles }
          if next.parts.count == 1 {
            next.parts[0].amountE4 = rubles
            next.parts[0].amountRubE4 = rubles
          }
        }
        next.transaction.updatedAt = instant
        try rewrite(next, over: companion, into: &write, db: db)
        write.counts.companions += 1
      }
      for (moneyBackId, rubles) in outcome.surplusRub {
        guard var state = moneyBacks[moneyBackId], let back = backRows[moneyBackId] else {
          continue
        }
        state.surplusRubE4 = rubles
        moneyBacks[moneyBackId] = state
        try writeSurplus(
          rubles, of: back, state: state, setting: setting, at: instant, into: &write, db: db)
      }
    }
    return write
  }

  /// Takes a re-balancing back, in the caller's write: surpluses written anew go, rewritten
  /// operations, links and statuses are as they were.
  static func revert(_ settlement: SettlementWrite, db: Database) throws {
    guard !settlement.isEmpty else { return }
    _ = try CoreKit.Transaction.deleteAll(
      db, keys: settlement.createdOperations.map(\.uuidString))
    for entry in settlement.operationsBefore {
      try entry.transaction.save(db)
      try replaceParts(of: entry, db: db)
    }
    for link in settlement.linksBefore {
      try db.execute(
        sql: "UPDATE reimbursement_links SET amount_e4 = ? WHERE id = ?",
        arguments: [link.amountE4.raw, link.id.uuidString])
    }
    for (partId, status) in settlement.statusesBefore {
      try db.execute(
        sql: "UPDATE transaction_parts SET reimbursement_status = ? WHERE id = ?",
        arguments: [status?.rawValue, partId.uuidString])
    }
  }

  /// The surplus of `back` at `rubles`: rewritten, deleted below a kopeck, brought back from
  /// the bin, or written anew.
  private static func writeSurplus(
    _ rubles: AmountE4, of back: CoreKit.Transaction,
    state: MoneyBackSettlement.MoneyBackState, setting: SettlementSetting, at instant: Date,
    into write: inout SettlementWrite, db: Database
  ) throws {
    let key = ReimbursementCompanions.surplusKey(of: back.id)
    let amount = MoneyBackSettlement.surplusAmount(rub: rubles, of: state)
    let keeps = rubles.raw >= MoneyBack.crumb.raw && amount.raw > 0
    if let existing = try anyOperation(keyed: key, db: db) {
      var next = existing
      if keeps {
        next.transaction.deletedAt = nil
        next.transaction.amountE4 = amount
        next.transaction.amountRubE4 = rubles
        next.transaction.amountExpr = nil
        next.transaction.accountCurrency = nil
        next.transaction.accountAmountE4 = nil
        if next.parts.count == 1 {
          next.parts[0].amountE4 = amount
          next.parts[0].amountRubE4 = rubles
        }
      } else {
        guard !existing.transaction.isDeleted else { return }
        next.transaction.deletedAt = instant
      }
      guard next != existing else { return }
      next.transaction.updatedAt = instant
      try rewrite(next, over: existing, into: &write, db: db)
      write.counts.surpluses += 1
      return
    }
    guard keeps else { return }
    guard
      let surcharges = try String.fetchOne(
        db,
        sql: """
          SELECT id FROM categories WHERE system_role = ? AND kind = ?
          ORDER BY archived, rowid LIMIT 1
          """,
        arguments: [SystemRole.surcharges.rawValue, CategoryKind.income.rawValue]
      ).flatMap(UUID.init(uuidString:))
    else {
      write.counts.surplusesWithoutCategory += 1
      return
    }
    let income = SurchargeIncome(
      amountE4: amount, currency: back.currency, amountRubE4: rubles,
      accountId: back.paymentMethodId)
    var entry = try MoneyBack.surplusEntry(
      income, of: back.id, on: back.occurredAt, now: instant,
      rate: back.currency == .rub ? nil : back.rate, rateDate: back.rateDate,
      categoryId: surcharges, note: setting.surplusNote)
    entry = try assigningAccount(entry, checkingCharge: false, db: db)
    try entry.transaction.insert(db)
    for part in entry.parts { try part.insert(db) }
    write.createdOperations.append(entry.id)
    write.written.append(entry)
    write.counts.surpluses += 1
  }

  /// Writes `next` over `previous` and keeps `previous` for undo, once.
  private static func rewrite(
    _ next: TransactionEntry, over previous: TransactionEntry,
    into write: inout SettlementWrite, db: Database
  ) throws {
    try Self.write(next, over: previous, db: db)
    if !write.operationsBefore.contains(where: { $0.id == previous.id }),
      !write.createdOperations.contains(previous.id)
    {
      write.operationsBefore.append(previous)
    }
    write.written.removeAll { $0.id == next.id }
    write.written.append(next)
  }

  /// The live operation with this key in `external_id`.
  private static func liveOperation(keyed key: String, db: Database) throws -> TransactionEntry? {
    guard let found = try anyOperation(keyed: key, db: db), !found.transaction.isDeleted else {
      return nil
    }
    return found
  }

  /// The operation with this key in `external_id`, live or in the bin: the key is unique among
  /// both.
  private static func anyOperation(keyed key: String, db: Database) throws -> TransactionEntry? {
    guard
      let id = try String.fetchOne(
        db, sql: "SELECT id FROM transactions WHERE external_id = ?", arguments: [key]
      ).flatMap(UUID.init(uuidString:))
    else { return nil }
    return try entry(id: id, db: db)
  }

  /// The live shortfalls (`reimb:<money back>:shortfall:<part>`) and remainders written off
  /// (`writeoff:<part>:<operation>`) of a part, oldest first.
  private static func companionEntries(
    ofPart partId: UUID, db: Database
  ) throws -> [TransactionEntry] {
    let part = partId.uuidString.lowercased()
    let ids = try String.fetchAll(
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
    return try ids.compactMap { try entry(id: $0, db: db) }
  }
}
