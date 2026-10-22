import CoreAnalytics
import CoreKit
import Foundation

/// The month buffer: a sum set aside for the unexpected, apart from the cushion. It is held
/// back from «Можно тратить» as a grey line («Буфер на непредвиденное −5 000 ₽»); an operation
/// marked «из буфера» spends it, so the buffer left shrinks and the free sum does not (the
/// money is spent and held back no longer, which is one figure).
///
/// Kept in the `settings` table under these keys; 0 or no key — the buffer is off.
public struct MonthBufferSettings: Hashable, Sendable {
  /// The buffer, in `*_e4` units as text.
  public static let amountKey = "planning.monthBuffer"
  /// The income of the month the buffer was set (or last confirmed) at, in `*_e4` units.
  public static let incomeKey = "planning.monthBuffer.incomeAtSet"
  /// The operations marked «из буфера», one transaction id per line.
  public static let marksKey = "planning.monthBuffer.marks"

  public var amount: AmountE4
  public var incomeAtSet: AmountE4?

  public var isOn: Bool { amount.raw > 0 }

  public init(amount: AmountE4 = .zero, incomeAtSet: AmountE4? = nil) {
    self.amount = amount
    self.incomeAtSet = incomeAtSet
  }

  /// From the stored texts; an unreadable or negative amount is no buffer.
  public init(amountText: String?, incomeText: String?) {
    let amount = amountText.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    let income = incomeText.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    self.init(
      amount: AmountE4(raw: max(0, amount ?? 0)),
      incomeAtSet: income.flatMap { $0 > 0 ? AmountE4(raw: $0) : nil })
  }

  /// The text for `amountKey`; `nil` — delete the key.
  public var amountText: String? { isOn ? String(amount.raw) : nil }
  public var incomeText: String? { incomeAtSet.map { String($0.raw) } }

  /// The marks as stored: sorted, one id per line; `nil` for none.
  public static func marksText(_ marks: Set<UUID>) -> String? {
    marks.isEmpty ? nil : marks.map(\.uuidString).sorted().joined(separator: "\n")
  }

  /// The marks from their text; a line that is no id is skipped.
  public static func marks(from text: String?) -> Set<UUID> {
    guard let text else { return [] }
    return Set(text.split(whereSeparator: \.isNewline).compactMap { UUID(uuidString: String($0)) })
  }
}

/// Where the buffer of a month stands.
public struct MonthBufferState: Hashable, Sendable {
  public var amount: AmountE4
  /// Spent by the operations marked «из буфера» in this month.
  public var used: AmountE4
  /// What is held back from the free sum: max(0, amount − used).
  public var left: AmountE4
  /// «Буфер использован на 80 %»: used ÷ amount in basis points, up to and over 10 000.
  public var usedBp: Int

  public var isOverrun: Bool { used > amount }
}

public enum MonthBuffer {
  /// The buffer of `month` given what the marked operations spent in it.
  public static func state(settings: MonthBufferSettings, used: AmountE4) -> MonthBufferState? {
    guard settings.isOn else { return nil }
    let spent = max(.zero, used)
    let share = SeasonMath.basisPoints(spent.decimal / settings.amount.decimal)
    return MonthBufferState(
      amount: settings.amount, used: spent, left: max(.zero, settings.amount - spent),
      usedBp: share)
  }

  /// What the marked operations spent in `month`: their contributions to my expenses
  /// (refunds taken off), dated in that month.
  public static func used(marks: Set<UUID>, month: MonthKey, ledger: Ledger) -> AmountE4 {
    guard !marks.isEmpty else { return .zero }
    return AmountE4.sum(
      ledger.rows(attributedTo: [month]).lazy
        .filter { marks.contains($0.transactionId) }
        .map(\.contribution))
  }

  /// The free sum less the buffer that is left.
  public static func freeSum(_ free: AmountE4, state: MonthBufferState?) -> AmountE4 {
    free - (state?.left ?? .zero)
  }

  /// Income above this many percent of what the buffer was set at asks for a bigger one.
  public static let raiseOverBp = 1_000
  /// The offer is rounded to this step.
  public static let step = AmountE4(whole: 100)

  /// «Доход вырос больше чем на 10 % — повысить буфер?»: the buffer in proportion to the
  /// income, rounded to the nearest hundred rubles; `nil` when the buffer is off, no income was
  /// noted when it was set, or the income grew by 10 % or less.
  public static func raiseOffer(settings: MonthBufferSettings, income: AmountE4) -> AmountE4? {
    guard settings.isOn, let base = settings.incomeAtSet, base.raw > 0, income.raw > 0 else {
      return nil
    }
    let limit = base.decimal * Decimal(Seasonality.whole + raiseOverBp) / Decimal(Seasonality.whole)
    guard income.decimal > limit else { return nil }
    let proposed = SavingsMath.rounded(settings.amount.decimal * income.decimal / base.decimal)
    var ratio = proposed.decimal / step.decimal
    var hundreds = Decimal()
    NSDecimalRound(&hundreds, &ratio, 0, .plain)
    let rounded = AmountE4(raw: NSDecimalNumber(decimal: hundreds).int64Value * step.raw)
    return max(rounded, settings.amount)
  }

  /// The settings after the owner answered the offer (yes, with `newAmount`, or no with `nil`):
  /// the income is noted either way, so the offer comes again only when income grows another
  /// 10 % beyond it.
  public static func answered(
    settings: MonthBufferSettings, income: AmountE4, newAmount: AmountE4?
  ) -> MonthBufferSettings {
    MonthBufferSettings(amount: newAmount ?? settings.amount, incomeAtSet: income)
  }
}
