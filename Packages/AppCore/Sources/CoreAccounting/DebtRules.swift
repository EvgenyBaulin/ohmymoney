import CoreKit
import Foundation

/// What one kind of journal line does to the balance of a debt.
public enum DebtEntryEffect: Hashable, Sendable {
  /// Plus: the debt grows.
  case increases
  /// Minus: the debt shrinks.
  case decreases
  /// Either way — the caller decides and the sign is kept as given.
  case signed
}

/// Subtotal of one group of journal lines (`group_name`) inside a debt.
public struct DebtGroupTotal: Hashable, Sendable {
  public var groupName: String?
  public var totalE4: AmountE4
  public var count: Int

  public init(groupName: String?, totalE4: AmountE4, count: Int) {
    self.groupName = groupName
    self.totalE4 = totalE4
    self.count = count
  }
}

/// The expense a debt payment produces: it lives in the system Loans category, in the
/// subcategory of that debt, and starts out `neutral`.
public struct LoanExpense: Hashable, Sendable {
  public var debtId: UUID
  public var amountE4: AmountE4
  public var subcategoryId: UUID?
  public var quality: Quality
  public var qualitySource: QualitySource

  public init(
    debtId: UUID, amountE4: AmountE4, subcategoryId: UUID?, quality: Quality = .neutral,
    qualitySource: QualitySource = .category
  ) {
    self.debtId = debtId
    self.amountE4 = amountE4
    self.subcategoryId = subcategoryId
    self.quality = quality
    self.qualitySource = qualitySource
  }

  public var systemRole: SystemRole { .loans }
}

/// What one payment against a debt asks to be written: always a journal line, and an
/// expense only for the debts whose payments are expenses.
public struct DebtPaymentOutcome: Hashable, Sendable {
  public var entry: DebtEntry
  public var expense: LoanExpense?

  public init(entry: DebtEntry, expense: LoanExpense? = nil) {
    self.entry = entry
    self.expense = expense
  }

  public var isExpense: Bool { expense != nil }
  /// The journal line is negative, so the payment always reduces the balance by this.
  public var reducesBalanceByE4: AmountE4 { entry.amountE4.magnitude }
}

/// A debt that a third party paid off, with the money moving into another debt: the
/// first one is closed by a `transfer_out`, the second gains a `transfer_in`.
public struct DebtTransfer: Hashable, Sendable {
  public var out: DebtEntry
  public var into: DebtEntry
  /// `true` when the transfer covers everything that was left on the source debt.
  public var closesSource: Bool

  public init(out: DebtEntry, into: DebtEntry, closesSource: Bool) {
    self.out = out
    self.into = into
    self.closesSource = closesSource
  }
}

public enum DebtError: Error, Equatable, Sendable, CustomStringConvertible {
  case negativeAmount
  case shareOutOfRange
  case sameDebt
  /// A transfer of more than is left on the debt it comes from.
  case exceedsBalance

  public var description: String {
    switch self {
    case .negativeAmount: return "A debt entry needs an amount above zero."
    case .shareOutOfRange: return "A share has to be above zero and at most the whole amount."
    case .sameDebt: return "A debt cannot be transferred into itself."
    case .exceedsBalance: return "A transfer cannot move more than is left on the debt."
    }
  }
}

/// Debts and credits.
///
/// A journal line carries a signed amount: plus grows the debt, minus reduces it. The
/// balance of a debt is the sum of its lines, and the journal can be grouped, with a
/// subtotal per group.
///
/// Two kinds of debt, and the difference is the whole point:
///
/// * a debt I already had (`origin == .existing`, `paymentsAreExpenses == true`) — each
///   payment is an expense in the system Loans category and reduces the balance at the
///   same time, which is how I used to record credits;
/// * something bought on credit here (`origin == .purchase`,
///   `paymentsAreExpenses == false`) — the expense is recorded once, at the purchase, in
///   its own category, and the payments only reduce the balance. Counting them again
///   would be counting one purchase twice.
///
/// Balances never reach the overview or the analytics: they are not spending.
public enum DebtRules {

  // MARK: - Signs and balances

  public static func effect(of kind: DebtEntryKind) -> DebtEntryEffect {
    switch kind {
    case .borrowed, .transferIn: return .increases
    case .payment, .offset, .transferOut: return .decreases
    case .adjustment: return .signed
    }
  }

  /// Puts the sign of the kind on an amount the UI collected without one.
  public static func signedAmount(_ amount: AmountE4, for kind: DebtEntryKind) -> AmountE4 {
    switch effect(of: kind) {
    case .increases: return amount.magnitude
    case .decreases: return -amount.magnitude
    case .signed: return amount
    }
  }

  /// The balance left on a debt: plus means it is still owed.
  public static func balance(entries: some Sequence<DebtEntry>) -> AmountE4 {
    AmountE4.sum(entries.map(\.amountE4))
  }

  public static func balance(of debtId: UUID, entries: [DebtEntry]) -> AmountE4 {
    balance(entries: entries.filter { $0.debtId == debtId })
  }

  /// Subtotals per group, in the order the groups first appear in the journal.
  public static func groupTotals(entries: [DebtEntry]) -> [DebtGroupTotal] {
    var order: [String?] = []
    var totals: [String: AmountE4] = [:]
    var counts: [String: Int] = [:]
    let ungrouped = "\u{0}"
    for entry in entries {
      let key = entry.groupName ?? ungrouped
      if totals[key] == nil {
        order.append(entry.groupName)
        totals[key] = .zero
        counts[key] = 0
      }
      totals[key] = (totals[key] ?? .zero) + entry.amountE4
      counts[key] = (counts[key] ?? 0) + 1
    }
    return order.map { groupName in
      let key = groupName ?? ungrouped
      return DebtGroupTotal(
        groupName: groupName, totalE4: totals[key] ?? .zero, count: counts[key] ?? 0)
    }
  }

  /// Totals for the two lists of the Debts section, by direction.
  public static func balances(
    debts: [Debt], entries: [DebtEntry]
  ) -> [DebtDirection: AmountE4] {
    var byDebt: [UUID: AmountE4] = [:]
    for entry in entries {
      byDebt[entry.debtId] = (byDebt[entry.debtId] ?? .zero) + entry.amountE4
    }
    var totals: [DebtDirection: AmountE4] = [:]
    for debt in debts where !debt.closed {
      let balance = byDebt[debt.id] ?? .zero
      totals[debt.direction] = (totals[debt.direction] ?? .zero) + balance
    }
    return totals
  }

  // MARK: - A share of a full amount

  /// «The whole thing was 1 000 000 and my share is a half» — the amount of the line.
  public static func share(of fullAmount: AmountE4, share: Decimal) throws -> AmountE4 {
    guard share > 0, share <= 1 else { throw DebtError.shareOutOfRange }
    guard !fullAmount.isNegative else { throw DebtError.negativeAmount }
    return try AmountE4(decimal: fullAmount.decimal * share)
  }

  /// Builds a journal line, applying the sign of its kind. The group, the description and the
  /// note are kept without the spaces around them, and one of spaces alone is none: groups are
  /// told apart by their exact name, so «Техника » would make a second «Техника» with its own
  /// subtotal.
  public static func makeEntry(
    id: UUID = UUID(),
    debtId: UUID,
    kind: DebtEntryKind,
    amountE4: AmountE4,
    fullAmountE4: AmountE4? = nil,
    share: Decimal? = nil,
    date: DateOnly? = nil,
    groupName: String? = nil,
    description: String? = nil,
    transactionId: UUID? = nil,
    note: String? = nil,
    closesTerm: Bool = false
  ) -> DebtEntry {
    DebtEntry(
      id: id,
      debtId: debtId,
      groupName: cleaned(groupName),
      date: date,
      description: cleaned(description),
      fullAmountE4: fullAmountE4,
      share: share,
      amountE4: signedAmount(amountE4, for: kind),
      kind: kind,
      transactionId: transactionId,
      note: cleaned(note),
      closesTerm: closesTerm && kind == .payment)
  }

  /// A text as it is stored: without the spaces and line breaks around it, `nil` when nothing
  /// is left.
  public static func cleaned(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  /// A line for a share of a full amount: «full 1 000 000, share 1/2».
  public static func makeShareEntry(
    id: UUID = UUID(),
    debtId: UUID,
    kind: DebtEntryKind = .borrowed,
    fullAmountE4: AmountE4,
    share: Decimal,
    date: DateOnly? = nil,
    groupName: String? = nil,
    description: String? = nil,
    note: String? = nil
  ) throws -> DebtEntry {
    let amount = try self.share(of: fullAmountE4, share: share)
    return makeEntry(
      id: id, debtId: debtId, kind: kind, amountE4: amount, fullAmountE4: fullAmountE4,
      share: share, date: date, groupName: groupName, description: description, note: note)
  }

  // MARK: - Opening and growth

  /// The first line of a debt the Debts section creates: what is owed on the day it is
  /// written down.
  ///
  /// A debt that already existed (`origin == .existing`, «Долг, который уже был») brought
  /// its money before the app knew about it, so by default the line is a signed
  /// `adjustment`: it sets the balance, and no reconciliation reads it as money borrowed or
  /// lent inside its window. Only when the money really changes hands now
  /// (`moneyMovedNow`) is it a `borrowed` line, which the reconciliation counts. The same
  /// line serves both directions: on a debt owed to me a `borrowed` line is money I lent.
  public static func opening(
    of debt: Debt,
    balance: AmountE4,
    date: DateOnly? = nil,
    moneyMovedNow: Bool = false,
    description: String? = nil,
    entryId: UUID = UUID()
  ) throws -> DebtEntry {
    guard balance.raw > 0 else { throw DebtError.negativeAmount }
    return makeEntry(
      id: entryId, debtId: debt.id, kind: moneyMovedNow ? .borrowed : .adjustment,
      amountE4: balance, date: date, description: description)
  }

  /// «Add entry» when the debt grew without any money reaching me — interest, a fee, a
  /// share of a full amount («1 000 000, доля 1/2»): a positive `adjustment`, which moves
  /// the balance and never the reconciliation. Money actually borrowed is a `borrowed` line
  /// (`makeEntry` or `makeShareEntry` with their default kind).
  public static func growth(
    on debt: Debt,
    amountE4: AmountE4,
    fullAmountE4: AmountE4? = nil,
    share: Decimal? = nil,
    date: DateOnly? = nil,
    groupName: String? = nil,
    description: String? = nil,
    entryId: UUID = UUID()
  ) throws -> DebtEntry {
    let amount: AmountE4
    if let fullAmountE4, let share {
      amount = try self.share(of: fullAmountE4, share: share)
    } else {
      amount = amountE4
    }
    guard amount.raw > 0 else { throw DebtError.negativeAmount }
    return makeEntry(
      id: entryId, debtId: debt.id, kind: .adjustment, amountE4: amount,
      fullAmountE4: fullAmountE4, share: share, date: date, groupName: groupName,
      description: description)
  }

  // MARK: - Payments and purchases

  /// The default of `payments_are_expenses` for a debt: a debt I already had records its
  /// payments as expenses, a purchase made here does not.
  public static func defaultPaymentsAreExpenses(for origin: DebtOrigin) -> Bool {
    origin == .existing
  }

  /// Is the purchase itself an expense? It is, unless the debt records its payments as
  /// expenses instead: exactly one of the two sides counts, so one purchase is an expense
  /// exactly once.
  ///
  /// It used to answer `debt.origin == .purchase`, which ignored the «payments are
  /// expenses» switch of the debt card: with the switch on, a purchase made in
  /// instalments was counted at the purchase *and* again at every payment.
  public static func purchaseIsExpense(on debt: Debt) -> Bool {
    !paymentIsExpense(on: debt)
  }

  /// A payment is an expense only on a debt I owe. On the other side of the section a
  /// payment is money coming back to me, and money coming back is never spending — the
  /// model creates such a debt with `paymentsAreExpenses == true` all the same.
  public static func paymentIsExpense(on debt: Debt) -> Bool {
    debt.paymentsAreExpenses && debt.direction == .iOwe
  }

  /// One payment against a debt. It always reduces the balance; it is also an expense in
  /// Loans when the debt records its payments that way. Never both an expense here and
  /// an expense at the purchase: one purchase is an expense exactly once.
  ///
  /// With `closesTerm` — «в этом месяце больше платежей не будет» — the line says the due the
  /// payment was made for is closed although the payment is smaller than the monthly one
  /// (`DebtDues`).
  public static func payment(
    on debt: Debt,
    amountE4: AmountE4,
    date: DateOnly? = nil,
    transactionId: UUID? = nil,
    groupName: String? = nil,
    description: String? = nil,
    closesTerm: Bool = false,
    entryId: UUID = UUID()
  ) throws -> DebtPaymentOutcome {
    guard amountE4.raw > 0 else { throw DebtError.negativeAmount }
    let entry = makeEntry(
      id: entryId, debtId: debt.id, kind: .payment, amountE4: amountE4, date: date,
      groupName: groupName, description: description, transactionId: transactionId,
      closesTerm: closesTerm)
    guard paymentIsExpense(on: debt) else { return DebtPaymentOutcome(entry: entry) }
    let expense = LoanExpense(
      debtId: debt.id, amountE4: amountE4.magnitude, subcategoryId: debt.loansSubcategoryId)
    return DebtPaymentOutcome(entry: entry, expense: expense)
  }

  /// I paid something for the creditor, so the debt shrinks without a payment.
  public static func offset(
    on debt: Debt,
    amountE4: AmountE4,
    date: DateOnly? = nil,
    transactionId: UUID? = nil,
    groupName: String? = nil,
    description: String? = nil,
    entryId: UUID = UUID()
  ) throws -> DebtEntry {
    guard amountE4.raw > 0 else { throw DebtError.negativeAmount }
    return makeEntry(
      id: entryId, debtId: debt.id, kind: .offset, amountE4: amountE4, date: date,
      groupName: groupName, description: description, transactionId: transactionId)
  }

  /// The opening line of something bought on credit: the debt starts at the price of the
  /// purchase. The expense of that purchase is the operation itself, in its own category.
  public static func creditPurchaseOpening(
    on debt: Debt,
    amountE4: AmountE4,
    date: DateOnly? = nil,
    transactionId: UUID? = nil,
    description: String? = nil,
    entryId: UUID = UUID()
  ) throws -> DebtEntry {
    guard amountE4.raw > 0 else { throw DebtError.negativeAmount }
    return makeEntry(
      id: entryId, debtId: debt.id, kind: .borrowed, amountE4: amountE4, date: date,
      description: description, transactionId: transactionId)
  }

  // MARK: - What is no payment, and a due the bank took before a count

  /// The operations that point at a debt without paying it: the journal wrote them as an
  /// `offset` («Offset») or as more `borrowed` (money taken or lent more through the entry
  /// line). Every rule that asks whether a debt was paid leaves them out.
  public static func notPayments(_ journal: some Sequence<DebtEntry>) -> Set<UUID> {
    Set(
      journal.lazy.filter { $0.kind == .offset || $0.kind == .borrowed }
        .compactMap(\.transactionId))
  }

  /// «Уже списано до сверки» of a debt's due date: the bank took the monthly payment before a
  /// count of the account, so the count already holds that money gone. A `payment` line of
  /// min(monthly payment, balance) dated the due date, with no operation and no account: it
  /// lowers the balance and closes the earliest unpaid due like any payment, and moves no money
  /// on any account — only `borrowed` lines without an operation do. `nil` when nothing is left
  /// on the debt or it has no monthly payment — or, for a debt whose dues have sums of their own
  /// (a grace period, a main payment worked out over months), no `owed` was given.
  ///
  /// A due paid in part is taken for what is left of it: `owed` is that rest, never more than
  /// the monthly payment, and the line pays it. The line says the due is closed either way.
  public static func settledByCount(
    debt: Debt, due: DateOnly, balance: AmountE4, owed: AmountE4? = nil, entryId: UUID = UUID()
  ) -> DebtEntry? {
    guard balance.raw > 0 else { return nil }
    let rest: AmountE4
    if let monthly = debt.monthlyPaymentE4, monthly.raw > 0,
      debt.grace == nil, debt.repayMonths == nil
    {
      rest = min(monthly, owed ?? monthly)
    } else if debt.hasDues, let owed {
      // A due of its own sum — of a grace period, of a worked out main payment —: the rest of it.
      rest = owed
    } else {
      return nil
    }
    guard rest.raw > 0 else { return nil }
    return makeEntry(
      id: entryId, debtId: debt.id, kind: .payment, amountE4: min(rest, balance), date: due,
      closesTerm: true)
  }

  // MARK: - Transfer

  /// A third party paid off one debt and the amount moved into another one. Two lines
  /// come out of it: the source always loses the money; the destination gains it when it
  /// runs the same way, and loses it when it runs the other way.
  ///
  /// * Same direction: Petya paid my bank loan, so now I owe Petya (`transfer_in`, +).
  /// * Across directions: Anna, who owes me, paid my bank loan — what she owes me shrinks
  ///   by the same amount (`transfer_out`, −). The other way round, Anna paid what she owed
  ///   me to Petya, whom I owe: both debts shrink.
  ///
  /// `sourceBalanceE4` is what was left on the source before the transfer; without it the
  /// transfer is taken to close the source, which is what the action is for. With it, more
  /// than is left is refused (`exceedsBalance`): the source would close with money on it
  /// that nobody is going to pay.
  public static func transfer(
    from source: Debt,
    to destination: Debt,
    amountE4: AmountE4,
    sourceBalanceE4: AmountE4? = nil,
    date: DateOnly? = nil,
    groupName: String? = nil,
    description: String? = nil,
    note: String? = nil,
    outId: UUID = UUID(),
    intoId: UUID = UUID()
  ) throws -> DebtTransfer {
    guard amountE4.raw > 0 else { throw DebtError.negativeAmount }
    guard source.id != destination.id else { throw DebtError.sameDebt }
    if let sourceBalanceE4, amountE4 > sourceBalanceE4 { throw DebtError.exceedsBalance }
    let out = makeEntry(
      id: outId, debtId: source.id, kind: .transferOut, amountE4: amountE4, date: date,
      groupName: groupName, description: description, note: note)
    let into = makeEntry(
      id: intoId, debtId: destination.id,
      kind: source.direction == destination.direction ? .transferIn : .transferOut,
      amountE4: amountE4, date: date, groupName: groupName, description: description, note: note)
    let closes: Bool
    if let sourceBalanceE4 {
      closes = (sourceBalanceE4 + out.amountE4).raw <= 0
    } else {
      closes = true
    }
    return DebtTransfer(out: out, into: into, closesSource: closes)
  }
}
