import CoreAnalytics
import CoreKit
import Foundation

/// Settings of the bank screens, kept in the `settings` table. A key that is not there means its
/// default; they travel inside the database of the archive.
public struct BankSettings: Hashable, Sendable {
  /// Days without a movement after which a product counts as forgotten; absent — 90.
  public static let forgottenDaysKey = "banks.forgottenDays"
  /// The operations and transfers the owner took out of the free limits, UUIDs separated by
  /// commas.
  public static let limitOffKey = "banks.limitOff"
  /// The limit of the deposit insurance the owner corrected, a decimal string in rubles.
  public static let insuranceLimitKey = "banks.insuranceLimit"

  public static let storageKeys = [forgottenDaysKey, limitOffKey, insuranceLimitKey]

  public static let defaultForgottenDays = 90

  public var forgottenDays: Int
  public var limitOff: Set<UUID>
  /// `nil`: as the law says on the day (`DepositInsurance`).
  public var insuranceLimitE4: AmountE4?

  public init(
    forgottenDays: Int = BankSettings.defaultForgottenDays, limitOff: Set<UUID> = [],
    insuranceLimitE4: AmountE4? = nil
  ) {
    self.forgottenDays = forgottenDays
    self.limitOff = limitOff
    self.insuranceLimitE4 = insuranceLimitE4
  }

  public static let standard = BankSettings()

  /// The settings the rows give; a value that does not read keeps its default.
  public init(storedValues values: [String: String]) {
    let days = values[Self.forgottenDaysKey].flatMap {
      Int($0.trimmingCharacters(in: .whitespaces))
    }
    let off =
      values[Self.limitOffKey]?.split(separator: ",").compactMap {
        UUID(uuidString: $0.trimmingCharacters(in: .whitespaces))
      } ?? []
    let limit = values[Self.insuranceLimitKey].flatMap { text -> AmountE4? in
      guard let decimal = Decimal(string: text.trimmingCharacters(in: .whitespaces)),
        let amount = try? AmountE4(decimal: decimal), amount.raw > 0
      else { return nil }
      return amount
    }
    self.init(
      forgottenDays: days.flatMap { $0 >= 1 ? $0 : nil } ?? Self.defaultForgottenDays,
      limitOff: Set(off), insuranceLimitE4: limit)
  }

  /// The rows to write; a setting at its default deletes its key (`nil`).
  public var storedValues: [String: String?] {
    [
      Self.forgottenDaysKey: forgottenDays == Self.defaultForgottenDays
        ? nil : String(forgottenDays),
      Self.limitOffKey: limitOff.isEmpty
        ? nil : limitOff.map(\.uuidString).sorted().joined(separator: ","),
      Self.insuranceLimitKey: insuranceLimitE4.map { "\($0.decimal)" },
    ]
  }
}

/// What the bank screens read besides the accounts: the conditions the owner typed for the
/// products and the settings above. Read with the rest of the data.
public struct BankData: Hashable, Sendable {
  public var conditions: [BankConditions]
  public var settings: BankSettings

  public init(conditions: [BankConditions] = [], settings: BankSettings = .standard) {
    self.conditions = conditions
    self.settings = settings
  }

  public static let empty = BankData()

  /// The row of an account (`cardId == nil`) or of one of its cards.
  public func conditions(account: UUID, card: UUID? = nil) -> BankConditions? {
    conditions.first { $0.accountId == account && $0.cardId == card }
  }

  /// The rows of the cards of an account that state something.
  public func cardConditions(of account: UUID) -> [BankConditions] {
    conditions.filter { $0.accountId == account && $0.cardId != nil && !$0.isEmpty }
  }
}

extension Dataset {
  public static let bankDataKey = "planning.bankData"

  /// The conditions of bank products and the settings of the bank screens.
  public var bankData: BankData {
    get { extras.value(Self.bankDataKey) ?? .empty }
    set { extras.set(newValue, for: Self.bankDataKey) }
  }
}

/// The tags the app reserves for the free limits of a bank: an expense that carries one is a
/// movement of that kind (a transfer to a person through the fast payment system, cash taken out,
/// a transfer to another bank). Taking the tag off, or switching the operation off in the list of
/// what the limit counted, leaves it out.
public enum BankLimitTags {
  public static let cash = "_cash"
  public static let sbp = "_sbp"
  public static let interbank = "_interbank"

  public static func kind(ofTag name: String) -> BankLimitKind? {
    switch TagName.key(name) {
    case TagName.key(cash): .cash
    case TagName.key(sbp): .sbp
    case TagName.key(interbank): .interbank
    default: nil
    }
  }

  public static func name(of kind: BankLimitKind) -> String {
    switch kind {
    case .cash: cash
    case .sbp: sbp
    case .interbank: interbank
    }
  }
}
