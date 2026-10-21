import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// One debt of the Debts section, with its journal worked out.
public struct DebtLine: Identifiable, Hashable, Sendable {
  public var debt: Debt
  /// Σ of the journal, in the currency of the debt: plus is still owed. For a loan that accrues
  /// interest, the principal: the journal with the interest its payments paid given back
  /// (`DebtInterest`) — the interest accrued since is `accruedInterestE4`.
  public var balance: AmountE4
  /// The balance in rubles; `nil` for a foreign debt without a known rate.
  public var balanceRub: AmountE4?
  /// Subtotals per group, in the order the groups first appear in the journal.
  public var groups: [DebtGroupTotal]
  /// The earliest monthly due nothing paid yet (`DebtDueState.firstUnpaid`): it may lie in an
  /// earlier month — overdue; `nil` for a closed debt, one without a payment day and one with
  /// nothing left to pay.
  public var nextPayment: DateOnly?
  /// This month's due is paid (`dues`).
  public var paidThisMonth: Bool
  /// The journal, newest first; lines without a date last.
  public var entries: [DebtEntry]
  /// Which monthly dues are paid: each payment closes the earliest one still unpaid.
  public var dues: DebtDueState
  /// The grace period and the main schedule of a loan that has one; `nil` for any other debt.
  public var schedule: DebtScheduleSummary?
  /// The interest accrued since the last payment and not paid yet, for a debt that accrues it;
  /// zero for any other.
  public var accruedInterestE4: AmountE4
  /// For a loan that accrues interest, the interest each payment of the journal paid first, by
  /// the id of the payment's line («из них проценты ≈»); payments that paid none are not in it.
  public var interestByPayment: [UUID: AmountE4]

  public init(
    debt: Debt, balance: AmountE4, balanceRub: AmountE4?, groups: [DebtGroupTotal],
    nextPayment: DateOnly?, paidThisMonth: Bool, entries: [DebtEntry],
    dues: DebtDueState? = nil, schedule: DebtScheduleSummary? = nil,
    accruedInterestE4: AmountE4 = .zero, interestByPayment: [UUID: AmountE4] = [:]
  ) {
    self.debt = debt
    self.balance = balance
    self.balanceRub = balanceRub
    self.groups = groups
    self.nextPayment = nextPayment
    self.paidThisMonth = paidThisMonth
    self.entries = entries
    self.dues = dues ?? .none(of: debt.id)
    self.schedule = schedule
    self.accruedInterestE4 = accruedInterestE4
    self.interestByPayment = interestByPayment
  }

  public var id: UUID { debt.id }
}

/// The schedule of a loan with a grace period, as its card tells it: «Льготный период до …
/// · платёж ≈ …», «С … — … в месяц», the tranches drawn and the interest accrued.
public struct DebtScheduleSummary: Hashable, Sendable {
  public enum Phase: Hashable, Sendable {
    case grace
    case main
  }

  public var phase: Phase
  /// What the next due asks for.
  public var current: AmountE4
  /// The first day of the main schedule.
  public var mainFrom: DateOnly
  /// The main payment, once it is known; `nil` while it is worked out from a balance still to
  /// come.
  public var mainAmount: AmountE4?
  /// The money drawn so far — every tranche through today, the first loan included.
  public var drawnE4: AmountE4
  public var accruedInterestE4: AmountE4

  public init(
    phase: Phase, current: AmountE4, mainFrom: DateOnly, mainAmount: AmountE4?,
    drawnE4: AmountE4, accruedInterestE4: AmountE4
  ) {
    self.phase = phase
    self.current = current
    self.mainFrom = mainFrom
    self.mainAmount = mainAmount
    self.drawnE4 = drawnE4
    self.accruedInterestE4 = accruedInterestE4
  }
}

/// A part I paid for somebody else that is still expected back, as the «Owed to me» list
/// shows it.
public struct OwedPartSummary: Identifiable, Hashable, Sendable {
  public var partId: UUID
  public var transactionId: UUID
  /// The day of the purchase.
  public var day: DateOnly
  /// Who owes it: the debtor of the part.
  public var personId: UUID?
  /// What is still owed, in rubles: what the part cost on the day of the purchase, less what
  /// already came back for it.
  public var amountRub: AmountE4
  /// The note of the part, otherwise of its operation.
  public var note: String?
  /// What already came back for the part, in rubles, while it waits for the rest.
  public var returnedRub: AmountE4

  public init(
    partId: UUID, transactionId: UUID, day: DateOnly, personId: UUID?, amountRub: AmountE4,
    note: String?, returnedRub: AmountE4 = .zero
  ) {
    self.partId = partId
    self.transactionId = transactionId
    self.day = day
    self.personId = personId
    self.amountRub = amountRub
    self.note = note
    self.returnedRub = returnedRub
  }

  public var id: UUID { partId }
}

/// Everything one person owes me: their personal debts and the parts I paid for them.
public struct OwedToMeGroup: Hashable, Sendable {
  /// `nil` gathers the debts and the parts that name nobody.
  public var personId: UUID?
  public var debts: [DebtLine]
  /// Oldest first.
  public var parts: [OwedPartSummary]
  /// The balances of the debts in rubles (those with a rate) plus the parts.
  public var totalRub: AmountE4
  /// The oldest expectation: the earliest part, or the earliest dated journal line of a
  /// debt that still has something owed on it.
  public var oldest: DateOnly?

  public init(
    personId: UUID?, debts: [DebtLine], parts: [OwedPartSummary], totalRub: AmountE4,
    oldest: DateOnly?
  ) {
    self.personId = personId
    self.debts = debts
    self.parts = parts
    self.totalRub = totalRub
    self.oldest = oldest
  }
}

/// The Debts section: two lists — «I owe» and «Owed to me» — the closed
/// debts, and the totals on top.
///
/// Balances live here and nowhere else: they never reach the Overview or the analytics, which
/// read operations only.
public struct DebtsOverview: Hashable, Sendable {
  /// Open debts I owe: the nearest payment first, then by name.
  public var iOwe: [DebtLine]
  /// Open debts owed to me and the parts I paid for others that are still expected, merged
  /// by person: the largest total first, the group without a person last.
  public var owedToMe: [OwedToMeGroup]
  /// Closed debts of both directions, by name.
  public var closed: [DebtLine]
  /// Σ balances of `iOwe` in rubles, the debts without a rate left out.
  public var totalIOweRub: AmountE4
  /// Σ totals of `owedToMe`.
  public var totalOwedToMeRub: AmountE4
  /// Σ monthly payments of the open debts I owe, in rubles.
  public var monthlyPaymentsRub: AmountE4
  /// Open debts left out of a total because their currency has no known rate (or, beyond any
  /// real figure, their rubles do not fit into stored units: `DebtRubles.convert`).
  public var withoutRate: [UUID]

  public init(
    iOwe: [DebtLine], owedToMe: [OwedToMeGroup], closed: [DebtLine], totalIOweRub: AmountE4,
    totalOwedToMeRub: AmountE4, monthlyPaymentsRub: AmountE4, withoutRate: [UUID]
  ) {
    self.iOwe = iOwe
    self.owedToMe = owedToMe
    self.closed = closed
    self.totalIOweRub = totalIOweRub
    self.totalOwedToMeRub = totalOwedToMeRub
    self.monthlyPaymentsRub = monthlyPaymentsRub
    self.withoutRate = withoutRate
  }

  /// The section for `today`.
  ///
  /// * Debts come from the dataset of the ledger, the closed ones included; their journals
  ///   from `book.debtEntries`. A balance is `DebtRules.balance` of the journal — for a loan
  ///   that accrues interest, of the journal as the interest makes it through today
  ///   (`DebtInterest`) —, the groups are `DebtRules.groupTotals`. A loan with a grace period
  ///   tells its schedule (`DebtScheduleSummary`).
  /// * A foreign balance or payment is converted at the last rate the caller knows
  ///   (`rubPerUnit`); without one the debt stays in its list with no rubles and is named in
  ///   `withoutRate` instead of being guessed into a total.
  /// * The parts paid for others are the ones the Overview counts as owed to me: parts of
  ///   purchases, paid for somebody else, still expected — what is left of each in rubles,
  ///   the rubles they cost on the day of the purchase less what already came back. The person
  ///   is the debtor of the part, the same key the report of payments for others groups by.
  public static func build(
    ledger: Ledger, book: PlanningBook, today: DateOnly, rubPerUnit: [CurrencyCode: Decimal]
  ) -> DebtsOverview {
    var journals: [UUID: [DebtEntry]] = [:]
    for entry in book.debtEntries { journals[entry.debtId, default: []].append(entry) }
    let debts = ledger.dataset.debts
    let states = DebtDues.states(
      debts: debts, ledger: ledger, journal: book.debtEntries, today: today)

    func line(_ debt: Debt) -> DebtLine {
      let journal = journals[debt.id] ?? []
      let dues = states[debt.id] ?? .none(of: debt.id)
      let interest = DebtInterest.read(
        debt: debt, journal: journal, through: today, calendar: ledger.calendar)
      var balance = DebtRules.balance(entries: journal)
      if let interest { balance += DebtRules.balance(entries: interest.lines) }
      let accrued = interest?.accruedE4 ?? .zero
      let thisMonth = debt.paymentDay.map { DebtDueState.payday($0, in: today.monthKey) }
      return DebtLine(
        debt: debt, balance: balance,
        balanceRub: DebtRubles.convert(balance, from: debt.currency, rubPerUnit: rubPerUnit),
        groups: DebtRules.groupTotals(entries: journal),
        nextPayment: debt.closed ? nil : dues.firstUnpaid,
        paidThisMonth: thisMonth.map(dues.isPaid) ?? false, entries: newestFirst(journal),
        dues: dues,
        schedule: schedule(
          of: debt, journal: journal, dues: dues, accrued: accrued, today: today,
          calendar: ledger.calendar),
        accruedInterestE4: accrued, interestByPayment: interest?.interestByPayment ?? [:])
    }

    let open = debts.filter { !$0.closed }.map(line)
    let iOwe = open.filter { $0.debt.direction == .iOwe }.sorted(by: nearestPaymentFirst)
    let closed = debts.filter(\.closed).map(line).sorted(by: byName)

    // «Owed to me»: the person's debts and the parts they owe, one group per person.
    var groupDebts: [UUID?: [DebtLine]] = [:]
    for line in open where line.debt.direction == .owedToMe {
      groupDebts[line.debt.personId, default: []].append(line)
    }
    var groupParts: [UUID?: [OwedPartSummary]] = [:]
    for row in ledger.rows
    where row.kind == .expense && row.reimbursable && row.reimbursementStatus == .expected {
      let remaining = ledger.remaining(ofPart: row)
      guard remaining.raw > 0 else { continue }
      let entry = ledger.entry(row.transactionId)
      let part = entry?.parts.first { $0.id == row.partId }
      groupParts[row.debtorPersonId, default: []].append(
        OwedPartSummary(
          partId: row.partId, transactionId: row.transactionId, day: row.day,
          personId: row.debtorPersonId, amountRub: remaining,
          note: part?.note ?? entry?.transaction.note,
          returnedRub: ledger.returned(forPart: row.partId)))
    }
    let people = Set(groupDebts.keys).union(groupParts.keys)
    let owedToMe = people.map { person in
      group(
        person, debts: (groupDebts[person] ?? []).sorted(by: byName),
        parts: groupParts[person] ?? [])
    }.sorted(by: largestFirst)

    let payments = DebtLoad.monthlyPayments(of: debts, rubPerUnit: rubPerUnit, dues: states)
    let unconverted = open.filter { $0.balanceRub == nil }.map(\.debt.id)
    return DebtsOverview(
      iOwe: iOwe, owedToMe: owedToMe, closed: closed,
      totalIOweRub: AmountE4.sum(iOwe.compactMap(\.balanceRub)),
      totalOwedToMeRub: AmountE4.sum(owedToMe.map(\.totalRub)),
      monthlyPaymentsRub: payments.total,
      withoutRate: DebtRubles.sorted(Set(unconverted).union(payments.withoutRate)))
  }

  // MARK: - Pieces

  /// The schedule of a loan with a grace period, as its card tells it; `nil` for any other debt,
  /// and for one whose dues have no first day.
  static func schedule(
    of debt: Debt, journal: [DebtEntry], dues: DebtDueState, accrued: AmountE4, today: DateOnly,
    calendar: CalendarContext
  ) -> DebtScheduleSummary? {
    guard let grace = debt.grace, let firstDue = dues.firstDue, dues.paymentDay >= 1 else {
      return nil
    }
    let plan = DebtSchedulePlan.plan(
      debt: debt, journal: journal, firstDue: firstDue, paymentDay: dues.paymentDay,
      today: today, calendar: calendar)
    let current: AmountE4
    if let index = dues.firstUnpaidIndex {
      current = dues.amount(ofDue: index)
    } else {
      current = today < grace.mainFrom ? .zero : (plan.mainAmount ?? .zero)
    }
    return DebtScheduleSummary(
      phase: today < grace.mainFrom ? .grace : .main, current: current,
      mainFrom: grace.mainFrom, mainAmount: plan.mainAmount,
      drawnE4: DebtSchedulePlan.drawnE4(journal: journal, through: today, calendar: calendar),
      accruedInterestE4: accrued)
  }

  /// Parts come in the order of the ledger — by day — which is oldest first.
  static func group(
    _ personId: UUID?, debts: [DebtLine], parts: [OwedPartSummary]
  ) -> OwedToMeGroup {
    let total =
      AmountE4.sum(debts.compactMap(\.balanceRub)) + AmountE4.sum(parts.map(\.amountRub))
    let starts = debts.filter { $0.balance.raw > 0 }.compactMap { line in
      line.entries.compactMap(\.date).min()
    }
    let oldest = (parts.map(\.day) + starts).min()
    return OwedToMeGroup(
      personId: personId, debts: debts, parts: parts, totalRub: total, oldest: oldest)
  }

  /// Dated lines newest first, undated ones after them; among equals the later line of the
  /// journal first, since the journal is written in the order things happen.
  static func newestFirst(_ journal: [DebtEntry]) -> [DebtEntry] {
    journal.enumerated().sorted { left, right in
      switch (left.element.date, right.element.date) {
      case (let leftDate?, let rightDate?) where leftDate != rightDate:
        return leftDate > rightDate
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      default:
        return left.offset > right.offset
      }
    }.map(\.element)
  }

  static func nearestPaymentFirst(_ left: DebtLine, _ right: DebtLine) -> Bool {
    switch (left.nextPayment, right.nextPayment) {
    case (let leftDay?, let rightDay?) where leftDay != rightDay:
      return leftDay < rightDay
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    default:
      return byName(left, right)
    }
  }

  static func byName(_ left: DebtLine, _ right: DebtLine) -> Bool {
    if left.debt.name != right.debt.name { return left.debt.name < right.debt.name }
    return left.debt.id.uuidString < right.debt.id.uuidString
  }

  /// The largest total first; the group without a person last, as in the report of payments
  /// for others.
  static func largestFirst(_ left: OwedToMeGroup, _ right: OwedToMeGroup) -> Bool {
    if (left.personId == nil) != (right.personId == nil) { return right.personId == nil }
    if left.totalRub != right.totalRub { return left.totalRub > right.totalRub }
    return (left.personId?.uuidString ?? "") < (right.personId?.uuidString ?? "")
  }
}
