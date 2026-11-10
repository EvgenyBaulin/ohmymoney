import AppCore
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// «Обзор» and «Операции» of the phone and the tablet against their frames, by the numbers:
/// the phone's Overview 5:8097 and Operations 5:7974 (5:7984), the tablet's Overview 5:76205
/// (the Mac's master laid into it) and Operations 5:76343. The numbers come from the design's
/// models (`OverviewPageMetrics`, `OperationsHeaderMetrics`, `StyleType`), checked for each
/// idiom, so the tablet's are checked on a phone too.
@MainActor
final class TouchScreensFigmaTests: XCTestCase {
  // MARK: Overview, the phone (5:8097)

  func testThePhonesOverviewStacksEverythingTenApart() {
    let phone = OverviewPageMetrics.phone
    XCTAssertEqual(phone.side, 16, "the content 16 from the sides")
    XCTAssertEqual(phone.stackGap, 10)
    XCTAssertEqual(phone.groupGap, 10)
    XCTAssertEqual(phone.nameGap, 10)
    XCTAssertEqual(phone.rowGap, 10)
    XCTAssertEqual(phone.nameTop, 6, "a group's name 6 lower than the gap")
    XCTAssertEqual(OverviewPageMetrics.of(.phone), phone)
  }

  func testThePhonesTitleRowIsThirtyFourBoldTwelveUnderTheBar() {
    let phone = OverviewPageMetrics.phone
    XCTAssertEqual(phone.top, 12)
    XCTAssertEqual(phone.titlePoints, 34)
    XCTAssertEqual(phone.titleFont.points(at: .regular), 34)
    // 8 under the row and 11 to the content: 19 from the title to the main card.
    XCTAssertEqual(phone.titleBottom + phone.stackGap, 19)
    XCTAssertEqual(OverviewTitleType.phoneAction.points(at: .regular), 15)
  }

  func testThePhonesMainCardIsFourteenBySixteenWithATwentyPointFigure() {
    let margins = MainCard<EmptyView>.margins(.phone)
    XCTAssertEqual(margins.horizontal, 14)
    XCTAssertEqual(margins.vertical, 16)
    XCTAssertEqual(OverviewHeadlineCard.figureFont(.phone).points(at: .regular), 20)
    XCTAssertEqual(StyleMetrics.stripeWidth, 4)
    XCTAssertEqual(StyleMetrics.stripeHeight, 56)
    XCTAssertEqual(StyleMetrics.mainCardGap, 16)
    XCTAssertEqual(StyleMetrics.mainCardLineGap, 3)
  }

  func testThePhonesTilesWearTheHairlineAndNoShadow() {
    let tile = ContentCard.edge(.tile, idiom: .phone)
    XCTAssertEqual(tile.width, 1)
    XCTAssertEqual(tile.ink, .hairline)
    XCTAssertFalse(ContentCard.hasShadow(.tile, idiom: .phone), "no tile of 5:8097 has a shadow")
    XCTAssertTrue(ContentCard.hasShadow(.plain, idiom: .phone))
    XCTAssertEqual(ContentCard.cornerRadius, 22)
    XCTAssertEqual(StyleMetrics.tilePadding, 14)
    XCTAssertEqual(StyleMetrics.tileGap, 6)
  }

  func testThePhonesCountOfThingsToDoIsInTheAccentsWords() {
    let theme = AppThemeColors.fallback
    XCTAssertEqual(OverviewDoNowCard.countInk(in: theme, idiom: .phone), theme.accentContent)
    XCTAssertEqual(OverviewDoNowCard.countInk(in: theme, idiom: .pad), theme.contentSecondary)
    XCTAssertEqual(OverviewDoNowCard.countInk(in: theme, idiom: .mac), theme.contentSecondary)
  }

  func testOnThePhoneWhatToDoNowStandsUnderTheMainCard() {
    XCTAssertFalse(OverviewPageMetrics.phone.doNowStandsBesideMain(columns: 1))
    let placed = OverviewGridItem.placed([.freeSumParts, .doNow], columns: 1)
    XCTAssertEqual(placed.above, [.doNow])
    XCTAssertEqual(placed.amongTiles, [.freeSumParts])
  }

  // MARK: Overview, the tablet (5:76205)

  func testTheTabletsOverviewHasTheMacsMarginsAndItsOwnGaps() {
    let pad = OverviewPageMetrics.pad
    XCTAssertEqual(pad.side, 28)
    XCTAssertEqual(pad.bottom, 24)
    XCTAssertEqual(pad.stackGap, 12)
    XCTAssertEqual(pad.groupGap, 12)
    XCTAssertEqual(pad.nameGap, 12)
    XCTAssertEqual(pad.rowGap, 12)
    XCTAssertEqual(pad.columnGap, 14)
    XCTAssertEqual(pad.nameTop, 0)
    XCTAssertEqual(pad.titlePoints, 22)
  }

  func testTheTabletsMainCardIsTwentyBySixteenWithATwentyFourPointFigure() {
    let margins = MainCard<EmptyView>.margins(.pad)
    XCTAssertEqual(margins.horizontal, 20)
    XCTAssertEqual(margins.vertical, 16)
    XCTAssertEqual(OverviewHeadlineCard.figureFont(.pad).points(at: .regular), 24)
  }

  func testOnTheTabletWhatToDoNowStandsBesideTheMainCard440Wide() {
    let pad = OverviewPageMetrics.pad
    XCTAssertEqual(pad.doNowBesideMain, 440)
    XCTAssertTrue(pad.doNowStandsBesideMain(columns: 3))
    XCTAssertFalse(pad.doNowStandsBesideMain(columns: 2), "a narrower grid keeps it among tiles")
    XCTAssertFalse(OverviewPageMetrics.mac.doNowStandsBesideMain(columns: 4))
  }

  func testTheTabletsTilesWearTheOutlineAndNoShadow() {
    XCTAssertEqual(ContentCard.edge(.tile, idiom: .pad).ink, .outline)
    XCTAssertFalse(ContentCard.hasShadow(.tile, idiom: .pad))
  }

  /// The tablet's Split View ½ (564:97540, 678 pt, two tiles in a row): 24 at the sides and
  /// «Что сделать сейчас» under the main card, across the page.
  func testTheTabletsNarrowWindowHasTheNumbersOfItsSplitViewFrame() {
    let narrow = OverviewPageMetrics.of(.pad, columns: 2)
    XCTAssertEqual(narrow.side, 24)
    XCTAssertTrue(narrow.doNowWithMain)
    XCTAssertFalse(narrow.doNowStandsBesideMain(columns: 2))
    XCTAssertEqual(OverviewPageMetrics.of(.pad, columns: 3).side, 28)
    XCTAssertEqual(OverviewPageMetrics.of(.pad, columns: nil).side, 28)
    XCTAssertEqual(OverviewPageMetrics.of(.phone, columns: 1).side, 16, "the phone keeps its 16")
    XCTAssertFalse(OverviewPageMetrics.phone.doNowWithMain)
  }

  // MARK: Drawn

  /// The size a view asks for, laid out by SwiftUI as the screen lays it out.
  private func size<Content: View>(_ view: Content, width: CGFloat? = nil) -> CGSize {
    let controller = UIHostingController(rootView: view)
    return controller.sizeThatFits(
      in: CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
  }

  /// The main card as drawn: the stripe 4 × 56 and 16 to the words, and its margins — 14 × 16 on
  /// a phone, 20 × 16 on a tablet, 20 × 12 on the Mac.
  func testTheMainCardIsDrawnWithTheMarginsOfEachFrame() {
    for (idiom, width, height) in [
      (LayoutIdiom.phone, 148.0, 88.0), (.pad, 160, 88), (.mac, 160, 80),
    ] {
      let card = MainCard(stripe: .green) { Color.clear.frame(width: 100, height: 56) }
        .fixedSize()
        .environment(\.layoutIdiom, idiom)
      let drawn = size(card)
      XCTAssertEqual(drawn.width, CGFloat(width), accuracy: 0.5, "\(idiom)")
      XCTAssertEqual(drawn.height, CGFloat(height), accuracy: 0.5, "\(idiom)")
    }
  }

  /// A tile as drawn: 14 inside on every side.
  func testATileIsDrawnWithFourteenInside() {
    for idiom in [LayoutIdiom.phone, .pad] {
      let tile = Color.clear.frame(width: 100, height: 64)
        .contentCard()
        .fixedSize()
        .environment(\.cardStyle, .tile)
        .environment(\.layoutIdiom, idiom)
      let drawn = size(tile)
      XCTAssertEqual(drawn.width, 128, accuracy: 0.5, "\(idiom)")
      XCTAssertEqual(drawn.height, 92, accuracy: 0.5, "\(idiom)")
    }
  }

  func testTheMacKeepsItsOwnNumbers() {
    let mac = OverviewPageMetrics.mac
    XCTAssertEqual(mac.side, 28)
    XCTAssertEqual(mac.top, 22)
    XCTAssertEqual(mac.stackGap, 10)
    XCTAssertEqual(mac.rowGap, 10)
    XCTAssertEqual(MainCard<EmptyView>.margins(.mac).vertical, 12)
    XCTAssertEqual(ContentCard.edge(.tile, idiom: .mac).ink, .outline)
    XCTAssertFalse(ContentCard.hasShadow(.plain, idiom: .mac))
  }

  // MARK: The type

  /// The one style's type on a phone and a tablet is written in the frames' points: the system's
  /// text styles of iOS would draw it 3–6 points larger.
  func testTheTypeOfTheOneStyleHasThePointsOfTheFrames() {
    func points(_ font: AppFont) -> CGFloat? { font.points(at: .regular) }
    XCTAssertEqual(points(StyleType.screenTitle), 22)
    XCTAssertEqual(points(StyleType.mainCaption), 12)
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
    XCTAssertEqual(points(StyleType.partLabel), 10)
    XCTAssertEqual(points(OverviewGroupHeader.nameFont), 14)
    XCTAssertFalse(OverviewGroupHeader.nameIsPrimary, "a group's name is in the secondary ink")
  }

  /// The text styles inside Overview's tiles are drawn at the design's points too: «Расходы»
  /// 12, a hint 11, as the frames write them; outside it the system's sizes stay.
  func testTheTilesTextStylesTakeTheDesignsPoints() {
    XCTAssertEqual(AppFont.callout.points(at: .regular, designPoints: true), 12)
    XCTAssertEqual(AppFont.subheadline.points(at: .regular, designPoints: true), 11)
    XCTAssertEqual(AppFont.title3.points(at: .regular, designPoints: true), 15)
    XCTAssertNil(AppFont.callout.points(at: .regular), "the system's own size outside")
    XCTAssertEqual(AppFont.callout.points(at: .large, designPoints: true), 14)
  }

  // MARK: Operations

  func testThePhonesOperationsHaveTheNumbersOf5_7984() {
    XCTAssertEqual(OperationsMetrics.phonePageSide, 16)
    XCTAssertEqual(OperationsMetrics.phoneStackGap, 10)
    XCTAssertEqual(OperationsMetrics.phoneDayInset, 6)
    XCTAssertEqual(OperationsMetrics.phoneDayGap, 4)
    XCTAssertEqual(OperationsMetrics.phoneRowHorizontal, 14)
    XCTAssertEqual(OperationsMetrics.phoneRowVertical, 10)
    XCTAssertEqual(OperationsMetrics.phoneBadge, 36)
    XCTAssertEqual(OperationsMetrics.phoneBadgeSymbol, 18)
    XCTAssertEqual(OperationsMetrics.phoneLineGap, 1)
    XCTAssertEqual(OperationsMetrics.badgeGap, 12)
    XCTAssertEqual(OperationsType.phoneTitle.points(at: .regular), 16)
    XCTAssertEqual(OperationsType.phoneCaption.points(at: .regular), 12)
    XCTAssertEqual(OperationsType.phoneAmount.points(at: .regular), 16)
    XCTAssertEqual(OperationsType.dayName.points(at: .regular), 12)
    XCTAssertEqual(OperationsType.dayFigure.points(at: .regular), 12)
    XCTAssertEqual(OperationsType.touchMonth.points(at: .regular), 14)
    XCTAssertEqual(OperationsMonthCapsule.horizontal(.phone), 12)
    XCTAssertEqual(OperationsMetrics.padMonthVertical, 7)
    XCTAssertEqual(OperationsMetrics.padMonthChevron, 14)
    let theme = AppThemeColors.fallback
    XCTAssertEqual(OperationDayHead.nameInk(in: theme, idiom: .phone), theme.contentSecondary)
    XCTAssertFalse(OperationDayCards<EmptyView>.showsColumns(width: 1_000, idiom: .phone))
  }

  func testThePhonesOperationsHeaderHasNoNewOperation() {
    let phone = OperationsHeaderMetrics.phone
    XCTAssertFalse(phone.showsNewOperation, "the «+» of the bar writes")
    XCTAssertEqual(phone.side, 16)
    XCTAssertEqual(phone.rowTop, 2, "2 under the title, as the frame lays the month")
    XCTAssertEqual(phone.chipsTop, 10)
    XCTAssertEqual(phone.chipsToList, 10)
  }

  func testTheTabletsOperationsHaveTheNumbersOf5_76343() {
    let pad = OperationsHeaderMetrics.pad
    XCTAssertEqual(pad.side, 32)
    XCTAssertEqual(pad.rowTop, 8)
    XCTAssertEqual(pad.rowHeight, 34)
    XCTAssertEqual(pad.rowBottom, 4, "the header 46 tall")
    XCTAssertEqual(pad.rowTop + pad.rowHeight + pad.rowBottom, 46)
    XCTAssertEqual(pad.chipsTop, 16)
    XCTAssertEqual(pad.chipsToList, 16)
    XCTAssertEqual(pad.searchWidth, 240)
    XCTAssertTrue(pad.newOperationFirst, "«Новая операция» before the search")
    XCTAssertTrue(pad.showsNewOperation)
    XCTAssertEqual(OperationsChip.font.points(at: .regular), 14)
    XCTAssertEqual(OperationsChip.horizontal, 16)
    XCTAssertEqual(OperationsChip.vertical, 7)
    XCTAssertEqual(OperationsMonthCapsule.horizontal(.pad), 14)
    XCTAssertEqual(OperationsSearchBox<EmptyView>.icon, 16)
    XCTAssertEqual(OperationsSearchBox<EmptyView>.horizontal, 14)
    XCTAssertEqual(OperationsSearchBox<EmptyView>.font.points(at: .regular), 14)
    XCTAssertEqual(OperationsMetrics.padCardRadius, 22)
    XCTAssertEqual(OperationsMetrics.padRowVertical, 8)
    XCTAssertEqual(OperationsMetrics.padDayTop, 8)
    XCTAssertEqual(OperationsMetrics.padDayBottom, 4)
    XCTAssertEqual(OperationColumnsHeader.categoryWidth, 137)
    XCTAssertEqual(OperationColumnsHeader.accountWidth, 121)
    XCTAssertEqual(OperationColumnsHeader.timeWidth, 57)
    XCTAssertEqual(OperationColumnsHeader.amountWidth, 97)
    XCTAssertEqual(StyleType.screenTitle.points(at: .regular), 22)
    let theme = AppThemeColors.fallback
    XCTAssertEqual(OperationDayHead.nameInk(in: theme, idiom: .pad), theme.accentContent)
    XCTAssertTrue(OperationDayCards<EmptyView>.showsColumns(width: 1_050, idiom: .pad))
    XCTAssertFalse(OperationDayCards<EmptyView>.showsColumns(width: 700, idiom: .pad))
  }

  func testTheMacsOperationsHeaderIsUnchanged() {
    let mac = OperationsHeaderMetrics.mac
    XCTAssertEqual(mac.side, 24)
    XCTAssertEqual(mac.rowTop + mac.rowHeight + mac.rowBottom, 56)
    XCTAssertEqual(mac.chipsTop, 6)
    XCTAssertEqual(mac.chipsToList, 16)
    XCTAssertEqual(mac.searchWidth, 220)
    XCTAssertFalse(mac.newOperationFirst)
  }
}
