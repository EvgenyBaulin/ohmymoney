import CoreAccounting
import CoreArchive
import CoreKit
import Foundation
import Testing

@testable import CoreSample

/// The education loan and the savings account the sample adds after its later count: its own
/// sequence of draws, pinned; every layer under it left exactly as it was; and the loan and the
/// account the way the app writes them.
@Suite("The education loan and the savings account of the sample")
struct SampleLoanAndSavingsTests {
  static let seed = SampleFeatureLayersTests.seed

  /// The set through this layer, without the ones written after it.
  static func layered(language: String = "en") -> SampleDataSet {
    let seed = SampleFeatureLayersTests.seed
    return SampleFeatureLayersTests.history(language: language)
      .withAccounts(seed: seed, calendar: .moscow, language: language)
      .withLayersThroughTheLoanAndSavings(
        seed: seed, calendar: .moscow, language: language, now: nil, demo: false)
  }

  static func earlier(language: String = "en") -> SampleDataSet {
    SampleFeatureLayersTests.throughTheCounts(language: language)
  }

  /// What the layer's draws decide: the account and its count, the subcategory and the loan, the
  /// lines of its journal, the operations and the transfer it adds, and the money at the end.
  static func digest(_ set: SampleDataSet, over earlier: SampleDataSet) -> String {
    func id(_ value: UUID?) -> String { value?.uuidString.lowercased() ?? "-" }
    var text = ""
    for account in set.paymentMethods.dropFirst(earlier.paymentMethods.count) {
      text +=
        "account \(id(account.id))|\(account.sort)|\(account.interest?.openedOn?.iso ?? "-")\n"
    }
    for count in set.reconciledBalances.dropFirst(earlier.reconciledBalances.count) {
      text += "count \(id(count.id))|\(id(count.reconciliationId))|\(count.actualE4.raw)\n"
    }
    for category in set.categories.dropFirst(earlier.categories.count) {
      text += "category \(id(category.id))|\(id(category.parentId))|\(category.sort)\n"
    }
    for debt in set.debts.dropFirst(earlier.debts.count) {
      text += "debt \(id(debt.id))|\(debt.paymentDay ?? 0)|\(debt.grace?.mainFrom.iso ?? "-")\n"
    }
    for line in set.debtEntries.dropFirst(earlier.debtEntries.count) {
      text += "line \(id(line.id))|\(line.kind.rawValue)|\(line.amountE4.raw)"
      text += "|\(line.date?.iso ?? "-")|\(id(line.transactionId))|\(line.tranche)\n"
    }
    let before = Set(earlier.entries.map(\.id))
    for entry in set.entries where !before.contains(entry.id) {
      let transaction = entry.transaction
      text += "\(id(transaction.id))|\(transaction.kind.rawValue)"
      text += "|\(Int(transaction.occurredAt.timeIntervalSince1970))|\(transaction.amountE4.raw)"
      text += "|\(id(transaction.paymentMethodId))|\(id(transaction.debtId))"
      text += "|\(id(transaction.creditDebtId))|\(transaction.externalId ?? "-")\n"
      for part in entry.parts {
        text += "  \(id(part.id))|\(id(part.categoryId))|\(part.amountE4.raw)\n"
      }
    }
    let transfers = Set(earlier.transfers.map(\.id))
    for transfer in set.transfers where !transfers.contains(transfer.id) {
      text += "transfer \(id(transfer.id))"
      text += "|\(Int(transfer.occurredAt.timeIntervalSince1970))|\(transfer.fromAmountE4.raw)\n"
    }
    for (key, amount) in set.accountExpectations.sorted(by: { $0.key < $1.key }) {
      text += "end \(id(key.accountId))|\(key.currency.code)|\(amount.raw)\n"
    }
    return SHA256.hexDigest(Data(text.utf8))
  }

  @Test func theLayerDrawsTheSameSequence() {
    let earlier = Self.earlier()
    let set = Self.layered()

    // Two tranches, two grace payments with their interest, and the interest of the savings.
    #expect(set.entries.count - earlier.entries.count == 7)
    #expect(
      Self.digest(set, over: earlier)
        == "a03b3d1055345c1b589d46dc99d6412ffa15ce53a3878d156507c0f19065aa26",
      """
      The education loan and the savings account drew a different sequence. If this was meant —
      a new feature, another amount — put the digest printed by the failure here and say why in
      the commit. If it was not, something asked the layer's random source for one more value.
      """)
  }

  /// Every layer under it keeps what it wrote: the layer only adds.
  @Test func theLayersUnderItAreKept() {
    let earlier = Self.earlier()
    let set = Self.layered()
    let byId = Dictionary(uniqueKeysWithValues: set.entries.map { ($0.id, $0) })
    #expect(earlier.entries.allSatisfy { byId[$0.id] == $0 })
    #expect(
      Array(set.paymentMethods.prefix(earlier.paymentMethods.count)) == earlier.paymentMethods)
    #expect(Array(set.categories.prefix(earlier.categories.count)) == earlier.categories)
    #expect(Array(set.debts.prefix(earlier.debts.count)) == earlier.debts)
    #expect(Array(set.debtEntries.prefix(earlier.debtEntries.count)) == earlier.debtEntries)
    #expect(
      Array(set.reconciliations.prefix(earlier.reconciliations.count)) == earlier.reconciliations)
    #expect(
      Array(set.reconciledBalances.prefix(earlier.reconciledBalances.count))
        == earlier.reconciledBalances)
    #expect(Set(earlier.transfers).isSubset(of: Set(set.transfers)))
    #expect(set.cards == earlier.cards && set.cashbackRules == earlier.cashbackRules)
    #expect(set.planning == earlier.planning)
    #expect(set.places == earlier.places && set.events == earlier.events)
    let main = set.mainAccount?.id
    for (key, amount) in earlier.accountExpectations where key.accountId != main {
      #expect(set.accountExpectations[key] == amount, "\(key)")
    }
  }

  /// The loan: the state programme at 3 %, interest charged by the bank, the main schedule two
  /// years ahead over 180 months, its payments no expense.
  @Test func theEducationLoanIsTheStateProgramme() throws {
    let set = Self.layered(language: "ru")
    let loan = try #require(set.debts.first { $0.name == "Образовательный кредит" })
    #expect(loan.direction == .iOwe && loan.type == .loan && loan.origin == .existing)
    #expect(loan.interestRate == 3 && loan.accruesInterest)
    #expect(loan.grace?.payment == .programme && loan.repayMonths == 180)
    #expect(!loan.paymentsAreExpenses && loan.monthlyPaymentE4 == nil)
    let mainFrom = try #require(loan.grace?.mainFrom)
    #expect(mainFrom == DateOnly(year: set.lastDay.year + 2, month: set.lastDay.month, day: 1))
    let payday = try #require(loan.paymentDay)
    #expect((1...28).contains(payday))
    #expect(loan.hasDues)
    let subcategory = try #require(set.categories.first { $0.id == loan.loansSubcategoryId })
    #expect(subcategory.name == loan.name)
    #expect(set.categories.first { $0.id == subcategory.parentId }?.systemRole == .loans)
  }

  /// Two tranches, each an expense in «Образование» on the loan, the line of the journal that
  /// grows the debt naming it; neither moves money.
  @Test func eachTrancheIsAnExpenseInEducation() throws {
    let set = Self.layered(language: "ru")
    let loan = try #require(set.debts.first { $0.accruesInterest })
    let education = try #require(set.categories.first { $0.name == "Образование" })
    let tranches = set.debtEntries.filter { $0.debtId == loan.id && $0.tranche }
    #expect(tranches.count == 2)
    #expect(set.debtEntries.filter { $0.debtId == loan.id && $0.amountE4.raw > 0 } == tranches)
    let tree = CategoryTree(set.categories)
    for line in tranches {
      #expect(line.kind == .borrowed && line.amountE4.raw > 0)
      let entry = try #require(set.entries.first { $0.id == line.transactionId })
      #expect(entry.transaction.kind == .expense && entry.transaction.creditDebtId == loan.id)
      #expect(entry.transaction.amountE4 == line.amountE4)
      #expect(entry.parts.map(\.categoryId) == [education.id])
      #expect(set.calendarDay(of: entry) == line.date)
      #expect(!AccountBalances.movesMoney(entry, tree: tree))
    }
  }

  /// Every grace due up to the last day is paid exactly what the programme asks — 40 % of the
  /// interest of its month on the money drawn —, and beside each payment the interest
  /// operation the app writes: all of the payment, on the loan as a purchase on credit.
  @Test func everyGraceDueIsPaidWithItsInterestBeside() throws {
    let set = Self.layered()
    let loan = try #require(set.debts.first { $0.accruesInterest })
    let payday = try #require(loan.paymentDay)
    let drawn = set.debtEntries.filter { $0.debtId == loan.id && $0.tranche }
      .sorted { ($0.date ?? set.lastDay) < ($1.date ?? set.lastDay) }
    var running = AmountE4.zero
    let segments = drawn.map { line -> (from: DateOnly, amount: AmountE4) in
      running += line.amountE4
      return (line.date ?? set.lastDay, running)
    }
    let payments = set.debtEntries.filter { $0.debtId == loan.id && $0.kind == .payment }
      .sorted { ($0.date ?? set.lastDay) < ($1.date ?? set.lastDay) }
    #expect(payments.count == 2)
    let tree = CategoryTree(set.categories)
    for line in payments {
      let due = try #require(line.date)
      #expect(due.day == payday && due < set.lastDay)
      let previous = due.monthKey.previous
      let accrued = InterestMath.accrue(
        segments: segments, percent: 3,
        after: DateOnly(year: previous.year, month: previous.month, day: payday), through: due)
      let asked = InterestMath.cents(accrued * Decimal(4) / 10)
      #expect(line.amountE4 == -asked, "\(due.iso)")

      let payment = try #require(set.entries.first { $0.id == line.transactionId })
      #expect(payment.transaction.debtId == loan.id && payment.transaction.kind == .expense)
      #expect(payment.transaction.amountE4 == asked)
      #expect(payment.parts.map(\.categoryId) == [loan.loansSubcategoryId])
      #expect(AccountBalances.movesMoney(payment, tree: tree))

      let interest = try #require(
        set.entries.first { entry in
          entry.transaction.externalId
            == "debtinterest:\(payment.id.uuidString.lowercased()):"
            + entry.id.uuidString.lowercased()
        })
      #expect(interest.transaction.creditDebtId == loan.id && interest.transaction.debtId == nil)
      #expect(interest.transaction.amountE4 == asked)
      #expect(interest.transaction.occurredAt == payment.transaction.occurredAt)
      #expect(interest.transaction.paymentMethodId == payment.transaction.paymentMethodId)
      #expect(interest.parts.map(\.categoryId) == [loan.loansSubcategoryId])
      #expect(!AccountBalances.movesMoney(interest, tree: tree))
    }
  }

  /// Money moves on an account only after its last count before the layer: the counts under it
  /// still find what they found.
  @Test func nothingMovesMoneyBeforeACountOfItsAccount() {
    let earlier = Self.earlier()
    let set = Self.layered()
    let before = Set(earlier.entries.map(\.id))
    let tree = CategoryTree(set.categories)
    let moments = Dictionary(
      uniqueKeysWithValues: set.reconciliations.map { ($0.id, $0.reconciledAt ?? .distantPast) })
    func lastCount(of account: UUID) -> Date? {
      earlier.reconciledBalances.filter { $0.accountId == account }
        .compactMap { moments[$0.reconciliationId] }.max()
    }
    for entry in set.entries where !before.contains(entry.id) {
      guard AccountBalances.movesMoney(entry, tree: tree),
        let account = entry.transaction.paymentMethodId, let counted = lastCount(of: account)
      else { continue }
      #expect(entry.transaction.occurredAt > counted, "\(entry.id)")
    }
    let transfers = Set(earlier.transfers.map(\.id))
    for transfer in set.transfers where !transfers.contains(transfer.id) {
      for account in [transfer.fromAccountId, transfer.toAccountId] {
        guard let counted = lastCount(of: account) else { continue }
        #expect(transfer.occurredAt > counted)
      }
    }
  }

  /// The savings account: 16 % paid monthly onto itself from the day it was opened, its first
  /// count that day, the first month's interest recorded on the pay date in the category the
  /// setting remembers, and a top-up from the main account.
  @Test func theSavingsAccountEarnsAndRecordsItsInterest() throws {
    let set = Self.layered(language: "ru")
    let savings = try #require(set.paymentMethods.first { $0.name == "Накопительный счёт" })
    let terms = try #require(savings.interest)
    #expect(terms.rate == 16 && terms.period == .monthly && terms.capitalizes)
    #expect(terms.endsOn == nil && terms.day == nil)
    let opened = try #require(terms.openedOn)
    #expect(opened.day <= 28)
    #expect(savings.kind == .account && savings.mainCurrency == .rub && !savings.isDefault)

    let count = try #require(set.reconciledBalances.first { $0.accountId == savings.id })
    #expect(count.isStartingPoint)
    #expect(set.reconciliations.first { $0.id == count.reconciliationId }?.date == opened)

    let category = try #require(
      set.settings[AccountSettings.interestCategoryKey].flatMap(UUID.init))
    #expect(set.categories.first { $0.id == category }?.kind == .income)
    let income = set.entries.filter { entry in
      entry.transaction.paymentMethodId == savings.id && entry.transaction.kind == .income
    }
    #expect(income.count == 1)
    let paid = try #require(income.first)
    #expect(paid.parts.map(\.categoryId) == [category])
    let payDate = DateOnly(
      year: opened.monthKey.next.year, month: opened.monthKey.next.month, day: opened.day)
    #expect(set.calendarDay(of: paid) == payDate)

    // What the month earned: the balance of each day, the loan's first payment out of it.
    var balance: [(from: DateOnly, amount: AmountE4)] = [(opened, count.actualE4)]
    for entry in set.entries where entry.transaction.paymentMethodId == savings.id {
      guard entry.transaction.kind == .expense, entry.transaction.debtId != nil else { continue }
      let day = set.calendarDay(of: entry)
      #expect(day > opened && day < payDate)
      balance.append((day, count.actualE4 - entry.transaction.amountE4))
    }
    #expect(balance.count == 2, "the loan's first grace payment is made from it")
    let earned = InterestMath.cents(
      InterestMath.accrue(segments: balance, percent: 16, after: opened, through: payDate))
    #expect(paid.transaction.amountE4 == earned)
    #expect(earned.raw > 0)

    let main = try #require(set.mainAccount)
    let topUp = try #require(set.transfers.first { $0.toAccountId == savings.id })
    #expect(topUp.fromAccountId == main.id && topUp.occurredAt > paid.transaction.occurredAt)
  }

  /// The names in English.
  @Test func theNamesFollowTheLanguage() {
    let set = Self.layered()
    #expect(set.debts.contains { $0.name == "Education loan" })
    #expect(set.paymentMethods.contains { $0.name == "Savings account" })
  }

  /// A history too short for the first tranche gets neither the loan nor the account.
  @Test func aShortHistoryGetsNeither() {
    let day = DateOnly(year: 2026, month: 9, day: 1)
    let history = SampleDataGenerator(seed: 3).generate(
      months: 1, endingOn: day, calendar: .moscow, language: "en")
    let set = history.withEveryFeature(seed: 3, calendar: .moscow, language: "en")
    #expect(!set.debts.contains { $0.accruesInterest })
    #expect(!set.paymentMethods.contains { $0.interest != nil })
  }

  /// The days work out for every last day of a year: the second due five to eight days before
  /// it, the first a month earlier, the savings account opened before the first and paid after
  /// it, and nothing past the 28th.
  @Test func theDaysFitEveryLastDay() throws {
    var day = DateOnly(year: 2027, month: 1, day: 1)
    for _ in 0..<366 {
      let dates = try #require(LoanAndSavingsDates(lastDay: day, calendar: .moscow))
      let gap =
        dates.secondDue.monthKey == day.monthKey
        ? day.day - dates.secondDue.day
        : CalendarContext.moscow.daysInMonth(dates.secondDue.monthKey) - dates.secondDue.day
          + day.day
      #expect((5...8).contains(gap), "\(day.iso)")
      #expect(dates.firstDue.monthKey.next == dates.secondDue.monthKey)
      #expect(dates.firstTranche < dates.savingsOpened && dates.savingsOpened < dates.firstDue)
      #expect(dates.firstDue < dates.savingsPaid && dates.savingsPaid < dates.secondDue)
      #expect(dates.firstDue < dates.secondTranche && dates.secondTranche < dates.secondDue)
      #expect(dates.payday <= 28 && dates.savingsOpened.day <= 28)
      day = CalendarContext.moscow.adding(days: 1, to: day)
    }
  }
}

extension SampleDataSet {
  /// The day of an operation in Moscow, the calendar of the tests.
  fileprivate func calendarDay(of entry: TransactionEntry) -> DateOnly {
    CalendarContext.moscow.day(of: entry.transaction.occurredAt)
  }
}
