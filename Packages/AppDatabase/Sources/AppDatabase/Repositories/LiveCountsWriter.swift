import AppCore
import CoreKit
import Foundation
import GRDB

/// What following the books needs from the app: the owner's calendar, which gives the days of
/// the counts and of journal lines dated by the day, and the name «Сверка» takes when a write
/// has to make the category again.
public struct LiveCountsContext: Hashable, Sendable {
  public var calendar: CalendarContext
  public var categoryName: String

  public init(calendar: CalendarContext, categoryName: String) {
    self.calendar = calendar
    self.categoryName = categoryName
  }

  public static var standard: LiveCountsContext {
    LiveCountsContext(calendar: .system, categoryName: "Сверка")
  }

  public static func == (left: LiveCountsContext, right: LiveCountsContext) -> Bool {
    left.calendar.timeZone == right.calendar.timeZone && left.categoryName == right.categoryName
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(calendar.timeZone)
    hasher.combine(categoryName)
  }
}

/// What a write moved, for the counts whose windows it reached: the movements it took away and
/// the ones it made (old and new positions alike), the counts whose own operation it touched —
/// a difference deleted or brought back moves no money, but its count's mode follows it —, and
/// keys and accounts whose every live count is to follow the books again.
public struct CountTouch: Hashable, Sendable {
  public var movements: [AccountMovement]
  public var countsOfTouchedOperations: Set<UUID>
  public var wholeKeys: Set<BalanceKey>
  /// Accounts whose every key is settled whole: the main account's, when the flag moved and
  /// lines without an account move money on it.
  public var wholeAccounts: Set<UUID>

  public init(
    movements: [AccountMovement] = [], countsOfTouchedOperations: Set<UUID> = [],
    wholeKeys: Set<BalanceKey> = [], wholeAccounts: Set<UUID> = []
  ) {
    self.movements = movements
    self.countsOfTouchedOperations = countsOfTouchedOperations
    self.wholeKeys = wholeKeys
    self.wholeAccounts = wholeAccounts
  }

  public static let none = CountTouch()

  public var isEmpty: Bool {
    movements.isEmpty && countsOfTouchedOperations.isEmpty && wholeKeys.isEmpty
      && wholeAccounts.isEmpty
  }

  public mutating func formUnion(_ other: CountTouch) {
    movements += other.movements
    countsOfTouchedOperations.formUnion(other.countsOfTouchedOperations)
    wholeKeys.formUnion(other.wholeKeys)
    wholeAccounts.formUnion(other.wholeAccounts)
  }
}

/// What following the books wrote in one write: the operations of the differences created or
/// rewritten, as written, and the ones that went for good — for the lists to lay over what
/// they show —, with counts for the journal.
public struct CountsSettled: Hashable, Sendable {
  public var upserted: [TransactionEntry]
  public var removed: [UUID]
  /// Counts whose expected balance, difference, operation or mode changed.
  public var countsChanged: Int
  public var created: Int
  public var rewritten: Int
  public var purged: Int
  public var modeChanged: Int
  /// Counts recording a foreign difference that has no rate yet: their operation waits.
  public var waitingForRate: Int
  /// Differences whose count is gone, taken away by the catch-up at open.
  public var orphansPurged: Int
  /// Every count the settle changed, as it was before — the first time it changed, when
  /// settles are merged.
  public var countsBefore: [ReconciledBalance]
  /// The operation of each of those counts as it was before, `nil` when it had none.
  public var operationsBefore: [UUID: TransactionEntry?]

  public init(
    upserted: [TransactionEntry] = [], removed: [UUID] = [], countsChanged: Int = 0,
    created: Int = 0, rewritten: Int = 0, purged: Int = 0, modeChanged: Int = 0,
    waitingForRate: Int = 0, orphansPurged: Int = 0, countsBefore: [ReconciledBalance] = [],
    operationsBefore: [UUID: TransactionEntry?] = [:]
  ) {
    self.countsBefore = countsBefore
    self.operationsBefore = operationsBefore
    self.upserted = upserted
    self.removed = removed
    self.countsChanged = countsChanged
    self.created = created
    self.rewritten = rewritten
    self.purged = purged
    self.modeChanged = modeChanged
    self.waitingForRate = waitingForRate
    self.orphansPurged = orphansPurged
  }

  public static let none = CountsSettled()

  /// Nothing was written.
  public var isEmpty: Bool {
    upserted.isEmpty && removed.isEmpty && countsChanged == 0 && orphansPurged == 0
  }

  public mutating func merge(_ other: CountsSettled) {
    for entry in other.upserted {
      upserted.removeAll { $0.id == entry.id }
      upserted.append(entry)
    }
    upserted.removeAll { other.removed.contains($0.id) }
    removed += other.removed.filter { !removed.contains($0) }
    countsChanged += other.countsChanged
    created += other.created
    rewritten += other.rewritten
    purged += other.purged
    modeChanged += other.modeChanged
    waitingForRate += other.waitingForRate
    orphansPurged += other.orphansPurged
    let known = Set(countsBefore.map(\.id))
    for count in other.countsBefore where !known.contains(count.id) {
      countsBefore.append(count)
      operationsBefore.updateValue(other.operationsBefore[count.id] ?? nil, forKey: count.id)
    }
  }
}

/// Settles live counts inside the write that moved their money (`LiveCounts`): every writer
/// of an operation, a transfer or a journal line hands what it moved (`CountTouch`) and the
/// counts whose windows hold it follow the books in the same transaction — one write, one step
/// of ⌘Z, whose undo settles again. The rows it writes are derived and never in an undo
/// journal: the operation of a difference and its part take ids derived from the count, so a
/// re-creation names the same rows.
///
/// A settle reads only what it needs: the counts and the accounts (small tables), then, for the
/// counts reached, the operations, transfers and journal lines of their accounts in their
/// windows, the debts of those lines — deleted ones too: a deleted debt's line still moved the
/// money — and the purchases on credit of those debts.
enum LiveCountsWriter {

  // MARK: What a write moved

  /// The touch of operations written from `before` to `after` (either `nil` for a new or a
  /// removed one), of transfers and of journal lines in any position they had or have. The
  /// main account and the categories are those `lookups` read in this write. The debt of a line
  /// is read from the database, or taken from `debts` — a debt the write deleted took its
  /// journal along, and those lines moved money until then.
  static func touch(
    entries: [(before: TransactionEntry?, after: TransactionEntry?)],
    transfers: [Transfer] = [], lines: [DebtEntry] = [], debts known: [Debt] = [],
    calendar: CalendarContext, lookups: WriteLookups, db: Database
  ) throws -> CountTouch {
    var touch = CountTouch()
    let pairs = entries.filter { $0.before != nil || $0.after != nil }
    guard !pairs.isEmpty || !transfers.isEmpty || !lines.isEmpty else { return touch }
    let mainId = try lookups.mainAccountId(db)
    let tree = try lookups.categories(db)
    for pair in pairs {
      for entry in [pair.before, pair.after].compactMap({ $0 }) {
        if let moved = AccountBalances.movement(of: entry, mainId: mainId, tree: tree) {
          touch.movements.append(moved)
        }
        if case .reconciledBalance(_, let count) = OperationLink(
          externalId: entry.transaction.externalId)
        {
          touch.countsOfTouchedOperations.insert(count)
        }
      }
    }
    for transfer in transfers {
      touch.movements += movements(of: transfer)
    }
    if !lines.isEmpty {
      var debts = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      var none: [CreditOpening: Int] = [:]
      for line in lines {
        if debts[line.debtId] == nil {
          debts[line.debtId] = try Debt.fetchOne(db, key: line.debtId.uuidString)
        }
        guard let debt = debts[line.debtId],
          let moved = AccountBalances.journalMovement(
            of: line, debt: debt, mainId: mainId, openings: &none, calendar: calendar)
        else { continue }
        touch.movements.append(moved)
      }
    }
    return touch
  }

  /// The two movements of a transfer, as the balances read them.
  static func movements(of transfer: Transfer) -> [AccountMovement] {
    [
      AccountMovement(
        key: transfer.from, at: transfer.occurredAt, amountE4: -transfer.fromAmountE4,
        source: .transferOut(transfer.id)),
      AccountMovement(
        key: transfer.to, at: transfer.occurredAt, amountE4: transfer.toAmountE4,
        source: .transferIn(transfer.id)),
    ]
  }

  // MARK: Settling

  /// Settles the live counts the touch reaches, inside the caller's transaction: a count of a
  /// whole key or account, a count whose operation was touched, and a count whose window holds
  /// a movement (`AccountBalances.windowHolds`). Throws what the database throws; the caller's
  /// write then rolls back whole.
  ///
  /// `templates` are the operations of the counts as the write being taken back found them
  /// (`CountsSettled.operationsBefore` of that write): an operation it purged at zero comes back
  /// as the owner left it (`LiveCounts.settle(…, template:)`), unless something it names is gone
  /// since — then the difference is written anew.
  static func settle(
    _ touch: CountTouch, context: LiveCountsContext, now: Date = Date(),
    templates: [UUID: TransactionEntry?] = [:], db: Database
  ) throws -> CountsSettled {
    guard !touch.isEmpty else { return .none }
    let book = try Book.read(context: context, now: now, db: db)
    guard !book.live.isEmpty else { return .none }
    var keys = Set(touch.movements.map(\.key)).union(touch.wholeKeys)
    for balance in book.balances {
      if touch.countsOfTouchedOperations.contains(balance.id)
        || touch.wholeAccounts.contains(balance.accountId)
      {
        keys.insert(balance.key)
      }
    }
    let byKey = Dictionary(grouping: touch.movements, by: \.key)
    var chosen: [UUID] = []
    for key in keys.sorted() {
      let anchors = book.anchors.anchors(key)
      let whole = touch.wholeKeys.contains(key) || touch.wholeAccounts.contains(key.accountId)
      for index in anchors.indices.dropFirst() where book.live.contains(anchors[index].balance.id) {
        let count = anchors[index]
        let previous = anchors[index - 1]
        let reached =
          whole || touch.countsOfTouchedOperations.contains(count.balance.id)
          || (byKey[key] ?? []).contains {
            book.anchors.windowHolds($0, after: previous.at, through: count.at)
          }
        if reached { chosen.append(count.balance.id) }
      }
    }
    return try settle(
      counts: chosen, book: book, context: context, now: now, templates: templates, db: db)
  }

  /// Every live count follows the books, and every difference whose count is gone goes: the
  /// catch-up at every open. Idempotent: a book already settled writes nothing. A first count
  /// the owner has not decided about is never touched.
  static func settleAll(
    context: LiveCountsContext, now: Date = Date(), db: Database
  ) throws
    -> CountsSettled
  {
    var result = CountsSettled()
    result.orphansPurged = try purgeOrphans(db: db)
    let book = try Book.read(context: context, now: now, db: db)
    let chosen = book.balances.map(\.id).filter(book.live.contains)
    result.merge(
      try settle(
        counts: chosen, book: book, context: context, now: now, db: db))
    return result
  }

  /// The money on `key` at `instant` as the books say inside this write — its latest count made
  /// by then plus what moved after it —, `nil` while it was never counted.
  static func balance(
    of key: BalanceKey, at instant: Date, context: LiveCountsContext, db: Database
  ) throws -> AmountE4? {
    let book = try Book.read(context: context, now: instant, db: db)
    guard let anchor = book.anchors.anchors(key).last(where: { $0.at <= instant }) else {
      return nil
    }
    let window = try Window.load(
      spans: [key.accountId: (anchor.at, instant)], book: book,
      context: context, now: instant, db: db)
    return anchor.balance.actualE4 + window.moved(key, after: anchor.at, through: instant)
  }

  private static func settle(
    counts chosen: [UUID], book: Book, context: LiveCountsContext,
    now: Date, templates: [UUID: TransactionEntry?] = [:], db: Database
  ) throws -> CountsSettled {
    guard !chosen.isEmpty else { return .none }
    // Each count with the count before it, and the span of each account to read.
    var pairs:
      [(count: ReconciledBalance, countAt: Date, previous: ReconciledBalance, from: Date)] =
        []
    var spans: [UUID: (Date, Date)] = [:]
    let wanted = Set(chosen)
    for key in Set(book.balances.filter { wanted.contains($0.id) }.map(\.key)).sorted() {
      let anchors = book.anchors.anchors(key)
      for index in anchors.indices.dropFirst() where wanted.contains(anchors[index].balance.id) {
        let count = anchors[index]
        let previous = anchors[index - 1]
        pairs.append((count.balance, count.at, previous.balance, previous.at))
        let span = spans[key.accountId] ?? (previous.at, count.at)
        spans[key.accountId] = (min(span.0, previous.at), max(span.1, count.at))
      }
    }
    guard !pairs.isEmpty else { return .none }
    let window = try Window.load(
      spans: spans, book: book, context: context, now: now,
      db: db)
    let operations = try keyedOperations(of: pairs.map(\.count), db: db)
    let tree = try CategoryTree(CoreKit.Category.fetchAll(db))
    var categories: ReconcileCategories?
    var rates: RateTable?
    var result = CountsSettled()

    for pair in pairs {
      let expected =
        pair.previous.actualE4
        + window.moved(pair.count.key, after: pair.from, through: pair.countAt)
      let state = CountState(
        count: pair.count, countAt: pair.countAt, operation: operations[pair.count.id])
      func decide(_ template: TransactionEntry?) throws -> CountSettlement {
        var rate: CountRate?
        var settlement = LiveCounts.settle(
          state, expected: expected, rate: nil, categories: categories, tree: tree, now: now,
          template: template)
        if settlement.waitsForRate {
          if rates == nil { rates = try rateTable(db: db) }
          let day = context.calendar.day(of: pair.countAt)
          rate = rates?.resolve(pair.count.currency, on: day).map {
            CountRate(perUnit: $0.rate.perUnit, day: day, provisional: $0.isProvisional)
          }
          if rate != nil {
            settlement = LiveCounts.settle(
              state, expected: expected, rate: rate, categories: categories, tree: tree,
              now: now, template: template)
          }
        }
        if settlement.needsCategories {
          categories = try Self.categories(context: context, db: db)
          settlement = LiveCounts.settle(
            state, expected: expected, rate: rate, categories: categories,
            tree: try CategoryTree(CoreKit.Category.fetchAll(db)), now: now, template: template)
        }
        return settlement
      }
      let template = templates[pair.count.id] ?? nil
      let settlement = try decide(template)
      if template != nil, case .create = settlement.operation {
        // The owner's operation comes back as it was unless a category, a person, a place or
        // anything else it names went since: then the difference is written anew.
        var attempt = result
        do {
          try db.inSavepoint {
            try write(settlement, over: state, db: db, into: &attempt)
            return .commit
          }
          result = attempt
          continue
        } catch let error as GRDB.DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
          try write(try decide(nil), over: state, db: db, into: &result)
          continue
        }
      }
      try write(settlement, over: state, db: db, into: &result)
    }
    return result
  }

  /// Writes one settlement: a new operation before the count points at it, the count before an
  /// operation it lets go of is purged. What it changes is kept as it was, for ⌘Z.
  private static func write(
    _ settlement: CountSettlement, over state: CountState, db: Database,
    into result: inout CountsSettled
  ) throws {
    if settlement.countChanged || settlement.operation != .none {
      result.countsBefore.append(state.count)
      result.operationsBefore.updateValue(state.operation, forKey: state.count.id)
    }
    switch settlement.operation {
    case .create(let entry):
      // The count's own operation, once put in the bin, gives its place to the new one: the
      // owner asked the count to record again (`LiveCounts.settle`). Whatever its id — 1.1 wrote
      // a difference under an id of its own —: both carry the count's key, which is unique.
      if let binned = state.operation, binned.transaction.isDeleted {
        try purge([binned.id], db: db)
      }
      try entry.transaction.insert(db)
      for part in entry.parts { try part.insert(db) }
      result.upserted.append(entry)
      result.created += 1
    case .rewrite(let entry):
      try entry.transaction.update(db)
      for part in entry.parts { try part.update(db) }
      result.upserted.append(entry)
      result.rewritten += 1
    case .none, .purge:
      break
    }
    if settlement.countChanged {
      let count = settlement.count
      try db.execute(
        sql: """
          UPDATE reconciliation_balances
          SET expected_e4 = ?, difference_e4 = ?, transaction_id = ?, records_difference = ?
          WHERE id IN (?, ?)
          """,
        arguments: [
          count.expectedE4?.raw, count.differenceE4?.raw, count.transactionId?.uuidString,
          count.recordsDifference.map { $0 ? 1 : 0 }, count.id.uuidString,
          count.id.uuidString.lowercased(),
        ])
      result.countsChanged += 1
    }
    if settlement.modeChanged { result.modeChanged += 1 }
    if settlement.waitsForRate { result.waitingForRate += 1 }
    if case .purge(let id) = settlement.operation {
      try purge([id], db: db)
      result.removed.append(id)
      result.purged += 1
    }
  }

  /// Takes operations away for good, with the journal lines and income links that point at
  /// them: a foreign key would only clear those.
  static func purge(_ ids: [UUID], db: Database) throws {
    for chunk in ids.flatMap({ [$0.uuidString, $0.uuidString.lowercased()] })
      .chunked(by: TransactionRepository.chunkSize)
    {
      let marks = databaseQuestionMarks(count: chunk.count)
      let arguments = StatementArguments(Array(chunk))
      try db.execute(
        sql: "DELETE FROM debt_entries WHERE transaction_id IN (\(marks))", arguments: arguments)
      try db.execute(
        sql: "DELETE FROM expected_income_links WHERE transaction_id IN (\(marks))",
        arguments: arguments)
      try db.execute(sql: "DELETE FROM transactions WHERE id IN (\(marks))", arguments: arguments)
    }
  }

  /// Takes away, live or in the bin, every operation keyed to one of these counts
  /// (`reconcile:<reconciliation>:<count>`) — the undo of the step that added the counts. Read
  /// before the counts go.
  static func purgeOperations(ofCounts ids: [UUID], db: Database) throws {
    guard !ids.isEmpty else { return }
    var keys: [String] = []
    for chunk in ids.flatMap({ [$0.uuidString, $0.uuidString.lowercased()] })
      .chunked(by: TransactionRepository.chunkSize)
    {
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT id, reconciliation_id FROM reconciliation_balances
          WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))
          """,
        arguments: StatementArguments(Array(chunk)))
      {
        guard let count = RowMapping.optionalUUID(row, "id"),
          let reconciliation = RowMapping.optionalUUID(row, "reconciliation_id")
        else { continue }
        keys.append(
          OperationLink.reconciledBalance(reconciliation: reconciliation, balance: count)
            .externalId)
      }
    }
    var found: [UUID] = []
    for chunk in keys.chunked(by: TransactionRepository.chunkSize) {
      found += try String.fetchAll(
        db,
        sql: """
          SELECT id FROM transactions
          WHERE external_id IN (\(databaseQuestionMarks(count: chunk.count)))
          """,
        arguments: StatementArguments(Array(chunk))
      ).compactMap(UUID.init(uuidString:))
    }
    try purge(found, db: db)
  }

  /// Takes back the operations a settle wrote for counts that only kept their numbers before it
  /// — the change asked them to record («Записывать разницу») —, and puts the operation the
  /// owner had in the bin back where it was: a live operation would turn the count to recording
  /// again in the settle after the undo. `before` are the counts as the change found them; run
  /// once their rows are back.
  static func restoreKeeping(
    _ before: [ReconciledBalance], settled: CountsSettled, db: Database
  ) throws {
    let keeping = before.filter { $0.recordsDifference == false }
    guard !keeping.isEmpty else { return }
    let current = try keyedOperations(of: keeping, db: db)
    for count in keeping {
      guard let written = current[count.id], !written.transaction.isDeleted else { continue }
      try purge([written.id], db: db)
      if let binned = settled.operationsBefore[count.id] ?? nil, binned.transaction.isDeleted {
        try binned.transaction.insert(db)
        for part in binned.parts { try part.insert(db) }
      }
    }
  }

  /// Puts back, as they were before a settle, the counts it changed that no longer follow the
  /// books — a first count whose «настоящая разница» ⌘Z took back is frozen again, and nothing
  /// else would give it back its numbers and its operation. A count that follows the books is
  /// left to the settle after it; a count that is gone, to the undo that took it.
  static func restoreUnsettled(
    _ settled: CountsSettled, context: LiveCountsContext, now: Date, db: Database
  ) throws {
    guard !settled.countsBefore.isEmpty else { return }
    let book = try Book.read(context: context, now: now, db: db)
    let present = Set(book.balances.map(\.id))
    let restoring = settled.countsBefore.filter {
      present.contains($0.id) && !book.live.contains($0.id)
    }
    guard !restoring.isEmpty else { return }
    let current = try keyedOperations(of: restoring, db: db)
    for count in restoring {
      let ids = [count.id.uuidString, count.id.uuidString.lowercased()]
      try db.execute(
        sql: "UPDATE reconciliation_balances SET transaction_id = NULL WHERE id IN (?, ?)",
        arguments: StatementArguments(ids))
      let before = settled.operationsBefore[count.id] ?? nil
      if let before {
        if let existing = current[count.id] {
          try before.transaction.update(db)
          if Set(existing.parts.map(\.id)) == Set(before.parts.map(\.id)) {
            for part in before.parts { try part.update(db) }
          } else {
            try TransactionRepository.replaceParts(of: before, db: db)
          }
        } else {
          try before.transaction.insert(db)
          for part in before.parts { try part.insert(db) }
        }
      } else if let existing = current[count.id] {
        try purge([existing.id], db: db)
      }
      try db.execute(
        sql: """
          UPDATE reconciliation_balances
          SET expected_e4 = ?, difference_e4 = ?, transaction_id = ?, records_difference = ?
          WHERE id IN (?, ?)
          """,
        arguments: [
          count.expectedE4?.raw, count.differenceE4?.raw, count.transactionId?.uuidString,
          count.recordsDifference.map { $0 ? 1 : 0 },
        ] + StatementArguments(ids))
    }
  }

  /// Every `reconcile:<reconciliation>:<count>` operation, live or in the bin, whose count is
  /// no longer there goes for good. A difference of a reconciliation of one total
  /// (`reconcile:<reconciliation>`) is never touched.
  private static func purgeOrphans(db: Database) throws -> Int {
    let counts = Set(
      try String.fetchAll(db, sql: "SELECT id FROM reconciliation_balances")
        .compactMap(UUID.init(uuidString:)))
    var orphans: [UUID] = []
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT id, external_id FROM transactions
        WHERE substr(external_id, 1, 10) = 'reconcile:'
        """)
    {
      guard let id = RowMapping.optionalUUID(row, "id"),
        case .reconciledBalance(_, let count) = OperationLink(externalId: row["external_id"]),
        !counts.contains(count)
      else { continue }
      orphans.append(id)
    }
    try purge(orphans, db: db)
    return orphans.count
  }

  /// The operation keyed to each count, live or in the bin.
  private static func keyedOperations(
    of counts: [ReconciledBalance], db: Database
  ) throws
    -> [UUID: TransactionEntry]
  {
    var byKey: [String: UUID] = [:]
    for count in counts {
      byKey[
        OperationLink.reconciledBalance(reconciliation: count.reconciliationId, balance: count.id)
          .externalId] = count.id
    }
    var found: [UUID: TransactionEntry] = [:]
    for chunk in Array(byKey.keys).sorted().chunked(by: TransactionRepository.chunkSize) {
      let transactions = try CoreKit.Transaction.fetchAll(
        db,
        sql: """
          SELECT * FROM transactions
          WHERE external_id IN (\(databaseQuestionMarks(count: chunk.count)))
          """,
        arguments: StatementArguments(Array(chunk)))
      for entry in try TransactionRepository.attachParts(to: transactions, db: db) {
        guard let key = entry.transaction.externalId, let count = byKey[key] else { continue }
        found[count] = entry
      }
    }
    return found
  }

  /// The rates of the bank as `RateTable` reads them, inside this write.
  private static func rateTable(db: Database) throws -> RateTable {
    let stored = try String.fetchOne(
      db, sql: "SELECT value FROM settings WHERE key = ?",
      arguments: [RateRepository.unpublishedDaysKey])
    return RateTable(
      rates: try Rate.order(Column("date").desc).fetchAll(db),
      unpublishedDays: RateRepository.decodeUnpublishedDays(stored))
  }

  // MARK: «Сверка»

  /// «Сверка» and its income twin: the categories the settings name. One that is missing,
  /// of another kind or deleted is made again at the top level in the owner's language and
  /// remembered; one in the archive is brought back — the app still writes into it. Written in
  /// this transaction and never taken back by ⌘Z, as the sheet makes them.
  static func categories(context: LiveCountsContext, db: Database) throws -> ReconcileCategories {
    func pick(_ key: String, _ kind: CategoryKind) throws -> UUID? {
      guard
        let text = try String.fetchOne(
          db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key]),
        let id = UUID(uuidString: text),
        let found = try CoreKit.Category.fetchOne(
          db, sql: "SELECT * FROM categories WHERE id IN (?, ?)",
          arguments: [id.uuidString, id.uuidString.lowercased()]),
        found.kind == kind
      else { return nil }
      if found.archived {
        try db.execute(
          sql: "UPDATE categories SET archived = 0 WHERE id IN (?, ?)",
          arguments: [id.uuidString, id.uuidString.lowercased()])
      }
      return found.id
    }
    func make(_ key: String, _ kind: CategoryKind) throws -> UUID {
      let sort =
        (try Int.fetchOne(
          db, sql: "SELECT MAX(sort) FROM categories WHERE kind = ? AND parent_id IS NULL",
          arguments: [kind.rawValue]) ?? 0) + 1
      let category = CoreKit.Category(
        parentId: nil, kind: kind, name: context.categoryName, sort: sort,
        quality: kind == .expense ? .neutral : nil)
      try category.insert(db)
      try db.execute(
        sql: """
          INSERT INTO settings (key, value) VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
          """,
        arguments: [key, category.id.uuidString])
      return category.id
    }
    let expense =
      try pick(PlanningSettings.reconcileExpenseCategoryKey, .expense)
      ?? make(PlanningSettings.reconcileExpenseCategoryKey, .expense)
    let income =
      try pick(PlanningSettings.reconcileIncomeCategoryKey, .income)
      ?? make(PlanningSettings.reconcileIncomeCategoryKey, .income)
    return ReconcileCategories(expense: expense, income: income)
  }

  // MARK: The book of counts

  /// The counts, their reconciliations, the accounts and the owner's decisions, read inside
  /// the write — small tables —, with the counts that follow the books.
  struct Book {
    var reconciliations: [Reconciliation]
    var balances: [ReconciledBalance]
    var accounts: [PaymentMethod]
    /// The counts of every key, without any movement: the windows and the frozen set read
    /// only them.
    var anchors: AccountBalances
    var live: Set<UUID>

    static func read(context: LiveCountsContext, now: Date, db: Database) throws -> Book {
      let reconciliations = try ReconciliationRepository.all(db)
      let balances = try ReconciliationRepository.balances(db)
      let accounts = try PaymentMethod.fetchAll(db)
      let kept = try PlanningRepository.settings(db).firstCountKept
      let anchors = AccountBalances.build(
        entries: [], transfers: [], debtEntries: [], debts: [:],
        reconciliations: reconciliations, balances: balances, accounts: accounts,
        tree: CategoryTree(), now: now, calendar: context.calendar)
      let frozen = ZeroOpenings.frozenCounts(
        balances: anchors, reconciliations: reconciliations, kept: kept)
      let live = LiveCounts.liveIds(
        reconciliations: reconciliations, balances: balances, frozen: frozen)
      return Book(
        reconciliations: reconciliations, balances: balances, accounts: accounts,
        anchors: anchors, live: live)
    }
  }

  // MARK: The windows

  /// The balances over what moved on some accounts in some spans — every count of every key,
  /// and the operations, transfers and journal lines of those accounts dated within a day or
  /// two of their spans, so every window inside a span is whole. Even the catch-up at open reads
  /// no more than the spans its live counts cover: a history read whole costs a launch more than
  /// the windows do.
  enum Window {
    static func load(
      spans: [UUID: (Date, Date)], book: Book, context: LiveCountsContext, now: Date,
      db: Database
    ) throws -> AccountBalances {
      let mainId = book.accounts.first { $0.isDefault && !$0.archived }?.id
      var transactions: [UUID: CoreKit.Transaction] = [:]
      var transfers: [UUID: Transfer] = [:]
      // In the order the planning reads the journals, which decides which purchase on credit
      // explains which opening line.
      var lines: [DebtEntry] = []
      var seenLines: Set<UUID> = []
      func keep(_ line: DebtEntry) {
        if seenLines.insert(line.id).inserted { lines.append(line) }
      }
      let margin: TimeInterval = 2 * 86_400
      for (account, span) in spans.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
        let ids = [account.uuidString, account.uuidString.lowercased()]
        let unassigned = account == mainId ? " OR payment_method_id IS NULL" : ""
        let from = StoredInstant.databaseValue(span.0.addingTimeInterval(-margin))
        let through = StoredInstant.databaseValue(span.1.addingTimeInterval(margin))
        for row in try CoreKit.Transaction.fetchAll(
          db,
          sql: """
            SELECT * FROM transactions
            WHERE deleted_at IS NULL AND (payment_method_id IN (?, ?)\(unassigned))
              AND occurred_at >= ? AND occurred_at <= ?
            """,
          arguments: StatementArguments(ids) + [from, through])
        {
          transactions[row.id] = row
        }
        for row in try Transfer.fetchAll(
          db,
          sql: """
            SELECT * FROM transfers
            WHERE (from_payment_method_id IN (?, ?) OR to_payment_method_id IN (?, ?))
              AND occurred_at >= ? AND occurred_at <= ?
            """,
          arguments: StatementArguments(ids + ids) + [from, through])
        {
          transfers[row.id] = row
        }
        let firstDay = context.calendar.day(of: span.0).adding(days: -2).iso
        let lastDay = context.calendar.day(of: span.1).adding(days: 2).iso
        for row in try DebtEntry.fetchAll(
          db,
          sql: """
            SELECT * FROM debt_entries
            WHERE kind = 'borrowed' AND transaction_id IS NULL
              AND (payment_method_id IN (?, ?)\(unassigned))
              AND ((occurred_at >= ? AND occurred_at <= ?)
                OR (occurred_at IS NULL AND date >= ? AND date <= ?))
            ORDER BY debt_id, date, rowid
            """,
          arguments: StatementArguments(ids) + [from, through, firstDay, lastDay])
        {
          keep(row)
        }
      }
      // The debts of the lines, deleted ones too, and the purchases on credit whose opening
      // line explains one of them, deleted ones too.
      let debts = Dictionary(
        try Debt.fetchAll(db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let debtIds = Set(lines.map(\.debtId))
      for chunk in debtIds.flatMap({ [$0.uuidString, $0.uuidString.lowercased()] }).sorted()
        .chunked(by: TransactionRepository.chunkSize)
      {
        for row in try CoreKit.Transaction.fetchAll(
          db,
          sql: """
            SELECT * FROM transactions
            WHERE kind = 'expense' AND credit_debt_id IN (\(databaseQuestionMarks(count: chunk.count)))
            """,
          arguments: StatementArguments(Array(chunk)))
        where transactions[row.id] == nil {
          transactions[row.id] = row
        }
      }
      let entries = try TransactionRepository.attachParts(
        to: transactions.values.sorted { $0.id.uuidString < $1.id.uuidString }, db: db)
      return AccountBalances.build(
        entries: entries,
        transfers: transfers.values.sorted { $0.id.uuidString < $1.id.uuidString },
        debtEntries: lines, debts: debts,
        reconciliations: book.reconciliations, balances: book.balances, accounts: book.accounts,
        tree: try CategoryTree(CoreKit.Category.fetchAll(db)), now: now,
        calendar: context.calendar)
    }
  }
}
