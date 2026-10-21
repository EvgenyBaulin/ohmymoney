import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// One row of the reconciliation sheet: one account in one currency, with the balance the
/// books expect.
public struct ReconcileRow: Hashable, Sendable {
  public var key: BalanceKey
  /// The balance now in the key's currency; `nil` while it was never counted — the count the
  /// owner types is then its starting point.
  public var expected: AmountE4?
  /// The moment of the latest count of the key.
  public var lastCountedAt: Date?
  /// The account holds the currency; `false` for money that moved in a currency the account
  /// does not list.
  public var isHeld: Bool
  /// `false` for an account of a group left out of the summary: the sheet counts its money all
  /// the same and can say it is apart.
  public var isInSummary: Bool

  public init(
    key: BalanceKey, expected: AmountE4?, lastCountedAt: Date?, isHeld: Bool,
    isInSummary: Bool = true
  ) {
    self.key = key
    self.expected = expected
    self.lastCountedAt = lastCountedAt
    self.isHeld = isHeld
    self.isInSummary = isInSummary
  }
}

/// What one reconciliation writes, worked out before anything is written: the reconciliation,
/// a counted balance per counted row, and the operations that record the differences.
public struct AccountReconciliationRecord: Hashable, Sendable {
  public var reconciliation: Reconciliation
  public var balances: [ReconciledBalance]
  /// One operation per non-zero difference, when the owner chose «Записать разницу».
  public var differences: [TransactionEntry]
  /// Rows whose difference had to be written but could not, for want of today's rate of their
  /// currency: the balance is counted, the operation is not written.
  public var withoutRate: [BalanceKey]
  /// Currencies of counted rows the ruble totals of the reconciliation leave out for want of
  /// today's rate, by code: those totals are then short by them and say so.
  public var totalsWithoutRate: [CurrencyCode]

  public init(
    reconciliation: Reconciliation, balances: [ReconciledBalance],
    differences: [TransactionEntry], withoutRate: [BalanceKey] = [],
    totalsWithoutRate: [CurrencyCode] = []
  ) {
    self.reconciliation = reconciliation
    self.balances = balances
    self.differences = differences
    self.withoutRate = withoutRate
    self.totalsWithoutRate = totalsWithoutRate
  }
}

/// What saving an operation or a transfer has to ask about the counts of its day
/// (`AccountReconciliation.countToAsk`).
public enum CountAsk: Sendable {
  /// No count of its balances was made on its day before it was saved.
  case none
  /// The questions to walk, oldest count first; their answer is the moment to save it at.
  case ask(CountQuestions)
  /// Answers remembered for the reconciliations settle every count of the day: the moment to
  /// save it at, without a question.
  case answered(stamp: Date)
}

/// Reconciliation by account and currency: how much money is on each account, in each of its
/// currencies, against what the books say.
///
/// * The first count of a balance is its starting point: nothing compared, nothing written.
///   Each later one shows its difference, actual − expected, in the balance's own currency —
///   a rate that moved is never a difference, since nothing is converted.
/// * The counted balances become the anchors every balance and the free sum count from.
/// * Reconciliations of one total in rubles, as they were made before accounts, stay as
///   history and anchor nothing; they still keep the reminder's rhythm.
public enum AccountReconciliation {

  // MARK: - The sheet

  /// The rows of the sheet at `t0`: every live account, each of its currencies in its own
  /// order, the accounts in the order of every menu (`AccountRules.ordered`; groups do not
  /// reorder it) — the groups left out of the summary included, their money is real, and their
  /// rows say they are apart (`groups`). Then every other balance with money on it: a currency
  /// an account does not hold, an archived account.
  public static func rows(
    accounts: [PaymentMethod], groups: [AccountGroup], balances: AccountBalances, at t0: Date,
    locale: Locale
  ) -> [ReconcileRow] {
    // An archived group is no group, as in the sidebar and in «Всего»: its accounts count.
    let apart = Set(groups.filter { !$0.archived && !$0.inSummary }.map(\.id))
    let accountsApart = Set(
      accounts.filter { account in account.groupId.map(apart.contains) ?? false }.map(\.id))
    func row(_ key: BalanceKey, held: Bool) -> ReconcileRow {
      ReconcileRow(
        key: key, expected: balances.balance(key, at: t0),
        lastCountedAt: balances.latestAnchor(key)?.at, isHeld: held,
        isInSummary: !accountsApart.contains(key.accountId))
    }
    var rows: [ReconcileRow] = []
    var listed: Set<BalanceKey> = []
    for account in AccountRules.ordered(accounts, locale: locale) {
      for currency in account.currencies {
        let key = BalanceKey(accountId: account.id, currency: currency)
        rows.append(row(key, held: true))
        listed.insert(key)
      }
    }
    let others =
      balances.keys
      .filter { !listed.contains($0) }
      .map { row($0, held: false) }
      .filter { $0.expected.map { !$0.isZero } ?? false }
      .sorted { $0.key < $1.key }
    // Each live account's other currencies right after its own ones; archived accounts last.
    var result: [ReconcileRow] = []
    var pending = others
    for (index, current) in rows.enumerated() {
      result.append(current)
      let isLastOfAccount =
        index + 1 == rows.count || rows[index + 1].key.accountId != current.key.accountId
      guard isLastOfAccount else { continue }
      result += pending.filter { $0.key.accountId == current.key.accountId }
      pending.removeAll { $0.key.accountId == current.key.accountId }
    }
    return result + pending
  }

  /// What saving the sheet writes at `t0`.
  ///
  /// * One counted balance for every row with a counted value, changed or not, so every
  ///   counted balance is anchored at `t0` and the money now equals the count exactly. Rows
  ///   left empty are not written; counts of keys that are not rows are ignored.
  /// * A row the books expected something for compares: `expected` and `difference = actual −
  ///   expected`. A row never counted before is a starting point: both `nil`, nothing else. So
  ///   is a row of `startingPoints`, whatever the books expected: the owner said its count is
  ///   where its money starts.
  /// * Every compared row says how it keeps its difference (`recordsDifference`): it records
  ///   with `writeDifference`, and when no compared row differs — there was nothing to
  ///   decline —; otherwise it only keeps the numbers. A starting point keeps nothing.
  /// * With `writeDifference`, every non-zero difference becomes an operation
  ///   (`LiveCounts.differenceOperation`): an expense in «Сверка» when money is missing, an
  ///   income in its twin when there is more; on that account, in that currency, at `t0`, at
  ///   today's rate of the bank (`rubPerUnit`, rubles for one unit, marked provisional so the
  ///   day's own rate settles it), keyed `reconcile:<reconciliation>:<balance>`. The operation
  ///   and its one part take the ids derived from the count (`ReconcileDifferenceIds`). The
  ///   balance points at its operation. A foreign difference without a rate is not written and
  ///   is listed. From then on the difference follows the books (`LiveCounts`).
  /// * The reconciliation of `kind`, dated the day of `t0`: its ruble columns are for display
  ///   only — the counts at today's rates, and the expected ones the same way when there are
  ///   any. A currency without a rate today is left out of both and listed
  ///   (`totalsWithoutRate`).
  public static func record(
    counted: [BalanceKey: AmountE4], rows: [ReconcileRow], writeDifference: Bool,
    kind: ReconciliationKind, at t0: Date, calendar: CalendarContext, tree: CategoryTree,
    categories: (expense: UUID, income: UUID), rubPerUnit: [CurrencyCode: Decimal],
    makeId: () -> UUID, startingPoints: Set<BalanceKey> = []
  ) -> AccountReconciliationRecord {
    let reconciliationId = makeId()
    let day = calendar.day(of: t0)
    func expected(_ row: ReconcileRow) -> AmountE4? {
      startingPoints.contains(row.key) ? nil : row.expected
    }
    let anyRowDiffers = rows.contains { row in
      guard let actual = counted[row.key], let expected = expected(row) else { return false }
      return actual != expected
    }
    let records = writeDifference || !anyRowDiffers
    var balances: [ReconciledBalance] = []
    var differences: [TransactionEntry] = []
    var withoutRate: [BalanceKey] = []
    var totalsWithoutRate: Set<CurrencyCode> = []
    var actualRub = AmountE4.zero
    var expectedRub = AmountE4.zero
    var anyExpected = false

    for row in rows {
      guard let actual = counted[row.key] else { continue }
      let expected = expected(row)
      var balance = ReconciledBalance(
        id: makeId(), reconciliationId: reconciliationId, accountId: row.key.accountId,
        currency: row.key.currency, actualE4: actual, expectedE4: expected,
        differenceE4: expected.map { actual - $0 },
        recordsDifference: expected == nil ? nil : records)
      let rate = perUnit(row.key.currency, rubPerUnit)
      if let rate {
        actualRub += SubscriptionMath.rounded(actual.decimal * rate)
        if let expected {
          expectedRub += SubscriptionMath.rounded(expected.decimal * rate)
          anyExpected = true
        }
      } else {
        totalsWithoutRate.insert(row.key.currency)
      }
      if writeDifference, let difference = balance.differenceE4, !difference.isZero {
        if let rate {
          let entry = LiveCounts.differenceOperation(
            difference, key: row.key,
            rate: CountRate(perUnit: rate, day: day, provisional: true), at: t0, tree: tree,
            categories: ReconcileCategories(expense: categories.expense, income: categories.income),
            countId: balance.id,
            link: .reconciledBalance(reconciliation: reconciliationId, balance: balance.id),
            now: t0)
          balance.transactionId = entry.id
          differences.append(entry)
        } else {
          withoutRate.append(row.key)
        }
      }
      balances.append(balance)
    }

    let reconciliation = Reconciliation(
      id: reconciliationId, date: day, reconciledAt: t0, actualTotalRubE4: actualRub,
      expectedTotalRubE4: anyExpected ? expectedRub : nil, kind: kind)
    return AccountReconciliationRecord(
      reconciliation: reconciliation, balances: balances, differences: differences,
      withoutRate: withoutRate,
      totalsWithoutRate: totalsWithoutRate.sorted { $0.code < $1.code })
  }

  // MARK: - Before the count

  /// Whether an operation or a transfer dated `occurredAt` and saved at `savedAt` has to ask
  /// «Это было до сверки в 14:05?»: it moves `keys`, and the latest count of one of them was
  /// made on the day it is dated, before it was saved. The answer is the moment of that count
  /// — the earliest of them when several ask — or `nil` when nothing asks.
  ///
  /// Only the day of `occurredAt` counts, not its time: a line dated «вчера» carries noon,
  /// which says nothing about before or after a count.
  public static func beforeTheCount(
    occurredAt: Date, savedAt: Date, keys: [BalanceKey], balances: AccountBalances,
    calendar: CalendarContext
  ) -> Date? {
    let day = calendar.day(of: occurredAt)
    var earliest: Date?
    for key in Set(keys) {
      guard let anchor = balances.latestAnchor(key), calendar.day(of: anchor.at) == day,
        savedAt > anchor.at
      else { continue }
      earliest = min(earliest ?? anchor.at, anchor.at)
    }
    return earliest
  }

  /// Every count of `keys` made on the day of `occurredAt` before `savedAt`, oldest first, one
  /// per moment, each with its reconciliation — not only the latest count of each key: once a
  /// later count's difference follows the books, the window a movement lands in matters, and a
  /// morning coffee typed at night belongs before the setup of 09:00, not inside the sheet of
  /// 21:00. Two counts at one moment are one question, named by the first found — the keys in
  /// the order given, the counts of each in the order of the book.
  ///
  /// Only the day of `occurredAt` counts, not its time: a line dated «вчера» carries noon,
  /// which says nothing about before or after a count.
  public static func countsOfTheDay(
    occurredAt: Date, savedAt: Date, keys: [BalanceKey], balances: AccountBalances,
    calendar: CalendarContext
  ) -> [(at: Date, reconciliation: UUID)] {
    let day = calendar.day(of: occurredAt)
    var found: [Date: UUID] = [:]
    var seen: Set<BalanceKey> = []
    for key in keys where seen.insert(key).inserted {
      for anchor in balances.anchors(key) where savedAt > anchor.at && found[anchor.at] == nil {
        guard calendar.day(of: anchor.at) == day else { continue }
        found[anchor.at] = anchor.balance.reconciliationId
      }
    }
    return found.keys.sorted().compactMap { at in found[at].map { (at, $0) } }
  }

  /// What saving a movement of `keys` dated `occurredAt` at `savedAt` asks: nothing when no
  /// count of its day came before the save (`countsOfTheDay`); otherwise the questions about
  /// those counts, oldest first, with the answers `remembered` for their reconciliations
  /// (reconciliation → «до») applied — and when those settle every count, the moment itself.
  /// The questions know which of the counts an answer can be remembered for
  /// (`CountQuestions.remembers`).
  ///
  /// An answer answers for a count only while that day is the latest counted day of every one
  /// of `keys` the count counted: one sheet counts several accounts under one reconciliation,
  /// and once one of them is counted again on a later day, the sheet's answer no longer dates
  /// that account's movements — they are asked about it again, without the offer to remember.
  public static func countToAsk(
    occurredAt: Date, savedAt: Date, keys: [BalanceKey], balances: AccountBalances,
    calendar: CalendarContext, remembered: [UUID: Bool]
  ) -> CountAsk {
    let counts = countsOfTheDay(
      occurredAt: occurredAt, savedAt: savedAt, keys: keys, balances: balances,
      calendar: calendar)
    let day = calendar.day(of: occurredAt)
    var countedAgain: Set<UUID> = []
    for key in Set(keys) {
      guard let latest = balances.latestAnchor(key), calendar.day(of: latest.at) != day
      else { continue }
      for anchor in balances.anchors(key) where calendar.day(of: anchor.at) == day {
        countedAgain.insert(anchor.balance.reconciliationId)
      }
    }
    switch CountQuestions.start(
      counts: counts.map(\.at), reconciliations: counts.map(\.reconciliation),
      occurredAt: occurredAt, calendar: calendar,
      remembered: remembered.filter { !countedAgain.contains($0.key) })
    {
    case .none: return .none
    case .ask(var questions):
      // «Больше не спрашивать» is offered only where the answer would be kept and would answer
      // for these balances: a count of an earlier day than its balances' latest is asked about
      // again whatever is ticked.
      questions.remembering = BeforeCountAnswers.keptReconciliations(balances: balances)
        .subtracting(countedAgain)
      return .ask(questions)
    case .stamp(let stamp): return .answered(stamp: stamp)
    }
  }

  /// The moment the answer stamps: «Да» — one second before the count, so its money is
  /// inside it; «Нет» — after the count, whatever time the day carried.
  ///
  /// Given the owner's `calendar`, the answer never moves the operation to another day: the
  /// day is the one the owner typed, and it decides the month the operation is spent in. A
  /// count in the first second of its day answered «Да» stamps the start of the day — a
  /// movement at the count's own moment is inside it; one in the last second answered «Нет»
  /// stamps the last millisecond of the day, still after the count.
  public static func stamped(
    occurredAt: Date, count: Date, wasBefore: Bool, calendar: CalendarContext? = nil
  ) -> Date {
    let stamp =
      wasBefore ? count.addingTimeInterval(-1) : max(occurredAt, count.addingTimeInterval(1))
    guard let calendar else { return stamp }
    let day = calendar.day(of: count)
    let dayStart = calendar.startOfDay(day)
    if wasBefore { return max(stamp, dayStart) }
    let lastMoment = calendar.startOfDay(day.adding(days: 1)).addingTimeInterval(-0.001)
    return lastMoment > count ? min(stamp, lastMoment) : stamp
  }

  /// The balances an operation moves — none for one that moves no money
  /// (`AccountBalances.movement`).
  public static func movedKeys(
    of entry: TransactionEntry, mainId: UUID?, tree: CategoryTree
  ) -> [BalanceKey] {
    AccountBalances.movement(of: entry, mainId: mainId, tree: tree).map { [$0.key] } ?? []
  }

  /// The balance a line of a debt journal moves: money borrowed or lent through the journal
  /// alone, on the line's account (the main one when it names none), in what moved on it —
  /// the rule of `AccountBalances.journalMovement`. None for a line with its own operation
  /// (that operation asks) or for any other kind of line. `openings` are the purchases on
  /// credit (`AccountBalances.creditOpenings`) whose opening line is the purchase itself.
  public static func movedKeys(
    of line: DebtEntry, debt: Debt, mainId: UUID?, calendar: CalendarContext,
    openings: [CreditOpening: Int] = [:]
  ) -> [BalanceKey] {
    var openings = openings
    return AccountBalances.journalMovement(
      of: line, debt: debt, mainId: mainId, openings: &openings, calendar: calendar
    ).map { [$0.key] } ?? []
  }

  /// The two balances a transfer moves.
  public static func movedKeys(of transfer: Transfer) -> [BalanceKey] {
    transfer.from == transfer.to ? [transfer.from] : [transfer.from, transfer.to]
  }

  // MARK: - Reminder

  /// The reconciliation the reminder counts from, the later of two: the latest sheet of every
  /// account or, as before accounts, of one total — they keep the rhythm across the update —
  /// and the first opening count, the setup of the accounts, which counts every account too.
  /// A later opening — a new account's «Остаток сейчас», a merge — counts one account, not
  /// every one, and never puts the reminder off.
  public static func reminderAnchor(book: PlanningBook) -> Reconciliation? {
    var latest: Reconciliation?
    var firstOpening: Reconciliation?
    for candidate in book.reconciliations {
      switch candidate.kind {
      case .accounts, .total:
        if let current = latest, !isLater(candidate, than: current) { continue }
        latest = candidate
      case .opening:
        if let current = firstOpening, isLater(candidate, than: current) { continue }
        firstOpening = candidate
      }
    }
    guard let latest else { return firstOpening }
    guard let firstOpening else { return latest }
    return isLater(firstOpening, than: latest) ? firstOpening : latest
  }

  /// Time to reconcile: never reconciled, or the reconciliation the reminder counts from
  /// (`reminderAnchor`) is more than `everyDays` days old.
  public static func isDue(book: PlanningBook, today: DateOnly, everyDays: Int) -> Bool {
    guard let anchor = reminderAnchor(book: book) else { return true }
    return anchor.date.days(to: today) > everyDays
  }

  /// By day, then by moment; on a tie the one listed later, as the book keeps them oldest
  /// first.
  private static func isLater(_ candidate: Reconciliation, than current: Reconciliation) -> Bool {
    (candidate.date, candidate.reconciledAt ?? .distantPast)
      >= (current.date, current.reconciledAt ?? .distantPast)
  }

  private static func perUnit(
    _ currency: CurrencyCode, _ rubPerUnit: [CurrencyCode: Decimal]
  ) -> Decimal? {
    if currency == .rub { return 1 }
    guard let rate = rubPerUnit[currency], rate > 0 else { return nil }
    return rate
  }
}
