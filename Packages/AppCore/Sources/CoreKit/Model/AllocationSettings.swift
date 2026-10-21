import Foundation

/// Where the rest of a month goes when the owner allocates it.
public enum MonthRestTarget: Hashable, Sendable, Codable {
  case cushion
  case goal(UUID)

  /// `cushion` or `goal:<UUID>`, as the settings keep it.
  public var storedValue: String {
    switch self {
    case .cushion: "cushion"
    case .goal(let id): "goal:\(id.uuidString)"
    }
  }

  public init?(storedValue text: String) {
    let value = text.trimmingCharacters(in: .whitespaces)
    if value == "cushion" {
      self = .cushion
    } else if value.hasPrefix("goal:"), let id = UUID(uuidString: String(value.dropFirst(5))) {
      self = .goal(id)
    } else {
      return nil
    }
  }
}

/// Settings of the allocation of income, kept in the `settings` table under these keys. A key
/// that is not there means its default; they travel inside the database of the archive.
public struct AllocationSettings: Hashable, Sendable, Codable {
  /// The income category whose income is offered for allocation, by id; absent — «Заработок»
  /// / «Earnings» at the top.
  public static let earningsCategoryKey = "allocation.earningsCategory"
  /// The cushion account the owner chose for the allocation, by id.
  public static let cushionAccountKey = "allocation.cushionAccount"
  /// `cushion` or `goal:<UUID>`.
  public static let monthRestTargetKey = "allocation.monthRestTarget"
  /// The month whose rest was allocated or declined, `YYYY-MM`.
  public static let monthRestDoneKey = "allocation.monthRestDone"
  /// Incomes the owner said «Не надо» of, UUIDs separated by commas.
  public static let declinedKey = "allocation.declined"

  public static let storageKeys = [
    earningsCategoryKey, cushionAccountKey, monthRestTargetKey, monthRestDoneKey, declinedKey,
  ]

  public var earningsCategoryId: UUID?
  public var cushionAccountId: UUID?
  public var monthRestTarget: MonthRestTarget?
  public var monthRestDone: MonthKey?
  public var declined: [UUID]

  public init(
    earningsCategoryId: UUID? = nil, cushionAccountId: UUID? = nil,
    monthRestTarget: MonthRestTarget? = nil, monthRestDone: MonthKey? = nil,
    declined: [UUID] = []
  ) {
    self.earningsCategoryId = earningsCategoryId
    self.cushionAccountId = cushionAccountId
    self.monthRestTarget = monthRestTarget
    self.monthRestDone = monthRestDone
    self.declined = declined
  }

  public static let standard = AllocationSettings()

  /// The settings the rows give; a value that does not read keeps its default.
  public init(storedValues values: [String: String]) {
    self.init(
      earningsCategoryId: values[Self.earningsCategoryKey].flatMap(SettingText.uuid),
      cushionAccountId: values[Self.cushionAccountKey].flatMap(SettingText.uuid),
      monthRestTarget: values[Self.monthRestTargetKey].flatMap(MonthRestTarget.init),
      monthRestDone: values[Self.monthRestDoneKey].flatMap(SettingText.month),
      declined: values[Self.declinedKey].map(SettingText.uuids) ?? [])
  }

  /// The rows to write; a setting at nothing deletes its key (`nil`).
  public var storedValues: [String: String?] {
    [
      Self.earningsCategoryKey: earningsCategoryId?.uuidString,
      Self.cushionAccountKey: cushionAccountId?.uuidString,
      Self.monthRestTargetKey: monthRestTarget?.storedValue,
      Self.monthRestDoneKey: monthRestDone?.iso,
      Self.declinedKey: declined.isEmpty
        ? nil : declined.map(\.uuidString).joined(separator: ","),
    ]
  }
}
