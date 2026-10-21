import CoreAccounting
import CoreArchive
import CoreKit
import Foundation
import Testing

@testable import CoreSample

/// The allocation, self-employment and the owner's own currency the sample adds after the
/// credit: its own sequence of draws, pinned; every layer under it left as it was; and the rows
/// the way the app writes them — the categories and settings of self-employment, the tax paid
/// under its key, the last income allocated by the rules.
@Suite("The allocation and self-employment of the sample")
struct SampleAllocation19Tests {
  static let seed = SampleFeatureLayersTests.seed

  /// The layers through the credit: what the allocation is written on.
  static func earlier(language: String = "en") -> SampleDataSet {
    SampleCredit19Tests.layered(language: language)
  }

  static func layered(language: String = "en") -> SampleDataSet {
    SampleFeatureLayersTests.layered(language: language)
  }

  @Test func theLayerDrawsTheSameSequence() {
    let set = Self.layered()
    #expect(
      SampleCredit19Tests.digest(set, over: Self.earlier())
        == "682c56e6cc34e7d82f5fe6541790fc9c0976e24ddd72a6307c892892c68478a0",
      """
      The allocation layer drew a different sequence. If this was meant — a new row, another
      amount — put the digest printed by the failure here and say why in the commit. If it was
      not, something asked the layer's random source for one more value.
      """)
  }

  /// Everything under the layer is kept: it only adds.
  @Test func theLayersUnderItAreKept() {
    let earlier = Self.earlier()
    let set = Self.layered()
    let old = Set(earlier.entries.map(\.id))
    #expect(set.entries.filter { old.contains($0.id) } == earlier.entries)
    #expect(set.transfers.filter { earlier.transfers.contains($0) } == earlier.transfers)
    #expect(
      Array(set.paymentMethods.prefix(earlier.paymentMethods.count)) == earlier.paymentMethods)
    #expect(Array(set.categories.prefix(earlier.categories.count)) == earlier.categories)
    #expect(Array(set.goals.prefix(earlier.goals.count)) == earlier.goals)
    #expect(set.debts == earlier.debts && set.debtEntries == earlier.debtEntries)
    #expect(set.debtCosts == earlier.debtCosts)
    #expect(
      Array(set.reconciliations.prefix(earlier.reconciliations.count)) == earlier.reconciliations)
    #expect(set.banks == earlier.banks, "the debit account joins the bank of the credit card")
    #expect(set.planning.scheduled == earlier.planning.scheduled)
    #expect(set.planning.expected == earlier.planning.expected)
    #expect(set.planning.budgets.map(\.id) == earlier.planning.budgets.map(\.id))
    #expect(earlier.allocationRules.isEmpty && earlier.customCurrencies.isEmpty)
  }

  /// «Отпуск 10 %» and «Подушка 10 %», the cushion's to the savings account; «Заработок» named.
  @Test func theRulesAreTenPercentEach() throws {
    let set = Self.layered(language: "ru")
    let vacation = try #require(set.goals.first { $0.name == "Отпуск" })
    let category = try #require(set.categories.first { $0.id == vacation.subcategoryId })
    #expect(set.categories.first { $0.id == category.parentId }?.systemRole == .goals)
    let cushion = try #require(set.paymentMethods.first { $0.cushion })
    #expect(
      set.allocationRules
        == [
          AllocationRule(
            id: set.allocationRules[0].id, target: .goal(vacation.id), amount: .percent(10),
            sort: 0),
          AllocationRule(
            id: set.allocationRules[1].id, target: .cushion(cushion.id), amount: .percent(10),
            sort: 1),
        ])
    let work = try #require(set.categories.first { $0.name == "Заработок" && $0.parentId == nil })
    #expect(AllocationSettings(storedValues: set.settings).earningsCategoryId == work.id)
  }

  /// Self-employment on, with the categories the app makes, the tax category and the deduction
  /// left on the first day of the month before the last day's.
  @Test func selfEmploymentIsOnWithTheCategoriesOfTheApp() throws {
    let set = Self.layered(language: "ru")
    let settings = SelfEmploymentSettings(storedValues: set.settings)
    #expect(settings.enabled && settings.offered)
    #expect(settings.deductionLeftE4 == AmountE4(whole: 4_000))
    #expect(settings.deductionLeftOn == set.lastDay.monthKey.previous.firstDay)
    let tree = CategoryTree(set.categories)
    func named(_ name: String) throws -> CoreKit.Category {
      try #require(set.categories.first { $0.name == name }, "\(name)")
    }
    let work = try named("Заработок")
    let selfEmployed = try named("Самозанятость")
    #expect(selfEmployed.parentId == work.id && selfEmployed.kind == .income)
    #expect(try named("от физлиц").parentId == selfEmployed.id)
    #expect(tree.tax(of: try named("от физлиц").id) == IncomeTax(rate: 4, npd: true))
    #expect(tree.tax(of: try named("от организаций").id) == IncomeTax(rate: 6, npd: true))
    #expect(tree.tax(of: selfEmployed.id) == nil)
    let tax = try named("Налог самозанятого")
    #expect(settings.taxCategoryId == tax.id && tax.kind == .expense)
    #expect(set.categories.first { $0.id == tax.parentId }?.name == "Налоги и сборы")
  }

  /// Two incomes of self-employment on the debit account of «Т-Банк»; the tax of the month before
  /// — 3 % of the income from individuals, 4 % of any from organisations, the rates the
  /// deduction leaves — paid in the last day's month under `npd:<month>`.
  @Test func theTaxOfTheMonthBeforeIsPaid() throws {
    let set = Self.layered(language: "ru")
    let account = try #require(set.paymentMethods.first { $0.name == "Дебетовая Т-Банка" })
    #expect(set.banks.first { $0.id == account.bankId }?.name == "Т-Банк")
    let tree = CategoryTree(set.categories)
    let incomes = set.entries.filter {
      $0.transaction.kind == .income && tree.tax(of: $0.parts.first?.categoryId) != nil
    }
    #expect(incomes.count == 2)
    #expect(incomes.allSatisfy { $0.transaction.paymentMethodId == account.id })
    let month = set.lastDay.monthKey.previous
    var expected = Decimal(0)
    for income in incomes where day(of: income).monthKey == month {
      let rate = tree.tax(of: income.parts[0].categoryId)?.rate ?? 0
      expected += income.transaction.amountE4.decimal * (rate == 4 ? 3 : 4) / 100
    }
    let payment = try #require(
      set.entries.first { $0.transaction.externalId == "npd:" + month.iso })
    #expect(payment.transaction.amountE4 == InterestMath.cents(expected))
    #expect(payment.transaction.paymentMethodId == account.id)
    #expect(
      payment.parts.first?.categoryId
        == SelfEmploymentSettings(storedValues: set.settings).taxCategoryId)
    #expect(day(of: payment).monthKey == set.lastDay.monthKey)
    #expect(day(of: payment) <= set.lastDay)
  }

  /// The last income is allocated by the rules, a second after it: 10 % of the income less its
  /// tax into «Отпуск» and as much to the cushion, both keyed `alloc:<income>:<uuid>`; the
  /// salaries of the history are not.
  @Test func theLastIncomeIsAllocated() throws {
    let set = Self.layered(language: "ru")
    let keyed = set.entries.filter { $0.transaction.externalId?.hasPrefix("alloc:") == true }
    #expect(keyed.count == 1)
    let contribution = try #require(keyed.first)
    let incomeId = try #require(
      contribution.transaction.externalId.flatMap {
        UUID(uuidString: String($0.split(separator: ":")[1]))
      })
    let income = try #require(set.entries.first { $0.id == incomeId })
    #expect(
      set.categories.first { $0.id == income.parts.first?.categoryId }?.name == "от организаций")
    #expect(
      contribution.transaction.occurredAt == income.transaction.occurredAt.addingTimeInterval(1))
    let tax = InterestMath.cents(income.transaction.amountE4.decimal * 4 / 100)
    let share = InterestMath.cents((income.transaction.amountE4 - tax).decimal / 10)
    #expect(contribution.transaction.amountE4 == share)
    #expect(contribution.parts.first?.goalId == set.goals.first { $0.name == "Отпуск" }?.id)
    #expect(contribution.parts.first?.quality == .good)
    let transfer = try #require(set.transfers.first { $0.externalId?.hasPrefix("alloc:") == true })
    #expect(transfer.externalId?.hasPrefix("alloc:\(incomeId.uuidString):") == true)
    #expect(transfer.externalId != contribution.transaction.externalId)
    #expect(transfer.fromAmountE4 == share && transfer.toAmountE4 == share)
    #expect(transfer.fromAccountId == income.transaction.paymentMethodId)
    #expect(set.paymentMethods.first { $0.id == transfer.toAccountId }?.cushion == true)
    #expect(transfer.occurredAt == contribution.transaction.occurredAt)
  }

  /// «Мили»: a code that is no code of ISO 4217, no digits after the point, three rates typed by
  /// hand inside the history.
  @Test func theOwnCurrencyHasItsRates() throws {
    let set = Self.layered(language: "ru")
    let miles = try #require(set.customCurrencies.first)
    #expect(set.customCurrencies.count == 1)
    #expect(miles.code == CurrencyCode("MIL") && miles.name == "Мили" && miles.fractionDigits == 0)
    #expect(!ISOCurrencies.contains(miles.code))
    #expect(CurrencyCatalog.refusal(newCode: "MIL", existing: []) == nil)
    #expect(CurrencyCatalog.refusal(for: miles, existing: []) == nil)
    #expect(set.rates.count == 3)
    #expect(set.rates.allSatisfy { $0.currency == miles.code && $0.source == .manual })
    #expect(set.rates.map(\.date) == set.rates.map(\.date).sorted())
    #expect(set.rates.allSatisfy { $0.date >= set.firstDay && $0.date <= set.lastDay })
  }

  /// A history of a month gets none of it.
  @Test func aShortHistoryGetsNone() {
    let day = DateOnly(year: 2026, month: 9, day: 1)
    let history = SampleDataGenerator(seed: 3).generate(
      months: 1, endingOn: day, calendar: .moscow, language: "en")
    let set = history.withEveryFeature(seed: 3, calendar: .moscow, language: "en")
    #expect(set.allocationRules.isEmpty && set.customCurrencies.isEmpty && set.rates.isEmpty)
    #expect(!SelfEmploymentSettings(storedValues: set.settings).enabled)
  }

  /// The layer fits every last day: the tax is paid inside the last day's month and after the
  /// incomes it pays for, the allocation comes after its income, nothing after the last day.
  @Test(arguments: [
    DateOnly(year: 2026, month: 10, day: 1), DateOnly(year: 2026, month: 10, day: 2),
    DateOnly(year: 2026, month: 10, day: 3), DateOnly(year: 2027, month: 3, day: 1),
    DateOnly(year: 2027, month: 2, day: 28), DateOnly(year: 2026, month: 12, day: 31),
  ])
  func theDaysFitEveryLastDay(_ lastDay: DateOnly) throws {
    let set = SampleDataGenerator(seed: 11).generate(
      months: 4, endingOn: lastDay, calendar: .moscow, language: "en"
    ).withEveryFeature(seed: 11, calendar: .moscow, language: "en")
    let month = lastDay.monthKey.previous
    let payment = try #require(
      set.entries.first { $0.transaction.externalId == "npd:" + month.iso })
    #expect(day(of: payment).monthKey == lastDay.monthKey && day(of: payment) <= lastDay)
    let tree = CategoryTree(set.categories)
    let incomes = set.entries.filter {
      $0.transaction.kind == .income && tree.tax(of: $0.parts.first?.categoryId) != nil
    }
    #expect(incomes.count == 2)
    for income in incomes where day(of: income).monthKey == month {
      #expect(income.transaction.occurredAt < payment.transaction.occurredAt)
    }
    #expect(!set.entries.contains { day(of: $0) > lastDay })
    #expect(!set.transfers.contains { CalendarContext.moscow.day(of: $0.occurredAt) > lastDay })
    let statement = SampleDataSet.latestStatement(before: lastDay)
    #expect(statement < lastDay && statement.day == 5)
  }

  fileprivate func day(of entry: TransactionEntry) -> DateOnly {
    CalendarContext.moscow.day(of: entry.transaction.occurredAt)
  }
}
