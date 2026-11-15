import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Synthetic books for the yearly report of tax deductions: one ruble card, one broker's account
/// marked as an individual investment account, everything at noon utc.
private struct DeductionBooks {
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "DED00000-0000-0000-0000-%012d", number))!
  }
  static func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }
  static func noon(_ iso: String) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
  }
  static func money(_ text: String) -> AmountE4 { amountLiteral(text) }

  static let card = id(1)
  static let broker = id(2)
  static let savings = id(3)
  static let anya = id(10)
  static let misha = id(11)

  var entries: [TransactionEntry] = []
  var transfers: [Transfer] = []
  var debts: [Debt] = []
  var debtEntries: [DebtEntry] = []
  var accounts: [PaymentMethod] = [
    PaymentMethod(id: card, name: "Card", currency: .rub, isDefault: true),
    PaymentMethod(id: broker, name: "Broker", kind: .account, currency: .rub, taxDeduction: .iis),
    PaymentMethod(id: savings, name: "Savings", kind: .account, currency: .rub),
  ]

  static func expense(
    _ number: Int, _ iso: String, _ amount: String, _ kind: TaxDeductionKind?,
    person: UUID? = nil, reimbursable: Bool = false, status: ReimbursementStatus? = nil,
    currency: CurrencyCode = .rub, rubles: String? = nil, deleted: Bool = false,
    at moment: Date? = nil, timeZone: String? = nil
  ) -> TransactionEntry {
    let when = moment ?? noon(iso)
    let transactionId = id(1000 + number)
    let rub = money(rubles ?? amount)
    return TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: .expense, occurredAt: when, currency: currency,
        amountE4: money(amount), amountRubE4: rub, paymentMethodId: card, createdAt: when,
        updatedAt: when, deletedAt: deleted ? when : nil, timeZoneId: timeZone),
      parts: [
        TransactionPart(
          id: id(2000 + number), transactionId: transactionId, quality: .neutral,
          qualitySource: .category, amountE4: money(amount), amountRubE4: rub,
          forPersonId: person, reimbursable: reimbursable,
          debtorPersonId: reimbursable ? person : nil,
          reimbursementStatus: status, taxDeduction: kind)
      ])
  }

  static func refund(
    _ number: Int, _ iso: String, _ amount: String, of purchase: Int
  ) -> TransactionEntry {
    let when = noon(iso)
    let transactionId = id(1000 + number)
    return TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: .refund, occurredAt: when, amountE4: money(amount),
        paymentMethodId: card, createdAt: when, updatedAt: when),
      parts: [
        TransactionPart(
          id: id(2000 + number), transactionId: transactionId, amountE4: money(amount),
          refundOfPartId: id(2000 + purchase))
      ])
  }

  static func transfer(
    _ number: Int, _ iso: String, _ amount: String, to: UUID = broker
  ) -> Transfer {
    Transfer(
      id: id(3000 + number), occurredAt: noon(iso), fromAccountId: card, fromCurrency: .rub,
      fromAmountE4: money(amount), toAccountId: to, toCurrency: .rub, toAmountE4: money(amount),
      createdAt: noon(iso), updatedAt: noon(iso))
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, paymentMethods: accounts, debts: debts,
        planning: PlanningBook(debtEntries: debtEntries), transfers: transfers),
      calendar: .utc)
  }

  func report(_ year: Int = 2026, income: String? = nil) -> TaxDeductionYear {
    TaxDeductionReport.year(
      year, ledger: ledger, rubPerUnit: [:], income: income.map(Self.money))
  }
}

@Suite("Tax deductions: the table of limits and the scale")
struct TaxDeductionRulesTests {
  private typealias B = DeductionBooks

  @Test func theTableHoldsTheLimitsOfEachYear() throws {
    let rules = TaxDeductionRules.builtIn
    let now = try #require(rules.rules(for: 2026))
    #expect(now.year == 2026)
    #expect(now.socialLimit == B.money("150000"))
    #expect(now.childEducationLimit == B.money("110000"))
    #expect(now.iisLimit == B.money("400000"))
    #expect(now.mortgageInterestLimit == B.money("3000000"))
    #expect(now.basePercent == 13)
    // Spending of 2023 goes by the limits before 2024.
    let before = try #require(rules.rules(for: 2023))
    #expect(before.year == 2021)
    #expect(before.socialLimit == B.money("120000"))
    #expect(before.childEducationLimit == B.money("50000"))
    // A year past the table takes the newest one; a year before it has none.
    #expect(rules.rules(for: 2028)?.year == 2026)
    #expect(rules.rules(for: 2020) == nil)
  }

  @Test func theTaxFollowsTheScaleOfItsYear() throws {
    let rules = TaxDeductionRules.builtIn
    let now = try #require(rules.rules(for: 2026))
    #expect(now.tax(on: B.money("2400000")) == B.money("312000"))
    // 312 000 + 15 % of 600 000.
    #expect(now.tax(on: B.money("3000000")) == B.money("402000"))
    // 312 000 + 390 000 + 18 % of 1 000 000.
    #expect(now.tax(on: B.money("6000000")) == B.money("882000"))
    #expect(now.tax(on: .zero) == .zero)
    // Whole rubles, half up.
    #expect(now.tax(on: B.money("100.5")) == B.money("13"))
    let old = try #require(rules.rules(for: 2024))
    // 13 % of 5 000 000 + 15 % of 1 000 000.
    #expect(old.tax(on: B.money("6000000")) == B.money("800000"))
  }
}

@Suite("Tax deductions: what can come back for a year")
struct TaxDeductionReportTests {
  private typealias B = DeductionBooks

  @Test func treatmentEducationAndSportShareOneLimit() throws {
    var books = DeductionBooks()
    books.entries = [
      B.expense(1, "2026-02-03", "100000", .medical),
      B.expense(2, "2026-03-03", "40000", .education),
      B.expense(3, "2026-04-03", "30000", .sport),
      B.expense(4, "2026-04-04", "5000", nil),
    ]
    let report = books.report()
    let social = try #require(report.group(.social))
    #expect(social.spent == B.money("170000"))
    #expect(social.limit == B.money("150000"))
    #expect(social.claimable == B.money("150000"))
    #expect(social.byKind[.medical] == B.money("100000"))
    #expect(social.byKind[.sport] == B.money("30000"))
    #expect(social.operations == 3)
    #expect(report.claimable == B.money("150000"))
    // No income is known: «до» 13 % of the deduction.
    #expect(report.isUpperBound)
    #expect(report.refund == B.money("19500"))
    #expect(report.kinds == [.medical, .education, .sport])
  }

  @Test func theIncomeLimitsWhatComesBackAndTheScaleCounts() throws {
    var books = DeductionBooks()
    books.entries = [B.expense(1, "2026-02-03", "150000", .medical)]
    // 13 % of 1 000 000 less 13 % of 850 000.
    var report = books.report(income: "1000000")
    #expect(!report.isUpperBound)
    #expect(report.refund == B.money("19500"))
    // The tax of a small income is all that can come back.
    report = books.report(income: "100000")
    #expect(report.refund == B.money("13000"))
    // Above 2.4 million the deduction comes back at 15 %.
    report = books.report(income: "3000000")
    #expect(report.refund == B.money("22500"))
    report = books.report(income: "0")
    #expect(report.refund == .zero && !report.isUpperBound)
  }

  @Test func expensiveTreatmentHasNoLimitAndEachChildHasItsOwn() throws {
    var books = DeductionBooks()
    books.entries = [
      B.expense(1, "2026-02-03", "500000", .medicalExpensive),
      B.expense(2, "2026-02-04", "70000", .educationChild, person: B.anya),
      B.expense(3, "2026-09-04", "50000", .educationChild, person: B.anya),
      B.expense(4, "2026-09-05", "50000", .educationChild, person: B.misha),
    ]
    let report = books.report()
    let expensive = try #require(report.group(.medicalExpensive))
    #expect(expensive.limit == nil && expensive.claimable == B.money("500000"))
    let anya = try #require(report.group(.child(B.anya)))
    #expect(anya.spent == B.money("120000") && anya.claimable == B.money("110000"))
    #expect(anya.operations == 2)
    let misha = try #require(report.group(.child(B.misha)))
    #expect(misha.claimable == B.money("50000"))
    #expect(report.claimable == B.money("660000"))
  }

  @Test func refundsReimbursementsDeletionsCurrencyAndTheDayCount() throws {
    var books = DeductionBooks()
    let moscowNewYear = ISO8601DateFormatter().date(from: "2025-12-31T22:30:00Z")!
    books.entries = [
      B.expense(1, "2026-02-03", "10000", .medical),
      B.refund(2, "2026-02-10", "4000", of: 1),
      // Paid for someone else and expected back: not the owner's spending.
      B.expense(
        3, "2026-03-03", "8000", .medical, person: B.anya, reimbursable: true,
        status: .expected),
      B.expense(4, "2026-03-04", "7000", .medical, deleted: true),
      // Paid in euros: the rubles of the operation count.
      B.expense(5, "2026-05-05", "100", .medical, currency: CurrencyCode("EUR"), rubles: "9500"),
      // 1 January in Moscow, still 31 December in utc.
      B.expense(6, "2026-01-01", "1000", .sport, at: moscowNewYear, timeZone: "Europe/Moscow"),
      B.expense(7, "2025-12-30", "2000", .sport),
    ]
    let social = try #require(books.report().group(.social))
    #expect(social.byKind[.medical] == B.money("15500"))
    #expect(social.byKind[.sport] == B.money("1000"))
    #expect(books.report(2025).group(.social)?.spent == B.money("2000"))
  }

  @Test func contributionsToTheInvestmentAccountAreTransfersAndMarkedParts() throws {
    var books = DeductionBooks()
    books.transfers = [
      B.transfer(1, "2026-03-01", "300000"),
      B.transfer(2, "2026-06-01", "50000", to: B.savings),
      B.transfer(3, "2025-12-01", "70000"),
    ]
    books.entries = [B.expense(1, "2026-11-01", "200000", .iis)]
    let iis = try #require(books.report().group(.iis))
    #expect(iis.spent == B.money("500000"))
    #expect(iis.limit == B.money("400000"))
    #expect(iis.claimable == B.money("400000"))
    #expect(iis.operations == 2)
    #expect(books.report(2025).group(.iis)?.spent == B.money("70000"))
  }

  @Test func theInterestOfAMarkedMortgageCountsAndNoOtherLoan() throws {
    var books = DeductionBooks()
    let flat = B.id(80)
    let car = B.id(90)
    books.debts = [
      Debt(
        id: flat, direction: .iOwe, type: .loan, name: "Flat", interestRate: 12,
        accruesInterest: true, taxDeduction: .mortgageInterest),
      Debt(
        id: car, direction: .iOwe, type: .loan, name: "Car", interestRate: 12,
        accruesInterest: true),
    ]
    books.debtEntries = [flat, car].enumerated().flatMap { index, debt in
      [
        DebtEntry(
          id: B.id(81 + index * 10), debtId: debt, date: B.day("2026-01-01"),
          amountE4: B.money("1000000"), kind: .borrowed),
        DebtEntry(
          id: B.id(82 + index * 10), debtId: debt, date: B.day("2026-02-01"),
          amountE4: B.money("-50000"), kind: .payment),
      ]
    }
    let lines = LoanInterestPaid.lines(2026, ledger: books.ledger, rubPerUnit: [:])
    let paid = AmountE4.sum(lines.filter { $0.debtId == flat }.map(\.rub))
    #expect(paid.raw > 0)
    let mortgage = try #require(books.report().group(.mortgageInterest))
    #expect(mortgage.spent == paid)
    #expect(mortgage.claimable == paid)
    #expect(mortgage.limit == B.money("3000000"))
    #expect(books.report().kinds == [.mortgageInterest])
  }

  @Test func theMortgageLimitIsForLifeSoEarlierYearsUseItUp() throws {
    var books = DeductionBooks()
    let flat = B.id(80)
    books.debts = [
      Debt(
        id: flat, direction: .iOwe, type: .loan, name: "Flat", interestRate: 12,
        accruesInterest: true, taxDeduction: .mortgageInterest)
    ]
    books.debtEntries = [
      DebtEntry(
        id: B.id(81), debtId: flat, date: B.day("2025-01-01"), amountE4: B.money("1000000"),
        kind: .borrowed),
      DebtEntry(
        id: B.id(82), debtId: flat, date: B.day("2025-02-01"), amountE4: B.money("-50000"),
        kind: .payment),
      DebtEntry(
        id: B.id(83), debtId: flat, date: B.day("2026-02-01"), amountE4: B.money("-50000"),
        kind: .payment),
    ]
    let paid2025 = AmountE4.sum(
      LoanInterestPaid.lines(2025, ledger: books.ledger, rubPerUnit: [:]).map(\.rub))
    let paid2026 = AmountE4.sum(
      LoanInterestPaid.lines(2026, ledger: books.ledger, rubPerUnit: [:]).map(\.rub))
    #expect(paid2025.raw > 0 && paid2026 > B.money("1000"))
    // A life limit of last year's interest and 1 000 ₽ more.
    let lifeLimit = paid2025 + B.money("1000")
    let table = TaxDeductionRules(
      years: TaxDeductionRules.builtIn.years.map { year in
        var year = year
        year.mortgageInterestLimit = lifeLimit
        return year
      })
    let first = TaxDeductionReport.year(
      2025, ledger: books.ledger, rubPerUnit: [:], income: nil, rules: table)
    #expect(first.group(.mortgageInterest)?.claimable == paid2025)
    #expect(first.mortgagePriorYearsKnown == false)
    let second = TaxDeductionReport.year(
      2026, ledger: books.ledger, rubPerUnit: [:], income: nil, rules: table)
    let group = try #require(second.group(.mortgageInterest))
    #expect(second.mortgageUsedBefore == paid2025)
    #expect(second.mortgagePriorYearsKnown)
    #expect(group.limit == B.money("1000"))
    #expect(group.claimable == B.money("1000"))
  }

  @Test func aYearWithoutMarksIsEmptyAndAYearBeforeTheTableHasNoRules() {
    var books = DeductionBooks()
    #expect(books.report().isEmpty)
    #expect(books.report().refund == .zero)
    books.entries = [B.expense(1, "2019-02-03", "1000", .medical)]
    let old = books.report(2019)
    #expect(old.rules == nil)
    #expect(old.refund == nil)
    #expect(old.group(.social)?.spent == B.money("1000"))
  }

  @Test func everyKindNamesItsDocumentsAndTheDeclarationIsCommon() {
    for kind in TaxDeductionKind.allCases {
      #expect(!TaxDeductionDocument.needed(for: kind).isEmpty, "\(kind)")
    }
    #expect(TaxDeductionDocument.needed(for: .medical).contains(.medicalPaymentCertificate))
    #expect(TaxDeductionDocument.needed(for: .mortgageInterest).contains(.bankInterestCertificate))
    #expect(TaxDeductionDocument.needed(for: .educationChild).contains(.birthCertificate))
    #expect(TaxDeductionDocument.common == [.declaration, .incomeCertificate])
    let all = TaxDeductionDocument.needed(for: [.medical, .sport])
    #expect(Set(all).count == all.count, "a document is listed once")
  }
}

@Suite("Tax deductions: the income of a year in the settings")
struct TaxDeductionIncomeTests {
  @Test func theIncomeOfAYearIsKeptAsADecimalStringUnderItsKey() {
    #expect(TaxDeductionIncome.key(2026) == "deductions.income.2026")
    let income = amountLiteral("1234567.89")
    let text = TaxDeductionIncome.text(income)
    #expect(text == "1234567.89")
    #expect(TaxDeductionIncome.income(from: text) == income)
    #expect(TaxDeductionIncome.income(from: "0") == .zero)
    #expect(TaxDeductionIncome.income(from: "-5") == nil)
    #expect(TaxDeductionIncome.income(from: "много") == nil)
    #expect(TaxDeductionIncome.income(from: nil) == nil)
  }
}
