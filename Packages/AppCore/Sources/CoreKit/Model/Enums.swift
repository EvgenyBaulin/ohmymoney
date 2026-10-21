import Foundation

/// Raw values match the SQL schema in `Schema/` exactly: the same strings are stored by
/// the macOS app today and must be readable by the future Windows port.
public enum TransactionKind: String, Codable, Sendable, CaseIterable {
  case expense
  case income
  case refund
  case reimbursement

  /// Refunds and reimbursements move money back to me, so they never create new spending.
  public var reducesSpending: Bool { self == .refund || self == .reimbursement }

  /// The kind of category an operation of this kind is filed under. A refund takes money
  /// off the spending category it came from, and a reimbursement is money for spending I
  /// did for somebody else, so only income lives among the income categories.
  public var categoryKind: CategoryKind { self == .income ? .income : .expense }

  /// Only spending is rated good, neutral or bad: an expense, and a refund that takes part
  /// of one back. Income and money a person gave back have no quality at all.
  public var hasQuality: Bool { self == .expense || self == .refund }
}

public enum CategoryKind: String, Codable, Sendable, CaseIterable {
  case expense
  case income
}

/// How good a piece of spending is for me. Income has no quality.
public enum Quality: String, Codable, Sendable, CaseIterable {
  case good
  case neutral
  case bad
}

/// Which rule produced the quality, in the order the rules are applied.
public enum QualitySource: String, Codable, Sendable, CaseIterable {
  case system
  case history
  case category
  case manual
}

public enum CategorySource: String, Codable, Sendable, CaseIterable {
  case manual
  case history
  case model
  case template
  case imported = "import"
  case system
}

/// Categories the app owns: they cannot be renamed, deleted or given a limit.
public enum SystemRole: String, Codable, Sendable, CaseIterable {
  case goals
  case loans
  case unknown
  case surcharges
}

/// Analytics-only split. It never changes whether something counts as my spending.
public enum ForWhom: String, Codable, Sendable, CaseIterable {
  case me
  case partner
  case friends
  case family
  case other
}

public enum PersonRelation: String, Codable, Sendable, CaseIterable {
  case family
  case partner
  case friend
  case other
}

public enum PaymentMethodKind: String, Codable, Sendable, CaseIterable {
  case card
  case cash
  case account
  case other
}

public enum EventKind: String, Codable, Sendable, CaseIterable {
  case birthday
  case newYear = "new_year"
  case trip
  case holiday
  case other
}

/// A part paid for someone else: it is not my spending until it is written off.
public enum ReimbursementStatus: String, Codable, Sendable, CaseIterable {
  case expected
  case returned
  case writtenOff = "written_off"
}

public enum RateSource: String, Codable, Sendable, CaseIterable {
  case cbr
  case cbrMirror = "cbr_mirror"
  case manual
  case imported = "import"

  /// Manual rates and rates that came with an import are never overwritten automatically.
  public var isProtected: Bool { self == .manual || self == .imported }
}

public enum DebtDirection: String, Codable, Sendable, CaseIterable {
  case iOwe = "i_owe"
  case owedToMe = "owed_to_me"
}

public enum DebtType: String, Codable, Sendable, CaseIterable {
  case loan
  case creditCard = "credit_card"
  case installment
  case personal
}

/// `existing` — a debt I already had: its payments are expenses in Loans.
/// `purchase` — something bought on credit here: the expense is recorded once, at purchase.
public enum DebtOrigin: String, Codable, Sendable, CaseIterable {
  case existing
  case purchase
}

public enum DebtEntryKind: String, Codable, Sendable, CaseIterable {
  case borrowed
  case offset
  case payment
  case transferIn = "transfer_in"
  case transferOut = "transfer_out"
  case adjustment
}

public enum ScheduledKind: String, Codable, Sendable, CaseIterable {
  case bill
  case subscription
}

public enum Frequency: String, Codable, Sendable, CaseIterable {
  case weekly
  case monthly
  case yearly
}

public enum ExpectedIncomeKind: String, Codable, Sendable, CaseIterable {
  case oneOff = "one_off"
  case recurring
}

public enum BudgetScope: String, Codable, Sendable, CaseIterable {
  case category
  case badTotal = "bad_total"
  case forWhom = "for_whom"
}

public enum LimitStatus: String, Codable, Sendable, CaseIterable {
  case ok
  case warning
  case over
}
