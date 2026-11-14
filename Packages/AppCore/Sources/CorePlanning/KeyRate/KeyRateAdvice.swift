import CoreKit
import Foundation

/// A line of «Стоит посмотреть» the key rate brings. Never an offer of a product and never a
/// promise: it says what the rate did and what the owner's own debt or deposit stands at.
public enum KeyRateNote: Hashable, Sendable, Identifiable {
  /// «Ключевая ставка снизилась с 17 % до 16 % — у кредита «Х» 22 %: проверьте рефинансирование».
  case refinance(debtId: UUID, debtRate: Decimal, drop: KeyRateDrop)

  public var id: String {
    switch self {
    case .refinance(let debtId, _, let drop): "keyRate:refinance:\(debtId):\(drop.since.iso)"
    }
  }
}

public enum KeyRateAdvisor {
  /// The look back, in days, for «the rate fell».
  public static let windowDays = 90
  /// How far the rate has to fall in that time, in percentage points, to be worth a line.
  public static let minDropPoints = Decimal(1)

  /// The fall of the rate that is worth saying: at least `minDropPoints` over `windowDays`.
  public static func notableDrop(_ table: KeyRateTable, today: DateOnly) -> KeyRateDrop? {
    guard let drop = table.drop(overDays: windowDays, to: today), drop.points >= minDropPoints
    else { return nil }
    return drop
  }

  /// «Проверьте рефинансирование» for each debt I owe that still runs, has a rate above the key
  /// rate of today and is no pledge, while the rate has fallen notably in the last months. A
  /// debt below the key rate gets no line: there is nothing to win by changing it.
  public static func refinance(
    debts: [Debt], table: KeyRateTable, today: DateOnly
  ) -> [KeyRateNote] {
    guard let drop = notableDrop(table, today: today) else { return [] }
    return debts.compactMap { debt -> KeyRateNote? in
      guard debt.direction == .iOwe, !debt.closed, debt.deletedAt == nil, !debt.pledge,
        let rate = debt.interestRate, rate > drop.to
      else { return nil }
      return .refinance(debtId: debt.id, debtRate: rate, drop: drop)
    }
    .sorted { $0.id < $1.id }
  }
}
