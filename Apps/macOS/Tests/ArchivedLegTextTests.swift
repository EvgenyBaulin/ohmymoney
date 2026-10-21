import AppCore
import XCTest

@testable import OhMyMoney

/// The question about an account going to the archive names every transfer it will write — the
/// second one too, which takes money back out of the account that was just emptied: «И 30
/// сентября — перевод 30,000 ₽ с «Сбер» обратно на «Наличные», …».
@MainActor
final class ArchivedLegTextTests: XCTestCase {
  private let cash = UUID()
  private let sber = UUID()
  private var environment: AppEnvironment!

  override func setUp() async throws {
    environment = AppEnvironment()
  }

  private func leg(
    _ when: SettlingLeg.When, _ amount: Int64, from: UUID, to: UUID, daysAhead: Int = 0
  ) -> SettlingLeg {
    SettlingLeg(
      when: when,
      at: Date(timeIntervalSince1970: 1_790_000_000).addingTimeInterval(Double(daysAhead) * 86_400),
      amount: AmountE4(whole: amount), currency: .rub, from: from, to: to,
      returnsToArchived: to == cash)
  }

  func testEachKindOfLegHasItsOwnWords() {
    XCTAssertEqual(
      ArchivedLegText.key(for: leg(.now, 1, from: cash, to: sber), following: false),
      "archived.leftover.leg.now")
    XCTAssertEqual(
      ArchivedLegText.key(
        for: leg(.later, 1, from: sber, to: cash, daysAhead: 2), following: false),
      "archived.leftover.leg.back")
    XCTAssertEqual(
      ArchivedLegText.key(for: leg(.later, 1, from: sber, to: cash, daysAhead: 2), following: true),
      "archived.leftover.leg.back.and")
    XCTAssertEqual(
      ArchivedLegText.key(
        for: leg(.later, 1, from: cash, to: sber, daysAhead: 2), following: false),
      "archived.leftover.leg.later")
    XCTAssertEqual(
      ArchivedLegText.key(for: leg(.later, 1, from: cash, to: sber, daysAhead: 2), following: true),
      "archived.leftover.leg.later.and")
  }

  /// 12,000 held now and the rent of 30,000 typed ahead: two lines, the first dated now, the
  /// second with its day, its amount and both accounts.
  func testBothTransfersOfTheExampleAreNamed() {
    let names = [cash: "Наличные", sber: "Сбер"]
    let lines = ArchivedLegText.lines(
      [
        leg(.now, 12_000, from: cash, to: sber),
        leg(.later, 30_000, from: sber, to: cash, daysAhead: 2),
      ],
      name: { names[$0] ?? "?" }, environment)
    XCTAssertEqual(lines.count, 2)
    for line in lines {
      XCTAssertTrue(line.contains("Наличные"), line)
      XCTAssertTrue(line.contains("Сбер"), line)
    }
    XCTAssertTrue(
      lines[0].contains(environment.money.exact(AmountE4(whole: 12_000), currency: .rub)))
    XCTAssertTrue(
      lines[1].contains(environment.money.exact(AmountE4(whole: 30_000), currency: .rub)))
    let day = environment.dates.dayAndMonth(
      environment.calendar.day(
        of: Date(timeIntervalSince1970: 1_790_000_000).addingTimeInterval(2 * 86_400)))
    XCTAssertTrue(lines[1].contains(day), "the second leg says its day: \(lines[1])")
    XCTAssertFalse(lines[0].contains(day) && day.isEmpty)
    // The text of the second says the money goes back to the archived account and follows the first.
    XCTAssertEqual(
      lines[1],
      environment.format(
        "archived.leftover.leg.back.and", table: AccountText.table, day,
        environment.money.exact(AmountE4(whole: 30_000), currency: .rub), "Сбер", "Наличные"))
  }

  /// What an edit of the archived account's past leaves goes right after its last movement, in
  /// the past: the line says that day, with its year — it can be a year ago —, and not «Сейчас».
  func testATransferInThePastSaysItsDay() {
    let names = [cash: "Наличные", sber: "Сбер"]
    let earlier = leg(.earlier, 1_000, from: cash, to: sber, daysAhead: -40)
    XCTAssertEqual(
      ArchivedLegText.key(for: earlier, following: false), "archived.leftover.leg.earlier")
    let lines = ArchivedLegText.lines([earlier], name: { names[$0] ?? "?" }, environment)
    let day = environment.dates.longDay(environment.calendar.day(of: earlier.at))
    XCTAssertEqual(
      lines,
      [
        environment.format(
          "archived.leftover.leg.earlier", table: AccountText.table, day,
          environment.money.exact(AmountE4(whole: 1_000), currency: .rub), "Наличные", "Сбер")
      ])
    XCTAssertTrue(lines[0].contains(day), lines[0])
    XCTAssertNotEqual(
      lines[0],
      environment.format(
        "archived.leftover.leg.now", table: AccountText.table,
        environment.money.exact(AmountE4(whole: 1_000), currency: .rub), "Наличные", "Сбер"))
  }

  func testOneTransferIsOneLine() {
    let names = [cash: "Наличные", sber: "Сбер"]
    let lines = ArchivedLegText.lines(
      [leg(.now, 1_000, from: cash, to: sber)], name: { names[$0] ?? "?" }, environment)
    XCTAssertEqual(lines.count, 1)
    XCTAssertTrue(ArchivedLegText.lines([], name: { _ in "" }, environment).isEmpty)
  }
}
