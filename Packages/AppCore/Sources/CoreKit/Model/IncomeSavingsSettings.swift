import Foundation

/// The three baskets a month's money is laid out in: what cannot be stopped, what is chosen,
/// and what is put aside.
public enum BudgetBasket: String, Hashable, Sendable, Codable, CaseIterable {
  case needs
  case wants
  case savings
}

/// The owner's budget proportions in whole percent: needs / wants / savings, adding up to 100.
/// The usual rule is 50 / 30 / 20.
public struct BudgetProportions: Hashable, Sendable, Codable {
  public var needsPercent: Int
  public var wantsPercent: Int
  public var savingsPercent: Int

  public static let rule503020 = BudgetProportions(needs: 50, wants: 30, savings: 20)!

  /// `nil` unless the three are not negative and add up to exactly 100.
  public init?(needs: Int, wants: Int, savings: Int) {
    guard needs >= 0, wants >= 0, savings >= 0, needs + wants + savings == 100 else {
      return nil
    }
    needsPercent = needs
    wantsPercent = wants
    savingsPercent = savings
  }

  public func percent(of basket: BudgetBasket) -> Int {
    switch basket {
    case .needs: needsPercent
    case .wants: wantsPercent
    case .savings: savingsPercent
    }
  }

  /// The target in basis points of the income.
  public func targetBp(of basket: BudgetBasket) -> Int { percent(of: basket) * 100 }

  /// `60/25/15`, as the settings keep it.
  public var storedValue: String { "\(needsPercent)/\(wantsPercent)/\(savingsPercent)" }

  /// Reads `60/25/15` (a space, `-` or `:` between the numbers is fine too); anything that is
  /// not three numbers adding up to 100 is not a rule.
  public init?(storedValue text: String) {
    let parts = text.split(whereSeparator: { "/-: ".contains($0) }).map { Int($0) }
    guard parts.count == 3, let needs = parts[0], let wants = parts[1], let savings = parts[2]
    else { return nil }
    self.init(needs: needs, wants: wants, savings: savings)
  }
}

/// Settings of «Доход и сбережения», kept in the `settings` table under these keys. A key that
/// is not there means its default; they travel inside the database of the archive. (The basket
/// of a category is not here: it is a column of the category, `BudgetBasket.rawValue`.)
public struct IncomeSavingsSettings: Hashable, Sendable, Codable {
  /// `60/25/15`; absent — 50 / 30 / 20.
  public static let proportionsKey = "incomeSavings.proportions"
  /// `1`: the savings rate counts only the earnings category; default `0` (all income).
  public static let earningsOnlyKey = "incomeSavings.earningsOnly"
  /// `0`: the line «spending follows income» is switched off for good; default `1`.
  public static let trendNudgeEnabledKey = "incomeSavings.trendNudge.enabled"
  /// The quarter the line was last shown in, `YYYY-Qn`.
  public static let trendNudgeShownKey = "incomeSavings.trendNudge.shown"

  public static let storageKeys = [
    proportionsKey, earningsOnlyKey, trendNudgeEnabledKey, trendNudgeShownKey,
  ]

  public var proportions: BudgetProportions
  public var earningsOnly: Bool
  public var trendNudgeEnabled: Bool
  /// `YYYY-Qn`; `nil` — never shown.
  public var trendNudgeShown: String?

  public init(
    proportions: BudgetProportions = .rule503020, earningsOnly: Bool = false,
    trendNudgeEnabled: Bool = true, trendNudgeShown: String? = nil
  ) {
    self.proportions = proportions
    self.earningsOnly = earningsOnly
    self.trendNudgeEnabled = trendNudgeEnabled
    self.trendNudgeShown = trendNudgeShown
  }

  public static let standard = IncomeSavingsSettings()

  /// The settings the rows give; a value that does not read keeps its default.
  public init(storedValues values: [String: String]) {
    self.init(
      proportions: values[Self.proportionsKey].flatMap { BudgetProportions(storedValue: $0) }
        ?? .rule503020,
      earningsOnly: values[Self.earningsOnlyKey].flatMap(Self.switchValue) ?? false,
      trendNudgeEnabled: values[Self.trendNudgeEnabledKey].flatMap(Self.switchValue) ?? true,
      trendNudgeShown: values[Self.trendNudgeShownKey].flatMap(Self.quarter))
  }

  /// The rows to write; a setting at its default deletes its key (`nil`).
  public var storedValues: [String: String?] {
    [
      Self.proportionsKey: proportions == .rule503020 ? nil : proportions.storedValue,
      Self.earningsOnlyKey: earningsOnly ? "1" : nil,
      Self.trendNudgeEnabledKey: trendNudgeEnabled ? nil : "0",
      Self.trendNudgeShownKey: trendNudgeShown,
    ]
  }

  /// `YYYY-Qn` exactly.
  static func quarter(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 4, Int(parts[0]) != nil, parts[1].count == 2,
      parts[1].first == "Q", let number = Int(parts[1].dropFirst()), (1...4).contains(number)
    else { return nil }
    return trimmed
  }

  private static func switchValue(_ text: String) -> Bool? {
    switch text.trimmingCharacters(in: .whitespaces).lowercased() {
    case "1", "true": true
    case "0", "false": false
    default: nil
    }
  }
}
