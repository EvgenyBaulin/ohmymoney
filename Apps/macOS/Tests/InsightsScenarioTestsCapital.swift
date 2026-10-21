import AppCore
import XCTest

@testable import OhMyMoney

/// «Капитал» and the safety cushion: things valued by hand — the last valuation not after the
/// day, nothing before the first one, nothing from the day it was sold, a thing in dollars at
/// today's rate and one in a currency without a rate listed, never guessed — the cushion's
/// months floored to a tenth, its pace over the last month ends, its settings read whatever the
/// table holds, and on the synthetic sample the points, the breakdown and the goal agreeing.
final class InsightsScenarioCapitalTests: XCTestCase {
  private func rub(_ value: Int64) -> AmountE4 { AmountE4(whole: value) }
  private let pound = CurrencyCode("GBP")

  private func capital(
    assets: [Asset], valuations: [AssetValuation], today: DateOnly = .d(9, 14)
  ) -> CapitalSnapshot {
    var dataset = InsightsBook().dataset
    dataset.assets = assets
    dataset.assetValuations = valuations
    return DataSnapshot.build(
      dataset: dataset, calendar: .utc, today: today,
      context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]),
      version: DataVersion(load: 0), now: InsightsBook.noon(today)
    ).planning.capital
  }

  private func sampleSnapshot(seed: UInt64, months: Int, today: DateOnly) -> DataSnapshot {
    let set = SampleDataGenerator(seed: seed).generate(
      months: months, endingOn: today, calendar: .utc, language: "en"
    ).withEveryFeature(seed: seed, calendar: .utc, language: "en")
    let dataset = Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules, banks: set.banks, assets: set.assets,
      assetValuations: set.assetValuations,
      capitalSettings: CapitalSettings(storedValues: set.settings))
    return DataSnapshot.build(
      dataset: dataset, calendar: .utc, today: today,
      context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]),
      version: DataVersion(load: 0), now: InsightsBook.noon(today))
  }

  // MARK: - Things valued by hand

  /// A car alone is the capital: no account was ever counted, so «now» is the only point.
  func testAThingAloneIsTheCapitalNow() {
    let car = Asset(name: "Car", kind: .vehicle)
    let capital = capital(
      assets: [car],
      valuations: [AssetValuation(assetId: car.id, day: .d(9, 1), valueE4: rub(1_000_000))])
    XCTAssertEqual(capital.now.assetsRub, rub(1_000_000))
    XCTAssertEqual(capital.now.netRub, rub(1_000_000))
    XCTAssertEqual(capital.points.count, 1)
    XCTAssertTrue(capital.points[0].isNow)
    XCTAssertNil(capital.changeThisMonth)
    XCTAssertEqual(capital.breakdown.have.map(\.source), [.asset(car.id)])
  }

  /// The last valuation not after today counts; one dated ahead waits for its day.
  func testTheLastValuationNotAfterTodayCounts() {
    let car = Asset(name: "Car", kind: .vehicle)
    let capital = capital(
      assets: [car],
      valuations: [
        AssetValuation(assetId: car.id, day: .d(9, 1), valueE4: rub(850_000)),
        AssetValuation(assetId: car.id, day: .d(8, 1), valueE4: rub(900_000)),
        AssetValuation(assetId: car.id, day: .d(9, 20), valueE4: rub(800_000)),
      ])
    XCTAssertEqual(capital.now.assetsRub, rub(850_000))
  }

  /// A valuation of today itself counts.
  func testAValuationOfTodayCounts() {
    let flat = Asset(name: "Flat", kind: .realty)
    let capital = capital(
      assets: [flat],
      valuations: [AssetValuation(assetId: flat.id, day: .d(9, 14), valueE4: rub(5_000_000))])
    XCTAssertEqual(capital.now.assetsRub, rub(5_000_000))
  }

  /// Before its first valuation a thing is «no valuation»: listed, never guessed.
  func testAThingBeforeItsFirstValuationIsListedUnvalued() throws {
    let bike = Asset(name: "Bike", kind: .equipment)
    let capital = capital(
      assets: [bike],
      valuations: [AssetValuation(assetId: bike.id, day: .d(9, 20), valueE4: rub(30_000))])
    XCTAssertEqual(capital.now.assetsRub, .zero)
    XCTAssertEqual(capital.now.unvalued, [bike.id])
    XCTAssertEqual(try XCTUnwrap(capital.breakdown.have.first).issue, .unvalued)
  }

  /// Sold today: nothing from today; sold tomorrow: still counted today.
  func testASoldThingCountsUntilTheDayBefore() {
    let sold = Asset(name: "Old car", kind: .vehicle, disposedOn: .d(9, 14))
    let selling = Asset(name: "Boat", kind: .vehicle, disposedOn: .d(9, 15))
    let capital = capital(
      assets: [sold, selling],
      valuations: [
        AssetValuation(assetId: sold.id, day: .d(1, 1), valueE4: rub(400_000)),
        AssetValuation(assetId: selling.id, day: .d(1, 1), valueE4: rub(250_000)),
      ])
    XCTAssertEqual(capital.now.assetsRub, rub(250_000))
    XCTAssertEqual(capital.breakdown.have.map(\.source), [.asset(selling.id)])
  }

  /// Shares in dollars at today's rate.
  func testAThingInDollarsAtTodaysRate() {
    let shares = Asset(name: "Shares", kind: .investment, currency: .usd)
    let capital = capital(
      assets: [shares],
      valuations: [AssetValuation(assetId: shares.id, day: .d(9, 1), valueE4: rub(10_000))])
    XCTAssertEqual(capital.now.assetsRub, rub(950_000))
  }

  /// A thing in a currency without a rate adds nothing and is named as without a rate.
  func testAThingWithoutARateIsListedNotGuessed() throws {
    let stamp = Asset(name: "Stamp", kind: .other, currency: pound)
    let capital = capital(
      assets: [stamp],
      valuations: [AssetValuation(assetId: stamp.id, day: .d(9, 1), valueE4: rub(100))])
    XCTAssertEqual(capital.now.assetsRub, .zero)
    XCTAssertEqual(capital.now.withoutRate, [pound])
    let line = try XCTUnwrap(capital.breakdown.have.first)
    XCTAssertEqual(line.issue, .withoutRate)
    XCTAssertNil(line.amountRub)
    XCTAssertEqual(line.amount, rub(100))
  }

  /// A thing valued at zero is worth zero in any currency, without a rate.
  func testAThingWorthNothingNeedsNoRate() {
    let junk = Asset(name: "Junk", kind: .other, currency: pound)
    let capital = capital(
      assets: [junk],
      valuations: [AssetValuation(assetId: junk.id, day: .d(9, 1), valueE4: .zero)])
    XCTAssertTrue(capital.now.withoutRate.isEmpty)
    XCTAssertEqual(capital.now.assetsRub, .zero)
  }

  /// Several things add up; the net is what I have less what I owe.
  func testThingsAddUpToWhatIHave() {
    let a = Asset(name: "A", kind: .vehicle)
    let b = Asset(name: "B", kind: .investment, currency: .eur)
    let capital = capital(
      assets: [a, b],
      valuations: [
        AssetValuation(assetId: a.id, day: .d(2, 1), valueE4: rub(700_000)),
        AssetValuation(assetId: b.id, day: .d(3, 1), valueE4: AmountE4(raw: 12_345)),
      ])
    XCTAssertEqual(capital.now.assetsRub, rub(700_000) + AmountE4(raw: 1_271_535))
    XCTAssertEqual(capital.now.haveRub, capital.now.assetsRub)
    XCTAssertEqual(capital.now.netRub, capital.now.haveRub - capital.now.iOweRub)
  }

  // MARK: - The cushion

  /// Months of the cushion: floored to a tenth, never below zero, none without spending.
  func testCushionMonthsAreFlooredToATenth() {
    XCTAssertEqual(CushionRules.months(money: rub(35_000), monthly: rub(10_000)), 3.5)
    XCTAssertEqual(
      CushionRules.months(money: AmountE4(raw: 399_999_999), monthly: rub(10_000)),
      Decimal(string: "3.9"))
    XCTAssertEqual(CushionRules.months(money: .zero, monthly: rub(10_000)), 0)
    XCTAssertEqual(CushionRules.months(money: rub(-500), monthly: rub(10_000)), 0)
    XCTAssertNil(CushionRules.months(money: rub(500), monthly: .zero))
    XCTAssertNil(CushionRules.months(money: rub(500), monthly: rub(-1)))
  }

  /// A cushion too large for tenths in Int64 is still floored, without a trap.
  func testCushionMonthsOfAHugeSumDoNotOverflow() {
    let months = CushionRules.months(money: AmountE4(raw: .max), monthly: rub(1_000))
    XCTAssertEqual(months, Decimal(string: "922337203685.4"))
  }

  private func point(_ day: DateOnly, cushion: Int64, now: Bool = false) -> CapitalPoint {
    CapitalPoint(day: day, isNow: now, cushionRub: rub(cushion))
  }

  /// The pace: growth from the earliest of the last four month ends to the latest, per month.
  func testThePaceOfTheCushionIsOverTheLastMonthEnds() {
    let points = [
      point(.d(4, 30), cushion: 50_000), point(.d(5, 31), cushion: 0),
      point(.d(6, 30), cushion: 3_000), point(.d(7, 31), cushion: 6_000),
      point(.d(8, 31), cushion: 9_000), point(.d(9, 14), cushion: 99_000, now: true),
    ]
    let capital = CapitalSnapshot(
      points: points, now: points[5], breakdown: .empty, changeThisMonth: nil)
    XCTAssertEqual(CushionRules.pace(capital: capital), rub(3_000))
  }

  /// One month end or none: no pace. A shrinking cushion has a negative one.
  func testThePaceNeedsTwoMonthEnds() {
    let one = [point(.d(8, 31), cushion: 1_000), point(.d(9, 14), cushion: 5_000, now: true)]
    XCTAssertNil(
      CushionRules.pace(
        capital: CapitalSnapshot(
          points: one, now: one[1], breakdown: .empty, changeThisMonth: nil)))
    let falling = [
      point(.d(7, 31), cushion: 9_000), point(.d(8, 31), cushion: 4_000),
      point(.d(9, 14), cushion: 0, now: true),
    ]
    XCTAssertEqual(
      CushionRules.pace(
        capital: CapitalSnapshot(
          points: falling, now: falling[2], breakdown: .empty, changeThisMonth: nil)),
      rub(-5_000))
  }

  /// The settings of the cushion read whatever the table holds: out of range, a day instead of
  /// a month, words — each keeps its default.
  func testCushionSettingsReadWhateverTheTableHolds() {
    let damaged = CapitalSettings(storedValues: [
      CapitalSettings.targetMonthsKey: "25", CapitalSettings.targetMonthKey: "2026-09-01",
      CapitalSettings.historyMonthsKey: "2", CapitalSettings.outOfFreeMoneyKey: "maybe",
    ])
    XCTAssertEqual(damaged, .standard)
    let good = CapitalSettings(storedValues: [
      CapitalSettings.targetMonthsKey: " 6 ", CapitalSettings.targetMonthKey: "2027-03",
      CapitalSettings.historyMonthsKey: "12", CapitalSettings.outOfFreeMoneyKey: "1",
    ])
    XCTAssertEqual(good.targetMonths, 6)
    XCTAssertEqual(good.targetMonth, MonthKey(year: 2027, month: 3))
    XCTAssertEqual(good.historyMonths, 12)
    XCTAssertTrue(good.outOfFreeMoney)
    let back = CapitalSettings(
      storedValues: good.storedValues.compactMapValues { $0 })
    XCTAssertEqual(back, good)
    XCTAssertNil(CapitalSettings.standard.storedValues[CapitalSettings.targetMonthsKey] ?? nil)
  }

  // MARK: - The sample

  /// The points: month ends oldest first, «now» last; the net of each is what it has less what
  /// it owes; the change of the month is «now» less the last month end.
  private func assertPoints(_ capital: CapitalSnapshot, today: DateOnly) {
    XCTAssertEqual(capital.points.last, capital.now)
    XCTAssertTrue(capital.now.isNow)
    let ends = capital.points.dropLast()
    XCTAssertTrue(ends.allSatisfy { !$0.isNow && $0.day == $0.day.monthKey.lastDay })
    XCTAssertEqual(ends.map(\.day), ends.map(\.day).sorted())
    XCTAssertLessThanOrEqual(ends.count, NetWorth.defaultMonths)
    XCTAssertTrue(ends.allSatisfy { $0.day < today.monthKey.firstDay })
    for point in capital.points {
      XCTAssertEqual(point.netRub, point.haveRub - point.iOweRub)
    }
    if let last = ends.last, last.day == today.monthKey.previous.lastDay {
      XCTAssertEqual(capital.changeThisMonth, capital.now.netRub - last.netRub)
    }
  }

  /// The breakdown adds up line by line to the figures of «now».
  private func assertBreakdown(_ capital: CapitalSnapshot) {
    let have = AmountE4.sum(capital.breakdown.have.compactMap(\.amountRub))
    XCTAssertEqual(have, capital.now.haveRub)
    let owe = AmountE4.sum(capital.breakdown.owe.compactMap(\.amountRub))
    XCTAssertEqual(owe, capital.now.iOweRub)
  }

  func testTheSampleCapitalOfSixMonths() {
    let today = DateOnly.d(9, 14)
    let capital = sampleSnapshot(seed: 31, months: 6, today: today).planning.capital
    assertPoints(capital, today: today)
    assertBreakdown(capital)
    XCTAssertGreaterThan(capital.points.count, 1)
    XCTAssertNotNil(capital.changeThisMonth)
  }

  func testTheSampleCapitalOnNewYearsDay() {
    let today = DateOnly.d(1, 1, 2027)
    let capital = sampleSnapshot(seed: 32, months: 4, today: today).planning.capital
    assertPoints(capital, today: today)
    assertBreakdown(capital)
    XCTAssertEqual(capital.points.dropLast().last?.day, .d(12, 31))
  }

  func testTheSampleCapitalOnALeapDay() {
    let today = DateOnly.d(2, 29, 2028)
    let capital = sampleSnapshot(seed: 33, months: 5, today: today).planning.capital
    assertPoints(capital, today: today)
    assertBreakdown(capital)
  }

  /// The sample's cushion: its months are its money over the obligatory month, its goal of six
  /// months rounded up to a thousand, what is missing and what to put aside each month.
  func testTheSampleCushionAndItsGoalAgree() throws {
    let snapshot = sampleSnapshot(seed: 34, months: 8, today: .d(9, 14))
    let cushion = snapshot.planning.cushion
    XCTAssertFalse(cushion.accounts.isEmpty)
    let monthly = try XCTUnwrap(cushion.obligatory.monthlyRub)
    XCTAssertEqual(cushion.months, CushionRules.months(money: cushion.moneyRub, monthly: monthly))
    XCTAssertGreaterThanOrEqual(monthly, cushion.obligatory.committedRub)
    let goal = try XCTUnwrap(cushion.goal)
    XCTAssertEqual(goal.targetMonths, 6)
    XCTAssertEqual(goal.targetRub.raw % CushionRules.goalStep.raw, 0)
    XCTAssertGreaterThanOrEqual(goal.targetRub.raw, monthly.raw * 6)
    XCTAssertEqual(goal.missingRub, max(.zero, goal.targetRub - cushion.moneyRub))
    XCTAssertEqual(goal.reached, goal.missingRub.isZero)
    XCTAssertEqual(goal.defaultPerMonthRub.raw % CushionRules.perMonthStep.raw, 0)
    XCTAssertGreaterThanOrEqual(goal.defaultPerMonthRub.raw * 12, goal.missingRub.raw)
  }

  /// The obligatory spending of the sample: at most the history months, each a sum of its
  /// parts, before this month; the month figure never below what is committed.
  func testTheSampleObligatorySpendingIsWhole() throws {
    let snapshot = sampleSnapshot(seed: 35, months: 9, today: .d(9, 14))
    let obligatory = snapshot.planning.cushion.obligatory
    XCTAssertLessThanOrEqual(obligatory.months.count, CapitalSettings.defaultHistoryMonths)
    XCTAssertTrue(obligatory.months.allSatisfy { $0.month < MonthKey(year: 2026, month: 9) })
    for month in obligatory.months {
      XCTAssertEqual(month.total, month.scheduledRub + month.debtsRub + month.essentialRub)
    }
    let median = try XCTUnwrap(obligatory.medianRub)
    XCTAssertEqual(obligatory.monthlyRub, max(median, obligatory.committedRub))
  }

  /// A sample of two months has too few full months for the obligatory spending.
  func testAShortSampleHasTooFewMonthsForTheCushion() {
    let snapshot = sampleSnapshot(seed: 36, months: 2, today: .d(9, 14))
    let obligatory = snapshot.planning.cushion.obligatory
    XCTAssertNil(obligatory.monthlyRub)
    XCTAssertNil(snapshot.planning.cushion.months)
  }
}
