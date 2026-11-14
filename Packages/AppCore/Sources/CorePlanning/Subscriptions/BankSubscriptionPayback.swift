import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// Whether a subscription of a bank pays back: what it costs a month against what the owner says
/// it saves or earns besides cashback, and the part of the bank's cashback it gives.
public struct BankSubscriptionPayback: Hashable, Sendable, Identifiable {
  public enum Verdict: Hashable, Sendable {
    /// It brings more than it costs.
    case paysBack
    /// It costs more than it brings.
    case costsMore
    /// Neither a benefit nor a share of the cashback is stated: nothing to compare with.
    case notStated
  }

  public var paymentId: UUID
  public var bankId: UUID
  /// What the subscription costs a month, in rubles.
  public var costRub: AmountE4
  /// What the owner says it saves or earns besides cashback, in rubles.
  public var benefitRub: AmountE4
  /// The cashback the bank paid on the accounts of the month, in rubles, and the part of it that
  /// the subscription gives (`SubscriptionTerms.bankCashbackShare`).
  public var cashbackRub: AmountE4
  public var cashbackGainRub: AmountE4
  public var verdict: Verdict

  public var id: UUID { paymentId }
  /// What the subscription brings in all, in rubles.
  public var gainRub: AmountE4 { benefitRub + cashbackGainRub }
  /// What it brings less what it costs; negative when it costs more.
  public var netRub: AmountE4 { gainRub - costRub }
}

/// The report of the bank subscriptions: each running subscription paid from an account of a bank
/// that states a benefit or a share of the cashback.
public enum BankSubscriptionPaybacks {
  /// Whether `terms` say anything about a bank subscription.
  public static func isBankSubscription(_ terms: SubscriptionTerms?) -> Bool {
    guard let terms else { return false }
    return terms.bankBenefitE4 != nil || terms.bankCashbackShare != nil
  }

  /// The report for `today`. `cashbackRub` is the cashback each bank paid in the month to report
  /// on, in rubles (`CashbackReport`), by bank; `rubPerUnit` converts a payment in another
  /// currency, and a subscription whose currency has no rate is left out rather than guessed.
  /// Best first (largest net), then by name of the payment.
  public static func report(
    book: PlanningBook, subscriptions: SubscriptionBook, accounts: [PaymentMethod],
    cashbackRub: [UUID: AmountE4], today: DateOnly, rubPerUnit: [CurrencyCode: Decimal]
  ) -> [BankSubscriptionPayback] {
    let accountBank = Dictionary(
      uniqueKeysWithValues: accounts.compactMap { account in
        account.bankId.map { (account.id, $0) }
      })
    var lines: [(BankSubscriptionPayback, String)] = []
    for payment in book.scheduled where SubscriptionCosts.isRunning(payment, on: today) {
      guard let terms = subscriptions.terms(of: payment.id), isBankSubscription(terms),
        let accountId = payment.paymentMethodId, let bankId = accountBank[accountId]
      else { continue }
      let price = SubscriptionMath.price(of: payment, on: today, prices: book.prices)
      let monthly = SubscriptionMath.monthlyEquivalent(
        price, rule: RecurrenceRule(payment: payment))
      guard let cost = rubles(monthly, payment.currency, rubPerUnit),
        let benefit = rubles(terms.bankBenefitE4 ?? .zero, payment.currency, rubPerUnit)
      else { continue }
      let cashback = cashbackRub[bankId] ?? .zero
      let share = min(max(terms.bankCashbackShare ?? 0, 0), 100)
      let gain = InterestMath.cents(cashback.decimal * share / 100)
      let verdict: BankSubscriptionPayback.Verdict
      if benefit.isZero && gain.isZero && terms.bankBenefitE4 == nil
        && terms.bankCashbackShare == nil
      {
        verdict = .notStated
      } else {
        verdict = benefit + gain >= cost ? .paysBack : .costsMore
      }
      lines.append(
        (
          BankSubscriptionPayback(
            paymentId: payment.id, bankId: bankId, costRub: cost, benefitRub: benefit,
            cashbackRub: cashback, cashbackGainRub: gain, verdict: verdict), payment.name
        ))
    }
    return lines.sorted { left, right in
      if left.0.netRub != right.0.netRub { return left.0.netRub > right.0.netRub }
      return left.1 < right.1
    }.map(\.0)
  }

  private static func rubles(
    _ amount: AmountE4, _ currency: CurrencyCode, _ rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    if currency == .rub || amount.isZero { return amount }
    guard let rate = rubPerUnit[currency] else { return nil }
    return InterestMath.cents(amount.decimal * rate)
  }
}
