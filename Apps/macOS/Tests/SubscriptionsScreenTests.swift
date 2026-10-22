import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The Subscriptions screen on synthetic subscriptions: the page carries what the core counts
/// (totals that agree with the planning figures, the comparison of a year with twelve months, the
/// shares of the people, the band of a floating amount, the use, the split of a rise of the price
/// into service and rate), the notices can be put away, the calendar groups the charges by day,
/// every word is found in both languages, and the screen and the tile lay themselves out.
@MainActor
final class SubscriptionsScreenTests: XCTestCase {
  private var windows: [NSWindow] = []

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
  }

  private let today = DateOnly(year: 2026, month: 10, day: 14)
  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }
  private func day(_ month: Int, _ day: Int) -> DateOnly {
    DateOnly(year: 2026, month: month, day: day)
  }

  private func subscription(
    _ name: String, _ amount: Int64, freq: Frequency = .monthly, currency: CurrencyCode = .rub,
    next: DateOnly? = nil, trialEnd: DateOnly? = nil
  ) -> ScheduledPayment {
    let due = next ?? day(10, 20)
    return ScheduledPayment(
      name: name, kind: .subscription, amountE4: rub(amount), currency: currency, freq: freq,
      day: due.day, month: freq == .yearly ? due.month : nil, nextDate: due, trialEnd: trialEnd)
  }

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func page(
    _ payments: [ScheduledPayment], prices: [SubscriptionPrice] = [],
    subscriptions: SubscriptionBook = .empty, rates: DayRates = .empty,
    rubPerUnit: [CurrencyCode: Decimal] = [:], entries: [TransactionEntry] = []
  ) -> SubscriptionsPage {
    let book = PlanningBook(scheduled: payments, prices: prices)
    let ledger = Ledger(dataset: Dataset(entries: entries, planning: book), calendar: .utc)
    return SubscriptionsPage.build(
      book: book, subscriptions: subscriptions, ledger: ledger, rates: rates,
      rubPerUnit: rubPerUnit, today: today)
  }

  // MARK: - The figures

  /// The hero and the line of the block of Planning are two readings of the same money: for
  /// subscriptions in rubles they agree to the kopeck.
  func testTheTotalsAgreeWithThePlanningFigures() {
    let payments = [
      subscription("Music", 299), subscription("Cloud", 2_400, freq: .yearly, next: day(12, 1)),
      subscription("News", 150),
    ]
    let book = PlanningBook(scheduled: payments)
    let snapshot = DataSnapshot.build(
      dataset: Dataset(planning: book), calendar: .utc, today: today,
      context: SnapshotContext(), version: DataVersion(load: 0))
    let counted = SubscriptionsPage.build(snapshot)
    XCTAssertEqual(counted.totals.monthlyRub, snapshot.planning.subscriptionsMonthly)
    XCTAssertEqual(counted.totals.yearlyRub, snapshot.planning.subscriptionsYearly)
    XCTAssertEqual(counted.totals.monthlyRub, rub(649))
    XCTAssertEqual(counted.perDayRub, SubscriptionCosts.perDay(yearlyRub: counted.totals.yearlyRub))
  }

  func testAYearIsSetAgainstTwelveMonthsOnlyWhenThePlanIsKnown() {
    let cloud = subscription("Cloud", 2_400, freq: .yearly, next: day(12, 1))
    let plain = subscription("Plain", 100)
    let book = SubscriptionBook(
      terms: [SubscriptionTerms(paymentId: cloud.id, monthlyPlanE4: rub(249))])
    let counted = page([cloud, plain], subscriptions: book)
    let comparison = counted.row(cloud.id)?.comparison
    XCTAssertEqual(comparison?.twelveMonths, rub(2_988))
    XCTAssertEqual(comparison?.saving, rub(588))
    XCTAssertEqual(comparison?.cheaper, .yearly)
    XCTAssertNil(counted.row(plain.id)?.comparison)
  }

  func testThePeopleShareTheChargeAndTheOwnerKeepsTheRemainder() {
    let family = subscription("Family", 1_000)
    let anna = UUID()
    let boris = UUID()
    let book = SubscriptionBook(
      users: [
        SubscriptionUser(paymentId: family.id, personId: anna),
        SubscriptionUser(paymentId: family.id, personId: boris),
      ])
    let share = page([family], subscriptions: book).row(family.id)?.family
    XCTAssertEqual(share?.total, rub(1_000))
    XCTAssertEqual(share?.others.count, 2)
    XCTAssertEqual(
      (share?.mine ?? .zero) + AmountE4.sum(share?.others.map(\.amount) ?? []), rub(1_000))
  }

  func testAFloatingAmountShowsItsBandAndOneOutsideItIsANotice() throws {
    let bill = subscription("Utilities", 4_000, next: day(10, 20))
    let book = SubscriptionBook(
      terms: [SubscriptionTerms(paymentId: bill.id, floating: true, tolerancePercent: 10)])
    func charge(_ month: Int, _ amount: Int64) throws -> TransactionEntry {
      var draft = TransactionDraft(
        occurredAt: CalendarContext.utc.startOfDay(day(month, 5)), currency: .rub,
        amount: rub(amount))
      draft.parts = [PartDraft(amount: rub(amount))]
      var entry = try draft.materialize()
      entry.transaction.externalId = "sched:\(bill.id.uuidString.lowercased()):\(day(month, 5).iso)"
      return entry
    }
    let counted = page(
      [bill], subscriptions: book, entries: [try charge(7, 3_900), try charge(10, 5_900)])
    let band = try XCTUnwrap(counted.row(bill.id)?.band)
    XCTAssertEqual(band.tolerancePercent, 10)
    XCTAssertEqual(band.low, rub(3_600))
    XCTAssertEqual(band.high, rub(4_400))
    XCTAssertTrue(
      counted.notices.contains { $0.kind == .floatingOutside && $0.paymentId == bill.id })
    let inside = page(
      [bill], subscriptions: book, entries: [try charge(7, 3_900), try charge(10, 4_100)])
    XCTAssertFalse(inside.notices.contains { $0.kind == .floatingOutside })
  }

  /// A rise of a dollar subscription is told apart into what the service did and what the rate
  /// did, and the two parts add up to the whole rise in rubles.
  func testARiseInADollarSubscriptionIsSplitIntoServiceAndRate() {
    let service = subscription("Service", 10, currency: .usd)
    let prices = [
      SubscriptionPrice(paymentId: service.id, date: day(1, 1), amountE4: rub(10)),
      SubscriptionPrice(paymentId: service.id, date: day(9, 1), amountE4: rub(11)),
    ]
    let rates = DayRates(series: [
      .usd: [DayRate(day: day(1, 1), perUnit: 90), DayRate(day: day(9, 1), perUnit: 100)]
    ])
    let counted = page([service], prices: prices, rates: rates, rubPerUnit: [.usd: 100])
    let step = counted.row(service.id)?.steps.first
    XCTAssertEqual(step?.oldPrice, rub(10))
    XCTAssertEqual(step?.newPrice, rub(11))
    let split = step?.split
    XCTAssertEqual(split?.oldRub, rub(900))
    XCTAssertEqual(split?.newRub, rub(1_100))
    XCTAssertEqual(split?.servicePartRub, rub(90))
    XCTAssertEqual(split?.ratePartRub, rub(110))
    XCTAssertEqual(
      (split?.servicePartRub ?? .zero) + (split?.ratePartRub ?? .zero), split?.totalRub)
  }

  func testNoRateKeepsTheLineOutOfTheTotals() {
    let dollars = subscription("Service", 10, currency: .usd)
    let counted = page([dollars, subscription("Music", 300)])
    XCTAssertEqual(counted.totals.withoutRate, [dollars.id])
    XCTAssertEqual(counted.totals.monthlyRub, rub(300))
    XCTAssertNil(counted.row(dollars.id)?.line.yearlyRub)
  }

  func testUseIsMarkedByHandAndCostedPerUse() {
    let music = subscription("Music", 300)
    let marks = (0..<3).map { UsageMark(paymentId: music.id, day: today.adding(days: -$0)) }
    let counted = page([music], subscriptions: SubscriptionBook(usage: marks))
    let usage = counted.row(music.id)?.usage
    XCTAssertEqual(usage?.usedDays, 3)
    XCTAssertEqual(usage?.perUseRub, rub(100))
    XCTAssertEqual(page([music]).row(music.id)?.usage.hasMarks, false)
  }

  func testWhatCouldBeCancelledNamesTheDuplicatesAndTheKeepGroupHidesThem() {
    let first = subscription("Spotify", 300)
    let second = subscription("Яндекс Музыка", 200)
    let counted = page([first, second])
    XCTAssertEqual(counted.advice.duplicates.count, 1)
    XCTAssertEqual(counted.advice.duplicates.first?.type, .music)
    XCTAssertEqual(counted.advice.savingYearlyRub, rub(2_400))
    let kept = SubscriptionBook(
      keepGroups: [KeepGroup(type: .music, paymentIds: [first.id, second.id])])
    XCTAssertTrue(page([first, second], subscriptions: kept).advice.duplicates.isEmpty)
    // A third music subscription brings the offer back.
    let third = subscription("Zvuk", 100)
    XCTAssertEqual(page([first, second, third], subscriptions: kept).advice.duplicates.count, 1)
  }

  func testTheAppStoreLineIsRecognised() {
    XCTAssertTrue(AppStoreBilling.isAppleBilling("APPLE.COM/BILL"))
    XCTAssertFalse(AppStoreBilling.isAppleBilling("Netflix"))
  }

  // MARK: - Notices

  func testTrialsAndYearlyChargesAreNoticedAndPutAwayUntilTheOccasionChanges() {
    let trial = subscription("Kino", 399, next: day(10, 15), trialEnd: day(10, 15))
    let yearly = subscription("Office", 3_600, freq: .yearly, next: day(10, 25))
    let counted = page([trial, yearly])
    XCTAssertEqual(
      Set(counted.notices.map(\.kind)), [.trialEnding, .yearlyCharge])
    let ids = Set(counted.notices.map(\.id))
    XCTAssertEqual(counted.shownNotices(dismissed: []).count, 2)
    XCTAssertEqual(counted.shownNotices(dismissed: ids).count, 0)
    XCTAssertEqual(
      SubscriptionNoticeRows.visible(counted.notices, dismissed: [counted.notices[0].id]).count, 1)
    let many = (0..<6).map { index in
      subscription("T\(index)", 100, next: day(10, 15), trialEnd: day(10, 15))
    }
    XCTAssertEqual(
      SubscriptionNoticeRows.visible(page(many).notices, dismissed: []).count,
      SubscriptionNoticeRows.shown)
  }

  func testAPaidYearlyChargeIsNotAnnouncedAgain() throws {
    let yearly = subscription("Office", 3_600, freq: .yearly, next: day(10, 25))
    let book = PlanningBook(scheduled: [yearly])
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day(10, 13)), currency: .rub, amount: rub(3_600))
    draft.parts = [PartDraft(amount: rub(3_600))]
    var entry = try draft.materialize()
    entry.transaction.externalId = "sched:\(yearly.id.uuidString.lowercased()):\(day(10, 25).iso)"
    let ledger = Ledger(dataset: Dataset(entries: [entry], planning: book), calendar: .utc)
    let matches = ScheduledMatching.matches(
      book: book, ledger: ledger, today: today, rejections: [])
    let notices = SubscriptionWatch.notices(
      book: book, subscriptions: .empty, today: today, matches: matches)
    XCTAssertTrue(notices.isEmpty)
  }

  // MARK: - The calendar

  func testTheCalendarGroupsTheChargesByDayAndMarksTheBunchedOnes() {
    let one = subscription("A", 100, next: day(10, 20))
    let two = subscription("B", 200, next: day(10, 20))
    let three = subscription("C", 300, next: day(10, 25))
    let book = PlanningBook(scheduled: [one, two, three])
    let ledger = Ledger(dataset: Dataset(planning: book), calendar: .utc)
    let items = SubscriptionCalendar.items(
      in: MonthKey(year: 2026, month: 10), ledger: ledger, book: book, today: today)
    let groups = SubscriptionCalendarDay.groups(items, rubPerUnit: [:])
    XCTAssertEqual(groups.map(\.day), [day(10, 20), day(10, 25)])
    XCTAssertTrue(groups[0].isBunched)
    XCTAssertFalse(groups[1].isBunched)
    XCTAssertEqual(groups[0].totalRub, rub(300))
    XCTAssertEqual(groups[1].totalRub, rub(300))
  }

  // MARK: - Words

  func testEveryWordIsInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for key in SubscriptionsText.keys {
        XCTAssertNotEqual(
          environment.language(key, table: SubscriptionsText.table), key, "\(key) \(choice)")
      }
      for tile in [OverviewTile.subscriptions] {
        XCTAssertNotEqual(
          OverviewTileText.name(of: tile, environment), OverviewTileText.nameKey(of: tile))
        XCTAssertNotEqual(
          environment.language("why.rule.\(tile.rawValue)", table: "Overview"),
          "why.rule.\(tile.rawValue)")
      }
    }
  }

  func testTheLinesReadInBothLanguagesWithoutPlaceholdersLeft() {
    let trial = subscription("Kino", 399, next: day(10, 15), trialEnd: day(10, 15))
    let cloud = subscription("Cloud", 2_400, freq: .yearly, next: day(12, 1))
    let service = subscription("Service", 10, currency: .usd)
    let terms = SubscriptionTerms(paymentId: cloud.id, monthlyPlanE4: rub(249))
    let prices = [
      SubscriptionPrice(paymentId: service.id, date: day(1, 1), amountE4: rub(10)),
      SubscriptionPrice(paymentId: service.id, date: day(9, 1), amountE4: rub(11)),
    ]
    let rates = DayRates(series: [
      .usd: [DayRate(day: day(1, 1), perUnit: 90), DayRate(day: day(9, 1), perUnit: 100)]
    ])
    let counted = page(
      [trial, cloud, service], prices: prices,
      subscriptions: SubscriptionBook(terms: [terms]), rates: rates, rubPerUnit: [.usd: 100])
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      var texts: [String] = []
      for row in counted.rows {
        texts.append(SubscriptionsText.cost(row.line, environment))
        texts.append(SubscriptionsText.charge(row.line, environment))
        if let comparison = row.comparison {
          texts.append(SubscriptionsText.comparison(comparison, environment))
        }
        for step in row.steps {
          texts.append(
            SubscriptionsText.step(step, currency: row.line.payment.currency, environment))
          if let split = step.split { texts.append(SubscriptionsText.split(split, environment)) }
        }
      }
      let names = Dictionary(
        uniqueKeysWithValues: counted.rows.map { ($0.id, $0.line.payment.name) })
      for notice in counted.notices {
        texts.append(SubscriptionsText.notice(notice, names: names, environment))
      }
      XCTAssertFalse(texts.isEmpty)
      for text in texts {
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("%@") || text.contains("%lld") || text.contains("subs."), text)
      }
    }
  }

  func testAChangeIsSignedWithTheTrueMinus() {
    let environment = environment(.english)
    XCTAssertTrue(SubscriptionsText.signed(rub(-60), environment).hasPrefix("\u{2212}"))
    XCTAssertTrue(SubscriptionsText.signed(rub(60), environment).hasPrefix("+"))
  }

  // MARK: - The tile

  func testTheTileSaysNothingForNoSubscriptionsAndTheMonthOtherwise() {
    let environment = environment(.english)
    XCTAssertNil(SubscriptionsTileFigure.make(page([]), environment))
    let counted = page([subscription("Music", 300), subscription("Cloud", 600)])
    let figure = SubscriptionsTileFigure.make(counted, environment)
    XCTAssertEqual(figure?.value, environment.money.rounded(rub(900)))
    XCTAssertEqual(figure?.caption, "2 subscriptions")
  }

  func testTheTileIsInTheCatalogHiddenUntilAdded() {
    let item = OverviewCatalog.item(of: .subscriptions)
    XCTAssertEqual(item?.number, 128)
    XCTAssertEqual(item?.group, .plan)
    XCTAssertFalse(OverviewTile.subscriptions.isShownUnnamed)
    XCTAssertEqual(TileDestination.of(.subscriptions), .planning)
  }

  // MARK: - The windows

  private func dependencies(_ environment: AppEnvironment) -> AppDependencies {
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    let today = environment.today
    let music = ScheduledPayment(
      name: "Spotify", kind: .subscription, amountE4: rub(299), day: today.day, nextDate: today)
    let more = ScheduledPayment(
      name: "Яндекс Музыка", kind: .subscription, amountE4: rub(199), day: today.day,
      nextDate: today.adding(days: 3))
    let yearly = ScheduledPayment(
      name: "Office", kind: .subscription, amountE4: rub(3_600), freq: .yearly, day: today.day,
      month: today.adding(days: 5).month, nextDate: today.adding(days: 5))
    let snapshot = DataSnapshot.build(
      dataset: Dataset(planning: PlanningBook(scheduled: [music, more, yearly])),
      calendar: .system, today: today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    compute.applyLight(snapshot)
    return AppDependencies(environment: environment, store: TransactionsStore(), compute: compute)
  }

  private func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func assertSettles<V: View>(_ view: V, width: CGFloat, _ what: String) {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 800), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    windows.append(window)
    // dependencies: the caller hands the view its own dependencies; this host only sizes it.
    let hosting = NSHostingView(rootView: view.frame(width: width, height: 800))
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    settle(0.6)
    hosting.layoutSubtreeIfNeeded()
    let first = hosting.fittingSize
    settle(0.3)
    hosting.layoutSubtreeIfNeeded()
    XCTAssertEqual(hosting.fittingSize, first, "the size keeps changing: \(what)")
    XCTAssertFalse(hosting.needsLayout, "the screen asks for layout again: \(what)")
    XCTAssertEqual(window.frame.width, width, accuracy: 1, "the window grew: \(what)")
  }

  func testTheScreenLaysItselfOutAtEveryWidthInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      let deps = dependencies(environment)
      for width in [560.0, 860, 1_200] {
        assertSettles(
          SubscriptionsScreen().appDependencies(deps), width: width, "\(choice) \(Int(width))")
      }
    }
  }

  func testTheCalendarFilterAndTheNoticeRowsLayOutAndTheTileToo() {
    let environment = environment(.english)
    let deps = dependencies(environment)
    assertSettles(
      SubscriptionCalendarCard(month: environment.today.monthKey).padding().appDependencies(deps),
      width: 700, "calendar")
    assertSettles(SubscriptionNoticeRows().padding().appDependencies(deps), width: 400, "notices")
    assertSettles(
      SubscriptionsTileCard().padding().appDependencies(deps), width: 300, "tile")
  }
}
