import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The key rate: the table, the page, the merge, and the lines it brings")
struct KeyRateTests {
  func d(_ y: Int, _ m: Int, _ day: Int) -> DateOnly { DateOnly(year: y, month: m, day: day) }
  func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
  func change(_ y: Int, _ m: Int, _ day: Int, _ rate: String) -> KeyRateChange {
    KeyRateChange(effectiveOn: d(y, m, day), ratePercent: dec(rate))
  }

  var table: KeyRateTable {
    KeyRateTable(changes: [
      change(2026, 6, 1, "16"), change(2026, 3, 1, "18"), change(2026, 9, 1, "14.5"),
    ])
  }

  @Test func theRateInForceIsTheLastRowNotAfterTheDay() {
    #expect(table.rate(on: d(2026, 2, 28)) == nil)
    #expect(table.rate(on: d(2026, 3, 1)) == dec("18"))
    #expect(table.rate(on: d(2026, 5, 31)) == dec("18"))
    #expect(table.rate(on: d(2026, 6, 1)) == dec("16"))
    #expect(table.rate(on: d(2030, 1, 1)) == dec("14.5"))
  }

  @Test func rowsAreOrderedOneADayAndARepeatedRateIsNoChange() {
    let list = KeyRateTable(changes: [
      change(2026, 5, 1, "16"), change(2026, 2, 1, "16"), change(2026, 3, 1, "16"),
      change(2026, 3, 1, "15"),
    ])
    // 1 Feb 16, 1 Mar 15 (the later row of the day wins); 1 May 16 is a change from 15.
    #expect(list.changes.map(\.effectiveOn) == [d(2026, 2, 1), d(2026, 3, 1), d(2026, 5, 1)])
    let same = KeyRateTable(changes: [change(2026, 2, 1, "16"), change(2026, 4, 1, "16.00")])
    #expect(same.changes.count == 1)
  }

  @Test func theBuiltInTableKeepsTheDaysTheRatesCameIntoForce() {
    let builtIn = KeyRateTable.builtIn
    // The Bank of Russia's table up to the decision of 23.10.2026: 14 % since 27.07.2026.
    #expect(builtIn.latest?.ratePercent == dec("14"))
    #expect(builtIn.latest?.effectiveOn == d(2026, 7, 27))
    #expect(builtIn.rate(on: d(2025, 1, 15)) == dec("21"))
    // A decision on Friday 24.10.2025 came into force on Monday 27.10.2025.
    #expect(builtIn.rate(on: d(2025, 10, 26)) == dec("17"))
    #expect(builtIn.rate(on: d(2025, 10, 27)) == dec("16.5"))
    #expect(builtIn.rate(on: d(2026, 6, 21)) == dec("14.5"))
    #expect(builtIn.rate(on: d(2026, 6, 22)) == dec("14.25"))
    // Every year's highest rate matches the free sum of interest tax the app carries.
    #expect(builtIn.rate(on: d(2025, 6, 5)) == dec("21"))
  }

  @Test func theFallOverTheLastMonths() throws {
    let drop = try #require(table.drop(overDays: 90, to: d(2026, 9, 15)))
    // 90 days before 15 Sep is 17 Jun: 16 then, 14.5 now, the step on 1 Sep.
    #expect(drop.from == dec("16"))
    #expect(drop.to == dec("14.5"))
    #expect(drop.points == dec("1.5"))
    #expect(drop.since == d(2026, 9, 1))
    // A rate that did not fall, or a table that does not reach back, gives none.
    #expect(table.drop(overDays: 30, to: d(2026, 7, 1)) == nil)
    #expect(table.drop(overDays: 90, to: d(2026, 4, 1)) == nil)
  }

  @Test func theChartStepsInsteadOfSlopes() {
    let points = table.points(from: d(2026, 5, 1), through: d(2026, 10, 1))
    #expect(
      points.map(\.rateE4) == [
        180_000, 180_000, 160_000, 160_000, 145_000, 145_000,
      ])
    #expect(points.first?.day == d(2026, 5, 1))
    #expect(points.last?.day == d(2026, 10, 1))
    #expect(Set(points.map(\.id)).count == points.count)
    #expect(table.points(from: d(2026, 1, 1), through: d(2026, 2, 1)).isEmpty)
    #expect(table.points(from: d(2026, 5, 1), through: d(2026, 4, 1)).isEmpty)
  }

  // MARK: The page

  func page(_ rows: [(String, String)]) -> Data {
    let body = rows.map { "<tr><td>\($0.0)</td><td>\($0.1)</td></tr>" }.joined()
    return Data("<html><table class=\"data\"><tr><th>Дата</th><th>Ставка</th></tr>\(body)</table></html>".utf8)
  }

  @Test func thePageGivesTheDaysTheRateChanged() {
    let rows = KeyRatePageParser().parse(
      page([
        ("19.12.2025", "16,00"), ("18.12.2025", "16,50"), ("17.12.2025", "16,50"),
        ("not a day", "x"), ("16.12.2025", "17,00"),
      ]))
    #expect(rows.map(\.effectiveOn) == [d(2025, 12, 16), d(2025, 12, 17), d(2025, 12, 19)])
    #expect(rows.map(\.ratePercent) == [dec("17"), dec("16.5"), dec("16")])
  }

  @Test func aPageThatIsNotTheTableGivesNothing() {
    let parser = KeyRatePageParser()
    #expect(parser.parse(Data()).isEmpty)
    #expect(parser.parse(Data("<html><script>challenge()</script></html>".utf8)).isEmpty)
    #expect(parser.parse(page([("01.01.2026", "0"), ("01.01.2026", "250,5")])).isEmpty)
  }

  @Test func theFetchedRowsWinTheirDayAndAFirstRowThatIsNoChangeVanishes() {
    let fetched = [change(2026, 7, 27, "14"), change(2026, 12, 21, "13.5")]
    let merged = KeyRateTable.builtIn.merged(with: fetched)
    // 27 Jul 2026 is the same rate as the built-in row: no second row.
    #expect(merged.changes.count == KeyRateTable.builtIn.changes.count + 1)
    #expect(merged.latest?.ratePercent == dec("13.5"))
    let corrected = KeyRateTable.builtIn.merged(with: [change(2026, 7, 27, "13.75")])
    #expect(corrected.rate(on: d(2026, 7, 27)) == dec("13.75"))
  }

  @Test func theCacheAsksOnceADay() {
    let today = d(2026, 11, 14)
    #expect(KeyRateCache.isDue(nil, today: today))
    #expect(!KeyRateCache.isDue(KeyRateCache(day: today, changes: []), today: today))
    #expect(KeyRateCache.isDue(KeyRateCache(day: d(2026, 11, 13), changes: []), today: today))
  }

  // MARK: The lines

  var falling: KeyRateTable {
    KeyRateTable(changes: [change(2026, 1, 1, "17"), change(2026, 10, 1, "15.5")])
  }

  func debt(rate: String?, direction: DebtDirection = .iOwe, closed: Bool = false) -> Debt {
    Debt(
      direction: direction, type: .loan, name: "Кредит", interestRate: rate.map(dec),
      closed: closed)
  }

  @Test func aNotableFallMeansOneStepOfAPointOverNinetyDays() {
    let today = d(2026, 11, 1)
    #expect(KeyRateAdvisor.notableDrop(falling, today: today)?.points == dec("1.5"))
    let small = KeyRateTable(changes: [change(2026, 1, 1, "16"), change(2026, 10, 1, "15.5")])
    #expect(KeyRateAdvisor.notableDrop(small, today: today) == nil)
    // After the window passes without another step, the line goes quiet.
    #expect(KeyRateAdvisor.notableDrop(falling, today: d(2027, 2, 1)) == nil)
  }

  @Test func refinanceIsSaidOnlyOfARunningDebtIOweAboveTheKeyRate() {
    let today = d(2026, 11, 1)
    let dear = debt(rate: "22")
    let cheap = debt(rate: "12")
    let none = debt(rate: nil)
    let theirs = debt(rate: "22", direction: .owedToMe)
    let done = debt(rate: "22", closed: true)
    let notes = KeyRateAdvisor.refinance(
      debts: [dear, cheap, none, theirs, done], table: falling, today: today)
    #expect(notes.count == 1)
    guard case .refinance(let id, let rate, let drop) = notes[0] else { return }
    #expect(id == dear.id)
    #expect(rate == dec("22"))
    #expect(drop.to == dec("15.5"))
    #expect(
      // 21 % held from 28.10.2024 to 08.06.2025: no fall over the 90 days before 1 Jun 2025.
      KeyRateAdvisor.refinance(debts: [dear], table: .builtIn, today: d(2025, 6, 1)).isEmpty)
  }

  @Test func aDepositThatEndsWhileTheRateFallsGetsALineEvenWithNothingInTheShowcase() {
    let today = d(2026, 11, 1)
    let account = PaymentMethod(
      name: "Вклад", kind: .account,
      interest: DepositTerms(
        rate: 15, period: .atEnd, openedOn: d(2026, 5, 3), endsOn: d(2026, 11, 3)))
    let without = DepositEndAdvisor.advice(
      accounts: [account], balanceE4: { _ in nil }, entries: [], today: today)
    #expect(without.isEmpty)
    let with = DepositEndAdvisor.advice(
      accounts: [account], balanceE4: { _ in nil }, entries: [], today: today, keyRates: falling)
    #expect(with.count == 1)
    #expect(with[0].picks.isEmpty)
    #expect(with[0].keyRateFall?.to == dec("15.5"))
    // The rate did not fall: nothing is said.
    let steady = DepositEndAdvisor.advice(
      accounts: [account], balanceE4: { _ in nil }, entries: [], today: today,
      keyRates: KeyRateTable(changes: [change(2026, 1, 1, "16")]))
    #expect(steady.isEmpty)
  }
}
