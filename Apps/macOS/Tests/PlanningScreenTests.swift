import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The frame of the Planning screen: the sentence over the blocks says what the free sum says,
/// the ribbon of 14 days adds up what the calendar plans, the long blocks show their nearest few
/// with a length a block may set for itself, the order of the blocks is kept and carried by the
/// archive, and the screen lays itself out at every width from 720 to 1400 pt in both languages
/// with either kind of scroll bars.
@MainActor
final class PlanningScreenTests: XCTestCase {
  private var windows: [NSWindow] = []
  private var suites: [String] = []

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
    for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    suites = []
  }

  private func defaults() throws -> UserDefaults {
    let suite = "ohmymoney.tests.planning-layout.\(UUID().uuidString)"
    suites.append(suite)
    return try XCTUnwrap(UserDefaults(suiteName: suite))
  }

  private func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  // MARK: - A book to show

  private let main = UUID()
  private let loanId = UUID()

  /// One counted account of 200,000 ₽; eight bills due over the coming weeks, two
  /// subscriptions, a salary expected on the 10th of every month, two goals and a loan whose
  /// payments are expenses.
  private func dataset(today: DateOnly, bills: Int = 8) -> Dataset {
    let counted = Reconciliation(
      date: today.adding(days: -1), reconciledAt: Date().addingTimeInterval(-86_400),
      actualTotalRubE4: AmountE4(whole: 200_000), kind: .accounts)
    let balance = ReconciledBalance(
      reconciliationId: counted.id, accountId: main, currency: .rub,
      actualE4: AmountE4(whole: 200_000))
    var scheduled: [ScheduledPayment] = (0..<bills).map { index in
      let due = today.adding(days: 1 + index * 3)
      return ScheduledPayment(
        name: "Bill \(index)", amountE4: AmountE4(whole: Int64(1_000 * (index + 1))),
        day: due.day, nextDate: due)
    }
    scheduled.append(
      ScheduledPayment(
        name: "Music", kind: .subscription, amountE4: AmountE4(whole: 300),
        day: today.adding(days: 2).day, nextDate: today.adding(days: 2)))
    scheduled.append(
      ScheduledPayment(
        name: "Films", kind: .subscription, amountE4: AmountE4(whole: 500),
        day: today.adding(days: 9).day, nextDate: today.adding(days: 9)))
    let salary = ExpectedIncome(
      name: "Salary", kind: .recurring, totalE4: AmountE4(whole: 100_000), freq: .monthly,
      day: today.adding(days: 5).day)
    let goals = [
      Goal(name: "Laptop", targetE4: AmountE4(whole: 150_000), targetDate: today.adding(days: 200)),
      Goal(name: "Trip", targetE4: AmountE4(whole: 90_000), targetDate: today.adding(days: 60)),
    ]
    return Dataset(
      paymentMethods: [PaymentMethod(id: main, name: "Main", currency: .rub, isDefault: true)],
      goals: goals,
      planning: PlanningBook(
        scheduled: scheduled, expected: [salary], reconciliations: [counted],
        reconciledBalances: [balance]))
  }

  private func dependencies(
    _ environment: AppEnvironment, bills: Int = 8
  ) -> (AppDependencies, DataSnapshot) {
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    let snapshot = DataSnapshot.build(
      dataset: dataset(today: environment.today, bills: bills), calendar: .system,
      today: environment.today, context: SnapshotContext(), version: DataVersion(load: 0))
    compute.applyLight(snapshot)
    return (
      AppDependencies(environment: environment, store: TransactionsStore(), compute: compute),
      snapshot
    )
  }

  // MARK: - The sentence

  /// «До 31 октября можно потратить ещё …, впереди N платежей на …» is the grey line of the free
  /// sum, its day and its two payment lines — in both languages, and for another day too.
  func testTheSentenceSaysWhatTheFreeMoneyBlockSays() throws {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      let (_, snapshot) = dependencies(environment)
      for picked in [nil, environment.today.adding(days: 20)] as [DateOnly?] {
        let free = snapshot.planning.freeMoney(
          until: FreeMoneyBlock.day(today: snapshot.today, picked: picked),
          ledger: snapshot.ledger)
        let summary = try XCTUnwrap(PlanningSummary(free), "counted: there is a sentence")
        let grey = try XCTUnwrap(free.grey)
        XCTAssertEqual(summary.left, grey)
        XCTAssertEqual(summary.until, free.until)
        let lines = free.lines.filter {
          $0.key == FreeMoney.Key.scheduled || $0.key == FreeMoney.Key.debts
        }
        XCTAssertEqual(summary.duesAmount, AmountE4.sum(lines.map(\.amount)))
        let bills = snapshot.planning.book.scheduled.flatMap { payment in
          Recurrence.occurrences(
            from: payment.nextDate ?? snapshot.today, through: free.until,
            rule: RecurrenceRule(payment: payment), end: payment.endDate, limit: 1000)
        }
        XCTAssertEqual(summary.dueCount, bills.count, "\(choice) \(String(describing: picked))")

        let sentence = PlanningBlockText.sentence(summary, environment)
        XCTAssertTrue(
          sentence.contains(environment.money.rounded(grey)), "\(sentence)")
        XCTAssertTrue(
          sentence.contains(PlanningBlockText.dayText(free.until, environment)), sentence)
        XCTAssertTrue(
          sentence.contains(environment.money.rounded(summary.duesAmount)), sentence)
        XCTAssertTrue(sentence.contains(environment.money.count(Int64(bills.count))), sentence)
        let total = try XCTUnwrap(
          PlanningBlockText.total(
            of: .freeMoney, snapshot, free: free, adviceCount: nil, environment))
        XCTAssertTrue(total.contains(environment.money.rounded(grey)), total)
      }
    }
    let ru = environment(.russian)
    let words = PlanningBlockText.sentence(
      PlanningSummary(
        until: DateOnly(year: ru.today.year, month: 10, day: 25), left: AmountE4(whole: 18_400),
        dueCount: 3, duesAmount: AmountE4(whole: 12_900)), ru)
    XCTAssertEqual(
      plain(words), "До 25 октября можно потратить ещё 18,400 ₽, впереди 3 платежа на 12,900 ₽.")
    let short = PlanningBlockText.sentence(
      PlanningSummary(
        until: DateOnly(year: ru.today.year, month: 10, day: 25), left: AmountE4(whole: -1_000),
        dueCount: 0, duesAmount: .zero), ru)
    XCTAssertTrue(plain(short).contains("не хватает 1,000 ₽"), short)
    XCTAssertTrue(short.contains("впереди платежей нет"), short)
  }

  /// The text with its non-breaking spaces read as spaces.
  private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00A0}", with: " ")
      .replacingOccurrences(of: "\u{202F}", with: " ")
  }

  /// Every word of the frame in both languages.
  func testEveryWordInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for key in PlanningBlockText.keys {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key, "\(key) \(choice)")
      }
      for block in PlanningBlock.allCases {
        XCTAssertNotEqual(
          PlanningBlockText.name(of: block, environment), PlanningBlockText.nameKey(of: block))
      }
      for addition in PlanningAddition.allCases {
        XCTAssertNotEqual(
          environment.language(addition.titleKey, table: "Planning"), addition.titleKey)
      }
      for key in [
        "settings.planning.screen", "settings.planning.listLength",
        "settings.planning.listLengthHint", "settings.planning.blockOrderHint",
        "settings.planning.blockOrderReset",
      ] {
        XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(key) \(choice)")
      }
    }
  }

  // MARK: - The ribbon

  /// The ribbon holds every plan of the calendar for its 14 days and adds up their money; a
  /// click on a payment opens its form, on an income its form, on a debt nothing here — the
  /// Debts section opens.
  func testTheRibbonAddsUpThePaymentsAndIncomesOfFourteenDays() throws {
    let environment = environment(.russian)
    let (_, snapshot) = dependencies(environment)
    let ribbon = PlanningView.ribbon(of: snapshot)
    XCTAssertEqual(ribbon.days.count, 14)
    XCTAssertEqual(ribbon.days.first?.day, snapshot.today)
    let plans = CalendarPlans.collect(
      ledger: snapshot.ledger, book: snapshot.planning.book, today: snapshot.today,
      through: snapshot.today.adding(days: 13), rubPerUnit: snapshot.planning.rubPerUnit,
      matches: snapshot.planning.matches)
    let payments = plans.filter { $0.kind == .payment }
    let incomes = plans.filter { $0.kind == .income }
    XCTAssertFalse(payments.isEmpty)
    XCTAssertFalse(incomes.isEmpty)
    XCTAssertEqual(ribbon.paymentsRub, AmountE4.sum(payments.map(\.amount)))
    XCTAssertEqual(ribbon.incomesRub, AmountE4.sum(incomes.map(\.amount)))
    XCTAssertEqual(ribbon.days.flatMap(\.payments).count, payments.count)
    XCTAssertEqual(ribbon.days.flatMap(\.incomes).count, incomes.count)
    // Bills 0…4 are due within the 14 days (days 1, 4, 7, 10, 13), Music and Films too.
    XCTAssertEqual(payments.count, 7)
    let totals = PlanningRibbonView.totals(ribbon, environment)
    XCTAssertTrue(totals.contains(environment.money.rounded(ribbon.paymentsRub)), totals)
    XCTAssertTrue(totals.contains(environment.money.rounded(ribbon.incomesRub)), totals)

    let book = snapshot.planning.book
    let payment = try XCTUnwrap(payments.first)
    guard case .payment(let opened)? = PlanningView.target(of: payment, in: book) else {
      return XCTFail("a payment opens its form")
    }
    XCTAssertEqual(opened?.id, payment.sourceId)
    let income = try XCTUnwrap(incomes.first)
    guard case .expected(let expected)? = PlanningView.target(of: income, in: book) else {
      return XCTFail("an income opens its form")
    }
    XCTAssertEqual(expected?.id, income.sourceId)
    let debt = CalendarPlan(
      kind: .payment, sourceId: loanId, day: snapshot.today, name: "Loan",
      amount: AmountE4(whole: 5_000), currency: .rub)
    XCTAssertNil(PlanningView.target(of: debt, in: book), "a debt opens the Debts section")
  }

  // MARK: - The nearest few

  /// Five of the eight bills, nearest first, three behind «Показать все (8)»; the block's own
  /// three beat the five of the settings; «Все» shows them all; opened out, all eight.
  func testALongBlockShowsItsNearestFewAndTheRestBehindTheButton() throws {
    let environment = environment(.russian)
    let (_, snapshot) = dependencies(environment)
    let layout = PlanningLayoutStore(defaults: try defaults())
    let bills = snapshot.planning.scheduled.filter { $0.payment.kind == .bill }.shuffled()
    XCTAssertEqual(bills.count, 8)
    XCTAssertEqual(layout.length(of: .payments), .count(5))

    var shown = PlanningShortListView.shown(
      bills, length: layout.length(of: .payments), expanded: false, date: { $0.nextUnpaid })
    XCTAssertEqual(shown.items.map(\.payment.name), (0..<5).map { "Bill \($0)" })
    XCTAssertEqual(shown.hidden, 3)
    XCTAssertEqual(
      environment.format("layout.showAll", table: "Planning", counts: bills.count),
      "Показать все (8)")

    layout.setOwnLength(.count(3), for: .payments)
    XCTAssertEqual(layout.length(of: .payments), .count(3), "the block's own beats the setting")
    XCTAssertEqual(layout.length(of: .goals), .count(5), "another block follows the setting")
    shown = PlanningShortListView.shown(
      bills, length: layout.length(of: .payments), expanded: false, date: { $0.nextUnpaid })
    XCTAssertEqual(shown.items.count, 3)
    XCTAssertEqual(shown.hidden, 5)

    layout.setLength(.count(10))
    XCTAssertEqual(layout.length(of: .payments), .count(3), "still the block's own")
    XCTAssertEqual(layout.length(of: .goals), .count(10))
    layout.setOwnLength(nil, for: .payments)
    XCTAssertEqual(layout.length(of: .payments), .count(10), "«Как в настройках»")

    layout.setOwnLength(.all, for: .payments)
    shown = PlanningShortListView.shown(
      bills, length: layout.length(of: .payments), expanded: false, date: { $0.nextUnpaid })
    XCTAssertEqual(shown.items.count, 8)
    XCTAssertEqual(shown.hidden, 0)
    shown = PlanningShortListView.shown(
      bills, length: .count(5), expanded: true, date: { $0.nextUnpaid })
    XCTAssertEqual(shown.items.count, 8, "opened out")

    // Goals are nearest by the day each is for: the trip in 60 days before the laptop in 200.
    let goals = PlanningShortListView.shown(
      snapshot.planning.goals, length: .count(1), expanded: false,
      date: { $0.goal.targetDate })
    XCTAssertEqual(goals.items.map(\.goal.name), ["Trip"])
    XCTAssertEqual(goals.hidden, 1)
  }

  /// The lengths are kept on this Mac: a new store on the same defaults reads them back, a text
  /// that names no choice is the setting of all blocks, and a block's «Как в настройках» removes
  /// its key.
  func testTheLengthsAreKeptAndReadBack() throws {
    let defaults = try defaults()
    let layout = PlanningLayoutStore(defaults: defaults)
    layout.setLength(.count(3))
    layout.setOwnLength(.all, for: .subscriptions)
    layout.setOwnLength(.count(10), for: .goals)
    XCTAssertEqual(defaults.string(forKey: PlanningLayoutStore.lengthKey), "3")
    XCTAssertEqual(
      defaults.string(forKey: PlanningLayoutStore.lengthKey(for: .subscriptions)), "all")

    let again = PlanningLayoutStore(defaults: defaults)
    XCTAssertEqual(again.length, .count(3))
    XCTAssertEqual(again.length(of: .subscriptions), .all)
    XCTAssertEqual(again.length(of: .goals), .count(10))
    XCTAssertEqual(again.length(of: .payments), .count(3))

    again.setOwnLength(nil, for: .goals)
    XCTAssertNil(defaults.string(forKey: PlanningLayoutStore.lengthKey(for: .goals)))
    defaults.set("7", forKey: PlanningLayoutStore.lengthKey(for: .payments))
    defaults.set("lots", forKey: PlanningLayoutStore.lengthKey)
    let odd = PlanningLayoutStore(defaults: defaults)
    XCTAssertEqual(odd.length, .count(5), "a text that names no choice is the standard five")
    XCTAssertNil(odd.ownLength(of: .payments))
  }

  // MARK: - The order of the blocks

  /// Dropped, moved, reset: each written at once, read back as every block once.
  func testTheOrderIsKeptAsEveryBlockOnce() throws {
    let defaults = try defaults()
    defaults.set("goals,unknown,payments,goals", forKey: PlanningLayoutStore.orderKey)
    let layout = PlanningLayoutStore(defaults: defaults)
    XCTAssertEqual(Array(layout.order.prefix(2)), [.goals, .payments])
    XCTAssertEqual(layout.order.count, PlanningBlock.allCases.count)

    XCTAssertTrue(layout.drop(.advice, onto: .goals))
    XCTAssertEqual(layout.order.first, .advice)
    XCTAssertFalse(layout.drop(.advice, onto: .advice))
    layout.move(.advice, by: 1)
    XCTAssertEqual(Array(layout.order.prefix(2)), [.goals, .advice])
    XCTAssertFalse(layout.canMove(.goals, by: -1))
    XCTAssertEqual(
      PlanningBlocks.decode(defaults.string(forKey: PlanningLayoutStore.orderKey)), layout.order)
    XCTAssertEqual(PlanningLayoutStore(defaults: defaults).order, layout.order)

    layout.resetOrder()
    XCTAssertEqual(layout.order, PlanningBlocks.standard)
    XCTAssertEqual(
      PlanningBlockOrderActions.block(PlanningBlockOrderActions.payload(of: .limits)),
      .limits)
    XCTAssertNil(PlanningBlockOrderActions.block("limits"), "text dragged from elsewhere")
  }

  /// The order travels in the archive's `settings.json` as every block once, and an archive
  /// read back puts it into the defaults the same way; a block this build does not know goes.
  func testTheArchiveCarriesTheOrder() throws {
    let from = try defaults()
    from.set("advice,events", forKey: PlanningLayoutStore.orderKey)
    let carried = PlanningLayoutStore.portableOrder(in: from)
    XCTAssertEqual(PlanningBlocks.decode(carried).prefix(2), [.advice, .events])
    XCTAssertEqual(PlanningBlocks.decode(carried).count, PlanningBlock.allCases.count)

    let to = try defaults()
    PlanningLayoutStore.applyPortable(
      [PlanningLayoutStore.orderKey: "banana," + carried], to: to)
    XCTAssertEqual(PlanningLayoutStore(defaults: to).order.prefix(2), [.advice, .events])
    let untouched = try defaults()
    PlanningLayoutStore.applyPortable(["language": "ru"], to: untouched)
    XCTAssertNil(untouched.string(forKey: PlanningLayoutStore.orderKey))

    XCTAssertNotNil(
      AppEnvironment().portableSettings()[PlanningLayoutStore.orderKey],
      "the archive's settings carry the order")
  }

  // MARK: - The totals and the empty blocks

  func testTheTotalsOfTheHeaders() throws {
    let environment = environment(.russian)
    let (_, snapshot) = dependencies(environment)
    let month = snapshot.today.monthKey.lastDay
    let dueBills = snapshot.planning.scheduled.filter {
      $0.payment.kind == .bill && $0.nextUnpaid <= month
    }
    XCTAssertEqual(
      PlanningBlockText.dueThisMonth(of: .bill, snapshot),
      AmountE4.sum(dueBills.map(\.amountNext)))
    let subscriptions = try XCTUnwrap(
      PlanningBlockText.total(
        of: .subscriptions, snapshot, free: nil, adviceCount: nil, environment))
    XCTAssertTrue(
      subscriptions.contains(environment.money.rounded(snapshot.planning.subscriptionsMonthly)))
    XCTAssertNotNil(
      PlanningBlockText.total(of: .goals, snapshot, free: nil, adviceCount: nil, environment))
    XCTAssertNil(
      PlanningBlockText.total(of: .limits, snapshot, free: nil, adviceCount: nil, environment),
      "no limit, nothing to add up")
    XCTAssertEqual(
      PlanningBlockText.total(of: .advice, snapshot, free: nil, adviceCount: 2, environment),
      "2 подсказки")
    for block in PlanningBlock.allCases {
      XCTAssertEqual(
        PlanningBlockText.emptyHint(of: block) != nil,
        ![.freeMoney, .advice, .selfEmployment].contains(block))
    }
  }

  /// A weekly bill of 1,000 ₽ unpaid since the 14th asks for the 14th, the 21st and the 28th:
  /// the header of Payments says 3,000 ₽ for the month, each due at its own price — the free
  /// sum's rule of unpaid dues — not one week's price.
  func testThePaymentsHeaderCountsEveryUnpaidDueOfTheMonth() throws {
    let environment = environment(.russian)
    let today = try XCTUnwrap(DateOnly(iso: "2026-09-19"))
    let weekly = ScheduledPayment(
      name: "Cleaning", amountE4: AmountE4(whole: 1_000), freq: .weekly,
      nextDate: try XCTUnwrap(DateOnly(iso: "2026-09-14")))
    let raised = SubscriptionPrice(
      paymentId: weekly.id, date: try XCTUnwrap(DateOnly(iso: "2026-09-25")),
      amountE4: AmountE4(whole: 1_500))
    let dataset = Dataset(
      paymentMethods: [PaymentMethod(id: main, name: "Main", currency: .rub, isDefault: true)],
      planning: PlanningBook(scheduled: [weekly]))
    func snapshot(_ dataset: Dataset) -> DataSnapshot {
      DataSnapshot.build(
        dataset: dataset, calendar: .system, today: today, context: SnapshotContext(),
        version: DataVersion(load: 0))
    }
    XCTAssertEqual(
      PlanningBlockText.dueThisMonth(of: .bill, snapshot(dataset)), AmountE4(whole: 3_000))
    let total = try XCTUnwrap(
      PlanningBlockText.total(
        of: .payments, snapshot(dataset), free: nil, adviceCount: nil, environment))
    XCTAssertTrue(total.contains(environment.money.rounded(AmountE4(whole: 3_000))), total)

    var priced = dataset
    priced.planning.prices = [raised]
    XCTAssertEqual(
      PlanningBlockText.dueThisMonth(of: .bill, snapshot(priced)), AmountE4(whole: 3_500),
      "the 28th at the price of its own day")
    XCTAssertNil(
      PlanningBlockText.dueThisMonth(of: .subscription, snapshot(dataset)),
      "no subscription, no total")
  }

  // MARK: - The window

  /// From 720 to 1400 pt, in both languages, with legacy and overlay scroll bars: the screen
  /// settles — its size stops changing and nothing asks for layout again —, two columns from
  /// 760 pt of content and one below. A layout that never converged would end in AppKit's
  /// exception here.
  func testTheScreenSettlesAtEveryWidthInBothLanguages() throws {
    XCTAssertEqual(PlanningView.columns(forWidth: 680), 1)
    XCTAssertEqual(PlanningView.columns(forWidth: 759), 1)
    XCTAssertEqual(PlanningView.columns(forWidth: 760), 2)
    XCTAssertEqual(PlanningView.columns(forWidth: 1360), 2)
    for style in [NSScroller.Style.legacy, .overlay] {
      try ScrollerStyleOverride.with(style) {
        for choice in [AppLanguage.Choice.russian, .english] {
          let environment = environment(choice)
          let (deps, _) = dependencies(environment)
          let layout = PlanningLayoutStore(defaults: try defaults())
          layout.setOwnLength(.all, for: .payments)
          for width in [CGFloat(720), 900, 1100, 1400] {
            try assertSettles(
              PlanningView(layout: layout).appDependencies(deps), width: width,
              "\(style == .legacy ? "legacy" : "overlay") \(choice) \(Int(width))")
          }
        }
      }
    }
  }

  /// An empty book: every block shows its hint, and the screen settles all the same.
  func testAnEmptyBookSettlesWithItsHints() throws {
    let environment = environment(.russian)
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(), calendar: .system, today: environment.today,
        context: SnapshotContext(), version: DataVersion(load: 0)))
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: compute)
    let layout = PlanningLayoutStore(defaults: try defaults())
    for width in [CGFloat(720), 1400] {
      try assertSettles(
        PlanningView(layout: layout).appDependencies(deps), width: width, "empty \(Int(width))")
    }
  }

  private func assertSettles<V: View>(_ view: V, width: CGFloat, _ what: String) throws {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    windows.append(window)
    // dependencies: every caller hands them to its view with `.appDependencies`
    let hosting = NSHostingView(rootView: view.frame(width: width, height: 900))
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    settle(0.5)
    hosting.layoutSubtreeIfNeeded()
    let first = hosting.fittingSize
    settle(0.3)
    hosting.layoutSubtreeIfNeeded()
    XCTAssertEqual(hosting.fittingSize, first, "the size keeps changing: \(what)")
    XCTAssertFalse(hosting.needsLayout, "the screen asks for layout again: \(what)")
    XCTAssertEqual(window.frame.width, width, accuracy: 1, "the window grew: \(what)")
  }
}
