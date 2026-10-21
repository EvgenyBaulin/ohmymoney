import CoreAccounting
import CoreKit
import Foundation

/// One movement of money on a credit card, in the main currency of its account.
public struct CreditMovement: Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    /// Spending charged to the card.
    case purchase
    /// Cash taken or money transferred from the card: no grace period when the terms say so.
    case cashLike
    /// Money paid onto the card.
    case payment
  }

  public var id: UUID
  public var day: DateOnly
  public var at: Date
  /// Signed: plus pays into the card, minus is charged to it.
  public var amountE4: AmountE4
  public var kind: Kind
  /// The fee of a transfer the owner recorded (`transfer:<id>:fee`): the bank's own fee is in
  /// the books, so none is estimated for it.
  public var isFee: Bool
  /// A transfer whose fee the owner recorded: no fee is estimated for it either.
  public var hasRecordedFee: Bool

  public init(
    id: UUID, day: DateOnly, at: Date, amountE4: AmountE4, kind: Kind, isFee: Bool = false,
    hasRecordedFee: Bool = false
  ) {
    self.id = id
    self.day = day
    self.at = at
    self.amountE4 = amountE4
    self.kind = kind
    self.isFee = isFee
    self.hasRecordedFee = hasRecordedFee
  }
}

/// One statement of a credit card: its period, the debt it closes on, and whether it was paid in
/// full by its due day.
public struct CreditStatement: Hashable, Sendable {
  public enum State: String, Hashable, Sendable {
    /// The due day has not passed and the statement is not paid in full.
    case waiting
    case paidInFull
    case missed
  }

  /// The period is (`periodAfter`, `closesOn`].
  public var periodAfter: DateOnly
  /// The statement day.
  public var closesOn: DateOnly
  /// The day the statement is to be paid by.
  public var due: DateOnly
  /// The debt at the end of the statement day, never below zero.
  public var debtE4: AmountE4
  public var purchasesE4: AmountE4
  public var cashLikeE4: AmountE4
  public var minimumE4: AmountE4
  /// What was paid in (`closesOn`, `due`].
  public var paidByDueE4: AmountE4
  public var state: State

  public init(
    periodAfter: DateOnly, closesOn: DateOnly, due: DateOnly, debtE4: AmountE4,
    purchasesE4: AmountE4, cashLikeE4: AmountE4, minimumE4: AmountE4, paidByDueE4: AmountE4,
    state: State
  ) {
    self.periodAfter = periodAfter
    self.closesOn = closesOn
    self.due = due
    self.debtE4 = debtE4
    self.purchasesE4 = purchasesE4
    self.cashLikeE4 = cashLikeE4
    self.minimumE4 = minimumE4
    self.paidByDueE4 = paidByDueE4
    self.state = state
  }

  /// What is still to pay of the statement not to pay interest: its debt less what came by the
  /// due day, never below zero.
  public var remainingE4: AmountE4 {
    let left = debtE4 - paidByDueE4
    return left.raw > 0 ? left : .zero
  }

  /// Whether `day` is inside the period of the statement.
  public func holds(_ day: DateOnly) -> Bool { periodAfter < day && day <= closesOn }
}

/// A credit card today, as the screen of its account shows it.
public struct CreditCardNow: Hashable, Sendable {
  /// The limit plus the balance.
  public var availableE4: AmountE4
  public var debtE4: AmountE4
  /// What to pay by `payBy` not to pay interest.
  public var toPayNoInterestE4: AmountE4
  public var minimumE4: AmountE4?
  public var payBy: DateOnly?
  public var nextStatement: DateOnly?
  /// The grace period still holds.
  public var graceKept: Bool
  /// The interest the card will likely charge: an estimate, never money.
  public var estimate: CreditInterestEstimate?

  public init(
    availableE4: AmountE4 = .zero, debtE4: AmountE4 = .zero,
    toPayNoInterestE4: AmountE4 = .zero, minimumE4: AmountE4? = nil, payBy: DateOnly? = nil,
    nextStatement: DateOnly? = nil, graceKept: Bool = true,
    estimate: CreditInterestEstimate? = nil
  ) {
    self.availableE4 = availableE4
    self.debtE4 = debtE4
    self.toPayNoInterestE4 = toPayNoInterestE4
    self.minimumE4 = minimumE4
    self.payBy = payBy
    self.nextStatement = nextStatement
    self.graceKept = graceKept
    self.estimate = estimate
  }
}

/// The statements of a credit card worked out from its movements, as a bank like Т-Банк makes
/// them: every month on the statement day (31 — the last day of the month) the debt at the end
/// of that day is to be paid within the days the terms give. Only the main currency of the
/// account counts, and only from the first count of it: before a balance there is no debt to
/// speak of.
public enum CreditStatements {
  /// The money that moved on the main currency of `account`, oldest first: spending charged to
  /// it (a purchase), money sent from it to another account or currency (cash-like — taking
  /// cash is a transfer to «Наличные», paying a person a transfer too), and money that came onto
  /// it (a payment: income, a refund, a transfer in). The fee of a transfer the owner recorded
  /// is cash-like money of its own.
  public static func movements(
    account: PaymentMethod, ledger: Ledger, transfers: [Transfer]
  ) -> [CreditMovement] {
    let key = BalanceKey(accountId: account.id, currency: account.mainCurrency)
    let dataset = ledger.dataset
    let calendar = ledger.calendar
    let mainId = dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id
    var result: [CreditMovement] = []
    var feeOf: Set<UUID> = []
    for entry in dataset.entries {
      guard let moved = AccountBalances.movement(of: entry, mainId: mainId, tree: ledger.tree),
        moved.key == key, !moved.amountE4.isZero
      else { continue }
      var isFee = false
      if case .transferFee(let transferId) = OperationLink(
        externalId: entry.transaction.externalId)
      {
        isFee = true
        feeOf.insert(transferId)
      }
      let kind: CreditMovement.Kind =
        moved.amountE4.raw > 0 ? .payment : isFee ? .cashLike : .purchase
      result.append(
        CreditMovement(
          id: entry.id, day: calendar.day(of: moved.at), at: moved.at, amountE4: moved.amountE4,
          kind: kind, isFee: isFee && kind == .cashLike))
    }
    for transfer in transfers {
      let day = calendar.day(of: transfer.occurredAt)
      if transfer.from == key, !transfer.fromAmountE4.isZero {
        result.append(
          CreditMovement(
            id: transfer.id, day: day, at: transfer.occurredAt, amountE4: -transfer.fromAmountE4,
            kind: .cashLike, hasRecordedFee: feeOf.contains(transfer.id)))
      }
      if transfer.to == key, !transfer.toAmountE4.isZero {
        result.append(
          CreditMovement(
            id: transfer.id, day: day, at: transfer.occurredAt, amountE4: transfer.toAmountE4,
            kind: .payment))
      }
    }
    return result.sorted(by: oldestFirst)
  }

  /// `movements` with the money the first count of the card says was there: a count is the
  /// truth, so what the movements before it do not explain is a movement of its own at the
  /// moment of the count — a debt that was already there is a purchase of that moment, money
  /// already on the card a payment. Nothing is added when the movements agree with the count,
  /// or when the card was never counted.
  public static func withOpening(
    _ movements: [CreditMovement], account: PaymentMethod, balances: AccountBalances,
    calendar: CalendarContext
  ) -> [CreditMovement] {
    let key = BalanceKey(accountId: account.id, currency: account.mainCurrency)
    guard let first = balances.anchors(key).first,
      let counted = balances.balance(key, at: first.at)
    else { return movements }
    let before = AmountE4.sum(movements.filter { $0.at <= first.at }.map(\.amountE4))
    let gap = counted - before
    guard !gap.isZero else { return movements }
    let opening = CreditMovement(
      id: first.balance.id, day: calendar.day(of: first.at), at: first.at, amountE4: gap,
      kind: gap.raw < 0 ? .purchase : .payment)
    return (movements + [opening]).sorted(by: oldestFirst)
  }

  public static func statements(
    account: PaymentMethod, terms: CreditCardTerms, movements: [CreditMovement],
    balances: AccountBalances, through today: DateOnly, calendar: CalendarContext
  ) -> [CreditStatement] {
    guard case .statement(let statementDay, let payDays) = terms.grace else { return [] }
    let key = BalanceKey(accountId: account.id, currency: account.mainCurrency)
    guard let first = balances.anchors(key).first else { return [] }
    let counted = calendar.day(of: first.at)
    var result: [CreditStatement] = []
    var month = counted.monthKey
    while month.firstDay <= today {
      let closes = day(statementDay, in: month, calendar: calendar)
      month = month.next
      guard closes > counted, closes <= today else { continue }
      let after = day(statementDay, in: closes.monthKey.previous, calendar: calendar)
      let due = calendar.adding(days: payDays, to: closes)
      let owed = -(balances.balance(key, at: calendar.endOfDay(closes)) ?? .zero)
      let debt = owed.raw > 0 ? owed : .zero
      let inPeriod = movements.filter { after < $0.day && $0.day <= closes }
      let purchases = AmountE4.sum(
        inPeriod.filter { $0.kind == .purchase }.map(\.amountE4.magnitude))
      let cash = AmountE4.sum(inPeriod.filter { $0.kind == .cashLike }.map(\.amountE4.magnitude))
      let paid = AmountE4.sum(
        movements.filter { $0.kind == .payment && closes < $0.day && $0.day <= due }
          .map(\.amountE4))
      let state: CreditStatement.State =
        debt.isZero || paid >= debt ? .paidInFull : due >= today ? .waiting : .missed
      result.append(
        CreditStatement(
          periodAfter: after, closesOn: closes, due: due, debtE4: debt, purchasesE4: purchases,
          cashLikeE4: cash, minimumE4: minimum(debt: debt, terms: terms) ?? .zero,
          paidByDueE4: paid, state: state))
    }
    return result
  }

  /// max(floor, percent × debt) to the kopeck, not above the debt; no percent — the floor;
  /// neither — `nil`.
  public static func minimum(debt: AmountE4, terms: CreditCardTerms) -> AmountE4? {
    guard terms.minPercent != nil || terms.minFloorE4 != nil else { return nil }
    guard debt.raw > 0 else { return .zero }
    var value = terms.minPercent.map { InterestMath.cents(debt.decimal * $0 / 100) } ?? .zero
    if let floor = terms.minFloorE4, floor > value { value = floor }
    return min(value, debt)
  }

  /// The card today: available money, the debt and what to pay by when.
  ///
  /// With a statement every month: while the latest statement waits for its due day, it says
  /// what to pay by then — what is left of its debt — and the minimum payment left of it. Once a
  /// statement was missed the grace period is lost until a statement is paid in full in time:
  /// the whole debt is what stops the interest. With days from the first purchase, the whole
  /// debt is due that many days after the oldest purchase not yet repaid. `estimate` is the
  /// interest likely charged at the next statement (or by today, for days from a purchase),
  /// when there is any.
  public static func now(
    account: PaymentMethod, terms: CreditCardTerms, statements: [CreditStatement],
    movements: [CreditMovement], balances: AccountBalances, today: DateOnly,
    calendar: CalendarContext
  ) -> CreditCardNow {
    let key = BalanceKey(accountId: account.id, currency: account.mainCurrency)
    let balance = balances[key]?.amountE4 ?? .zero
    let debt = balance.raw < 0 ? -balance : .zero
    var card = CreditCardNow(availableE4: terms.limitE4 + balance, debtE4: debt)
    let all = withOpening(movements, account: account, balances: balances, calendar: calendar)
    let estimates = CreditInterest.estimates(
      terms: terms, statements: statements, movements: all, recorded: [:], through: today)

    switch terms.grace {
    case .statement(let statementDay, _):
      card.nextStatement = nextStatementDay(after: today, day: statementDay, calendar: calendar)
      card.graceKept = CreditInterest.graceKept(statements)
      if let last = statements.last, last.state == .waiting {
        card.toPayNoInterestE4 = last.remainingE4
        card.payBy = last.due
        card.minimumE4 = minimum(debt: last.debtE4, terms: terms).map {
          let left = $0 - last.paidByDueE4
          return left.raw > 0 ? left : .zero
        }
      } else if !card.graceKept, debt.raw > 0 {
        card.toPayNoInterestE4 = debt
        card.minimumE4 = minimum(debt: debt, terms: terms)
      }
      card.estimate = estimates.first { $0.statementDay == card.nextStatement }
    case .fromPurchase(let days):
      if let oldest = CreditInterest.lots(all).filter({ !$0.repaid(by: today) }).map(\.day).min() {
        let payBy = calendar.adding(days: days, to: oldest)
        card.payBy = payBy
        card.graceKept = payBy >= today
        card.toPayNoInterestE4 = debt
        card.minimumE4 = minimum(debt: debt, terms: terms)
      }
      card.estimate = estimates.first { $0.statementDay == today }
    }
    if let estimate = card.estimate, estimate.shownE4.isZero { card.estimate = nil }
    return card
  }

  // MARK: Days

  /// The statement day of `month`: `day`, or the last day of a month that has no such day.
  public static func day(_ day: Int, in month: MonthKey, calendar: CalendarContext) -> DateOnly {
    DateOnly(year: month.year, month: month.month, day: min(day, calendar.daysInMonth(month)))
  }

  /// The first statement day after `today`.
  public static func nextStatementDay(
    after today: DateOnly, day statementDay: Int, calendar: CalendarContext
  ) -> DateOnly {
    let this = day(statementDay, in: today.monthKey, calendar: calendar)
    return this > today ? this : day(statementDay, in: today.monthKey.next, calendar: calendar)
  }

  static func oldestFirst(_ left: CreditMovement, _ right: CreditMovement) -> Bool {
    if left.at != right.at { return left.at < right.at }
    if left.kind != right.kind { return left.kind == .payment }
    return left.id.uuidString < right.id.uuidString
  }
}
