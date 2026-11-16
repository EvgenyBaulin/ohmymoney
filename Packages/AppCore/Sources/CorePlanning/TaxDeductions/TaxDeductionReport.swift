import CoreAnalytics
import CoreKit
import Foundation

/// One line of the yearly report: a group of spending that shares one limit.
public struct TaxDeductionGroup: Hashable, Sendable, Identifiable {
  public enum Key: Hashable, Sendable {
    /// Treatment, the owner's own education and sport: one limit for all three.
    case social
    /// Expensive treatment: no limit.
    case medicalExpensive
    /// A child's education, per child; `nil` — the parts named no child.
    case child(UUID?)
    /// Contributions to an individual investment account.
    case iis
    /// The interest of a mortgage.
    case mortgageInterest
  }

  public var key: Key
  public var id: Key { key }
  /// What was spent of each kind in the group, in rubles.
  public var byKind: [TaxDeductionKind: AmountE4]
  /// Operations, transfers and payments that make it up.
  public var operations: Int
  /// The limit of the group in the year; `nil` — none (expensive treatment) or no table.
  public var limit: AmountE4?
  /// What counts towards the deduction: the spending up to the limit.
  public var claimable: AmountE4

  public var spent: AmountE4 { AmountE4.sum(byKind.values) }

  public init(
    key: Key, byKind: [TaxDeductionKind: AmountE4], operations: Int, limit: AmountE4?,
    claimable: AmountE4
  ) {
    self.key = key
    self.byKind = byKind
    self.operations = operations
    self.limit = limit
    self.claimable = claimable
  }
}

/// The deductions of one year of spending.
public struct TaxDeductionYear: Hashable, Sendable {
  public var year: Int
  /// The limits the year goes by; `nil` — the table holds no year this early.
  public var rules: TaxDeductionRules.Year?
  /// In a fixed order: social, expensive treatment, children, investment account, mortgage.
  public var groups: [TaxDeductionGroup]
  /// The taxable income of the year the owner gave; `nil` — not given.
  public var income: AmountE4?
  /// What earlier years of the app's data already took of the mortgage limit (the limit is for
  /// life, not per year); the mortgage group's limit is what is left after it.
  public var mortgageUsedBefore: AmountE4
  /// Whether any earlier year holds mortgage interest. When none does, the mortgage group goes by
  /// the full limit, and the report says it is without the earlier years.
  public var mortgagePriorYearsKnown: Bool

  public init(
    year: Int, rules: TaxDeductionRules.Year?, groups: [TaxDeductionGroup], income: AmountE4?,
    mortgageUsedBefore: AmountE4 = .zero, mortgagePriorYearsKnown: Bool = false
  ) {
    self.year = year
    self.rules = rules
    self.groups = groups
    self.income = income
    self.mortgageUsedBefore = mortgageUsedBefore
    self.mortgagePriorYearsKnown = mortgagePriorYearsKnown
  }

  public var isEmpty: Bool { groups.allSatisfy { $0.spent.isZero } }

  /// Whether the mortgage group holds interest whose limit was counted without earlier years: the
  /// screen says so, because interest already deducted in a year the app has no data for makes
  /// the real limit smaller.
  public var mortgageLimitIgnoresEarlierYears: Bool {
    !mortgagePriorYearsKnown
      && groups.contains { $0.key == .mortgageInterest && $0.spent.raw > 0 }
  }

  /// What the deductions take off the taxable income.
  public var claimable: AmountE4 { AmountE4.sum(groups.map(\.claimable)) }

  /// No income was given, so `refund` is the most that can come back: the deduction at the
  /// lowest rate, and only if at least that much tax was paid.
  public var isUpperBound: Bool { income == nil }

  /// What the tax service returns. With the income: the tax on it less the tax on it after the
  /// deductions, so never more than the tax paid, and each ruble at the rate of its step. Without
  /// it: the deduction at the lowest rate («до N ₽»). `nil` when the table holds no rules for the
  /// year.
  public var refund: AmountE4? {
    guard let rules else { return nil }
    let deduction = claimable
    guard let income else {
      let whole = deduction.decimal * rules.basePercent / 100
      return AmountE4(whole: (try? DecimalMath.int64(rounding: whole)) ?? 0)
    }
    let after = income - deduction
    return rules.tax(on: income) - rules.tax(on: after.isNegative ? .zero : after)
  }

  /// The kinds the year has spending of, in the order of `TaxDeductionKind.allCases`.
  public var kinds: [TaxDeductionKind] {
    let present = Set(groups.flatMap { $0.byKind.filter { !$1.isZero }.keys })
    return TaxDeductionKind.allCases.filter(present.contains)
  }

  public func group(_ key: TaxDeductionGroup.Key) -> TaxDeductionGroup? {
    groups.first { $0.key == key }
  }
}

/// What can come back for a year of spending: the marked parts of the owner's spending, the
/// transfers into an individual investment account and the interest of a marked mortgage, each
/// group up to its limit from `TaxDeductionRules`.
public enum TaxDeductionReport {
  /// The year `year`. A part counts with what it adds to the owner's spending (`contribution`):
  /// a purchase less what its refunds took back, nothing for a part paid for someone else until
  /// it is written off, in rubles, on the day of the operation where it was recorded. `income`
  /// is the taxable income of the year the owner gave, never guessed from the operations.
  public static func year(
    _ year: Int, ledger: Ledger, rubPerUnit: [CurrencyCode: Decimal], income: AmountE4?,
    rules table: TaxDeductionRules = .builtIn
  ) -> TaxDeductionYear {
    let dataset = ledger.dataset
    let rules = table.rules(for: year)
    var marks: [UUID: TaxDeductionKind] = [:]
    for entry in dataset.entries where !entry.transaction.isDeleted {
      for part in entry.parts {
        if let kind = part.taxDeduction { marks[part.id] = kind }
      }
    }

    struct Tally {
      var byKind: [TaxDeductionKind: AmountE4] = [:]
      var operations = Set<String>()
    }
    var tallies: [TaxDeductionGroup.Key: Tally] = [:]
    func add(_ key: TaxDeductionGroup.Key, _ kind: TaxDeductionKind, _ rub: AmountE4, _ op: String)
    {
      tallies[key, default: Tally()].byKind[kind, default: .zero] += rub
      tallies[key, default: Tally()].operations.insert(op)
    }

    for row in ledger.rows where row.day.year == year && !row.contribution.isZero {
      guard let kind = marks[row.partId] else { continue }
      let key: TaxDeductionGroup.Key
      switch kind {
      case .medical, .education, .sport: key = .social
      case .medicalExpensive: key = .medicalExpensive
      case .educationChild: key = .child(row.forPersonId)
      case .iis: key = .iis
      case .mortgageInterest: continue
      }
      add(key, kind, row.contribution, "t:" + row.transactionId.uuidString)
    }

    let investment = Set(
      dataset.paymentMethods.filter { $0.taxDeduction == .iis }.map(\.id))
    for transfer in dataset.transfers where investment.contains(transfer.toAccountId) {
      guard !investment.contains(transfer.fromAccountId),
        ledger.calendar.day(of: transfer).year == year,
        let rub = rubles(of: transfer, rubPerUnit: rubPerUnit)
      else { continue }
      add(.iis, .iis, rub, "x:" + transfer.id.uuidString)
    }

    let mortgages = Set(
      dataset.debts.filter { $0.taxDeduction == .mortgageInterest && !$0.isDeleted }.map(\.id))
    var usedBefore = AmountE4.zero
    var priorKnown = false
    if !mortgages.isEmpty {
      for (index, line) in LoanInterestPaid.lines(year, ledger: ledger, rubPerUnit: rubPerUnit)
        .enumerated()
      {
        guard let debt = line.debtId, mortgages.contains(debt) else { continue }
        add(.mortgageInterest, .mortgageInterest, line.rub, "i:\(index)")
      }
      // The limit is for life: what earlier years took (each up to what was left) is gone.
      if let first = table.years.first?.year, first < year {
        for earlier in first..<year {
          let spent = AmountE4.sum(
            LoanInterestPaid.lines(earlier, ledger: ledger, rubPerUnit: rubPerUnit)
              .filter { $0.debtId.map(mortgages.contains) == true }.map(\.rub))
          guard spent.raw > 0 else { continue }
          priorKnown = true
          let limit = table.rules(for: earlier)?.mortgageInterestLimit ?? .zero
          usedBefore += min(spent, max(.zero, limit - usedBefore))
        }
      }
    }

    func limit(of key: TaxDeductionGroup.Key) -> AmountE4? {
      guard let rules else { return nil }
      switch key {
      case .social: return rules.socialLimit
      case .medicalExpensive: return nil
      case .child: return rules.childEducationLimit
      case .iis: return rules.iisLimit
      case .mortgageInterest: return max(.zero, rules.mortgageInterestLimit - usedBefore)
      }
    }
    let order: [TaxDeductionGroup.Key] =
      [.social, .medicalExpensive]
      + tallies.keys.compactMap { key -> (TaxDeductionGroup.Key, String)? in
        if case .child(let person) = key { return (key, person?.uuidString ?? "") }
        return nil
      }
      .sorted { $0.1 < $1.1 }.map(\.0) + [.iis, .mortgageInterest]
    let groups = order.compactMap { key -> TaxDeductionGroup? in
      guard let tally = tallies[key] else { return nil }
      let spent = AmountE4.sum(tally.byKind.values)
      let positive = spent.isNegative ? AmountE4.zero : spent
      let cap = limit(of: key)
      let claimable = cap.map { min(positive, $0) } ?? (rules == nil ? .zero : positive)
      return TaxDeductionGroup(
        key: key, byKind: tally.byKind, operations: tally.operations.count, limit: cap,
        claimable: claimable)
    }
    return TaxDeductionYear(
      year: year, rules: rules, groups: groups, income: income, mortgageUsedBefore: usedBefore,
      mortgagePriorYearsKnown: priorKnown)
  }

  /// The rubles that came into the account: the ruble side of the transfer, else the incoming
  /// amount at the rate of the day it is given at; `nil` when neither is known.
  private static func rubles(
    of transfer: Transfer, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    if transfer.toCurrency == .rub { return transfer.toAmountE4 }
    if transfer.fromCurrency == .rub { return transfer.fromAmountE4 }
    guard let rate = rubPerUnit[transfer.toCurrency] else { return nil }
    return InterestMath.cents(transfer.toAmountE4.decimal * rate)
  }
}

/// A document the tax service asks for. The raw value names the string of the interface
/// (`deductions.document.<raw>`).
public enum TaxDeductionDocument: String, Sendable, CaseIterable, Hashable {
  case declaration
  case incomeCertificate
  case medicalPaymentCertificate
  case prescription
  case clinicContract
  case educationPaymentCertificate
  case educationContract
  case birthCertificate
  case fullTimeStudyCertificate
  case sportPaymentCertificate
  case iisContract
  case brokerStatement
  case loanContract
  case bankInterestCertificate
  case ownershipExtract
  case paymentDocuments

  /// What every claim needs: the declaration 3-NDFL and the certificate of income and tax.
  public static let common: [TaxDeductionDocument] = [.declaration, .incomeCertificate]

  /// What the tax service asks for a kind, beyond `common`.
  public static func needed(for kind: TaxDeductionKind) -> [TaxDeductionDocument] {
    switch kind {
    case .medical, .medicalExpensive:
      [.medicalPaymentCertificate, .prescription, .clinicContract]
    case .education:
      [.educationPaymentCertificate, .educationContract]
    case .educationChild:
      [
        .educationPaymentCertificate, .educationContract, .birthCertificate,
        .fullTimeStudyCertificate,
      ]
    case .sport:
      [.sportPaymentCertificate]
    case .iis:
      [.iisContract, .brokerStatement]
    case .mortgageInterest:
      [.loanContract, .bankInterestCertificate, .ownershipExtract, .paymentDocuments]
    }
  }

  /// What the kinds need together, each document once, in the order the kinds name them.
  public static func needed(for kinds: [TaxDeductionKind]) -> [TaxDeductionDocument] {
    var seen = Set<TaxDeductionDocument>()
    return kinds.flatMap(needed(for:)).filter { seen.insert($0).inserted }
  }
}

/// The taxable income of a year the owner gives the report, kept in the `settings` table of the
/// database (it travels with the archive and the exchange) under `deductions.income.<YYYY>` as a
/// decimal string in rubles. A year without the key has no income: the report says «до N ₽».
public enum TaxDeductionIncome {
  public static let keyPrefix = "deductions.income."

  public static func key(_ year: Int) -> String { keyPrefix + String(year) }

  /// The income the stored text gives; text that does not read, or a negative number, is none.
  public static func income(from text: String?) -> AmountE4? {
    guard let text, let value = DecimalMath.parse(text), value >= 0,
      let amount = try? AmountE4(decimal: value)
    else { return nil }
    return amount
  }

  /// The text to store for `income`.
  public static func text(_ income: AmountE4) -> String { "\(income.decimal)" }
}
