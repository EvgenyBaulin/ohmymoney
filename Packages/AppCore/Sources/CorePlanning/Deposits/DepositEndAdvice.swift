import CoreAnalytics
import CoreKit
import Foundation

/// «Вклад кончится 3 ноября. Сейчас в витрине: …»: the showcase laid against a deposit that is
/// about to end. Not advice and never «the best one»: one line per condition the owner's own
/// deposit has — its term, the money on it, a top-up — each with the highest rate among the
/// showcase entries that meet that one condition.
public struct DepositEndAdvice: Hashable, Sendable, Identifiable {
  public enum Condition: Hashable, Sendable {
    /// The term of the deposit that ends, in months.
    case term(months: Int)
    /// The money on it.
    case amount(AmountE4)
    /// A deposit that can be topped up.
    case topup
  }

  public struct Pick: Hashable, Sendable {
    public var condition: Condition
    public var entry: DepositShowcaseEntry
  }

  public var accountId: UUID
  public var endsOn: DateOnly
  public var picks: [Pick]

  public var id: String { "\(accountId.uuidString):\(endsOn.iso)" }
}

public enum DepositEndAdvisor {
  /// How many days before the end the line shows (and on the day itself).
  public static let daysBefore = 7

  /// The advice for each ruble deposit ending within `daysBefore` days, in the order of the end.
  /// A deposit with nothing in the showcase to put against it gets no line: nothing is said
  /// only to say something.
  public static func advice(
    accounts: [PaymentMethod], balanceE4: (PaymentMethod) -> AmountE4?,
    entries: [DepositShowcaseEntry], today: DateOnly
  ) -> [DepositEndAdvice] {
    accounts.compactMap { account -> DepositEndAdvice? in
      guard !account.archived, account.mainCurrency == .rub, let terms = account.interest,
        let ends = terms.endsOn
      else { return nil }
      let left = today.days(to: ends)
      guard left >= 0, left <= daysBefore else { return nil }
      var picks: [DepositEndAdvice.Pick] = []
      if let opened = terms.openedOn {
        let months = max(1, (opened.days(to: ends) * 100 + 1522) / 3044)
        if let entry = best(entries, DepositFilter(termMonths: months)) {
          picks.append(.init(condition: .term(months: months), entry: entry))
        }
      }
      if let balance = balanceE4(account), balance.raw > 0,
        let entry = best(entries, DepositFilter(amountE4: balance))
      {
        picks.append(.init(condition: .amount(balance), entry: entry))
      }
      if let entry = best(entries, DepositFilter(requiresTopup: true)) {
        picks.append(.init(condition: .topup, entry: entry))
      }
      guard !picks.isEmpty else { return nil }
      return DepositEndAdvice(accountId: account.id, endsOn: ends, picks: picks)
    }
    .sorted { ($0.endsOn, $0.accountId.uuidString) < ($1.endsOn, $1.accountId.uuidString) }
  }

  /// The admitted entry with the highest known rate.
  private static func best(
    _ entries: [DepositShowcaseEntry], _ filter: DepositFilter
  ) -> DepositShowcaseEntry? {
    DepositShowcase.sorted(entries.filter(filter.admits)).first { $0.ratePercent != nil }
  }
}
