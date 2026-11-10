import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Planning against its frames in the design file: the master at 1440 × 900 and the narrower
/// frames at 1280 and 1024. Each value is read off a frame, so a change of a margin, a gap, a
/// column or a size the frames do not make fails here first; and «+ Добавить ▾» holds the six
/// forms of its menu, in the design's order, each opening its own.
@MainActor
final class PlanningFigmaNumbersTests: XCTestCase {
  /// The sidebar of every frame is 232; the content stands 28 in from each side.
  private let sidebar: CGFloat = 232

  private func content(ofWindow width: CGFloat) -> CGFloat {
    width - sidebar - 2 * StyleMetrics.pageSide
  }

  func testThePageHasTheMarginsAndGapsOfTheFrames() {
    XCTAssertEqual(PlanningMetrics.pageSide, 28)
    XCTAssertEqual(PlanningMetrics.pageTop, 22)
    XCTAssertEqual(PlanningMetrics.pageBottom, 24)
    // The header at 22, 65 tall; the tabs at 101; the free sum at 140, 146 tall; the next 14
    // days at 300; the blocks at 422: 14 between each.
    XCTAssertEqual(22 + 65 + PlanningMetrics.stackGap, 101)
    XCTAssertEqual(101 + 25 + PlanningMetrics.stackGap, 140)
    XCTAssertEqual(140 + 146 + PlanningMetrics.stackGap, 300)
    XCTAssertEqual(300 + 108 + PlanningMetrics.stackGap, 422)
    XCTAssertEqual(PlanningMetrics.columnGap, 14)
  }

  func testTheCardsHaveTheNumbersOfTheFrames() {
    // A card: 1 pt edge, 16 inside it — its rows start 17 in —, 8 between the rows.
    XCTAssertEqual(PlanningMetrics.cardInset + PlanningMetrics.cardEdge, 17)
    XCTAssertEqual(PlanningMetrics.cardGap, 8)
    XCTAssertEqual(PlanningMetrics.headerIcon, 16)
    XCTAssertEqual(PlanningMetrics.headerIconGap, 8)
    // The free sum: 18 in, 10 between its parts; six columns with 24 after the first and 20 at
    // each side of the others, dividers 1 × 52; four metrics 18 apart.
    XCTAssertEqual(PlanningMetrics.freeInset + PlanningMetrics.cardEdge, 18)
    XCTAssertEqual(PlanningMetrics.freeGap, 10)
    XCTAssertEqual(PlanningMetrics.freeFirstTrailing, 24)
    XCTAssertEqual(PlanningMetrics.freeColumnSide, 20)
    XCTAssertEqual(PlanningMetrics.dividerHeight, 52)
    XCTAssertEqual(PlanningMetrics.figureGap, 4)
    XCTAssertEqual(PlanningMetrics.metricGap, 18)
    XCTAssertEqual(PlanningMetrics.metricLineGap, 5)
    // A tab 11 × 5, 6 apart; a day 4 × 8, radius 10, 6 apart, 3 to its mark of 12.
    XCTAssertEqual(PlanningMetrics.tabHorizontal, 11)
    XCTAssertEqual(PlanningMetrics.tabVertical, 5)
    XCTAssertEqual(PlanningMetrics.tabGap, 6)
    XCTAssertEqual(PlanningMetrics.dayHorizontal, 4)
    XCTAssertEqual(PlanningMetrics.dayVertical, 8)
    XCTAssertEqual(PlanningMetrics.dayRadius, 10)
    XCTAssertEqual(PlanningMetrics.dayGap, 6)
    XCTAssertEqual(PlanningMetrics.dayLineGap, 3)
    XCTAssertEqual(PlanningMetrics.dayMark, 12)
    XCTAssertEqual(StyleMetrics.cardRadius, 12)
  }

  /// 1440: 1,152 of content, three columns of 374.67, the free sum in six columns. 1280: 992,
  /// three of 321.33, four metrics. 1024: 736, one column, four metrics. The window's edges of
  /// 1 pt take two more points, and change nothing.
  func testTheThreeFramesLayOutAsTheDesignDrawsThem() {
    let frames: [(window: CGFloat, content: CGFloat, columns: Int, card: CGFloat, six: Bool)] = [
      (1_440, 1_152, 3, 374.67, true),
      (1_280, 992, 3, 321.33, false),
      (1_024, 736, 1, 736, false),
    ]
    for frame in frames {
      XCTAssertEqual(content(ofWindow: frame.window), frame.content)
      for edges in [CGFloat(0), 2] {
        let width = frame.content - edges
        XCTAssertEqual(
          PlanningPageLayout.blockColumns(forContent: width), frame.columns, "\(frame.window)")
        XCTAssertEqual(
          PlanningPageLayout.freeShowsColumns(forContent: width), frame.six, "\(frame.window)")
      }
      XCTAssertEqual(
        PlanningPageLayout.cardWidth(forContent: frame.content, columns: frame.columns),
        frame.card, accuracy: 0.01, "\(frame.window)")
    }
  }

  /// The largest text asks for more room before three columns and six figures: the narrowest
  /// window then keeps one column and the four metrics.
  func testLargerTextNeedsMoreRoomForColumns() {
    XCTAssertEqual(PlanningPageLayout.blockColumns(forContent: 992, fontSize: .xlarge), 1)
    XCTAssertFalse(PlanningPageLayout.freeShowsColumns(forContent: 1_152, fontSize: .xlarge))
    XCTAssertEqual(PlanningPageLayout.blockColumns(forContent: 1_600, fontSize: .xlarge), 3)
    XCTAssertEqual(PlanningPageLayout.blockColumns(forContent: 1_152, fontSize: .small), 3)
  }

  /// Each column a run of the order: «Платежи», «Подписки», «Ожидаемые поступления» down the
  /// first, as the design puts payments over the expected incomes; the free sum is the card above
  /// the grid, never a block of it.
  func testTheBlocksRunDownTheColumns() {
    let grid = PlanningPageLayout.gridBlocks(
      PlanningBlockText.shown(PlanningBlocks.standard, selfEmployed: false))
    XCTAssertFalse(grid.contains(.freeMoney))
    XCTAssertEqual(
      PlanningPageLayout.deal(grid, into: 3),
      [[.payments, .subscriptions, .expectedIncome], [.limits, .goals], [.events, .advice]])
    XCTAssertEqual(PlanningPageLayout.deal(grid, into: 1), [grid])
    XCTAssertEqual(PlanningPageLayout.deal([], into: 3), [[], [], []])
    let withTax = PlanningPageLayout.gridBlocks(PlanningBlocks.standard)
    XCTAssertEqual(PlanningPageLayout.deal(withTax, into: 3).map(\.count), [3, 3, 2])
  }

  /// The type of the frames at «Обычный», in points.
  func testTheTypeHasTheSizesOfTheFrames() {
    func points(_ font: AppFont) -> CGFloat? {
      switch font.base {
      case .style(let style, _): AppFontSize.regular.points(of: style)
      case .points(let size, _, _): size
      }
    }
    XCTAssertEqual(points(PlanningType.title), 22)
    XCTAssertEqual(points(PlanningType.subtitle), 14)
    XCTAssertEqual(points(PlanningType.tab), 12)
    XCTAssertEqual(points(PlanningType.chosenTab), 12)
    XCTAssertEqual(points(PlanningType.freeTitle), 14)
    XCTAssertEqual(points(PlanningType.freeFigure), 34)
    XCTAssertEqual(points(PlanningType.freeColumn), 16)
    XCTAssertEqual(points(PlanningType.freeWords), 12)
    XCTAssertEqual(points(PlanningType.freeHint), 11)
    XCTAssertEqual(points(PlanningType.metricFigure), 21)
    XCTAssertEqual(points(PlanningType.cardTitle), 15)
    XCTAssertEqual(points(PlanningType.cardLink), 12)
    XCTAssertEqual(points(PlanningType.dayNumber), 13)
  }

  // MARK: - «+ Добавить ▾»

  /// Six items, in the design's order, plain words: Платёж, Подписку, Поступление, Лимит, Цель,
  /// Событие.
  func testTheAddMenuHasTheSixItemsOfTheDesign() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    XCTAssertEqual(
      PlanningAddition.allCases, [.payment, .subscription, .income, .limit, .goal, .event])
    XCTAssertEqual(
      PlanningAddition.allCases.map { PlanningBlockText.t($0.titleKey, environment) },
      ["Платёж", "Подписку", "Поступление", "Лимит", "Цель", "Событие"])
    XCTAssertEqual(PlanningBlockText.t("layout.add", environment), "Добавить")
    environment.language.choice = .english
    for addition in PlanningAddition.allCases {
      XCTAssertNotEqual(
        environment.language(addition.titleKey, table: "Planning"), addition.titleKey)
    }
  }

  /// Every item opens its own form: a new payment, a new subscription, an expected income, a
  /// limit, a goal — each empty — and the form of an event.
  func testEachItemOfTheAddMenuOpensItsOwnForm() throws {
    let environment = AppEnvironment()
    var opened: [String] = []
    for addition in PlanningAddition.allCases {
      switch PlanningView.target(of: addition, environment) {
      case .sheet(let sheet):
        switch (addition, sheet) {
        case (.payment, .payment(nil)): opened.append("payment")
        case (.subscription, .newPayment(let payment, let chosen)):
          XCTAssertEqual(payment.kind, .subscription)
          XCTAssertFalse(chosen, "the currency follows the account picked")
          opened.append("subscription")
        case (.income, .expected(nil)): opened.append("income")
        case (.limit, .budget(nil)): opened.append("limit")
        case (.goal, .goal(nil)): opened.append("goal")
        default: XCTFail("\(addition) opens \(sheet.id)")
        }
      case .event:
        XCTAssertEqual(addition, .event)
        opened.append("event")
      }
    }
    XCTAssertEqual(opened, ["payment", "subscription", "income", "limit", "goal", "event"])
    XCTAssertEqual(Set(opened).count, 6, "six different forms")
  }

  // MARK: - The tabs and the header

  func testTheTabsAreTheDesignsAndEachLeadsToItsBlocks() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    XCTAssertEqual(
      PlanningTab.allCases.map { PlanningBlockText.t($0.titleKey, environment) },
      ["Всё", "Платежи", "Поступления", "Лимиты", "Цели", "События", "Подушка", "План года"])
    XCTAssertEqual(PlanningTab.tab(of: .payments), .payments)
    XCTAssertEqual(PlanningTab.tab(of: .subscriptions), .payments)
    XCTAssertEqual(PlanningTab.tab(of: .expectedIncome), .income)
    XCTAssertEqual(PlanningTab.tab(of: .limits), .limits)
    XCTAssertEqual(PlanningTab.tab(of: .goals), .goals)
    XCTAssertEqual(PlanningTab.tab(of: .events), .events)
    XCTAssertNil(PlanningTab.tab(of: .advice))
    XCTAssertNil(PlanningTab.tab(of: .freeMoney))
    XCTAssertTrue(PlanningTab.all.blocks.isEmpty)
    environment.language.choice = .english
    for tab in PlanningTab.allCases {
      XCTAssertNotEqual(environment.language(tab.titleKey, table: "Planning"), tab.titleKey)
    }
    for key in ["layout.more", "layout.card.all", "layout.free.hint", "layout.free.noIncome"] {
      XCTAssertNotEqual(environment.language(key, table: "Planning"), key)
    }
  }

  /// «Ноябрь 2026»: the month of today, its name in the nominative.
  func testTheSubtitleIsTheMonthOfToday() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let subtitle = PlanningHeader.subtitle(environment)
    XCTAssertEqual(subtitle, environment.dates.monthTitle(environment.today.monthKey))
    XCTAssertTrue(subtitle.hasSuffix(" \(environment.today.year)"), subtitle)
    XCTAssertEqual(
      subtitle.first.map { String($0) }, subtitle.first.map { String($0).uppercased() })
  }
}
