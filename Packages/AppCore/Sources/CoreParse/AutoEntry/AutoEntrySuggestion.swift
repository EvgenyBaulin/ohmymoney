import CoreKit
import Foundation

/// How a text a bank sent on its own — an SMS or a push passed on by «Быстрые команды» — is
/// written: offered first (the owner's default: «Кафе 450 ₽ — записать?» with «Записать» and
/// «Изменить»), or written at once, when the owner switches it so.
public enum AutoEntryMode: String, CaseIterable, Hashable, Sendable {
  case propose
  case immediate

  public static let standard = AutoEntryMode.propose
}

/// What is kept of a text of a bank: the fields read out of it and the line they make, never
/// the text itself. A push carries more than the operation (the balance of other cards, a code,
/// an advert), and the owner's rule is that a message is not stored whole anywhere — not in the
/// base, not in a notification, not in a log.
public struct AutoEntrySuggestion: Hashable, Sendable, Codable, Identifiable {
  public var id: UUID
  public var receivedAt: Date
  public var bank: BankBrand
  public var operation: BankOperation
  public var money: Money
  public var merchant: String?
  public var cardLast4: String?
  public var isAccountDigits: Bool
  public var balance: Money?
  public var day: DateOnly?
  /// The line the entry line reads back as this operation («Кофемания 450 Платинум»).
  public var line: String

  public init(
    message: BankMessage, line: String, id: UUID = UUID(), receivedAt: Date
  ) {
    self.id = id
    self.receivedAt = receivedAt
    bank = message.bank
    operation = message.operation
    money = message.money
    merchant = message.merchant
    cardLast4 = message.cardLast4
    isAccountDigits = message.isAccountDigits
    balance = message.balance
    day = message.day
    self.line = line
  }

  public var kind: TransactionKind { operation.kind }

  /// The key the owner's corrections are kept under: the shop as the bank spells it, letters and
  /// digits only.
  public var merchantKey: String? {
    merchant.flatMap { AutoEntryNames.key(of: $0) }
  }

  /// Two texts about the same operation — the SMS and the push of one purchase, or one message
  /// passed on twice — have the same fingerprint; two coffees of the same price do not, since
  /// the balance after each differs.
  public var fingerprint: String {
    [
      operation.rawValue, String(money.amount.raw), money.currency.code, cardLast4 ?? "",
      merchantKey ?? "", balance.map { String($0.amount.raw) } ?? "", day?.iso ?? "",
    ].joined(separator: "|")
  }
}

extension BankTextParser {
  /// One text of a bank, read with the owner's own banks in mind: a text signed by a bank of the
  /// owner's accounts («Озон Банк», «Совкомбанк») does not give that bank's name as the shop.
  /// The four banks with templates (Т-Банк, Сбер, Альфа, ВТБ) are known to the parser already.
  public func parse(_ text: String, today: DateOnly?, ownBanks: [String]) -> BankMessage? {
    guard var message = parse(text, today: today) else { return nil }
    if let merchant = message.merchant {
      let key = AutoEntryNames.key(of: merchant)
      let banks = Set(ownBanks.compactMap(AutoEntryNames.key(of:)))
      if let key, banks.contains(key) { message.merchant = nil }
    }
    return message
  }
}

/// The owner's corrections of a shop's name: «KOFEMANIYA» once written as «Кофемания» is
/// offered as «Кофемания» from then on — and with it the category the history of «Кофемания»
/// gives. Kept as JSON in the `settings` table (`autoEntry.names`), so it travels in the archive
/// with the rest of the owner's data.
public struct AutoEntryNames: Hashable, Sendable, Codable {
  public static let settingsKey = "autoEntry.names"
  /// More names than this keep the latest ones: the list is a habit, not a ledger.
  public static let capacity = 500

  public private(set) var names: [String: String]
  /// Keys in the order they were last taught, oldest first.
  public private(set) var order: [String]

  public init() {
    names = [:]
    order = []
  }

  /// The key of a shop as a bank spells it: letters and digits only, lower case, «ё» as «е»;
  /// `nil` without a letter.
  public static func key(of merchant: String) -> String? {
    let key = BankMerchants.squeezed(merchant)
    return key.contains(where: \.isLetter) ? key : nil
  }

  public func name(for merchant: String) -> String? {
    Self.key(of: merchant).flatMap { names[$0] }
  }

  /// The owner wrote the operation of `merchant` under `name`. Returns whether anything changed:
  /// a name the bank's own spelling already gives, or an empty one, teaches nothing.
  @discardableResult
  public mutating func learn(merchant: String, name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let key = Self.key(of: merchant), !trimmed.isEmpty,
      trimmed.contains(where: \.isLetter)
    else { return false }
    let builtIn = BankMerchants.resolve(merchant)?.name
    if names[key] == trimmed { return false }
    if names[key] == nil, let builtIn, NameKey.fold(builtIn) == NameKey.fold(trimmed) {
      return false
    }
    names[key] = trimmed
    order.removeAll { $0 == key }
    order.append(key)
    while order.count > Self.capacity {
      names[order.removeFirst()] = nil
    }
    return true
  }

  public func encoded() -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
  }

  public static func decoded(_ text: String?) -> AutoEntryNames {
    guard let data = text?.data(using: .utf8),
      let names = try? JSONDecoder().decode(AutoEntryNames.self, from: data)
    else { return AutoEntryNames() }
    return names
  }
}
