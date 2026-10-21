import Foundation

/// Settings of the accounts, kept in the `settings` table under these keys. A key that is not
/// there means its default, so nothing is ever inserted for them up front.
public struct AccountSettings: Hashable, Sendable, Codable {
  /// The currency of everything new; ISO code. Default RUB.
  public static let defaultCurrencyKey = "currencies.default"
  /// `later` or `done`; absent until the owner has been through the setup of the accounts.
  public static let setupKey = "accounts.setup"
  /// The category the fees of transfers go to, by id; made at the first fee.
  public static let transferFeeCategoryKey = "transfers.feeCategory"
  /// The category the interest of deposits and savings accounts goes to, by id; made at the
  /// first account that earns interest.
  public static let interestCategoryKey = "accounts.interestCategory"

  /// Every key these settings live under.
  public static let storageKeys = [
    defaultCurrencyKey, setupKey, transferFeeCategoryKey, interestCategoryKey,
  ]

  public enum Setup: String, Hashable, Sendable, Codable {
    /// The owner put the setup off; a main account exists anyway.
    case later
    case done
  }

  public var defaultCurrency: CurrencyCode
  /// `nil`: the setup of the accounts is still due.
  public var setup: Setup?
  public var transferFeeCategoryId: UUID?
  public var interestCategoryId: UUID?

  public init(
    defaultCurrency: CurrencyCode = .rub, setup: Setup? = nil, transferFeeCategoryId: UUID? = nil,
    interestCategoryId: UUID? = nil
  ) {
    self.defaultCurrency = defaultCurrency
    self.setup = setup
    self.transferFeeCategoryId = transferFeeCategoryId
    self.interestCategoryId = interestCategoryId
  }

  /// The settings the rows give. A value that does not read — a currency that is not three
  /// Latin letters, an unknown state, an id that is not one — keeps its default: a damaged
  /// value must not stop anything from being computed.
  public init(storedValues values: [String: String]) {
    self.init(
      defaultCurrency: values[Self.defaultCurrencyKey].flatMap(Self.currency) ?? .rub,
      setup: values[Self.setupKey].flatMap {
        Setup(rawValue: $0.trimmingCharacters(in: .whitespaces))
      },
      transferFeeCategoryId: values[Self.transferFeeCategoryKey].flatMap {
        UUID(uuidString: $0.trimmingCharacters(in: .whitespaces))
      },
      interestCategoryId: values[Self.interestCategoryKey].flatMap {
        UUID(uuidString: $0.trimmingCharacters(in: .whitespaces))
      })
  }

  /// Three Latin letters, in any case; anything else is not a currency code.
  static func currency(_ text: String) -> CurrencyCode? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.count == 3,
      trimmed.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("a"..."z").contains($0) })
    else { return nil }
    return CurrencyCode(trimmed)
  }
}
