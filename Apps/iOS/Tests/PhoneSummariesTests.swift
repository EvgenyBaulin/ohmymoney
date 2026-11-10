import AppCore
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// «Итоги» on touch as their frames draw them: the page «Итоги» of a phone (68:18578 and its
/// scroll 264:91420, 440 wide) with the cards one under another, the tab «По периодам» of a
/// tablet (572:224407, the board 1060 wide) with two columns — and a picture of each kept with
/// the result, to lay beside the frame.
@MainActor
final class PhoneSummariesTests: XCTestCase {
  private static let today = DateOnly(year: 2026, month: 10, day: 26)

  /// The week of the frames: 18 400 ₽ over five categories, 32 000 ₽ in.
  private static var dataset: Dataset {
    let names = ["Жильё", "Продукты", "Кафе", "Транспорт", "Подарки"]
    let categories = names.map { CoreKit.Category(kind: .expense, name: $0) }
    let salary = CoreKit.Category(kind: .income, name: "Зарплата")
    let spent: [(Int, Int64, Int, Quality)] = [
      (0, 5_890, 16, .good), (1, 5_150, 14, .neutral), (2, 3_310, 15, .bad),
      (3, 2_210, 12, .neutral), (4, 1_840, 15, .bad), (1, 18_400, 9, .neutral),
    ]
    func entry(
      _ kind: TransactionKind, _ whole: Int64, _ day: Int, _ category: UUID, _ quality: Quality?
    )
      -> TransactionEntry
    {
      let id = UUID()
      let amount = AmountE4(whole: whole)
      return TransactionEntry(
        transaction: Transaction(
          id: id, kind: kind,
          occurredAt: CalendarContext.system.noon(of: DateOnly(year: 2026, month: 10, day: day)),
          amountE4: amount),
        parts: [
          TransactionPart(
            transactionId: id, categoryId: category, quality: quality, amountE4: amount)
        ])
    }
    let entries =
      [entry(.income, 32_000, 12, salary.id, nil)]
      + spent.map { entry(.expense, $0.1, $0.2, categories[$0.0].id, $0.3) }
    return Dataset(entries: entries, categories: categories + [salary])
  }

  private func dependencies() -> AppDependencies {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    compute.applyLight(
      DataSnapshot.build(
        dataset: Self.dataset, calendar: .system, today: Self.today, context: SnapshotContext(),
        version: DataVersion(load: 0)))
    return AppDependencies(environment: environment, store: TransactionsStore(), compute: compute)
  }

  /// Draws `view` `width` wide, keeps a picture of it and returns the height it takes.
  private func draw(_ view: some View, width: CGFloat, named name: String) throws -> CGFloat {
    let controller = UIHostingController(rootView: view)
    // A window wider than the simulator's screen would get the rest as a safe area.
    controller.safeAreaRegions = []
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1_600))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    for _ in 0..<40 {
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
    let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
      controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
    }
    let png = try XCTUnwrap(image.pngData())
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    let fitting = controller.sizeThatFits(
      in: CGSize(width: width, height: .greatestFiniteMagnitude))
    window.isHidden = true
    return fitting.height
  }

  func testTouchTakesTheNumbersOfItsFrames() {
    XCTAssertEqual(PeriodsBoardMetrics.of(.phone), .phone)
    XCTAssertEqual(PeriodsBoardMetrics.of(.pad), .pad)
    XCTAssertEqual(SummariesPageMetrics.side, 16)
    XCTAssertEqual(PeriodsBoardMetrics.leftColumn(.pad, width: 1_060), 411)
    XCTAssertFalse(PeriodsBoardMetrics.fitsTwoColumns(.phone, width: 408))
    XCTAssertTrue(PeriodsBoardMetrics.fitsTwoColumns(.pad, width: 1_060))
  }

  /// The week of the frame on the phone's page and on the tablet's tab, drawn and kept.
  func testThePhoneAndTheTabletDrawTheBoard() throws {
    let deps = dependencies()
    SummariesRoute.shared.pending = .week(
      WeekKey(containing: DateOnly(year: 2026, month: 10, day: 14)))
    _ = try draw(
      SummariesPage(deps: deps).appDependencies(deps), width: 440,
      named: "Итоги, iPhone 440 (Figma 68:18578, 264:91420)")
    SummariesRoute.shared.pending = .week(
      WeekKey(containing: DateOnly(year: 2026, month: 10, day: 14)))
    let store = PeriodsBoardStore()
    let tablet = try draw(
      PeriodsBoardView(store: store).padding(.horizontal, 28)
        .environment(\.layoutIdiom, .pad)
        .appDependencies(deps),
      width: 1_116, named: "Итоги, iPad 1116 (Figma 572:224407)")
    XCTAssertEqual(store.board?.spent, AmountE4(whole: 18_400), "the week asked for is shown")
    XCTAssertGreaterThan(tablet, 400, "the cards are drawn")
  }

  /// The tablet's Reports on «По периодам» (572:224407): the title, the period and the one orange
  /// «Поделиться…» at the right, the tabs with «По периодам» chosen, the board under them.
  func testTheTabletShowsTheTabUnderTheTabsOfReports() throws {
    let deps = dependencies()
    let suite = "ohmymoney-phone-summaries-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    SummariesRoute.shared.ask(
      .week(WeekKey(containing: DateOnly(year: 2026, month: 10, day: 14))), defaults: defaults)
    XCTAssertTrue(ReportsTab.tabs(.pad).contains(.byPeriods))
    let height = try draw(
      ReportsWindow(deps: deps)
        .environment(\.layoutIdiom, .pad)
        .appDependencies(deps)
        .defaultAppStorage(defaults),
      width: 1_116, named: "Отчёты · По периодам, iPad 1116 (Figma 572:224407)")
    XCTAssertGreaterThan(height, 400)
  }
}
