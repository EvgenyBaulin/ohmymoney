import CoreKit
import Foundation

/// What the accounts of the summary come to at the end of the month, currency by currency: the
/// middle of each counted balance's forecast (`AccountForecast`), added up within its currency —
/// never across currencies. The figure of the Overview tile «Прогноз остатка до конца месяца»
/// and the lines of its breakdown, in one pass.
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

  /// The currencies in the order they were first met, the accounts in their order.
  public var totals: [Total]
  /// Every balance in the totals, in the order of the accounts.
  public var lines: [Line]
  /// Some balance of the summary was never counted or has no rate: it is not in the totals.
  public var leftOut: Bool
  public var lowData: Bool
  public var through: DateOnly

  public init(forecast: AccountForecast, accountIds: [UUID]) {
    var totals: [Total] = []
    var lines: [Line] = []
    var leftOut = false
    for id in accountIds {
      for line in forecast.lines(of: id) {
        guard line.status == .ready, let balance = line.balance else {
          if line.flows.isHeld { leftOut = true }
          continue
        }
        let currency = line.key.currency
        lines.append(
          Line(
            accountId: id, name: line.flows.account.name, currency: currency,
            now: line.flows.now ?? .zero, middle: balance.middle))
        if let index = totals.firstIndex(where: { $0.currency == currency }) {
          totals[index].middle += balance.middle
          totals[index].accounts += 1
        } else {
          totals.append(Total(currency: currency, middle: balance.middle, accounts: 1))
        }
      }
    }
    self.totals = totals
    self.lines = lines
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
