import Foundation

/// The grace period of a loan — an education loan, typically: until `mainFrom` each due is the
/// grace payment, from it on the main one (`Debt.monthlyPaymentE4`, or the annuity over
/// `Debt.repayMonths`).
public struct DebtGrace: Hashable, Sendable, Codable {
  /// The first day of the main schedule: a due on it or after it is a main one.
  public var mainFrom: DateOnly
  public var payment: GracePayment

  public init(mainFrom: DateOnly, payment: GracePayment) {
    self.mainFrom = mainFrom
    self.payment = payment
  }
}

/// What a due of the grace period asks for.
public enum GracePayment: Hashable, Sendable, Codable {
  /// The interest on the money drawn so far, over the days since the due before — needs the
  /// rate of the debt.
  case interest
  /// The state education-loan programme: a share of that interest by year of the loan, counted
  /// from the first tranche — 40 % in the first year, 60 % in the second, all of it from the
  /// third (`interestShare(inLoanYear:)`). The share not paid is not forgiven: it joins the principal when
  /// the main schedule starts. Needs the rate of the debt.
  case programme
  /// The same sum every month.
  case fixed(AmountE4)

  /// The word the database keeps (`debts.grace_kind`).
  public var storedKind: String {
    switch self {
    case .interest: "interest"
    case .programme: "programme"
    case .fixed: "fixed"
    }
  }

  /// The share of the accrued interest a grace due asks for in year `loanYear` of the loan (1 the
  /// year from the first tranche): all of it for `.interest`, 40 %, 60 %, then all of it for
  /// `.programme`; `nil` for a fixed sum.
  public func interestShare(inLoanYear loanYear: Int) -> Decimal? {
    switch self {
    case .interest: return 1
    case .programme:
      if loanYear <= 1 { return Decimal(4) / 10 }
      if loanYear == 2 { return Decimal(6) / 10 }
      return 1
    case .fixed: return nil
    }
  }

  /// The fixed sum, when it is one (`debts.grace_payment_e4`).
  public var fixedAmount: AmountE4? {
    if case .fixed(let amount) = self { return amount }
    return nil
  }

  /// The payment a stored kind and sum say; `nil` for a word that is not one, and for a fixed
  /// payment without a sum above zero.
  public init?(storedKind: String?, amount: AmountE4?) {
    switch storedKind {
    case "interest": self = .interest
    case "programme": self = .programme
    case "fixed":
      guard let amount, amount.raw > 0 else { return nil }
      self = .fixed(amount)
    default: return nil
    }
  }
}

/// How often a deposit or a savings account pays its interest.
public enum InterestPeriod: String, Hashable, Sendable, Codable, CaseIterable {
  case monthly
  case quarterly
  /// Once, on the day the deposit ends.
  case atEnd = "end"
}

/// What a bank counts the interest of a savings account on.
public enum InterestBase: String, Hashable, Sendable, Codable, CaseIterable {
  /// The balance at the end of each day.
  case daily
  /// The lowest balance of the month: money taken out for a day lowers the interest of all of it.
  case minBalance = "min_balance"
}

/// The interest an account earns: a deposit (with an end) or a savings account (without one).
/// Interest is worked out on the balance of each day in the account's main currency; it is never
/// stored — only the income the owner records is.
public struct DepositTerms: Hashable, Sendable, Codable {
  /// The yearly rate, in percent: 16 is 16 %.
  public var rate: Decimal
  public var period: InterestPeriod
  /// The day of the month it is paid on (1…31, 31 is the end of any month); `nil` — the day the
  /// deposit was opened, else the last day of the month. Never with `.atEnd`.
  public var day: Int?
  /// The account the interest is paid to; `nil` — to the account itself, where it earns
  /// interest in turn.
  public var payoutAccountId: UUID?
  public var openedOn: DateOnly?
  /// The day the deposit ends; `nil` — a savings account. Interest paid at the end needs one.
  public var endsOn: DateOnly?
  /// What the interest is counted on; the balance of each day unless the bank says otherwise.
  public var base: InterestBase
  /// The rate the bank has announced and the first day it holds; from that day the interest is
  /// worked out at it. Both or neither.
  public var nextRate: Decimal?
  public var nextRateOn: DateOnly?

  public init(
    rate: Decimal, period: InterestPeriod, day: Int? = nil, payoutAccountId: UUID? = nil,
    openedOn: DateOnly? = nil, endsOn: DateOnly? = nil, base: InterestBase = .daily,
    nextRate: Decimal? = nil, nextRateOn: DateOnly? = nil
  ) {
    self.rate = rate
    self.period = period
    self.day = day
    self.payoutAccountId = payoutAccountId
    self.openedOn = openedOn
    self.endsOn = endsOn
    self.base = base
    self.nextRate = nextRate
    self.nextRateOn = nextRateOn
  }

  enum CodingKeys: String, CodingKey {
    case rate, period, day, payoutAccountId, openedOn, endsOn, base, nextRate, nextRateOn
  }

  /// Terms written before the base and the next rate existed read without them.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      rate: try container.decode(Decimal.self, forKey: .rate),
      period: try container.decode(InterestPeriod.self, forKey: .period),
      day: try container.decodeIfPresent(Int.self, forKey: .day),
      payoutAccountId: try container.decodeIfPresent(UUID.self, forKey: .payoutAccountId),
      openedOn: try container.decodeIfPresent(DateOnly.self, forKey: .openedOn),
      endsOn: try container.decodeIfPresent(DateOnly.self, forKey: .endsOn),
      base: try container.decodeIfPresent(InterestBase.self, forKey: .base) ?? .daily,
      nextRate: try container.decodeIfPresent(Decimal.self, forKey: .nextRate),
      nextRateOn: try container.decodeIfPresent(DateOnly.self, forKey: .nextRateOn))
  }

  /// Whether the interest joins the balance it was earned on.
  public var capitalizes: Bool { payoutAccountId == nil }

  /// The rate that holds on `day`: the announced one from its day on, the current one before.
  public func rate(on day: DateOnly) -> Decimal {
    if let nextRate, let nextRateOn, day >= nextRateOn { return nextRate }
    return rate
  }
}
