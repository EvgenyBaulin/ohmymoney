import AppCore
import XCTest

@testable import OhMyMoney

/// The chart of net worth: one place on the axis per month, «now» after the last end, whole
/// rubles rounded once, nothing in the model a floating-point number; the labels keep «now»;
/// the range is kept on this Mac and reads twelve months from anything it does not know.
@MainActor
final class NetWorthChartModelTests: XCTestCase {
  private func point(
    _ year: Int, _ month: Int, _ day: Int, now: Bool = false, have: AmountE4, owe: AmountE4
  ) -> CapitalPoint {
    CapitalPoint(
      day: DateOnly(year: year, month: month, day: day), isNow: now, accountsRub: have,
      iOweRub: owe)
  }

  func testThePlacesAndTheRubles() {
    let model = NetWorthChartModel([
      point(2025, 12, 31, have: AmountE4(raw: 1_000_005_000), owe: AmountE4(whole: 20_000)),
      point(2026, 1, 31, have: AmountE4(whole: 110_000), owe: AmountE4(whole: 15_000)),
      point(2026, 2, 11, now: true, have: AmountE4(whole: 120_000), owe: .zero),
    ])
    XCTAssertEqual(model.points.map(\.x), [2025 * 12 + 11, 2026 * 12, 2026 * 12 + 1])
    XCTAssertEqual(model.points.map(\.isNow), [false, false, true])
    XCTAssertEqual(model.points[0].have, 100_001, "100,000.50 ₽ rounds half away from zero")
    XCTAssertEqual(model.points[0].net, 80_001)
    XCTAssertEqual(model.points[1].owe, 15_000)
    XCTAssertEqual(NetWorthChartModel.month(at: model.points[0].x), MonthKey(year: 2025, month: 12))
    XCTAssertEqual(NetWorthChartModel.month(at: model.points[1].x), MonthKey(year: 2026, month: 1))
    XCTAssertTrue(model.hasLine)
  }

  /// «Now» on the last day of a month stands after the end of that month, never on it.
  func testNowNeverSharesAPlace() {
    let model = NetWorthChartModel([
      point(2026, 9, 30, have: .zero, owe: .zero),
      point(2026, 9, 30, now: true, have: .zero, owe: .zero),
    ])
    XCTAssertEqual(model.points.map(\.x), [2026 * 12 + 8, 2026 * 12 + 9])
  }

  func testOnePointIsNoLine() {
    XCTAssertFalse(NetWorthChartModel(CapitalSnapshot.empty.points).hasLine)
    XCTAssertFalse(NetWorthChartModel([]).hasLine)
  }

  /// No property of the model, nor of its points, is a `Double` or a `Float`.
  func testNoFloatingPointInTheModel() {
    let model = NetWorthChartModel([
      point(2026, 8, 31, have: AmountE4(whole: 1), owe: .zero),
      point(2026, 9, 1, now: true, have: AmountE4(whole: 2), owe: .zero),
    ])
    func check(_ value: Any, _ path: String) {
      for child in Mirror(reflecting: value).children {
        let label = "\(path).\(child.label ?? "?")"
        XCTAssertFalse(child.value is Double, "\(label) is a Double")
        XCTAssertFalse(child.value is Float, "\(label) is a Float")
        check(child.value, label)
      }
    }
    check(model, "model")
  }

  /// Many months: every n-th carries a word, counted back from «now», which always has one.
  func testTheLabelsKeepNow() {
    let ends = (0..<30).map { offset -> CapitalPoint in
      point(2024 + offset / 12, offset % 12 + 1, 28, have: .zero, owe: .zero)
    }
    let points = ends + [point(2026, 7, 10, now: true, have: .zero, owe: .zero)]
    let model = NetWorthChartModel(points)
    let labelled = model.labelled(limit: 7)
    XCTAssertEqual(labelled.last, model.points.last?.x)
    XCTAssertLessThanOrEqual(labelled.count, 7)
    XCTAssertEqual(labelled, labelled.sorted())
    let few = NetWorthChartModel(Array(points.prefix(3)))
    XCTAssertEqual(few.labelled(), few.points.map(\.x))
  }

  func testTheRangeIsKeptOnThisMac() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ohmymoney.tests.capital.\(UUID())"))
    XCTAssertEqual(CapitalChartRange.stored(in: defaults), .year)
    CapitalChartRange.all.store(in: defaults)
    XCTAssertEqual(defaults.string(forKey: "capital.chartRange"), "all")
    XCTAssertEqual(CapitalChartRange.stored(in: defaults), .all)
    defaults.set("decade", forKey: CapitalChartRange.storageKey)
    XCTAssertEqual(CapitalChartRange.stored(in: defaults), .year)
  }

  /// The three series differ by shape and pattern, not by colour alone.
  func testTheSeriesDifferByShape() {
    let styles = [NetWorthChart.netStyle, NetWorthChart.haveStyle, NetWorthChart.oweStyle]
    XCTAssertEqual(Set(styles.map(\.symbol)).count, 3)
    XCTAssertEqual(Set(styles.map(\.dash)).count, 3)
    XCTAssertEqual(NetWorthChart.netStyle.tint, .accent)
    XCTAssertEqual(NetWorthChart.haveStyle.tint, .secondary)
  }
}
