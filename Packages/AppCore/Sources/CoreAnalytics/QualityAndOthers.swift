import CoreKit
import Foundation

/// The «Good vs Bad» section.
public struct QualityReport: Hashable, Sendable {
  public struct Month: Hashable, Sendable {
    public var month: MonthKey
    /// Good → neutral → bad, with shares of that month.
    public var qualities: [BreakdownNode]
  }

  public var months: [Month]
  /// My bad spending in the period by top-level category.
  public var badByCategory: [BreakdownNode]
  /// Days in a row without bad spending, ending today; and the longest such run, counted
  /// from the first day with operations through today.
  public var currentStreak: Int
  public var bestStreak: Int
  /// Money put into goals against the rest of my spending in the period.
  public var goals: AmountE4
  public var rest: AmountE4
  public var goalsShare: Int?
  public var restShare: Int?

  public init(ledger: Ledger, period: Period, today: DateOnly) {
    months = period.months.map { month in
      Month(
        month: month,
        qualities: OverviewSummary.qualities(
          of: ledger.rows(in: ledger.slice(of: month, in: period))))
    }
    let rows = ledger.rows(in: period.range).filter { !$0.contribution.isZero }
    badByCategory = Tabulation.oneLevel(
      rows.filter { $0.quality == .bad }.map {
        (ReportGrouping.category.outerKey(of: $0), $0.contribution)
      })
    (currentStreak, bestStreak) = Self.streaks(ledger: ledger, today: today)
    goals = AmountE4.sum(rows.filter(\.isGoalContribution).map(\.contribution))
    rest = AmountE4.sum(rows.filter { !$0.isGoalContribution }.map(\.contribution))
    let shares = Shares.basisPoints([goals, rest])
    goalsShare = shares[0]
    restShare = shares[1]
  }

  /// A bad day has a part rated bad with a positive contribution: a bad purchase makes the
  /// day bad, and a refund of no purchase later that day does not make it good again. A refund
  /// taken back from the purchase counts in the purchase, on its day: taken back whole, the
  /// purchase contributes nothing and its day is not bad — as if it had not been bought; taken
  /// back in part, the day stays bad.
  static func streaks(ledger: Ledger, today: DateOnly) -> (current: Int, best: Int) {
    guard let first = ledger.firstDay, first <= today else { return (0, 0) }
    var badDays: Set<Int> = []
    for row in ledger.rows(in: DayRange(first, today))
    where row.quality == .bad && row.contribution.raw > 0 {
      badDays.insert(row.dayNumber)
    }
    var run = 0
    var best = 0
    for dayNumber in first.dayNumber...today.dayNumber {
      if badDays.contains(dayNumber) {
        run = 0
      } else {
        run += 1
        best = max(best, run)
      }
    }
    return (run, best)
  }
}

/// The «Paid for others» section.
///
/// Everything is counted on the parts of purchases I paid for somebody else, dated by the
/// purchase: what I paid, what came back through live reimbursement links (in rubles), what
/// I wrote off, what still waits, and the shortfall — how much less than a part came back
/// before it was closed. The surplus is income in the Surcharges category, by the month it
/// is for.
///
/// Money back may cover only some of a part: what still waits is what is left of it. A closed
/// part falls short and has something written off only by the operations the app wrote for
/// it (`Ledger.companionsRub`): a part closed within the drift of rates has neither, since the
/// drift is not spending.
public struct OthersReport: Hashable, Sendable {
  public struct Totals: Hashable, Sendable {
    public var paid: AmountE4 = .zero
    public var returned: AmountE4 = .zero
    public var writtenOff: AmountE4 = .zero
    public var waiting: AmountE4 = .zero
    public var shortfall: AmountE4 = .zero

    public init() {}

    mutating func add(
      _ row: LedgerRow, returnedForPart: AmountE4,
      companions: (shortfall: AmountE4, writtenOff: AmountE4)
    ) {
      paid += row.amountRubE4
      returned += returnedForPart
      switch row.reimbursementStatus ?? .expected {
      case .expected: waiting += max(.zero, row.amountRubE4 - returnedForPart)
      case .writtenOff: writtenOff += row.amountRubE4
      case .returned:
        shortfall += companions.shortfall
        writtenOff += companions.writtenOff
      }
    }
  }

  public struct Debtor: Hashable, Sendable {
    public var personId: UUID?
    public var totals: Totals
  }

  /// One scheduled payment paid for somebody else: what «Mark as paid» charged for it inside
  /// the period, with the same figures a debtor's bar carries.
  public struct Subscription: Hashable, Sendable {
    public var paymentId: UUID
    public var totals: Totals
    /// How many charges of the period the figures are made of.
    public var charges: Int

    public init(paymentId: UUID, totals: Totals, charges: Int) {
      self.paymentId = paymentId
      self.totals = totals
      self.charges = charges
    }
  }

  public var totals: Totals
  public var surplus: AmountE4
  /// By the person who owes, largest payment first; parts without a person last.
  public var byPerson: [Debtor]
  /// «По подпискам за других»: the same parts as `byPerson`, sliced by the scheduled payment
  /// whose charge they belong to, largest paid first.
  ///
  /// Read from the operations, never from the plan: a payment that was reimbursable when it
  /// was charged keeps its history even if it is no longer marked so, and a payment deleted
  /// from the plan keeps the money it really took. The surplus is not here — it is written as
  /// one income of Surcharges per reimbursement and names no part, so it belongs to the
  /// totals alone.
  public var bySubscription: [Subscription]

  public init(ledger: Ledger, period: Period) {
    var totals = Totals()
    var people: [UUID?: Totals] = [:]
    var subscriptions: [UUID: Totals] = [:]
    var charges: [UUID: Set<UUID>] = [:]
    for row in ledger.rows(in: period.range) where row.kind == .expense && row.reimbursable {
      let returned = ledger.returned(forPart: row.partId)
      let companions = ledger.companionsRub(forPart: row.partId)
      totals.add(row, returnedForPart: returned, companions: companions)
      people[row.debtorPersonId, default: Totals()].add(
        row, returnedForPart: returned, companions: companions)
      guard case .scheduled(let paymentId, _) = row.link else { continue }
      subscriptions[paymentId, default: Totals()].add(
        row, returnedForPart: returned, companions: companions)
      charges[paymentId, default: []].insert(row.transactionId)
    }
    self.totals = totals
    bySubscription =
      subscriptions
      .map {
        Subscription(paymentId: $0.key, totals: $0.value, charges: charges[$0.key]?.count ?? 0)
      }
      .sorted { left, right in
        if left.totals.paid != right.totals.paid { return left.totals.paid > right.totals.paid }
        return left.paymentId.uuidString < right.paymentId.uuidString
      }
    surplus = AmountE4.sum(
      ledger.incomeRows(in: period).filter { $0.systemRole == .surcharges }.map(\.amountRubE4))
    byPerson = people.map { Debtor(personId: $0.key, totals: $0.value) }.sorted { left, right in
      if (left.personId == nil) != (right.personId == nil) { return right.personId == nil }
      if left.totals.paid != right.totals.paid { return left.totals.paid > right.totals.paid }
      return (left.personId?.uuidString ?? "") < (right.personId?.uuidString ?? "")
    }
  }
}
