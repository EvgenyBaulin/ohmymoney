import CoreAnalytics
import CoreKit
import Foundation

/// The limit of the state insurance of deposits, as the law had it on a day: a versioned table
/// the app carries (the owner may correct the current value in the settings).
public enum DepositInsurance {
  /// The limit from `from` on, in rubles. Newest last.
  static let table: [(from: DateOnly, wholeRub: Int64)] = [
    (DateOnly(year: 2014, month: 12, day: 29), 700_000),
    (DateOnly(year: 2023, month: 3, day: 29), 1_400_000),
  ]

  /// The limit on `day`; before the first row, the first row's.
  public static func limitE4(on day: DateOnly, override: AmountE4? = nil) -> AmountE4 {
    if let override { return override }
    let row = table.last { $0.from <= day } ?? table[0]
    return AmountE4(whole: row.wholeRub)
  }

  /// The day the limit in force on `day` was set.
  public static func since(on day: DateOnly) -> DateOnly {
    (table.last { $0.from <= day } ?? table[0]).from
  }
}

/// All the money of one bank, as the insurance counts it: every live account of the bank, the
/// interest earned and not yet paid on top.
public struct BankInsurance: Hashable, Sendable, Identifiable {
  public var bankId: UUID
  public var name: String
  public var accountIds: [UUID]
  /// Rubles: positive balances at today's rate, plus the interest accrued and not paid.
  public var totalRub: AmountE4
  public var limitRub: AmountE4
  /// The day the limit is true on.
  public var on: DateOnly

  public init(
    bankId: UUID, name: String, accountIds: [UUID], totalRub: AmountE4, limitRub: AmountE4,
    on: DateOnly
  ) {
    self.bankId = bankId
    self.name = name
    self.accountIds = accountIds
    self.totalRub = totalRub
    self.limitRub = limitRub
    self.on = on
  }

  public var id: UUID { bankId }
  public var isOver: Bool { totalRub > limitRub }
  public var overRub: AmountE4 { isOver ? totalRub - limitRub : .zero }
}
