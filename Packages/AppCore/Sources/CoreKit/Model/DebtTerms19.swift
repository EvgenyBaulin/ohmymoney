import Foundation

/// Dues every `everyDays` days from `firstDue` — an instalment plan paid every two weeks —
/// instead of on a day of every month.
public struct DebtSteps: Hashable, Sendable, Codable {
  public var everyDays: Int
  public var firstDue: DateOnly

  public init(everyDays: Int, firstDue: DateOnly) {
    self.everyDays = everyDays
    self.firstDue = firstDue
  }

  /// The days a step may take, as the schema keeps them.
  public static let range = 1...366
}

/// An early repayment the owner plans: the day and the sum. Not money — only a reminder to file
/// the application, and a step of the payoff ladder.
public struct PlannedPrepay: Hashable, Sendable, Codable {
  public var day: DateOnly
  public var amountE4: AmountE4

  public init(day: DateOnly, amountE4: AmountE4) {
    self.day = day
    self.amountE4 = amountE4
  }
}

/// What the owner chose for a payment above its due: a shorter term or a smaller payment — an
/// early repayment, whose money above the due lowers the debt alone —, or the next dues paid
/// ahead (`forward`), whose money is kept toward them as every payment before 1.9 was.
public enum PrepayChoice: String, Hashable, Sendable, Codable, CaseIterable {
  case term
  case payment
  case forward

  /// A shorter term or a smaller payment: the money above the due goes to the principal and
  /// pays no later due. `forward` is not one — it is a payment of the dues ahead.
  public var isEarlyRepayment: Bool { self != .forward }
}

/// What a due asks for, typed from the bank's app: from due `fromIndex` (0 the first) on, until
/// the next step of either kind (`debt_instalments`).
public struct DebtInstalmentStep: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var debtId: UUID
  public var fromIndex: Int
  public var amountE4: AmountE4

  public init(id: UUID = UUID(), debtId: UUID, fromIndex: Int, amountE4: AmountE4) {
    self.id = id
    self.debtId = debtId
    self.fromIndex = fromIndex
    self.amountE4 = amountE4
  }
}

/// What else a loan costs besides its interest.
public enum DebtCostKind: String, Hashable, Sendable, Codable, CaseIterable {
  case fee
  case insurance
  case other
}

/// How often a cost of a loan is paid, from its day.
public enum DebtCostEvery: String, Hashable, Sendable, Codable, CaseIterable {
  case once
  case monthly
  case yearly
}

/// A cost of a loan (`debt_costs`): a fee for issuing it, insurance, anything else.
public struct DebtCost: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var debtId: UUID
  public var kind: DebtCostKind
  public var name: String?
  public var amountE4: AmountE4
  public var every: DebtCostEvery
  public var day: DateOnly
  /// Held back from the money the bank gave; only a cost paid once is.
  public var inLoan: Bool
  /// The expense written for a cost paid once; `nil` — none.
  public var transactionId: UUID?
  public var sort: Int

  public init(
    id: UUID = UUID(), debtId: UUID, kind: DebtCostKind = .other, name: String? = nil,
    amountE4: AmountE4, every: DebtCostEvery = .once, day: DateOnly, inLoan: Bool = false,
    transactionId: UUID? = nil, sort: Int = 0
  ) {
    self.id = id
    self.debtId = debtId
    self.kind = kind
    self.name = name
    self.amountE4 = amountE4
    self.every = every
    self.day = day
    self.inLoan = inLoan
    self.transactionId = transactionId
    self.sort = sort
  }
}
