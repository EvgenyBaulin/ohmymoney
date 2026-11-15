import Foundation

/// What a personal income tax deduction may be claimed for. The raw value is what the database
/// keeps (`transaction_parts.tax_deduction`, `debts.tax_deduction`,
/// `payment_methods.tax_deduction`) and what the CSV writes; it never changes once shipped, and a
/// later build may add a value, which this one reads as none.
public enum TaxDeductionKind: String, Codable, Sendable, CaseIterable, Hashable {
  /// Treatment and medicines for the owner or the family.
  case medical
  /// Expensive treatment from the government's list: no limit.
  case medicalExpensive = "medical_expensive"
  /// The owner's own education (or a brother's or sister's).
  case education
  /// A child's education: its own limit per child.
  case educationChild = "education_child"
  /// Sport and fitness services.
  case sport
  /// A contribution to an individual investment account.
  case iis
  /// The interest paid on a mortgage.
  case mortgageInterest = "mortgage_interest"

  /// The kinds a part of an operation may carry: the spending itself is the base.
  public static let partKinds: [TaxDeductionKind] = [
    .medical, .medicalExpensive, .education, .educationChild, .sport, .iis,
  ]

  /// The kind a debt may carry: the interest the loan was paid.
  public static let debtKinds: [TaxDeductionKind] = [.mortgageInterest]

  /// The kind an account may carry: the money moved into it is the contribution.
  public static let accountKinds: [TaxDeductionKind] = [.iis]

  /// The social deductions that share one yearly limit.
  public var sharesSocialLimit: Bool {
    self == .medical || self == .education || self == .sport
  }

  /// The kind a part keeps from the text the database holds; anything else is none.
  public static func part(_ stored: String?) -> TaxDeductionKind? {
    stored.flatMap(TaxDeductionKind.init(rawValue:)).flatMap { partKinds.contains($0) ? $0 : nil }
  }

  /// The kind a debt keeps from the text the database holds; anything else is none.
  public static func debt(_ stored: String?) -> TaxDeductionKind? {
    stored.flatMap(TaxDeductionKind.init(rawValue:)).flatMap { debtKinds.contains($0) ? $0 : nil }
  }

  /// The kind an account keeps from the text the database holds; anything else is none.
  public static func account(_ stored: String?) -> TaxDeductionKind? {
    stored.flatMap(TaxDeductionKind.init(rawValue:))
      .flatMap { accountKinds.contains($0) ? $0 : nil }
  }
}
