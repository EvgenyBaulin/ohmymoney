import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The numbers of the one style against the Overview master of the design file (Mac, 1440 × 900):
/// each value here is read off the frame, so a change of a margin, a gap, a radius or a size in
/// the code that the frame does not make fails here first.
@MainActor
final class OverviewFigmaNumbersTests: XCTestCase {
  /// The window of the frame: 1,440 wide, the sidebar 232, the content 28 in from each side.
  private let frameWidth: CGFloat = 1_440
  private let frameSidebar: CGFloat = 232

  func testThePageHasTheMarginsAndGapsOfTheFrame() {
    XCTAssertEqual(StyleMetrics.pageSide, 28)
    XCTAssertEqual(StyleMetrics.pageTop, 22)
    XCTAssertEqual(StyleMetrics.pageBottom, 24)
    XCTAssertEqual(StyleMetrics.stackGap, 10)
    XCTAssertEqual(StyleMetrics.columnGap, 14)
    #if os(macOS)
      XCTAssertEqual(OverviewView.sideMargin, 28)
      XCTAssertEqual(OverviewView.topMargin, 22)
      XCTAssertEqual(OverviewView.bottomMargin, 24)
      XCTAssertEqual(OverviewView.stackGap, 10)
      XCTAssertEqual(OverviewCard.columnGap, 14)
      XCTAssertEqual(OverviewCard.rowGap, 10)
      XCTAssertEqual(OverviewGroupedGrid.groupGap, 10)
      XCTAssertEqual(OverviewGroupedGrid.nameGap, 10)
    #endif
  }

  func testTheNarrowMacFrameUses22PointMarginsAnd12PointGaps() {
    let narrow = OverviewPageMetrics.of(.mac, columns: nil, windowWidth: 1_024)
    XCTAssertEqual(narrow.side, 22)
    XCTAssertEqual(narrow.columnGap, 12)
    let content: CGFloat = 1_024 - 232 - 2 - 2 * 22
    XCTAssertEqual(content, 746)
    XCTAssertEqual(OverviewCard.columns(forWidth: content, gap: narrow.columnGap), 2)
    XCTAssertEqual(OverviewCard.tileWidth(in: content, columns: 2, gap: narrow.columnGap), 367)
    XCTAssertEqual(OverviewCard.width(of: 1, in: content, columns: 2, gap: 12), 367)
    XCTAssertEqual(OverviewPageMetrics.of(.mac, columns: nil, windowWidth: 1_440), .mac)
    XCTAssertEqual(OverviewPageMetrics.of(.phone, columns: nil, windowWidth: 1_024), .phone)
    XCTAssertEqual(OverviewPageMetrics.of(.pad, columns: 2, windowWidth: 1_024).side, 24)
  }

  func testTheMoneyHeadingIsOnlyShownWhileEditingOnMac() {
    for editing in [false, true] {
      XCTAssertEqual(OverviewScreen.showsGroupName(.money, editing: editing, idiom: .mac), editing)
      for group in [OverviewTileGroup.plan, .analysis] {
        XCTAssertTrue(OverviewScreen.showsGroupName(group, editing: editing, idiom: .mac))
      }
      XCTAssertTrue(OverviewScreen.showsGroupName(.money, editing: editing, idiom: .pad))
      XCTAssertTrue(OverviewScreen.showsGroupName(.money, editing: editing, idiom: .phone))
    }
  }

  func testTheMacDebtPairSharesOneCardOnlyOutsideEditing() {
    let pair = OverviewLayout.Cell.pair(.owedToMe, .iOwe)
    XCTAssertTrue(OverviewCellView.sharesCard(pair, idiom: .mac, editing: false))
    XCTAssertTrue(OverviewCellView.sharesCard(.pair(.iOwe, .owedToMe), idiom: .mac, editing: false))
    XCTAssertFalse(OverviewCellView.sharesCard(pair, idiom: .mac, editing: true))
    XCTAssertFalse(OverviewCellView.sharesCard(pair, idiom: .phone, editing: false))
    XCTAssertFalse(OverviewCellView.sharesCard(pair, idiom: .pad, editing: false))
    XCTAssertFalse(
      OverviewCellView.sharesCard(.pair(.backups, .integrity), idiom: .mac, editing: false))
    XCTAssertFalse(OverviewCellView.sharesCard(.single(.owedToMe), idiom: .mac, editing: false))
    XCTAssertTrue(OverviewScreen.laysOut(.money, collapsed: [.money], editing: false, idiom: .mac))
    XCTAssertFalse(OverviewScreen.laysOut(.plan, collapsed: [.plan], editing: false, idiom: .mac))
  }

  /// Four tiles of 277 with three gaps of 14 fill the 1,150 of content; the limits, the card of
  /// the sum and «Что сделать сейчас» take two of them — 568.
  func testFourTilesOf277FillTheContentOfTheFrame() {
    let content = frameWidth - frameSidebar - 2 * StyleMetrics.pageSide - 2  // the 1 pt edges
    XCTAssertEqual(content, 1_150)
    XCTAssertEqual(OverviewCard.columns(forWidth: content), 4)
    let tile = OverviewCard.tileWidth(in: content, columns: 4)
    XCTAssertEqual(tile, 277, accuracy: 0.01)
    XCTAssertEqual(2 * tile + StyleMetrics.columnGap, 568, accuracy: 0.01)
    XCTAssertEqual(StyleMetrics.tileMinWidth, 277)
  }

  func testTilesAndCardsHaveTheRadiiPaddingAndEdgeOfTheFrame() {
    XCTAssertEqual(StyleMetrics.tilePadding, 14)
    XCTAssertEqual(StyleMetrics.tileGap, 6)
    XCTAssertEqual(StyleMetrics.cardRadius, 12)
    XCTAssertEqual(StyleMetrics.cardBorder, 1)
    let tile = ContentCard.edge(.tile)
    XCTAssertEqual(tile.width, 1)
    XCTAssertTrue(tile.outline, "a tile wears the theme's outline")
    XCTAssertFalse(ContentCard.edge(.plain).outline)
    #if os(macOS)
      XCTAssertEqual(ContentCard.cornerRadius, 12)
    #endif
  }

  func testTheMainCardHasTheNumbersOfTheFrame() {
    XCTAssertEqual(StyleMetrics.mainCardHorizontal, 20)
    XCTAssertEqual(StyleMetrics.mainCardVertical, 12)
    XCTAssertEqual(StyleMetrics.mainCardGap, 16)
    XCTAssertEqual(StyleMetrics.stripeWidth, 4)
    XCTAssertEqual(StyleMetrics.stripeHeight, 56)
    XCTAssertEqual(StyleMetrics.stripeRadius, 2)
    XCTAssertEqual(StyleMetrics.mainCardLineGap, 3)
  }

  func testLabelsAndButtonsHaveTheNumbersOfTheFrame() {
    XCTAssertEqual(StyleMetrics.statusDot, 6)
    XCTAssertEqual(StyleMetrics.statusGap, 5)
    XCTAssertEqual(StyleMetrics.statusHorizontal, 8)
    XCTAssertEqual(StyleMetrics.statusVertical, 3)
    XCTAssertEqual(StyleMetrics.headerButtonHorizontal, 16)
    XCTAssertEqual(StyleMetrics.headerButtonVertical, 9)
    XCTAssertEqual(StyleMetrics.headerButtonRadius, 10)
    XCTAssertEqual(StyleMetrics.headerButtonGap, 8)
    XCTAssertEqual(StyleMetrics.rowButtonHorizontal, 16)
    XCTAssertEqual(StyleMetrics.rowButtonVertical, 8)
    XCTAssertEqual(StyleMetrics.rowButtonRadius, 8)
    XCTAssertEqual(StyleMetrics.groupNameGap, 8)
    XCTAssertEqual(StyleMetrics.groupChevron, 12)
  }

  func testWhatToDoNowAndThePartsHaveTheNumbersOfTheFrame() {
    XCTAssertEqual(StyleMetrics.doNowHorizontal, 16)
    XCTAssertEqual(StyleMetrics.doNowTop, 14)
    XCTAssertEqual(StyleMetrics.doNowBottom, 8)
    XCTAssertEqual(StyleMetrics.doNowGap, 4)
    XCTAssertEqual(StyleMetrics.doNowRowVertical, 8)
    XCTAssertEqual(StyleMetrics.doNowRowGap, 12)
    XCTAssertEqual(StyleMetrics.doNowDot, 8)
    XCTAssertEqual(StyleMetrics.partWidth, 160)
    XCTAssertEqual(StyleMetrics.partHeight, 62)
    XCTAssertEqual(StyleMetrics.partRadius, 9)
    XCTAssertEqual(StyleMetrics.partPadding, 8)
    XCTAssertEqual(StyleMetrics.partLineGap, 3)
    XCTAssertEqual(StyleMetrics.partGap, 8)
    XCTAssertEqual(StyleMetrics.partsVertical, 6)
  }

  /// The type of the frame at «Обычный», in points.
  func testTheTypeHasTheSizesOfTheFrame() {
    func points(_ font: AppFont) -> CGFloat? {
      switch font.base {
      case .style(let style, _): AppFontSize.regular.points(of: style)
      case .points(let size, _, _): size
      }
    }
    XCTAssertEqual(points(StyleType.screenTitle), 22)
    XCTAssertEqual(points(StyleType.mainCaption), 12)
    XCTAssertEqual(points(StyleType.mainFigure), 24)
    XCTAssertEqual(points(StyleType.mainLine), 13)
    XCTAssertEqual(points(StyleType.status), 11.5)
    XCTAssertEqual(points(StyleType.headerButton), 13)
    XCTAssertEqual(points(StyleType.rowButton), 11)
    XCTAssertEqual(points(StyleType.tileTitle), 15)
    XCTAssertEqual(points(StyleType.tileRow), 12)
    XCTAssertEqual(points(StyleType.tileHint), 11)
    XCTAssertEqual(points(StyleType.groupName), 14)
    XCTAssertEqual(points(StyleType.rowTitle), 13)
    XCTAssertEqual(points(StyleType.rowDetail), 12)
    XCTAssertEqual(points(StyleType.cardSubtitle), 16)
    XCTAssertEqual(points(StyleType.partFigure), 16)
    XCTAssertEqual(points(StyleType.partLabel), 10)
  }

  /// The tint behind a status label is the theme's token for the tone, never the dot's colour
  /// faded by hand, and the dot is the tone's colour.
  func testAStatusLabelTakesTheTintTokensOfTheTheme() {
    let theme = AppThemeColors.fallback
    XCTAssertEqual(StatusLabel.tint(.good, in: theme), theme.statusPositiveTint)
    XCTAssertEqual(StatusLabel.tint(.attention, in: theme), theme.accentTint)
    XCTAssertEqual(StatusLabel.tint(.bad, in: theme), theme.statusNegativeTint)
    XCTAssertEqual(StatusLabel.tint(.neutral, in: theme), theme.contentSecondaryTint)
    XCTAssertEqual(StatusLabel.ink(.good, in: theme), theme.statusPositive)
    XCTAssertEqual(StatusLabel.ink(.bad, in: theme), theme.statusNegative)
    XCTAssertEqual(OverviewDoNowCard.dot(urgent: true, in: theme), theme.accentDefault)
    XCTAssertEqual(OverviewDoNowCard.dot(urgent: false, in: theme), theme.contentSecondary)
  }

  /// The rows of the frame: four tiles, then the card of the sum and «Что сделать сейчас» half
  /// and half; in the plan the limits take two of four between the payments and the 30 days.
  func testTheRowsOfTheFrame() {
    let money: [OverviewGridItem] = [
      .cell(.single(.monthToDate)), .cell(.single(.freeMoney)), .cell(.single(.canSave)),
      .cell(.pair(.owedToMe, .iOwe)), .freeSumParts, .doNow,
    ]
    XCTAssertEqual(
      OverviewGridItem.rows(money, columns: 4),
      [Array(money.prefix(4)), [.freeSumParts, .doNow]])
    let plan: [OverviewLayout.Cell] = [.single(.upcoming), .single(.limits), .single(.monthRest)]
    XCTAssertEqual(OverviewCard.rows(plan, columns: 4), [plan])
    XCTAssertEqual(OverviewCard.span(of: .single(.limits), columns: 4), 2)
    XCTAssertEqual(OverviewCard.span(of: .single(.weekdaySpending), columns: 4), 2)
    XCTAssertEqual(OverviewGridItem.span(of: .doNow, columns: 4), 2)
    XCTAssertEqual(OverviewGridItem.span(of: .freeSumParts, columns: 4), 2)
    // The 1,024 pt frame: two columns, the two cards one each.
    XCTAssertEqual(OverviewGridItem.span(of: .doNow, columns: 2), 1)
    XCTAssertEqual(OverviewGridItem.span(of: .freeSumParts, columns: 2), 1)
    XCTAssertEqual(OverviewCard.span(of: .single(.limits), columns: 2), 1)
  }

  /// The phone's frame: «Что сделать сейчас» right under the main card; the Mac's: beside the
  /// card of the sum among the tiles.
  func testWhatToDoNowStandsUnderTheMainCardInOneColumn() {
    let phone = OverviewGridItem.placed([.freeSumParts, .doNow], columns: 1)
    XCTAssertEqual(phone.above, [.doNow])
    XCTAssertEqual(phone.amongTiles, [.freeSumParts])
    let mac = OverviewGridItem.placed([.freeSumParts, .doNow], columns: 4)
    XCTAssertEqual(mac.above, [])
    XCTAssertEqual(mac.amongTiles, [.freeSumParts, .doNow])
  }

  /// A host that gives no room leaves the grid flexible: there a place two tiles wide would be
  /// sized by its content, so nothing takes two of four — a chart or a list takes the whole row,
  /// the limits and the two cards one column, as before the design's grid.
  func testWithoutAFixedWidthNothingTakesTwoOfFour() {
    XCTAssertEqual(OverviewCard.span(of: .single(.limits), columns: 4, halves: false), 1)
    XCTAssertEqual(OverviewCard.span(of: .single(.weekdaySpending), columns: 4, halves: false), 4)
    XCTAssertEqual(OverviewGridItem.span(of: .doNow, columns: 4, halves: false), 1)
    XCTAssertEqual(OverviewGridItem.span(of: .freeSumParts, columns: 4, halves: false), 1)
    let plan: [OverviewLayout.Cell] = [
      .single(.upcoming), .single(.weekdaySpending), .single(.limits),
    ]
    XCTAssertEqual(
      OverviewCard.rows(plan, columns: 4, halves: false),
      [[.single(.upcoming)], [.single(.weekdaySpending)], [.single(.limits)]])
  }

  /// The two cards join the first group whose tiles are laid out; with none they stand above.
  func testTheTwoCardsJoinTheFirstGroupLaidOut() {
    XCTAssertEqual(
      OverviewGridItem.doNowGroup(in: [.money, .plan]) { $0 == .plan }, .plan)
    XCTAssertEqual(OverviewGridItem.doNowGroup(in: [.money, .plan]) { _ in true }, .money)
    XCTAssertNil(OverviewGridItem.doNowGroup(in: [.money]) { _ in false })
  }

  private func freeSum(
    now: Int64, scheduled: Int64, debts: Int64, cushion: Int64, goals: Int64 = 0
  ) -> FreeMoney {
    let today = DateOnly(year: 2026, month: 11, day: 10)
    let accounts = AccountsSnapshot(
      sections: [], inSummaryTotalRub: AmountE4(whole: now), unanchored: [], withoutRate: [],
      balances: .empty)
    return FreeMoney(
      accounts: accounts,
      plan: CashPlan(
        scheduled: AmountE4(whole: scheduled), debts: AmountE4(whole: debts),
        goalSavings: AmountE4(whole: goals)),
      stillExpected: .zero, today: today, until: today.adding(days: 29),
      cushion: AmountE4(whole: cushion))
  }

  /// «Из чего складывается сумма»: the money on the accounts less the payments and the reserve
  /// is the free sum the core gives — the parts always add up to the total. The numbers of the
  /// frame: 126 400 − 68 800 − 16 000 = 41 600 for 30 days.
  func testThePartsOfTheSumAddUpToItsTotal() throws {
    let free = freeSum(now: 126_400, scheduled: 50_400, debts: 18_400, cushion: 16_000)
    let parts = try XCTUnwrap(FreeSumParts.make(free))
    XCTAssertEqual(parts.total, AmountE4(whole: 41_600))
    XCTAssertEqual(parts.parts.map(\.kind), [.accounts, .payments, .reserve])
    XCTAssertEqual(
      parts.parts.map(\.amount),
      [AmountE4(whole: 126_400), AmountE4(whole: -68_800), AmountE4(whole: -16_000)])
    XCTAssertEqual(parts.parts.reduce(AmountE4.zero) { $0 + $1.amount }, parts.total)
    XCTAssertEqual(parts.days, 30)
    XCTAssertEqual(parts.perDayRubles, free.dailyRubles)
    XCTAssertEqual(parts.reserve, AmountE4(whole: 16_000))
  }

  /// No reserve kept: no plate for it.
  func testThePartsLeaveOutAReserveThatIsNotKept() throws {
    let parts = try XCTUnwrap(
      FreeSumParts.make(freeSum(now: 50_000, scheduled: 10_000, debts: 0, cushion: 0)))
    XCTAssertEqual(parts.parts.map(\.kind), [.accounts, .payments])
    XCTAssertEqual(parts.total, AmountE4(whole: 40_000))
  }

  func testGoalsAreDeductedWithoutAnExtraPlateOnMac() throws {
    let parts = try XCTUnwrap(
      FreeSumParts.make(
        freeSum(now: 126_400, scheduled: 50_400, debts: 18_400, cushion: 16_000, goals: 6_000)))
    XCTAssertEqual(parts.total, AmountE4(whole: 35_600))
    XCTAssertEqual(parts.parts.reduce(AmountE4.zero) { $0 + $1.amount }, parts.total)
    XCTAssertEqual(parts.plates(for: .mac).map(\.kind), [.accounts, .payments, .reserve])
    XCTAssertEqual(parts.goalDeduction(for: .mac), AmountE4(whole: -6_000))
    XCTAssertEqual(
      parts.plates(for: .mac).reduce(AmountE4.zero) { $0 + $1.amount }
        + (parts.goalDeduction(for: .mac) ?? .zero), parts.total)
    XCTAssertEqual(parts.plates(for: .phone), parts.parts)
    XCTAssertNil(parts.goalDeduction(for: .phone))
    XCTAssertEqual(parts.plates(for: .pad), parts.parts)
    XCTAssertNil(parts.goalDeduction(for: .pad))
    let withoutGoals = try XCTUnwrap(
      FreeSumParts.make(
        freeSum(now: 50_000, scheduled: 10_000, debts: 0, cushion: 0)))
    XCTAssertNil(withoutGoals.goalDeduction(for: .mac))
  }

  func testThePartsWaitForACountedFreeSum() {
    let today = DateOnly(year: 2026, month: 11, day: 10)
    let free = FreeMoney(
      accounts: .empty, plan: CashPlan(), stillExpected: .zero, today: today,
      until: today.adding(days: 29))
    XCTAssertNil(FreeSumParts.make(free))
  }

  /// Every word of the card is in both languages.
  func testThePartsSpeakBothLanguages() throws {
    for code in ["ru", "en"] {
      let path = try XCTUnwrap(Bundle.main.path(forResource: code, ofType: "lproj"), code)
      let bundle = try XCTUnwrap(Bundle(path: path))
      for key in FreeSumParts.keys {
        let text = bundle.localizedString(forKey: key, value: "\u{0}", table: FreeSumParts.table)
        XCTAssertNotEqual(text, "\u{0}", "\(key) has no \(code) words")
        XCTAssertNotEqual(text, key, "\(key) has no \(code) words")
      }
    }
  }
}
