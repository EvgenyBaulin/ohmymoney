import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// An account whose balance stands below what the bank asks to keep.
public struct MinBalanceRisk: Hashable, Sendable, Identifiable {
  public var accountId: UUID
  public var currency: CurrencyCode
  public var balanceE4: AmountE4
  public var minimumE4: AmountE4

  public init(accountId: UUID, currency: CurrencyCode, balanceE4: AmountE4, minimumE4: AmountE4) {
    self.accountId = accountId
    self.currency = currency
    self.balanceE4 = balanceE4
    self.minimumE4 = minimumE4
  }

  public var id: UUID { accountId }
  public var shortE4: AmountE4 { minimumE4 - balanceE4 }
}

/// A line of «Стоит посмотреть» about the conditions of banks.
public enum BankNote: Hashable, Sendable, Identifiable {
  /// A free limit is close to used up.
  case limitNear(accountId: UUID, kind: BankLimitKind, leftE4: AmountE4, currency: CurrencyCode)
  /// A free limit is used up or passed; `overE4` is what went beyond it.
  case limitExceeded(
    accountId: UUID, kind: BankLimitKind, overE4: AmountE4, currency: CurrencyCode)
  /// The balance is below the minimum the bank asks to keep.
  case minBalanceBelow(
    accountId: UUID, balanceE4: AmountE4, minimumE4: AmountE4, currency: CurrencyCode)
  /// A card stops working at the end of `expiresOn`, or has stopped.
  case cardExpiry(
    accountId: UUID, cardId: UUID, expiresOn: MonthKey, expired: Bool, attachedCount: Int)
  /// Products nothing has moved on, with money or a charge on them.
  case forgotten(count: Int, balanceRub: AmountE4, month: MonthKey)
  /// All the money of a bank is above the insurance limit.
  case insuranceOver(bankId: UUID, name: String, totalRub: AmountE4, limitRub: AmountE4)

  /// The key «Готово» puts the line away by.
  public var id: String {
    switch self {
    case .limitNear(let account, let kind, _, _):
      "bankLimitNear:\(account.uuidString):\(kind.rawValue)"
    case .limitExceeded(let account, let kind, _, _):
      "bankLimitOver:\(account.uuidString):\(kind.rawValue)"
    case .minBalanceBelow(let account, _, _, _): "bankMinBalance:\(account.uuidString)"
    case .cardExpiry(_, let card, let month, _, _): "cardExpiry:\(card.uuidString):\(month.iso)"
    case .forgotten(_, _, let month): "bankForgotten:\(month.iso)"
    case .insuranceOver(let bank, _, _, _): "bankInsurance:\(bank.uuidString)"
    }
  }

  /// A line that cannot wait: the owner is paying or about to.
  public var isAlarm: Bool {
    switch self {
    case .limitExceeded, .minBalanceBelow: true
    default: false
    }
  }

  /// Whether «Готово» puts the line away: a limit or a balance below the minimum stays until the
  /// month ends or the balance is back.
  public var canBePutAway: Bool {
    switch self {
    case .cardExpiry, .forgotten, .insuranceOver: true
    case .limitNear, .limitExceeded, .minBalanceBelow: false
    }
  }
}

/// Everything the conditions of the banks say today, worked out once for the screens.
public struct BankReport: Hashable, Sendable {
  public var today: DateOnly
  public var limits: [BankLimitLine]
  public var service: [BankServiceProgress]
  public var minBalance: [MinBalanceRisk]
  /// Every bank with money in it, the largest first.
  public var insurance: [BankInsurance]
  public var forgotten: [ForgottenProduct]
  public var cardExpiries: [CardExpiry]

  public init(
    today: DateOnly, limits: [BankLimitLine] = [], service: [BankServiceProgress] = [],
    minBalance: [MinBalanceRisk] = [], insurance: [BankInsurance] = [],
    forgotten: [ForgottenProduct] = [], cardExpiries: [CardExpiry] = []
  ) {
    self.today = today
    self.limits = limits
    self.service = service
    self.minBalance = minBalance
    self.insurance = insurance
    self.forgotten = forgotten
    self.cardExpiries = cardExpiries
  }

  public static let empty = BankReport(today: DateOnly(year: 2000, month: 1, day: 1))

  public func limits(of accountId: UUID) -> [BankLimitLine] {
    limits.filter { $0.accountId == accountId }
  }

  public func service(of accountId: UUID) -> BankServiceProgress? {
    service.first { $0.accountId == accountId }
  }

  public func minBalanceRisk(of accountId: UUID) -> MinBalanceRisk? {
    minBalance.first { $0.accountId == accountId }
  }

  public func insurance(of bankId: UUID) -> BankInsurance? {
    insurance.first { $0.bankId == bankId }
  }

  public var isEmpty: Bool {
    limits.isEmpty && service.isEmpty && minBalance.isEmpty && forgotten.isEmpty
      && cardExpiries.isEmpty && !insurance.contains { $0.isOver }
  }

  // MARK: - Build

  public static func build(
    ledger: Ledger, accounts: AccountsSnapshot, today: DateOnly, rubPerUnit: [CurrencyCode: Decimal]
  ) -> BankReport {
    let dataset = ledger.dataset
    let data = dataset.bankData
    var risks: [MinBalanceRisk] = []
    for conditions in data.conditions where conditions.cardId == nil {
      guard let minimum = conditions.minBalanceE4,
        let account = dataset.paymentMethods.first(where: { $0.id == conditions.accountId }),
        !account.archived,
        let balance = accounts.line(of: account.id)?.keys
          .first(where: { $0.key.currency == conditions.currency })?.balance,
        balance < minimum
      else { continue }
      risks.append(
        MinBalanceRisk(
          accountId: account.id, currency: conditions.currency, balanceE4: balance,
          minimumE4: minimum))
    }
    return BankReport(
      today: today,
      limits: BankLimits.progress(ledger: ledger, data: data, month: today.monthKey),
      service: BankServiceFree.progress(
        ledger: ledger, data: data, accounts: accounts, today: today),
      minBalance: risks,
      insurance: insurance(
        ledger: ledger, accounts: accounts, today: today, rubPerUnit: rubPerUnit),
      forgotten: BankForgotten.list(ledger: ledger, data: data, accounts: accounts, today: today),
      cardExpiries: CardExpiries.list(dataset: dataset, today: today))
  }

  /// The money of each bank as the insurance counts it: the positive balances of its live
  /// accounts at today's rate (a credit card, cash and a currency without a rate are not money in
  /// the bank), and the interest earned and not paid yet.
  static func insurance(
    ledger: Ledger, accounts: AccountsSnapshot, today: DateOnly, rubPerUnit: [CurrencyCode: Decimal]
  ) -> [BankInsurance] {
    let dataset = ledger.dataset
    let data = dataset.bankData
    let limit = DepositInsurance.limitE4(on: today, override: data.settings.insuranceLimitE4)
    let banks = Dictionary(
      dataset.banks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var byBank: [UUID: (name: String, accounts: [UUID], total: AmountE4)] = [:]
    var order: [UUID] = []
    for account in dataset.paymentMethods where !account.archived {
      guard account.kind != .cash, !account.isCreditCard,
        let line = accounts.line(of: account.id)
      else { continue }
      let rub = AmountE4.sum(line.keys.compactMap { $0.rub }.filter { $0.raw > 0 })
      let key = BankLimits.bankKey(account)
      if byBank[key] == nil {
        byBank[key] = (account.bankId.flatMap { banks[$0]?.name } ?? account.name, [], .zero)
        order.append(key)
      }
      byBank[key]?.accounts.append(account.id)
      byBank[key]?.total += rub
    }
    let outlooks = DepositPayouts.outlooks(
      ledger: ledger, balances: accounts.balances,
      interestCategoryId: dataset.accountSettings.interestCategoryId, today: today, through: today)
    for outlook in outlooks {
      guard let account = dataset.paymentMethods.first(where: { $0.id == outlook.accountId }),
        let payout = outlook.current(today: today), payout.accruedE4.raw > 0
      else { continue }
      if case .received = payout.state { continue }
      let currency = outlook.key.currency
      let rate: Decimal? = currency == .rub ? 1 : rubPerUnit[currency]
      guard let rate, rate > 0 else { continue }
      byBank[BankLimits.bankKey(account)]?.total += InterestMath.cents(
        payout.accruedE4.decimal * rate)
    }
    return order.compactMap { key -> BankInsurance? in
      guard let value = byBank[key], value.total.raw > 0 else { return nil }
      return BankInsurance(
        bankId: key, name: value.name, accountIds: value.accounts, totalRub: value.total,
        limitRub: limit, on: DepositInsurance.since(on: today))
    }.sorted { ($1.totalRub, $0.name) < ($0.totalRub, $1.name) }
  }

  // MARK: - Notes

  /// The lines of «Стоит посмотреть», the alarms first; `dismissed` are the keys put away.
  public func notes(dismissed: Set<String> = []) -> [BankNote] {
    var notes: [BankNote] = []
    for line in limits {
      if line.exceeded {
        notes.append(
          .limitExceeded(
            accountId: line.accountId, kind: line.kind, overE4: line.overE4,
            currency: line.currency))
      } else if line.isNear || line.isUsedUp {
        notes.append(
          .limitNear(
            accountId: line.accountId, kind: line.kind, leftE4: line.leftE4, currency: line.currency
          ))
      }
    }
    for risk in minBalance {
      notes.append(
        .minBalanceBelow(
          accountId: risk.accountId, balanceE4: risk.balanceE4, minimumE4: risk.minimumE4,
          currency: risk.currency))
    }
    for expiry in cardExpiries {
      notes.append(
        .cardExpiry(
          accountId: expiry.accountId, cardId: expiry.cardId, expiresOn: expiry.expiresOn,
          expired: expiry.expired, attachedCount: expiry.attached.count))
    }
    if !forgotten.isEmpty {
      notes.append(
        .forgotten(
          count: forgotten.count, balanceRub: AmountE4.sum(forgotten.map(\.balanceRub)),
          month: today.monthKey))
    }
    for bank in insurance where bank.isOver {
      notes.append(
        .insuranceOver(
          bankId: bank.bankId, name: bank.name, totalRub: bank.totalRub, limitRub: bank.limitRub))
    }
    notes = notes.filter { !$0.canBePutAway || !dismissed.contains($0.id) }
    return notes.filter(\.isAlarm) + notes.filter { !$0.isAlarm }
  }
}
