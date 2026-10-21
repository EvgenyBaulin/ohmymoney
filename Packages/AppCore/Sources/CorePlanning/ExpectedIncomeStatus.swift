import CoreAnalytics
import CoreKit
import Foundation

/// One due date of an expected income and what came in for it. Amounts are in the currency
/// of the expectation.
public struct ExpectedOccurrence: Hashable, Sendable {
  public var due: DateOnly
  public var total: AmountE4
  public var received: AmountE4
  /// max(0, total − received).
  public var remaining: AmountE4
  /// `remaining` in rubles at the latest rate the caller knows; `nil` for a foreign
  /// expectation without a rate.
  public var remainingRub: AmountE4?
  /// Linked operations counted towards this due date.
  public var partsReceived: Int
  public var transactionIds: [UUID]

  public var isFulfilled: Bool { remaining.isZero }

  public init(
    due: DateOnly, total: AmountE4, received: AmountE4, remaining: AmountE4,
    remainingRub: AmountE4?, partsReceived: Int, transactionIds: [UUID]
  ) {
    self.due = due
    self.total = total
    self.received = received
    self.remaining = remaining
    self.remainingRub = remainingRub
    self.partsReceived = partsReceived
    self.transactionIds = transactionIds
  }
}

/// An expected income with what has come in for it: a one-off one with its prepayment and the
/// rest, or a recurring one due by due. Amounts are in the currency of the expectation unless
/// the name says rubles.
public struct ExpectedIncomeStatus: Hashable, Sendable, Identifiable {
  public var income: ExpectedIncome
  /// A one-off income has one, at its due date (none when it has no date). A recurring one
  /// has every due date from the first through the end of the current month — or through the
  /// horizon the statuses were built for — the latest 24.
  public var occurrences: [ExpectedOccurrence]
  public var received: AmountE4
  /// The rubles of the operations counted in `received`, at their own rates.
  public var receivedRub: AmountE4
  public var remaining: AmountE4
  public var remainingRub: AmountE4?
  public var partsReceived: Int
  public var partsExpected: Int
  /// A one-off income came in whole; every due date of a recurring one so far did.
  public var isFulfilled: Bool
  /// A due date before today still waits for money.
  public var isOverdue: Bool
  /// Every live income operation linked to it, oldest first — counted or not.
  public var linkedTransactionIds: [UUID]
  /// The currency has no known rate: the rubles are unknown, and an operation in a third
  /// currency could not be converted and is left out of `received`. Never guessed.
  public var withoutRate: Bool

  public var id: UUID { income.id }
  public var currency: CurrencyCode { income.currency }

  /// The due date of the current month for a recurring income, the only one for a one-off.
  public var current: ExpectedOccurrence? { occurrences.last }

  public init(
    income: ExpectedIncome, occurrences: [ExpectedOccurrence], received: AmountE4,
    receivedRub: AmountE4, remaining: AmountE4, remainingRub: AmountE4?, partsReceived: Int,
    partsExpected: Int, isFulfilled: Bool, isOverdue: Bool, linkedTransactionIds: [UUID],
    withoutRate: Bool
  ) {
    self.income = income
    self.occurrences = occurrences
    self.received = received
    self.receivedRub = receivedRub
    self.remaining = remaining
    self.remainingRub = remainingRub
    self.partsReceived = partsReceived
    self.partsExpected = partsExpected
    self.isFulfilled = isFulfilled
    self.isOverdue = isOverdue
    self.linkedTransactionIds = linkedTransactionIds
    self.withoutRate = withoutRate
  }
}

/// Expected income against what really came (`expected_income_links`).
///
/// * Only a link to a **live income** operation counts: a deleted operation, or one that
///   was turned into an expense, stops paying the expectation.
/// * An operation in the currency of the expectation counts with its own amount, so a
///   payment of 1 000 $ fulfils 1 000 $ whatever the rate did since. An operation in
///   another currency is compared through rubles: its rubles at its own rate, converted at
///   the latest rate of the expectation's currency (rubles need none).
/// * A recurring income is due from its first due date every week, month or year of its
///   frequency, through the end of the current month (or a later horizon: the free sum looks
///   up to a year ahead), the latest 24 due dates at most. An
///   operation counts towards the due date of its own month — the month it is for
///   (`period_month`), else the month of its date; towards the due date of its year for a
///   yearly income; of its week, by date, for a weekly one. An operation of no listed due
///   date (an advance for next month, say) is linked but counted nowhere yet.
public enum ExpectedIncomeRules {
  /// Due dates a recurring expectation lists at most.
  public static let maxOccurrences = 24

  /// The expectations that are not closed, in the order of the book. A recurring one lists
  /// its due dates through `through`, the end of today's month by default; a horizon before
  /// that is taken as the end of the month.
  public static func statuses(
    book: PlanningBook, ledger: Ledger, today: DateOnly,
    rubPerUnit: [CurrencyCode: Decimal] = [:], through: DateOnly? = nil
  ) -> [ExpectedIncomeStatus] {
    let horizon = max(through ?? today.monthKey.lastDay, today.monthKey.lastDay)
    var linked: [UUID: Set<UUID>] = [:]
    for link in book.expectedLinks {
      linked[link.expectedIncomeId, default: []].insert(link.transactionId)
    }
    return book.expected.filter { !$0.closed }.map { income in
      let operations = (linked[income.id] ?? [])
        .compactMap { ledger.entry($0) }
        .filter { $0.transaction.kind == .income && !$0.transaction.isDeleted }
        .sorted(by: oldestFirst)
      return status(
        of: income, operations: operations, ledger: ledger, today: today, through: horizon,
        rate: rate(of: income.currency, in: rubPerUnit))
    }
  }

  /// The expectation a new income most likely pays: an open one of the same category and
  /// the same person, else an open one of the same category. Of several, the one due
  /// earliest. `nil` for anything but an income, and for an income already linked.
  ///
  /// A recurring expectation is always open — its next due date is coming — and a one-off
  /// one is open until it came in whole.
  public static func suggestLink(
    for entry: TransactionEntry, statuses: [ExpectedIncomeStatus]
  ) -> UUID? {
    guard entry.transaction.kind == .income, !entry.transaction.isDeleted else { return nil }
    guard !statuses.contains(where: { $0.linkedTransactionIds.contains(entry.id) }) else {
      return nil
    }
    let categories = Set(entry.parts.compactMap(\.categoryId))
    let people = Set(entry.parts.compactMap { $0.forPersonId ?? $0.debtorPersonId })
    let candidates =
      statuses
      .filter { status in
        guard !status.income.closed, let category = status.income.categoryId else {
          return false
        }
        let open = status.income.kind == .recurring || !status.isFulfilled
        return open && categories.contains(category)
      }
      .sorted(by: earliestDueFirst)
    if let samePerson = candidates.first(where: { status in
      status.income.personId.map(people.contains) ?? false
    }) {
      return samePerson.id
    }
    return candidates.first?.id
  }

  /// Whether «Закрыть полностью» is offered: a one-off income that is not closed and has
  /// received no less than it expected — the whole amount or more. A recurring income is never
  /// received whole (its next term is coming), and one whose currency has no rate may have
  /// received what is not counted, so neither is offered on a guess; the form of an income still
  /// closes any of them by hand.
  public static func offersClosing(_ status: ExpectedIncomeStatus) -> Bool {
    guard !status.income.closed, status.income.kind == .oneOff, !status.withoutRate else {
      return false
    }
    return status.received >= status.income.totalE4
  }

  /// The incomes whose name another one of `incomes` has too, whatever the case and the spaces
  /// around it. Names may repeat; a menu tells these apart by amount and date.
  public static func namesakes(among incomes: [ExpectedIncome]) -> Set<UUID> {
    func key(_ name: String) -> String {
      name.trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive], locale: nil)
    }
    var counts: [String: Int] = [:]
    for income in incomes { counts[key(income.name), default: 0] += 1 }
    return Set(incomes.filter { (counts[key($0.name)] ?? 0) > 1 }.map(\.id))
  }

  // MARK: - Where the money comes and what an operation pays

  /// The account the money of `income` is to come to: the one the owner chose for it; without
  /// one, the account of the latest live income operation linked to it — the main one when
  /// that operation named none —; with neither, `mainId`. A salary lands on one account every
  /// month, so after one linked month the guess is right, and the choice says it from day one.
  public static func account(
    of income: ExpectedIncome, links: [ExpectedIncomeLink], ledger: Ledger, mainId: UUID?
  ) -> UUID? {
    if let chosen = income.paymentMethodId { return chosen }
    let latest =
      links
      .filter { $0.expectedIncomeId == income.id }
      .compactMap { ledger.entry($0.transactionId) }
      .filter { $0.transaction.kind == .income && !$0.transaction.isDeleted }
      .max { oldestFirst($0, $1) }
    guard let latest else { return mainId }
    return latest.transaction.paymentMethodId ?? mainId
  }

  /// The due date of `status` an income operation would be counted towards if it were
  /// linked: the only one of a one-off expectation, else the one of the operation's month
  /// (its year, its week — as the frequency says). `nil` when it belongs to no listed due date.
  public static func occurrenceIndex(
    of entry: TransactionEntry, in status: ExpectedIncomeStatus, ledger: Ledger
  ) -> Int? {
    guard !status.occurrences.isEmpty else { return nil }
    switch status.income.kind {
    case .oneOff:
      return 0
    case .recurring:
      guard let row = firstRow(of: entry, ledger) else { return nil }
      let freq = status.income.freq ?? .monthly
      return status.occurrences.firstIndex { belongs(row, to: $0.due, freq: freq) }
    }
  }

  /// An income operation in the currency of `income`, the way a link would count it: its own
  /// amount in the same currency, else through rubles at `rubPerUnit`; `nil` without a rate.
  public static func amount(
    of transaction: Transaction, towards income: ExpectedIncome,
    rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    amount(of: transaction, in: income.currency, rate: rate(of: income.currency, in: rubPerUnit))
  }

  // MARK: - One expectation

  private static func status(
    of income: ExpectedIncome, operations: [TransactionEntry], ledger: Ledger,
    today: DateOnly, through horizon: DateOnly, rate: Decimal?
  ) -> ExpectedIncomeStatus {
    var withoutRate = rate == nil
    let total = income.totalE4
    let perDue = max(1, income.partsExpected)

    // The amount of each operation in the currency of the expectation.
    var amounts: [UUID: AmountE4] = [:]
    for entry in operations {
      if let amount = amount(of: entry.transaction, in: income.currency, rate: rate) {
        amounts[entry.id] = amount
      } else {
        withoutRate = true
      }
    }

    func occurrence(_ due: DateOnly, _ counted: [TransactionEntry]) -> ExpectedOccurrence {
      let received = AmountE4.sum(counted.compactMap { amounts[$0.id] })
      let remaining = max(.zero, total - received)
      return ExpectedOccurrence(
        due: due, total: total, received: received, remaining: remaining,
        remainingRub: rubles(remaining, currency: income.currency, rate: rate),
        partsReceived: counted.count, transactionIds: counted.map(\.id))
    }

    let occurrences: [ExpectedOccurrence]
    let counted: [TransactionEntry]
    let received: AmountE4
    let remaining: AmountE4
    let isFulfilled: Bool
    let partsExpected: Int
    switch income.kind {
    case .oneOff:
      counted = operations
      received = AmountE4.sum(operations.compactMap { amounts[$0.id] })
      remaining = max(.zero, total - received)
      occurrences = income.dueDate.map { [occurrence($0, operations)] } ?? []
      isFulfilled = remaining.isZero
      partsExpected = perDue
    case .recurring:
      let freq = income.freq ?? .monthly
      let dues = dueDates(of: income, freq: freq, through: horizon, today: today)
      var buckets: [[TransactionEntry]] = Array(repeating: [], count: dues.count)
      for entry in operations {
        guard let row = firstRow(of: entry, ledger) else { continue }
        if let index = dues.firstIndex(where: { belongs(row, to: $0, freq: freq) }) {
          buckets[index].append(entry)
        }
      }
      occurrences = zip(dues, buckets).map { occurrence($0, $1) }
      counted = buckets.flatMap { $0 }
      received = AmountE4.sum(occurrences.map(\.received))
      remaining = AmountE4.sum(occurrences.map(\.remaining))
      isFulfilled = !occurrences.isEmpty && occurrences.allSatisfy(\.isFulfilled)
      partsExpected = perDue * occurrences.count
    }

    return ExpectedIncomeStatus(
      income: income, occurrences: occurrences, received: received,
      receivedRub: AmountE4.sum(counted.map(\.transaction.amountRubE4)), remaining: remaining,
      remainingRub: rubles(remaining, currency: income.currency, rate: rate),
      partsReceived: counted.count, partsExpected: partsExpected, isFulfilled: isFulfilled,
      isOverdue: occurrences.contains { $0.due < today && !$0.isFulfilled },
      linkedTransactionIds: operations.map(\.id), withoutRate: withoutRate)
  }

  /// The ledger row of the first part: the day and the month the operation belongs to.
  private static func firstRow(of entry: TransactionEntry, _ ledger: Ledger) -> LedgerRow? {
    entry.parts.first.flatMap { ledger.row(ofPart: $0.id) }
  }

  private static func belongs(_ row: LedgerRow, to due: DateOnly, freq: Frequency) -> Bool {
    switch freq {
    case .monthly: row.month == due.monthKey
    case .yearly: row.month.year == due.year
    case .weekly: row.day.weekStart == due.weekStart
    }
  }

  // MARK: - Due dates

  /// Due dates of a recurring income from its first one through `last`, the latest
  /// `maxOccurrences`. The first due date is the stored one; the later ones fall on the day
  /// of the income (its first due date's day when it has none), clipped to the length of a
  /// shorter month and counted from the first one each time, so the 31st goes 31 January →
  /// 28 February → 31 March. A weekly income moves to its weekday (1…7, Monday first) when
  /// it has one. Without a first due date the income is taken to start in the current month
  /// (week), on its day.
  static func dueDates(
    of income: ExpectedIncome, freq: Frequency, through last: DateOnly, today: DateOnly
  ) -> [DateOnly] {
    let first = income.dueDate ?? defaultFirstDue(of: income, freq: freq, today: today)
    guard first <= last else { return [] }
    func steps(to end: DateOnly) -> Int {
      switch freq {
      case .monthly: first.monthKey.months(to: end.monthKey)
      case .yearly: end.year - first.year
      case .weekly: first.days(to: end) / 7 + 1
      }
    }
    // The latest `maxOccurrences` through the end of this month, and every one after it up to
    // a later horizon: looking ahead never pushes this month's due dates out.
    let monthEnd = min(today.monthKey.lastDay, last)
    let lower = max(0, steps(to: monthEnd) - maxOccurrences - 1)
    let dues = (lower...max(lower, steps(to: last)))
      .map { dueDate(first: first, step: $0, freq: freq, day: income.day) }
      .filter { $0 <= last }
    return Array(dues.filter { $0 <= monthEnd }.suffix(maxOccurrences))
      + dues.filter { $0 > monthEnd }
  }

  private static func dueDate(
    first: DateOnly, step: Int, freq: Frequency, day: Int?
  )
    -> DateOnly
  {
    guard step > 0 else { return first }
    switch freq {
    case .monthly:
      return clipped(day: day ?? first.day, in: first.monthKey.adding(months: step))
    case .yearly:
      return clipped(
        day: day ?? first.day, in: MonthKey(year: first.year + step, month: first.month))
    case .weekly:
      guard let weekday = day, (1...7).contains(weekday) else {
        return first.adding(days: 7 * step)
      }
      return first.weekStart.adding(days: 7 * step + weekday - 1)
    }
  }

  private static func defaultFirstDue(
    of income: ExpectedIncome, freq: Frequency, today: DateOnly
  )
    -> DateOnly
  {
    switch freq {
    case .monthly, .yearly:
      return clipped(day: income.day ?? 1, in: today.monthKey)
    case .weekly:
      let weekday = income.day.map { min(7, max(1, $0)) } ?? 1
      return today.weekStart.adding(days: weekday - 1)
    }
  }

  private static func clipped(day: Int, in month: MonthKey) -> DateOnly {
    DateOnly(year: month.year, month: month.month, day: min(max(1, day), month.dayCount))
  }

  // MARK: - Currency

  /// Rubles per unit of `currency`: 1 for rubles, the caller's latest rate otherwise.
  static func rate(
    of currency: CurrencyCode, in rubPerUnit: [CurrencyCode: Decimal]
  )
    -> Decimal?
  {
    if currency == .rub { return 1 }
    guard let rate = rubPerUnit[currency], rate > 0 else { return nil }
    return rate
  }

  /// An operation in the currency of an expectation: its own amount in the same currency,
  /// its rubles for a ruble expectation, its rubles at the latest rate otherwise — `nil`
  /// when that rate is unknown.
  static func amount(
    of transaction: Transaction, in currency: CurrencyCode, rate: Decimal?
  )
    -> AmountE4?
  {
    if transaction.currency == currency { return transaction.amountE4 }
    if currency == .rub { return transaction.amountRubE4 }
    guard let rate else { return nil }
    return SavingsMath.rounded(transaction.amountRubE4.decimal / rate)
  }

  static func rubles(_ amount: AmountE4, currency: CurrencyCode, rate: Decimal?) -> AmountE4? {
    if currency == .rub { return amount }
    guard let rate else { return nil }
    return SavingsMath.rounded(amount.decimal * rate)
  }

  // MARK: - Order

  private static func oldestFirst(_ left: TransactionEntry, _ right: TransactionEntry) -> Bool {
    if left.transaction.occurredAt != right.transaction.occurredAt {
      return left.transaction.occurredAt < right.transaction.occurredAt
    }
    return left.id.uuidString < right.id.uuidString
  }

  /// The first due date still waiting, else none: expectations with nothing waiting go last.
  private static func earliestDueFirst(
    _ left: ExpectedIncomeStatus, _ right: ExpectedIncomeStatus
  )
    -> Bool
  {
    let leftDue = left.occurrences.first { !$0.isFulfilled }?.due
    let rightDue = right.occurrences.first { !$0.isFulfilled }?.due
    switch (leftDue, rightDue) {
    case (let l?, let r?) where l != r: return l < r
    case (.some, nil): return true
    case (nil, .some): return false
    default:
      if left.income.name != right.income.name { return left.income.name < right.income.name }
      return left.id.uuidString < right.id.uuidString
    }
  }
}
