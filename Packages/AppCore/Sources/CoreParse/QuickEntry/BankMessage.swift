import CoreKit
import Foundation

/// The bank a text came from, as far as its shape says. The bank never changes what is read:
/// the fields come from the same scan for every bank, and a text from a bank nobody wrote a
/// template for is read as long as it has the usual parts (an operation word, an amount, a
/// card or a balance). The brand is for the owner's eye and for the corpus tests.
public enum BankBrand: String, Hashable, Sendable, CaseIterable, Codable {
  case sber
  case tbank
  case vtb
  case raiffeisen
  case alfa
  case unknown
}

/// What the bank says happened.
public enum BankOperation: String, Hashable, Sendable, CaseIterable, Codable {
  case purchase
  case cashWithdrawal
  case transferOut
  case transferIn
  /// Salary, an advance, interest, a cashback that came.
  case income
  case refund
  case fee

  /// The kind of entry it is written as. A withdrawal and a transfer out are spending of the
  /// account until the app turns them into a transfer between accounts.
  public var kind: TransactionKind {
    switch self {
    case .purchase, .cashWithdrawal, .transferOut, .fee: .expense
    case .transferIn, .income: .income
    case .refund: .refund
    }
  }
}

/// One operation read out of a text of a bank: a push, an SMS, a letter, a row of a history.
public struct BankMessage: Hashable, Sendable {
  public var bank: BankBrand
  public var operation: BankOperation
  /// What moved, always above zero; the sign is `operation`.
  public var money: Money
  /// The shop or the person as the bank wrote it («PYATEROCHKA 4512» without the number).
  public var merchant: String?
  /// The last four digits of the card — or of the account, see `isAccountDigits`.
  public var cardLast4: String?
  public var isAccountDigits: Bool
  /// What the text says is left on the card after the operation.
  public var balance: Money?
  public var time: TimeOfDay?
  /// The day when the text names one (a row of a history does, a push usually does not).
  public var day: DateOnly?
  /// The text it was read from, trimmed.
  public var source: String
  /// What the text says the bank took as a commission, and the cashback it gave for the
  /// operation: fields of the operation, never operations of their own. Only a format file
  /// (`SmsFormat`) names them.
  public var fee: Money?
  public var cashback: Money?
  /// What is available to spend (a credit card's limit included); never compared with the books.
  public var availableBalance: Money?
  /// The merchant category code, when the text gives one.
  public var mcc: Int?
  /// The bank's own id of the operation.
  public var syncid: String?
  public var comment: String?
  /// The format that read the text; nil for the general scan.
  public var formatId: String?

  public init(
    bank: BankBrand = .unknown, operation: BankOperation, money: Money, merchant: String? = nil,
    cardLast4: String? = nil, isAccountDigits: Bool = false, balance: Money? = nil,
    time: TimeOfDay? = nil, day: DateOnly? = nil, source: String = ""
  ) {
    self.bank = bank
    self.operation = operation
    self.money = money
    self.merchant = merchant
    self.cardLast4 = cardLast4
    self.isAccountDigits = isAccountDigits
    self.balance = balance
    self.time = time
    self.day = day
    self.source = source
  }

  public var kind: TransactionKind { operation.kind }

  /// The merchant category code as the operation stores it: four digits, or `nil` when the text
  /// gave none or one outside 0000…9999.
  public var merchantCode: String? { MerchantCode.normalized(mcc) }

  /// What the text says beyond the line that the operation stores: the merchant code and the
  /// commission. `nil` when it names neither.
  public var storedFields: BankStoredFields? {
    let fields = BankStoredFields(mcc: merchantCode, fee: fee)
    return fields.mcc == nil && fields.fee == nil ? nil : fields
  }

  /// The balance is offered as «Сверить «Платинум» на 52 340,11?» after the operation is
  /// written. It is a tick the owner sets: a count is the owner's decision, never made on the
  /// way.
  public static let reconcileOfferedByDefault = false

  /// The line the entry field is filled with, which the entry line reads back as this very
  /// operation: «Пятёрочка 1250», «+85000 Иван И.», «возврат Ozon 700», «USD» after a foreign
  /// amount. `merchantName` is the place as the owner's list knows it (`BankMerchants`).
  public func suggestedLine(merchantName: String? = nil) -> String {
    let name = (merchantName ?? merchant)?.trimmingCharacters(in: .whitespaces) ?? ""
    var amount = BankMessage.plain(money.amount)
    if money.currency != .rub { amount += " " + money.currency.code }
    let words: [String]
    switch operation {
    case .purchase, .transferOut, .fee: words = [name, amount]
    case .cashWithdrawal: words = [name.isEmpty ? "снятие наличных" : name, amount]
    case .income, .transferIn: words = [name, "+" + amount]
    case .refund: words = ["возврат", name, amount]
    }
    // The cashback the text names goes in as the entry line's own phrase; a figure in another
    // currency than the amount would be read as the amount's.
    if kind == .expense, let cashback, cashback.amount > .zero, cashback.currency == money.currency
    {
      return (words.filter { !$0.isEmpty } + ["кэшбэк", BankMessage.plain(cashback.amount)])
        .joined(separator: " ")
    }
    return words.filter { !$0.isEmpty }.joined(separator: " ")
  }

  /// An amount as the entry line takes it: whole rubles without a fraction, a point before the
  /// fraction otherwise, no grouping.
  static func plain(_ amount: AmountE4) -> String {
    NumberText.plain(amount.decimal)
  }
}

/// The merchant code and the commission a text of a bank named: what an operation written from
/// that text stores besides what the entry line says. Kept per draft until the draft is written.
public struct BankStoredFields: Hashable, Sendable, Codable {
  public var mcc: String?
  public var fee: Money?

  public init(mcc: String? = nil, fee: Money? = nil) {
    self.mcc = MerchantCode.normalized(mcc)
    self.fee = fee
  }

  /// The commission, when it is above zero and in `currency` — the currency of the operation it
  /// is written into. A fee in another currency is not kept: the stored field carries no
  /// currency of its own.
  public func commission(in currency: CurrencyCode) -> AmountE4? {
    guard let fee, fee.amount > .zero, fee.currency == currency else { return nil }
    return fee.amount
  }
}
