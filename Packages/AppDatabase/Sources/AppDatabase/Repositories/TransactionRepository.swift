import AppCore
import CoreKit
import Foundation
import GRDB

/// Reads and writes operations together with their parts. Deletion is always soft, so
/// ⌘Z can bring an operation back exactly as it was.
public struct TransactionRepository: Sendable {
  let writer: any DatabaseWriter
  /// My ratings by description (`manualQualityHistory()`), kept between reads.
  let manualRatings = ManualRatingsCache()
  /// The owner's calendar and the name of «Сверка», for the counts every write settles.
  let liveCounts: LiveCountsContext

  public init(writer: any DatabaseWriter, liveCounts: LiveCountsContext = .standard) {
    self.writer = writer
    self.liveCounts = liveCounts
  }

  /// Saves an operation and its parts in one transaction. Parts must add up to the total.
  ///
  /// Every operation has an account: one saved without is given the main account
  /// (`assigningAccount`), and one that moves money on an account that does not hold its
  /// currency must say what the account was charged. A refund that takes back from a purchase
  /// part is held to that part as it is inside the write (`refuseUnsoundRefund`). Returns the
  /// operation as written.
  ///
  /// The counts whose windows the operation left or entered follow the books in the same write
  /// (`saveReporting`).
  @discardableResult
  public func save(_ entry: TransactionEntry) throws -> TransactionEntry {
    try saveReporting(entry).entry
  }

  /// `save`, and what the counts it reached wrote: a backdated operation changes the difference
  /// of the count whose window holds it, and the operation of that difference with it — in the
  /// same write, so ⌘Z of the save takes both back.
  public func saveReporting(
    _ entry: TransactionEntry
  ) throws -> (entry: TransactionEntry, counts: CountsSettled) {
    guard entry.isBalanced else { throw DatabaseError.unbalancedParts }
    let context = liveCounts
    return try writer.write { db in
      let previous = try Self.entry(id: entry.id, db: db)
      let lookups = WriteLookups()
      let assigned = try Self.assigningAccount(entry, over: previous, lookups: lookups, db: db)
      try Self.refuseUnsoundRefund(assigned, over: previous, db: db)
      try assigned.transaction.save(db)
      try Self.replaceParts(of: assigned, db: db)
      let touch = try LiveCountsWriter.touch(
        entries: [(previous, assigned)], calendar: context.calendar, lookups: lookups, db: db)
      return (assigned, try LiveCountsWriter.settle(touch, context: context, db: db))
    }
  }

  // MARK: Every operation has an account

  /// The operation with an account: one that names none gets the live main account — when
  /// there is none yet, before the accounts are set up, it stays without, and the setup gives
  /// it one. A card it names must be a card of that account, or the write is refused with
  /// `AccountWriteError.cardOfAnotherAccount` — money always moves on the card's own account.
  /// The cashback typed for it is kept only on an expense and only in the currency that moves
  /// on the account (`Transaction.keptCashback`). Then the charge is checked
  /// (`refuseMissingCharge`), unless `checkingCharge` is off: ⌘Z writes back a row as it was,
  /// and a row of the time before accounts had no charge.
  ///
  /// `lookups` keeps what the check reads for the whole write, when it writes many operations.
  static func assigningAccount(
    _ entry: TransactionEntry, over previous: TransactionEntry? = nil,
    checkingCharge: Bool = true, lookups: WriteLookups = WriteLookups(), db: Database
  ) throws -> TransactionEntry {
    var assigned = entry
    if assigned.transaction.paymentMethodId == nil {
      assigned.transaction.paymentMethodId = try lookups.mainAccountId(db)
    }
    if let cardId = assigned.transaction.cardId {
      guard let account = try lookups.cardAccount(cardId, db),
        account == assigned.transaction.paymentMethodId
      else { throw AccountWriteError.cardOfAnotherAccount }
    }
    assigned.transaction.cashback = assigned.transaction.keptCashback
    guard checkingCharge else { return assigned }
    var before = previous
    if before?.transaction.paymentMethodId == nil, previous != nil {
      before?.transaction.paymentMethodId = try lookups.mainAccountId(db)
    }
    try refuseMissingCharge(assigned, over: before, lookups: lookups, db: db)
    return assigned
  }

  /// The live main account, if there is one yet.
  static func mainAccountId(_ db: Database) throws -> UUID? {
    try String.fetchOne(
      db,
      sql: """
        SELECT id FROM payment_methods WHERE is_default = 1 AND archived = 0
        ORDER BY rowid LIMIT 1
        """
    ).flatMap(UUID.init(uuidString:))
  }

  /// Refuses, with `AccountWriteError.chargeMissing`, an operation that moves money on an
  /// account that does not hold its currency and does not say what the account was charged
  /// (`Transaction.accountCurrency`/`accountAmountE4`) in a currency the account holds.
  ///
  /// Only an operation that moves money is asked (`AccountBalances.movesMoney`): not a line of
  /// the books, not a purchase on credit, not money put into a goal. A new operation is asked,
  /// and so is one written over `previous`, unless it moves money just as `previous` did — the
  /// same account, currency, amount and charge, the same type, credit and line of the books,
  /// and money moved before as now. So a row of the time before accounts that nobody touched
  /// is never refused, but a charge cannot be taken away, and a contribution to a goal filed
  /// under an ordinary category becomes spending that says what the account was charged.
  static func refuseMissingCharge(
    _ entry: TransactionEntry, over previous: TransactionEntry?,
    lookups: WriteLookups = WriteLookups(), db: Database
  ) throws {
    let transaction = entry.transaction
    guard let accountId = transaction.paymentMethodId else { return }
    let alike = previous.map { movesAlike($0, entry) } ?? false
    if alike, let previous, sameGoalParts(previous, entry) { return }
    guard let account = try lookups.account(accountId, db), !account.holds(transaction.currency)
    else { return }
    if let charged = transaction.accountCurrency, transaction.accountAmountE4 != nil,
      account.holds(charged)
    {
      return
    }
    let tree = try lookups.categories(db)
    guard AccountBalances.movesMoney(entry, tree: tree) else { return }
    if alike, let previous, AccountBalances.movesMoney(previous, tree: tree) { return }
    throw AccountWriteError.chargeMissing
  }

  /// Whether `after` moves money on the same terms as `before`, its parts aside: the account,
  /// the currency, the amount, what the account was charged, the type, the credit, and whether
  /// it is a line of the books.
  private static func movesAlike(_ before: TransactionEntry, _ after: TransactionEntry) -> Bool {
    let old = before.transaction
    let new = after.transaction
    return old.paymentMethodId == new.paymentMethodId && old.currency == new.currency
      && old.amountE4 == new.amountE4 && old.accountCurrency == new.accountCurrency
      && old.accountAmountE4 == new.accountAmountE4 && old.kind == new.kind
      && old.creditDebtId == new.creditDebtId
      && OperationLink(externalId: old.externalId)?.isBookkeeping
        == OperationLink(externalId: new.externalId)?.isBookkeeping
  }

  /// Whether the parts go to the same goals and categories — what decides that money goes into
  /// a goal rather than out of the pocket.
  private static func sameGoalParts(
    _ before: TransactionEntry, _ after: TransactionEntry
  )
    -> Bool
  {
    before.parts.map(\.goalId) == after.parts.map(\.goalId)
      && before.parts.map(\.categoryId) == after.parts.map(\.categoryId)
  }

  // MARK: Refunds of a purchase

  /// Refuses, with `RefundError`, a refund that takes back from a purchase part what the part
  /// cannot give, judged by the rows as they are inside the write — two refunds drafted from
  /// the same list are both checked against the part:
  ///
  /// * only a refund takes back from a part, and only from a part it may be refunded from — a
  ///   live purchase of my own (`RefundRules.isRefundable`) —: `.notRefundable`;
  /// * in the purchase's currency: `.otherCurrency`;
  /// * with the part's other live refunds, never more than the part: `.exceedsRemaining`.
  ///
  /// A link the operation already had, to a part that took the same or more from it before, is
  /// not asked again: it was checked when it was made.
  static func refuseUnsoundRefund(
    _ entry: TransactionEntry, over previous: TransactionEntry?, db: Database
  ) throws {
    var asked: [UUID: AmountE4] = [:]
    for part in entry.parts {
      guard let target = part.refundOfPartId else { continue }
      asked[target, default: .zero] += part.amountE4
    }
    guard !asked.isEmpty else { return }
    guard entry.transaction.kind == .refund else { throw RefundError.notRefundable }
    var before: [UUID: AmountE4] = [:]
    if let previous, previous.transaction.kind == .refund,
      previous.transaction.currency == entry.transaction.currency
    {
      for part in previous.parts {
        guard let target = part.refundOfPartId else { continue }
        before[target, default: .zero] += part.amountE4
      }
    }
    var tree: CategoryTree?
    for (target, amount) in asked.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      if let earlier = before[target], amount <= earlier { continue }
      guard
        let purchaseId = try String.fetchOne(
          db, sql: "SELECT transaction_id FROM transaction_parts WHERE id = ?",
          arguments: [target.uuidString]
        ).flatMap(UUID.init(uuidString:)),
        let purchase = try Self.entry(id: purchaseId, db: db),
        let part = purchase.parts.first(where: { $0.id == target })
      else { throw RefundError.notRefundable }
      if before[target] == nil {
        if tree == nil { tree = CategoryTree(try CoreKit.Category.fetchAll(db)) }
        // A purchase on an instalment plan can be returned: the debt it was bought on says so.
        let plan = try purchase.transaction.creditDebtId.flatMap { id in
          try Debt.fetchOne(db, key: id.uuidString)
        }
        guard
          RefundRules.isRefundable(
            part: part, in: purchase, tree: tree ?? CategoryTree(), creditDebt: plan)
        else { throw RefundError.notRefundable }
      }
      guard purchase.transaction.currency == entry.transaction.currency else {
        throw RefundError.otherCurrency
      }
      let others = AmountE4(
        raw: try Int64.fetchOne(
          db,
          sql: """
            SELECT COALESCE(SUM(p.amount_e4), 0) FROM transaction_parts p
            JOIN transactions t ON t.id = p.transaction_id
            WHERE t.deleted_at IS NULL AND t.kind = ? AND p.refund_of_part_id = ? AND t.id <> ?
            """,
          arguments: [TransactionKind.refund.rawValue, target.uuidString, entry.id.uuidString])
          ?? 0)
      guard others + amount <= part.amountE4 else { throw RefundError.exceedsRemaining }
    }
  }

  /// Brings the parts of an operation in line with the entry, updating the rows that stay
  /// instead of recreating them.
  ///
  /// A `reimbursement_links` row cascades away with the part it points at, so deleting
  /// every part and inserting it again would wipe the trail of a reimbursement each time
  /// the operation is edited. Only the parts that really went away are deleted.
  ///
  /// A refund in the bin that took back from a part going away lets go of it: it takes back
  /// from nothing while it is deleted, and the schema would otherwise refuse to remove the part
  /// for as long as the refund stays in the bin. What was let go is returned, refund part →
  /// purchase part, so that ⌘Z can tie it back (`relink`). A live refund still taking back
  /// from a part going away refuses the write with `LinkedEditRefusal.refundedPartRemoved` —
  /// the edit's own rules say so first; this is what stands behind them.
  @discardableResult
  static func replaceParts(of entry: TransactionEntry, db: Database) throws -> [UUID: UUID] {
    let kept = entry.parts.map(\.id.uuidString)
    let going =
      try TransactionPart
      .filter(Column("transaction_id") == entry.transaction.id.uuidString)
      .filter(!kept.contains(Column("id")))
      .select(Column("id"), as: String.self)
      .fetchAll(db)
    var released: [UUID: UUID] = [:]
    if !going.isEmpty {
      let marks = databaseQuestionMarks(count: going.count)
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT p.id AS part, p.refund_of_part_id AS target FROM transaction_parts p
          JOIN transactions t ON t.id = p.transaction_id
          WHERE t.deleted_at IS NOT NULL AND p.refund_of_part_id IN (\(marks))
          ORDER BY p.rowid
          """,
        arguments: StatementArguments(going))
      {
        guard let part = RowMapping.optionalUUID(row, "part"),
          let target = RowMapping.optionalUUID(row, "target")
        else { continue }
        released[part] = target
      }
      for chunk in released.keys.map(\.uuidString).chunked(by: chunkSize) {
        try db.execute(
          sql: """
            UPDATE transaction_parts SET refund_of_part_id = NULL
            WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))
            """,
          arguments: StatementArguments(Array(chunk)))
      }
      do {
        try TransactionPart.filter(going.contains(Column("id"))).deleteAll(db)
      } catch let error as GRDB.DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
        // The one foreign key that keeps a part from going is a refund's.
        throw LinkedEditRefusal.refundedPartRemoved
      }
    }
    for part in entry.parts {
      try part.save(db)
    }
    try keepOrder(of: entry.parts, db: db)
    return released
  }

  /// Parts are read in the order they were written (`rowid`), which is the order of the split.
  /// A part given back — an edit taken back, a rewrite undone — is saved at a new rowid, after
  /// the parts it used to come before; when the rowids no longer follow the order the operation
  /// gives its parts in, the parts are written past the last rowid in that order. Only the
  /// parts of this operation move, and nothing points at a part by its rowid.
  static func keepOrder(of parts: [TransactionPart], db: Database) throws {
    guard parts.count > 1 else { return }
    let ids = parts.map(\.id.uuidString)
    var rowIDs: [String: Int64] = [:]
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT id, rowid FROM transaction_parts
        WHERE id IN (\(databaseQuestionMarks(count: ids.count)))
        """,
      arguments: StatementArguments(ids))
    {
      rowIDs[row["id"]] = row["rowid"]
    }
    let order = ids.compactMap { rowIDs[$0] }
    guard order.count == ids.count, zip(order, order.dropFirst()).contains(where: { $0 >= $1 })
    else { return }
    for id in ids {
      try db.execute(
        sql: """
          UPDATE transaction_parts SET rowid = (SELECT MAX(rowid) + 1 FROM transaction_parts)
          WHERE id = ?
          """,
        arguments: [id])
    }
  }

  /// Ties refunds in the bin back to the purchase parts `replaceParts` made them let go of,
  /// where both are there again.
  static func relink(_ released: [UUID: UUID], db: Database) throws {
    for (refundPart, target) in released.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      guard try TransactionPart.exists(db, key: target.uuidString) else { continue }
      try db.execute(
        sql: """
          UPDATE transaction_parts SET refund_of_part_id = ?
          WHERE id = ? AND refund_of_part_id IS NULL
          """,
        arguments: [target.uuidString, refundPart.uuidString])
    }
  }

  public func entry(id: UUID) throws -> TransactionEntry? {
    try writer.read { db in try Self.entry(id: id, db: db) }
  }

  /// One operation with its parts, in the order they were written, inside a read or a
  /// write the caller already holds.
  static func entry(id: UUID, db: Database) throws -> TransactionEntry? {
    guard let transaction = try CoreKit.Transaction.fetchOne(db, key: id.uuidString) else {
      return nil
    }
    let parts =
      try TransactionPart
      .filter(Column("transaction_id") == id.uuidString)
      .order(Column.rowID)
      .fetchAll(db)
    return TransactionEntry(transaction: transaction, parts: parts)
  }

  /// Operations of a period, newest first, deleted ones left out.
  ///
  /// Operations of the same instant — imported and generated rows share theirs — come by
  /// their ids, the way the ledger orders them (`Ledger`), not in whatever order the index
  /// happens to reach them.
  public func entries(from: Date, to: Date) throws -> [TransactionEntry] {
    try writer.read { db in
      try Self.entries(
        where: "deleted_at IS NULL AND occurred_at >= ? AND occurred_at <= ?",
        arguments: [StoredInstant.databaseValue(from), StoredInstant.databaseValue(to)],
        order: "occurred_at DESC, id DESC", db: db)
    }
  }

  /// The operations written at `moment` or later — by their own `created_at`, whatever date they
  /// carry — newest first, the deleted ones left out: what the entry line compares a new
  /// operation with before it is added.
  public func entries(recordedSince moment: Date) throws -> [TransactionEntry] {
    try writer.read { db in
      try Self.entries(
        where: "deleted_at IS NULL AND created_at >= ?",
        arguments: [StoredInstant.databaseValue(moment)],
        order: "created_at DESC, id DESC", db: db)
    }
  }

  /// The latest operations, newest first; ties go by the time they were written, then by id.
  public func recentEntries(limit: Int = 200) throws -> [TransactionEntry] {
    try writer.read { db in
      let transactions = try CoreKit.Transaction
        .filter(Column("deleted_at") == nil)
        .order(Column("occurred_at").desc, Column("created_at").desc, Column("id").desc)
        .limit(limit)
        .fetchAll(db)
      return try Self.attachParts(to: transactions, db: db)
    }
  }

  /// Operations with at least one part I rated by hand — everything rule 2 of the qualities
  /// needs (`ManualQualityHistory`), without reading the whole history for it.
  public func entriesRatedByHand() throws -> [TransactionEntry] {
    try writer.read { db in
      try Self.entries(
        where: """
          deleted_at IS NULL
            AND id IN (SELECT transaction_id FROM transaction_parts WHERE quality_source = ?)
          """,
        arguments: [QualitySource.manual.rawValue], db: db)
    }
  }

  /// Rule 2 of the qualities — my ratings by description — built from `entriesRatedByHand()`,
  /// read from the database once and kept until an operation or a part is written, by this
  /// repository or any other on the same database (`ManualRatingsCache`).
  public func manualQualityHistory() throws -> ManualQualityHistory {
    try manualRatings.history(in: writer) {
      ManualQualityHistory(entries: try entriesRatedByHand())
    }
  }

  public func count() throws -> Int {
    try writer.read { db in
      try CoreKit.Transaction.filter(Column("deleted_at") == nil).fetchCount(db)
    }
  }

  /// How many operations **in the bin** still have a part filed under one of these
  /// categories. Asked before a category is deleted: a deleted operation keeps its parts, and
  /// the schema refuses to drop a category while any part points at it — but nothing in the
  /// app can re-file the parts of an operation that is in the bin. Counted here rather than
  /// over the pipeline's data, which is live-only by construction.
  public func binnedOperations(inCategories ids: [UUID]) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return try writer.read { db in
      let marks = databaseQuestionMarks(count: ids.count)
      return try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(DISTINCT p.transaction_id)
          FROM transaction_parts p
          JOIN transactions t ON t.id = p.transaction_id
          WHERE t.deleted_at IS NOT NULL AND p.category_id IN (\(marks))
          """,
        arguments: StatementArguments(ids.map { $0.uuidString })) ?? 0
    }
  }

  /// Soft delete: the row stays, so undo brings it back with a single update. It goes the
  /// same way as a deletion of many (`softDelete(ids:at:)`), so a reimbursement deleted on
  /// its own also takes its surplus and shortfalls along and gives its parts back.
  @discardableResult
  public func softDelete(id: UUID, at instant: Date = Date()) throws -> DeletionEffects {
    try softDelete(ids: [id], at: instant)
  }

  public func restore(
    id: UUID, at instant: Date = Date(), effects: DeletionEffects = .none
  ) throws {
    try restore(ids: [id], at: instant, effects: effects)
  }

  /// Hard delete, used only when undoing a save that has just been made.
  ///
  /// A debt payment moved its debt right after it was saved, and that movement goes in the
  /// same write: the foreign key would only set its `transaction_id` to NULL and leave the
  /// debt reduced by a payment that never happened. The counts whose window held the operation
  /// follow the books again in the same write; what they wrote comes back.
  ///
  /// `templates` are the operations of the counts as the save being taken back found them
  /// (`CountsSettled.operationsBefore` of `saveReporting`): a difference that save purged at
  /// zero comes back as the owner left it — his category, comment and rating —, not written
  /// anew.
  @discardableResult
  public func purge(
    id: UUID, templates: [UUID: TransactionEntry?] = [:]
  ) throws -> CountsSettled {
    let context = liveCounts
    return try writer.write { db in
      let gone = try Self.entry(id: id, db: db)
      try db.execute(
        sql: "DELETE FROM debt_entries WHERE transaction_id = ?", arguments: [id.uuidString])
      try db.execute(sql: "DELETE FROM transactions WHERE id = ?", arguments: [id.uuidString])
      let touch = try LiveCountsWriter.touch(
        entries: [(gone, nil)], calendar: context.calendar, lookups: WriteLookups(), db: db)
      return try LiveCountsWriter.settle(touch, context: context, templates: templates, db: db)
    }
  }

  /// Ids go to SQLite in chunks: one `IN (…)` per operation would run into the limit on
  /// bound parameters (32 766) long before the history is large.
  static let chunkSize = 500

  /// Parts of a list of operations already in hand, their ids sent in chunks. For lists
  /// with a bound of their own — a page of recent operations, a selection.
  ///
  /// Parts come out in the order they were written (`rowid`), which is the order of the
  /// draft they were saved from: the last part is the one that took the rounding remainder
  /// of the rubles, and the first is the one the list shows.
  static func attachParts(
    to transactions: [CoreKit.Transaction], db: Database
  ) throws
    -> [TransactionEntry]
  {
    guard !transactions.isEmpty else { return [] }
    var parts: [TransactionPart] = []
    for chunk in transactions.map(\.id.uuidString).chunked(by: chunkSize) {
      parts += try TransactionPart.filter(chunk.contains(Column("transaction_id")))
        .order(Column.rowID)
        .fetchAll(db)
    }
    let grouped = Dictionary(grouping: parts, by: \.transactionId)
    return transactions.map {
      TransactionEntry(transaction: $0, parts: grouped[$0.id] ?? [])
    }
  }

  /// Operations a condition on `transactions` selects, with their parts.
  ///
  /// The parts are read by the same condition, as a subquery, in one statement: no id is
  /// ever bound as a parameter, so a history of any length reads the same way. `condition`
  /// and `order` are SQL written in this file, never text from outside; the values go in
  /// `arguments`, which the two statements share.
  static func entries(
    where condition: String, arguments: StatementArguments, order: String? = nil,
    db: Database
  ) throws -> [TransactionEntry] {
    let ordering = order.map { " ORDER BY \($0)" } ?? ""
    let transactions = try CoreKit.Transaction.fetchAll(
      db, sql: "SELECT * FROM transactions WHERE \(condition)\(ordering)", arguments: arguments)
    return try attachParts(
      to: transactions,
      selectedBy: """
        SELECT * FROM transaction_parts
        WHERE transaction_id IN (SELECT id FROM transactions WHERE \(condition))
        ORDER BY rowid
        """,
      arguments: arguments, db: db)
  }

  /// Attaches the parts a statement reads — in the order it reads them, which must be
  /// `rowid` — to the operations they belong to. Parts of operations not in the list are
  /// passed over.
  static func attachParts(
    to transactions: [CoreKit.Transaction], selectedBy sql: String,
    arguments: StatementArguments = [], db: Database
  ) throws -> [TransactionEntry] {
    guard !transactions.isEmpty else { return [] }
    var grouped: [UUID: [TransactionPart]] = [:]
    grouped.reserveCapacity(transactions.count)
    let parts = try TransactionPart.fetchCursor(db, sql: sql, arguments: arguments)
    while let part = try parts.next() {
      grouped[part.transactionId, default: []].append(part)
    }
    return transactions.map {
      TransactionEntry(transaction: $0, parts: grouped[$0.id] ?? [])
    }
  }
}

/// What the checks of one write read once: the main account, the accounts and the cards asked
/// about and the categories. A write of many operations would otherwise read them again for
/// each.
final class WriteLookups {
  private var main: UUID??
  private var accounts: [UUID: PaymentMethod?] = [:]
  private var cards: [UUID: UUID?] = [:]
  private var tree: CategoryTree?

  init() {}

  func mainAccountId(_ db: Database) throws -> UUID? {
    if let main { return main }
    let found = try TransactionRepository.mainAccountId(db)
    main = .some(found)
    return found
  }

  func account(_ id: UUID, _ db: Database) throws -> PaymentMethod? {
    if let known = accounts[id] { return known }
    let found = try PaymentMethod.fetchOne(db, key: id.uuidString)
    accounts[id] = .some(found)
    return found
  }

  /// The account a card belongs to; `nil` when there is no such card.
  func cardAccount(_ id: UUID, _ db: Database) throws -> UUID? {
    if let known = cards[id] { return known }
    let found = try String.fetchOne(
      db, sql: "SELECT payment_method_id FROM cards WHERE id = ?", arguments: [id.uuidString]
    ).flatMap(UUID.init(uuidString:))
    cards[id] = .some(found)
    return found
  }

  func categories(_ db: Database) throws -> CategoryTree {
    if let tree { return tree }
    let read = CategoryTree(try CoreKit.Category.fetchAll(db))
    tree = read
    return read
  }
}

extension Array {
  /// Consecutive slices of at most `size` elements, in order.
  func chunked(by size: Int) -> [ArraySlice<Element>] {
    guard size > 0 else { return [self[...]] }
    return stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
  }
}

/// Why a write did not land, as far as the owner can do something about it.
public enum WriteFailureCause: Hashable, Sendable {
  /// Rows are tied the other way: a row the write takes away is pointed at by one made since
  /// — an operation filed under a category the undone step created — or a row it puts back
  /// points at one removed since. The schema's foreign keys, or
  /// `PlanningWriteError.referencedByOperations`.
  case tiedToOtherRows
  /// A bulk change came with transfers that keep an account in the archive at zero, worked out
  /// on operations that changed since (`SettlingPlanOutdated`): nothing was written, and the
  /// change is to be made again from the operations as they are now.
  case planOutdated
  /// Anything else: the database did not take the write.
  case other

  public init(of error: any Error) {
    if error is SettlingPlanOutdated {
      self = .planOutdated
    } else if let planning = error as? PlanningWriteError {
      self = planning.tiesRows ? .tiedToOtherRows : .other
    } else if let database = error as? GRDB.DatabaseError,
      Self.ownTriggerMessages.contains(where: { database.message?.contains($0) == true })
    {
      self = .other
    } else if let database = error as? GRDB.DatabaseError,
      Self.foreignKeyCodes.contains(database.extendedResultCode)
    {
      self = .tiedToOtherRows
    } else {
      self = .other
    }
  }

  /// A row inserted or put back that points at nothing fails as a foreign key; a row deleted
  /// while another points at it by `ON DELETE RESTRICT` fails through SQLite's trigger code,
  /// with the same «FOREIGN KEY constraint failed».
  private static let foreignKeyCodes: [ResultCode] = [
    .SQLITE_CONSTRAINT_FOREIGNKEY, .SQLITE_CONSTRAINT_TRIGGER,
  ]

  /// The schema's own triggers (`card_of_account_*`) abort with a message of their own and the
  /// same trigger code, so their message is read first: a card of another account is not a row
  /// tied the other way. The repositories refuse it before writing; only another writer meets
  /// the trigger.
  private static let ownTriggerMessages = ["card_of_another_account"]
}
