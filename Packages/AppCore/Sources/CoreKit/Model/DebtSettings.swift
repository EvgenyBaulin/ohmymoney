import Foundation

/// Settings of the debts, kept in the `settings` table under these keys. A key that is not
/// there means its default; they travel inside the database of the archive.
public struct DebtSettings: Hashable, Sendable, Codable {
  /// What the owner pays above the minimums every month in the payoff ladder, a decimal string
  /// in rubles; absent — 0.
  public static let ladderExtraKey = "debts.ladder.extra"
  /// Credit-card accounts kept out of the ladder, UUIDs separated by commas.
  public static let ladderAccountsOutKey = "debts.ladder.accountsOut"
  /// The owner's text of a polite reminder to a debtor, with its fields; absent — the standard.
  public static let nudgeTemplateKey = "debts.nudgeTemplate"
  /// The category the interest of credit cards is written to, by id; made at the first record.
  public static let creditInterestCategoryKey = "cards.creditInterestCategory"

  public static let splitDatesKey = "debts.split.dates"
  public static let statementOverridesKey = "cards.statementOverrides"

  public static let storageKeys = [
    ladderExtraKey, ladderAccountsOutKey, nudgeTemplateKey, creditInterestCategoryKey,
    splitDatesKey, statementOverridesKey,
  ]

  public var ladderExtraE4: AmountE4?
  public var ladderAccountsOut: [UUID]
  public var nudgeTemplate: String?
  public var creditInterestCategoryId: UUID?
  public var splitDates: [SplitDueDates]
  public var statementOverrides: [CreditStatementOverride]

  public init(
    ladderExtraE4: AmountE4? = nil, ladderAccountsOut: [UUID] = [], nudgeTemplate: String? = nil,
    creditInterestCategoryId: UUID? = nil, splitDates: [SplitDueDates] = [],
    statementOverrides: [CreditStatementOverride] = []
  ) {
    self.ladderExtraE4 = ladderExtraE4
    self.ladderAccountsOut = ladderAccountsOut
    self.nudgeTemplate = nudgeTemplate
    self.creditInterestCategoryId = creditInterestCategoryId
    self.splitDates = splitDates
    self.statementOverrides = statementOverrides
  }

  public static let standard = DebtSettings()

  /// The settings the rows give; a value that does not read keeps its default.
  public init(storedValues values: [String: String]) {
    self.init(
      ladderExtraE4: values[Self.ladderExtraKey].flatMap(SettingText.amount)
        .flatMap { $0.isNegative ? nil : $0 },
      ladderAccountsOut: values[Self.ladderAccountsOutKey].map(SettingText.uuids) ?? [],
      nudgeTemplate: values[Self.nudgeTemplateKey].flatMap {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
      },
      creditInterestCategoryId: values[Self.creditInterestCategoryKey].flatMap(SettingText.uuid),
      splitDates: Self.decode(values[Self.splitDatesKey]),
      statementOverrides: Self.decode(values[Self.statementOverridesKey]))
  }

  /// The rows to write; a setting at nothing deletes its key (`nil`).
  public var storedValues: [String: String?] {
    [
      Self.ladderExtraKey: ladderExtraE4.map(SettingText.text),
      Self.ladderAccountsOutKey: ladderAccountsOut.isEmpty
        ? nil : ladderAccountsOut.map(\.uuidString).joined(separator: ","),
      Self.nudgeTemplateKey: nudgeTemplate,
      Self.creditInterestCategoryKey: creditInterestCategoryId?.uuidString,
      Self.splitDatesKey: Self.encode(splitDates),
      Self.statementOverridesKey: Self.encode(statementOverrides),
    ]
  }
  private enum CodingKeys: String, CodingKey {
    case ladderExtraE4, ladderAccountsOut, nudgeTemplate, creditInterestCategoryId
    case splitDates, statementOverrides
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      ladderExtraE4: try values.decodeIfPresent(AmountE4.self, forKey: .ladderExtraE4),
      ladderAccountsOut: try values.decodeIfPresent([UUID].self, forKey: .ladderAccountsOut) ?? [],
      nudgeTemplate: try values.decodeIfPresent(String.self, forKey: .nudgeTemplate),
      creditInterestCategoryId: try values.decodeIfPresent(
        UUID.self, forKey: .creditInterestCategoryId),
      splitDates: try values.decodeIfPresent([SplitDueDates].self, forKey: .splitDates) ?? [],
      statementOverrides: try values.decodeIfPresent(
        [CreditStatementOverride].self, forKey: .statementOverrides) ?? [])
  }

  private static func decode<T: Decodable>(_ text: String?) -> [T] {
    guard let data = text?.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([T].self, from: data)) ?? []
  }

  private static func encode<T: Encodable>(_ values: [T]) -> String? {
    guard !values.isEmpty else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(values)).flatMap { String(data: $0, encoding: .utf8) }
  }
}
