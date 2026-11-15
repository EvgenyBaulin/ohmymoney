import CoreKit
import Foundation

/// One combined forecast in rubles at today's rates. The spending allocation is only an
/// intermediate step in the total, never a prediction of an individual account's balance.
public struct BalanceForecastModel: Hashable, Sendable {
  public struct Total: Hashable, Sendable {
    public var currency: CurrencyCode
    public var middle: AmountE4
    public var accounts: Int

    public init(currency: CurrencyCode, middle: AmountE4, accounts: Int) {
      self.currency = currency
      self.middle = middle
      self.accounts = accounts
    }
  }

  /// One counted balance that went into a total.
  public struct Line: Hashable, Sendable {
    public var accountId: UUID
    public var name: String
    public var currency: CurrencyCode
    /// The balance now, in `currency`.
    public var now: AmountE4
    /// The middle of the forecast at the end of the month, in `currency`.
    public var middle: AmountE4

    public init(
      accountId: UUID, name: String, currency: CurrencyCode, now: AmountE4, middle: AmountE4
    ) {
      self.accountId = accountId
      self.name = name
      self.currency = currency
      self.now = now
      self.middle = middle
    }
  }

  /// One total in rubles, or none while every included balance is unknown.
  public var totals: [Total]
  /// Intermediate allocations; individual account presentations use `knownBalances()`.
  public var lines: [Line]
  public var moneyNow: AmountE4
  public var knownChanges: AmountE4
  public var estimatedChanges: AmountE4
  /// Some balance of the summary was never counted or has no rate: it is not in the totals.
  public var leftOut: Bool
  public var lowData: Bool
  public var through: DateOnly

  public init(forecast: AccountForecast, accountIds: [UUID]) {
    var middle = AmountE4.zero
    var counted = 0
    var moneyNow = AmountE4.zero
    var knownEnd = AmountE4.zero
    var lines: [Line] = []
    var leftOut = false
    for id in accountIds {
      for line in forecast.lines(of: id) {
        guard line.status == .ready, let balance = line.balance, let rub = line.balanceRub else {
          if line.flows.isHeld { leftOut = true }
          continue
        }
        let currency = line.key.currency
        lines.append(
          Line(
            accountId: id, name: line.flows.account.name, currency: currency,
            now: line.flows.now ?? .zero, middle: balance.middle))
        middle += rub.middle - line.internalTransfersAheadRub
        moneyNow += line.nowRub ?? .zero
        knownEnd += (line.knownEndRub ?? .zero) - line.internalTransfersAheadRub
        counted += 1
      }
    }
    self.totals = counted > 0 ? [Total(currency: .rub, middle: middle, accounts: counted)] : []
    self.lines = lines
    self.moneyNow = moneyNow
    self.knownChanges = knownEnd - moneyNow
    self.estimatedChanges = middle - knownEnd
    self.leftOut = leftOut
    self.lowData = forecast.lowData
    self.through = forecast.through
  }

  /// The accounts of the sections in the summary, in the order the sidebar shows them in the
  /// language of `locale`.
  public static func summaryAccountIds(_ accounts: AccountsSnapshot, locale: Locale) -> [UUID] {
    accounts.ordered(locale: locale).sections.filter(\.inSummary)
      .flatMap { $0.accounts.map(\.account.id) }
  }
}
