import CoreKit
import Foundation

/// One change a scenario makes to the plan. The changes are the whole scenario: it keeps no
/// copy of the data, and is always worked out from today's.
public struct ScenarioChange: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    /// A loan taken for a purchase.
    case loan
    /// Money paid into a loan early.
    case prepay
    /// A sum put aside every month.
    case save
    /// A big purchase paid for at once.
    case purchase
    /// A loan taken over by another on other terms.
    case refinance
    /// Putting money aside over years at a rate the owner types.
    case longHorizon
    /// The income stops for some months.
    case incomeLoss
  }

  /// How a loan is paid.
  public enum Payment: String, Codable, Sendable {
    case annuity
    case differentiated
  }

  public var kind: Kind
  /// The sum, in units of 1/10000 of the default currency.
  public var amountE4: Int64?
  public var months: Int?
  /// Percent a year, in hundredths of a percent (1250 = 12.5 %).
  public var rateBp: Int?
  public var payment: Payment?
  /// Fees and insurance paid once at the start.
  public var feesE4: Int64?
  /// The first day of the change, `YYYY-MM-DD`; none — today.
  public var start: String?

  public init(
    kind: Kind, amountE4: Int64? = nil, months: Int? = nil, rateBp: Int? = nil,
    payment: Payment? = nil, feesE4: Int64? = nil, start: String? = nil
  ) {
    self.kind = kind
    self.amountE4 = amountE4
    self.months = months
    self.rateBp = rateBp
    self.payment = payment
    self.feesE4 = feesE4
    self.start = start
  }
}

/// What a scenario says: its changes and the settings the numbers are read with.
public struct ScenarioSpec: Codable, Equatable, Hashable, Sendable {
  /// The longest horizon: thirty years.
  public static let maxHorizonMonths = 360
  public static let defaultHorizonMonths = 12

  public var changes: [ScenarioChange]
  public var horizonMonths: Int
  /// Income a month typed over the history's; none — from the history.
  public var incomeMonthlyE4: Int64?
  /// Spending a month typed over the history's; none — from the history.
  public var spendingMonthlyE4: Int64?
  /// Inflation a year in hundredths of a percent; 0 leaves the numbers as they are.
  public var inflationBp: Int
  /// The tax on the interest of savings counted (off by default).
  public var includeIncomeTax: Bool

  public init(
    changes: [ScenarioChange] = [], horizonMonths: Int = ScenarioSpec.defaultHorizonMonths,
    incomeMonthlyE4: Int64? = nil, spendingMonthlyE4: Int64? = nil, inflationBp: Int = 0,
    includeIncomeTax: Bool = false
  ) {
    self.changes = changes
    self.horizonMonths = min(max(horizonMonths, 1), Self.maxHorizonMonths)
    self.incomeMonthlyE4 = incomeMonthlyE4
    self.spendingMonthlyE4 = spendingMonthlyE4
    self.inflationBp = max(inflationBp, 0)
    self.includeIncomeTax = includeIncomeTax
  }

  /// The canonical text: the keys in one order whatever the order they were set in, so a spec
  /// that has not changed is the same text, and a text compares as a spec does.
  public func json() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
  }

  /// A spec read back from its text; `nil` for text that is none.
  public init?(json: String) {
    guard let spec = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else {
      return nil
    }
    self.init(
      changes: spec.changes, horizonMonths: spec.horizonMonths,
      incomeMonthlyE4: spec.incomeMonthlyE4, spendingMonthlyE4: spec.spendingMonthlyE4,
      inflationBp: spec.inflationBp, includeIncomeTax: spec.includeIncomeTax)
  }
}
