import CoreKit
import Foundation

/// A day with an optional minute of the day, as the bank wrote it. Banks give no time zone;
/// the zone is the profile's. Some sources (a list screen) have no time at all, and then the
/// minute is `nil` and the moment never takes part in time-based pairing.
public struct StatementMoment: Hashable, Sendable, Codable, Comparable {
  public var day: DateOnly
  public var minuteOfDay: Int?

  public init(day: DateOnly, minuteOfDay: Int? = nil) {
    self.day = day
    self.minuteOfDay = minuteOfDay
  }

  /// Minutes since 1970-01-01 00:00 of the bank's clock; `nil` when the time is unknown.
  public var absoluteMinutes: Int? {
    minuteOfDay.map { StatementCivil.dayNumber(day) * 1440 + $0 }
  }

  /// Whole minutes between two moments, `nil` if either has no time.
  public static func minutes(from a: StatementMoment, to b: StatementMoment) -> Int? {
    guard let x = a.absoluteMinutes, let y = b.absoluteMinutes else { return nil }
    return y - x
  }

  public static func days(from a: DateOnly, to b: DateOnly) -> Int {
    StatementCivil.dayNumber(b) - StatementCivil.dayNumber(a)
  }

  public static func < (lhs: StatementMoment, rhs: StatementMoment) -> Bool {
    if lhs.day != rhs.day { return lhs.day < rhs.day }
    return (lhs.minuteOfDay ?? -1) < (rhs.minuteOfDay ?? -1)
  }
}

/// Where the bank stands on an operation.
public enum StatementStatus: String, Sendable, Codable, Hashable {
  case posted
  /// Authorised and held, not yet posted. Counts as held money, not as a posted expense.
  case pending
  /// Refused by the bank. Never imported; it is only counted in the preview.
  case declined
  /// The source does not say (a screenshot shows a clock icon text recognition cannot read).
  case unknown
}

/// What an operation is, read from the bank's own fields and wording. This is a reading of
/// the file, not a bookkeeping decision: whether a transfer is one's own, an expense or a
/// gift is decided later by pairing, the identity of the owner, remembered rules and a
/// question.
public enum StatementOperationKind: String, Sendable, Codable, Hashable, CaseIterable {
  case purchase
  case purchaseRefund
  /// A positive card operation without wording; may be the refund of an earlier purchase.
  case cardCredit
  case servicePayment
  case mobileTopUp
  /// A transfer by phone number through the fast-payment system.
  case sbpTransferOut
  case sbpTransferIn
  case personTransferOut
  case personTransferIn
  /// «Internal transfer to contract N»: the bank names the owner's other contract.
  case ownContractTransferOut
  case ownContractTransferIn
  case cardTransferOut
  /// Money from a card or bank that the file does not name.
  case unnamedTransferIn
  case transferFee
  case bankFee
  case bankInterestCharge
  case depositInterest
  case cashbackPayout
  case cashbackCompensation
  case loanProceeds
  case loanRepayment
  case contractIncome
  case cashDeposit
  case savingsDeposit
  case savingsWithdrawal
  /// A card line the bank printed raw («CARD **1234 11AUG RUB 946.40 SHOP»).
  case rawCardLine
  case unknown
}

/// Who is on the other side of an operation, as far as the file says. Names and numbers are
/// personal data: they live in the parsed record and are never written to the log.
public struct StatementCounterparty: Sendable, Hashable, Codable {
  public var name: String?
  public var phone: String?
  public var bankName: String?
  /// The owner's other contract the bank names explicitly.
  public var contractRef: String?
  /// A masked card number, `2200 70** **** 3319`.
  public var cardMask: String?

  public init(
    name: String? = nil, phone: String? = nil, bankName: String? = nil,
    contractRef: String? = nil, cardMask: String? = nil
  ) {
    self.name = name
    self.phone = phone
    self.bankName = bankName
    self.contractRef = contractRef
    self.cardMask = cardMask
  }

  public var isEmpty: Bool {
    name == nil && phone == nil && bankName == nil && contractRef == nil && cardMask == nil
  }
}

/// One operation read from a statement, in the shape every format is normalised to. The
/// amount is signed (expense negative, income positive); the original text of the line is
/// not kept, only the cleaned description that the duplicate key and the rules need.
public struct ImportedOperation: Sendable, Hashable, Codable {
  public var profileID: String
  /// Position in the source, from zero, in file order.
  public var sourceIndex: Int
  /// Account the statement belongs to, as the file names it (last digits or contract
  /// number); empty when the format does not name one.
  public var accountRef: String
  public var cardTail: String?
  public var moment: StatementMoment
  /// Day of posting, when the bank gives one separately from the day of the operation.
  public var postedOn: DateOnly?
  public var status: StatementStatus
  /// In the currency of the operation.
  public var amount: AmountE4
  public var currency: CurrencyCode
  /// In the currency of the account, when it differs and the file says so.
  public var accountAmount: AmountE4?
  public var accountCurrency: CurrencyCode?
  public var kind: StatementOperationKind
  /// The bank's wording, blanks collapsed. This is what the duplicate key is built from.
  public var description: String
  public var counterparty: StatementCounterparty
  /// Place of a purchase with the noise of the bank taken off.
  public var merchant: String?
  public var message: String?
  public var mcc: String?
  public var bankCategory: String?
  public var comment: String?
  public var documentID: String?
  /// Cashback the bank says it will pay for this purchase. It wins over the account's own
  /// cashback rules when both exist.
  public var cashbackAccrued: AmountE4?
  /// Month a cashback payout names, if the wording names one.
  public var cashbackMonth: Int?
  /// Fee the bank took on top of the amount, positive.
  public var feeAmount: AmountE4?

  public init(
    profileID: String, sourceIndex: Int, accountRef: String = "", cardTail: String? = nil,
    moment: StatementMoment, postedOn: DateOnly? = nil, status: StatementStatus = .posted,
    amount: AmountE4, currency: CurrencyCode = .rub, accountAmount: AmountE4? = nil,
    accountCurrency: CurrencyCode? = nil, kind: StatementOperationKind = .unknown,
    description: String, counterparty: StatementCounterparty = StatementCounterparty(),
    merchant: String? = nil, message: String? = nil, mcc: String? = nil,
    bankCategory: String? = nil, comment: String? = nil, documentID: String? = nil,
    cashbackAccrued: AmountE4? = nil, cashbackMonth: Int? = nil, feeAmount: AmountE4? = nil
  ) {
    self.profileID = profileID
    self.sourceIndex = sourceIndex
    self.accountRef = accountRef
    self.cardTail = cardTail
    self.moment = moment
    self.postedOn = postedOn
    self.status = status
    self.amount = amount
    self.currency = currency
    self.accountAmount = accountAmount
    self.accountCurrency = accountCurrency
    self.kind = kind
    self.description = description
    self.counterparty = counterparty
    self.merchant = merchant
    self.message = message
    self.mcc = mcc
    self.bankCategory = bankCategory
    self.comment = comment
    self.documentID = documentID
    self.cashbackAccrued = cashbackAccrued
    self.cashbackMonth = cashbackMonth
    self.feeAmount = feeAmount
  }

  public var isIncome: Bool { !amount.isNegative }

  /// What names the place or person for comparing: the merchant if there is one, else the
  /// counterparty, else the description; folded so case and «ё» do not matter.
  public var placeKey: String {
    NameKey.fold(merchant ?? counterparty.name ?? counterparty.phone ?? description)
  }
}

/// Why a line of a statement could not be turned into an operation.
public enum StatementUnparsedReason: String, Sendable, Codable, Hashable {
  case columnCountMismatch
  case badDate
  case badAmount
  /// Both or neither of the income and expense columns are filled.
  case amountColumnsConflict
  /// The sign of the amount contradicts the bank's own «debit»/«credit» word.
  case signContradictsDirection
  /// A line of a text statement that sits where an operation should start but does not read
  /// as one.
  case unreadableLine
}

/// A line that was not imported, with the sum it carries when that can be read. Nothing is
/// dropped silently: the preview shows how many lines and how much money did not go through.
public struct StatementUnparsedLine: Sendable, Hashable, Codable {
  public var sourceIndex: Int
  public var reason: StatementUnparsedReason
  public var amount: AmountE4?
}

/// Facts from the head and the foot of a statement.
public struct StatementHeader: Sendable, Hashable, Codable {
  public var contractNumber: String?
  public var accountNumber: String?
  public var productName: String?
  public var openedOn: DateOnly?
  public var periodFrom: DateOnly?
  public var periodTo: DateOnly?
  /// «Income» and «expenses» totals printed in the foot of the statement, both positive.
  public var footerIncome: AmountE4?
  public var footerExpense: AmountE4?

  public init() {}

  /// Last four digits of the account number, the handle a statement is matched to an
  /// account by.
  public var accountTail: String? {
    guard let number = accountNumber ?? contractNumber else { return nil }
    let digits = StatementText.digits(number)
    return digits.isEmpty ? nil : String(digits.suffix(4))
  }
}

/// A check of the parsed statement against itself.
public struct StatementCheck: Sendable, Hashable, Codable {
  public enum Kind: String, Sendable, Codable, Hashable {
    /// The sums of the income and of the expense lines equal the totals in the foot.
    case footerTotals
    /// The sign of each amount agrees with the bank's debit/credit wording.
    case signMatchesDirection
    /// Exactly one of the income and expense columns is filled in each row.
    case oneAmountPerRow
    /// Every operation lies inside the period the statement declares.
    case datesInPeriod
  }

  public var kind: Kind
  public var passed: Bool
  /// A blocking check that failed stops the import; a non-blocking one is only shown.
  public var blocking: Bool
  /// For `footerTotals`: how much the footer says more than the lines add up to.
  public var missingIncome: AmountE4
  public var missingExpense: AmountE4
  /// Number of lines that broke the check.
  public var violations: Int

  public init(
    kind: Kind, passed: Bool, blocking: Bool, missingIncome: AmountE4 = .zero,
    missingExpense: AmountE4 = .zero, violations: Int = 0
  ) {
    self.kind = kind
    self.passed = passed
    self.blocking = blocking
    self.missingIncome = missingIncome
    self.missingExpense = missingExpense
    self.violations = violations
  }
}

/// Everything one statement file gives, before anything is written anywhere.
public struct StatementParseResult: Sendable, Hashable, Codable {
  public var profileID: String
  public var header: StatementHeader
  /// Operations to import, in file order. Declined ones are not here.
  public var operations: [ImportedOperation]
  public var declined: [ImportedOperation]
  public var unparsed: [StatementUnparsedLine]
  public var checks: [StatementCheck]
  /// The bytes were not UTF-8 and were read as windows-1251; the preview says so.
  public var usedLegacyEncoding: Bool

  /// Nothing blocks the import: every blocking check passed. Unparsed lines do not block
  /// by themselves — they are shown with their sum — except in a text statement, where a
  /// lost line breaks the footer check anyway.
  public var isImportable: Bool { !checks.contains { $0.blocking && !$0.passed } }

  /// Sum of the amounts that could be read in the lines that did not go through.
  public var unparsedSum: AmountE4 { AmountE4.sum(unparsed.compactMap(\.amount)) }
}

/// What a file turned out to be.
public enum StatementOutcome: Sendable {
  case parsed(StatementParseResult)
  /// No profile recognised the header or the first page. The cells of the first row are
  /// returned so a request for the bank can say what was seen. A file without a header row
  /// puts data there, so the caller shows them to the person only and never logs them.
  case unknownFormat(headerHint: [String])
  /// Fewer than one header row, or text that cannot be read at all.
  case unreadable
}
