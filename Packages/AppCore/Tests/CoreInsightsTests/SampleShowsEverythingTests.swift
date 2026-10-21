import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import CoreSample
import Foundation
import Testing

@testable import CoreInsights
@testable import CoreModel

/// `make sample` has to show the owner what the category model, the forecast and the anomalies
/// do, not an empty page of them: the model has to be on, the forecast has to be a real
/// forecast and the anomalies have to find something. Every one of these is a thing a person
/// trying the app is meant to look at.
@Suite("The sample shows what the model, the forecast and the anomalies built")
struct SampleShowsEverythingTests {
  static let endingOn = DateOnly(year: 2026, month: 9, day: 18)
  static let set = SampleDataGenerator(seed: 20_260_920).generate(
    months: 6, endingOn: endingOn, calendar: .moscow, language: "en")
  static let dataset = Dataset(
    entries: set.entries, links: set.links, categories: set.categories, people: set.people,
    places: set.places, events: set.events, paymentMethods: set.paymentMethods,
    debts: set.debts, goals: set.goals, planning: set.planningBook,
    settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId))
  static var ledger: Ledger { Ledger(dataset: dataset, calendar: .moscow) }

  @Test("Six months of the sample turn the category model on")
  func theModelIsOn() {
    let examples = LedgerTraining.examples(of: Self.dataset, calendar: .moscow)
    let model = CategoryModel.train(on: examples, anchor: Self.set.lastDay)

    #expect(examples.count > CategoryModelOptions.standard.minimumExamples)
    #expect(model.readiness.isOn, "the sample does not teach the model enough to turn it on")
  }

  /// Not «мало данных» and not a straight line: six months are past the two the weekday
  /// quantiles need.
  @Test("The forecast of the sample is a real forecast")
  func theForecastIsReal() {
    let remainder = MonthForecast.remainder(ledger: Self.ledger, today: Self.set.lastDay)

    #expect(!remainder.lowData)
    #expect(remainder.windowDays >= MonthForecast.weekdayWindow)
    #expect(remainder.middle.raw > 0)
    #expect(remainder.p10 <= remainder.middle)
    #expect(remainder.middle <= remainder.p90)
    #expect(remainder.p10 < remainder.p90, "an interval of one point says nothing")
  }

  /// And it can be checked against the days that have already happened.
  @Test("The sample has enough history to back the forecast test")
  func theBacktestRuns() {
    let backtest = ForecastBacktest.run(ledger: Self.ledger, today: Self.set.lastDay)

    #expect(!backtest.isEmpty)
    #expect(backtest.beatsTheRate)
  }

  /// The rent is a scheduled payment, so it is planned money and not something that might
  /// happen any day. A monthly lump inside the daily average was worth 47 000 ₽ a day of the
  /// month and pushed every forecast up by half.
  @Test("The rent of the sample is planned, not variable")
  func theRentIsPlanned() {
    let rent = SamplePlanning.rentPaymentId(categories: Self.set.categories)
    let payment = Self.set.planning.scheduled.first { $0.id == rent }
    let paid = Self.ledger.rows.filter {
      if case .scheduled(let id, _)? = $0.link { return id == rent }
      return false
    }

    #expect(payment != nil, "the sample has no rent payment for its rent operations")
    #expect(paid.count >= 6, "six months of rent should be six linked operations")
    // What «variable» means, asked of the forecast itself: the rent is out of its window.
    let spending = VariableSpending(ledger: Self.ledger)
    #expect(paid.allSatisfy { spending.amount(on: $0.dayNumber) < $0.amountRubE4.decimal })
  }

  /// The mobile plan is the other bill the sample declares, and the history pays it the way
  /// it pays the rent: each operation carries the link of its payment. So it is planned money,
  /// not variable spending; the payment shows its last charge; and the model does not learn
  /// from rows the app wrote itself.
  @Test("The mobile plan of the sample is planned, not variable")
  func theMobilePlanIsPlanned() throws {
    let payment = try #require(Self.set.planning.scheduled.first { $0.name == "Mobile plan" })
    let bills = Self.set.entries.filter { entry in
      !entry.transaction.isDeleted && entry.parts.map(\.categoryId) == [payment.categoryId]
        && entry.transaction.amountE4 == payment.amountE4
    }
    #expect(bills.count >= 6, "six months of the mobile plan should be six operations")
    for bill in bills {
      let due = CalendarContext.moscow.day(of: bill.transaction.occurredAt)
      #expect(
        bill.transaction.externalId
          == OperationLink.scheduled(paymentId: payment.id, due: due).externalId)
    }

    // Taking the bills out of the book leaves the variable spending of their days as it is.
    let ids = Set(bills.map(\.id))
    var without = Self.dataset
    without.entries.removeAll { ids.contains($0.id) }
    let spending = VariableSpending(ledger: Self.ledger)
    let rest = VariableSpending(ledger: Ledger(dataset: without, calendar: .moscow))
    for bill in bills {
      let day = CalendarContext.moscow.day(of: bill.transaction.occurredAt).dayNumber
      #expect(spending.amount(on: day) == rest.amount(on: day))
    }

    let parts = Set(bills.flatMap(\.parts).map(\.id))
    let examples = LedgerTraining.examples(of: Self.dataset, calendar: .moscow)
    #expect(!examples.contains { parts.contains($0.partId) })

    let status = ScheduledRules.statuses(
      book: Self.set.planningBook, ledger: Self.ledger, today: Self.set.lastDay
    ).first { $0.payment.id == payment.id }
    #expect(status?.lastCharge?.due == DateOnly(year: 2026, month: 9, day: 7))
  }

  /// «Аномалии» is not an empty page on the sample either: the rules have something to say
  /// about six months of a life.
  @Test("The anomalies find something in the sample")
  func theAnomaliesFindSomething() {
    let ledger = Self.ledger
    let report = AnomalyRules.build(
      ledger: ledger, events: EventPlanning.build(ledger: ledger, today: Self.set.lastDay),
      today: Self.set.lastDay)

    #expect(!report.all.isEmpty, "six months of the sample gave the seven rules nothing")
  }

  // MARK: - The layers after the accounts

  static let layered = SampleDataGenerator(seed: 20_260_920).generate(
    months: 6, endingOn: endingOn, calendar: .moscow, language: "en"
  ).withEveryFeature(seed: 20_260_920, calendar: .moscow, language: "en")
  static let demo = SampleDataGenerator(seed: 20_260_920).generate(
    months: 6, endingOn: endingOn, calendar: .moscow, language: "en"
  ).withEveryFeature(seed: 20_260_920, calendar: .moscow, language: "en", demo: true)

  static func dataset(of set: SampleDataSet) -> Dataset {
    Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules)
  }

  static func overdue(_ set: SampleDataSet) -> [OverdueDue] {
    let ledger = Ledger(dataset: dataset(of: set), calendar: .moscow)
    let now = CalendarContext.moscow.startOfDay(set.lastDay).addingTimeInterval(12 * 3_600)
    return PlanningSnapshot.build(
      ledger: ledger, today: set.lastDay, now: now,
      rubPerUnit: [.usd: 95, .eur: 103, CurrencyCode("KZT"): Decimal(2) / Decimal(10)]
    ).overdue
  }

  /// The demo has one scheduled payment due and not paid, which the launch asks about; the
  /// sample has none of its own.
  @Test("The demo asks about one overdue payment, the sample about none")
  func theDemoHasAnOverduePayment() throws {
    #expect(!Self.overdue(Self.layered).contains { !$0.isDebt })
    let overdue = Self.overdue(Self.demo).filter { !$0.isDebt }
    #expect(overdue.count == 1)
    let due = try #require(overdue.first)
    #expect(due.name == "Car inspection")
    #expect(due.due < Self.demo.lastDay)
    #expect(due.moreOverdue == 0)
    // The phone, bought on credit on its payment day and paid every month since, owes nothing
    // overdue.
    for set in [Self.layered, Self.demo] {
      #expect(set.debts.contains { $0.name == "New phone" })
      #expect(!Self.overdue(set).contains { $0.name == "New phone" })
    }
  }

  /// The later count follows the books: take away the groceries entered after it but dated
  /// inside its window, and its difference shrinks by what they cost — the operation of the
  /// difference is rewritten in place, as the app rewrites it.
  @Test("The later count of the sample follows an operation entered after it")
  func theLaterCountFollowsTheBooks() throws {
    let set = Self.layered
    let later = try #require(set.reconciliations.last { $0.kind == .accounts })
    let countedAt = try #require(later.reconciledAt)
    let count = try #require(
      set.reconciledBalances.first {
        $0.reconciliationId == later.id && !($0.differenceE4?.isZero ?? true)
      })
    let entered = try #require(
      set.entries.first { entry in
        entry.transaction.paymentMethodId == count.accountId
          && entry.transaction.createdAt > countedAt && entry.transaction.occurredAt < countedAt
      })
    let operation = try #require(set.entries.first { $0.id == count.transactionId })
    let categories = ReconcileCategories(
      expense: try #require(
        set.settings[PlanningSettings.reconcileExpenseCategoryKey].flatMap(UUID.init)),
      income: try #require(
        set.settings[PlanningSettings.reconcileIncomeCategoryKey].flatMap(UUID.init)))
    let without = set.entries.filter { $0.id != entered.id }
    let balances = AccountBalances.build(
      entries: without, transfers: set.transfers, debtEntries: set.debtEntries,
      debts: Dictionary(uniqueKeysWithValues: set.debts.map { ($0.id, $0) }),
      reconciliations: set.reconciliations, balances: set.reconciledBalances,
      accounts: set.paymentMethods, tree: CategoryTree(set.categories), now: countedAt,
      calendar: .moscow)
    let expected = try #require(balances.expected(forCount: count.id))
    let settled = LiveCounts.settle(
      CountState(count: count, countAt: countedAt, operation: operation), expected: expected,
      rate: nil, categories: categories, tree: CategoryTree(set.categories), now: countedAt)

    let before = try #require(count.differenceE4)
    #expect(settled.count.differenceE4 == before - entered.transaction.amountE4)
    guard case .rewrite(let rewritten) = settled.operation else {
      Issue.record("the difference was not rewritten: \(settled.operation)")
      return
    }
    #expect(rewritten.id == operation.id)
    #expect(
      rewritten.transaction.amountE4 == operation.transaction.amountE4
        + entered.transaction.amountE4)
  }
}
