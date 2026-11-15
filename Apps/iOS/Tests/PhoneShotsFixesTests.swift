import AppCore
import AppDatabase
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// What the owner saw on the phone's Overview: the history strip standing under the bar of the
/// sections, the tabs' names that outgrew their pill or shrank, and two groupings of thousands in
/// one card.
@MainActor
final class PhoneShotsFixesTests: XCTestCase {
  override func tearDown() {
    NumberText.style = .point
    super.tearDown()
  }

  // MARK: The history strip floats

  func testTheStripFloatsAboveTheBarAndOutOfTheHomeZone() {
    let bar: CGFloat = 80
    let inset = TouchHistoryPlacement.bottomInset(placement: .bottom, barHeight: bar, onPhone: true)
    // The measured bar includes 6 pt of its own above the pill: the strip clears the pill.
    XCTAssertGreaterThan(inset, bar - 6)
    XCTAssertEqual(inset, PhoneEntryButton.bottomPadding(placement: .bottom, barHeight: bar))
  }

  func testTheStripLeavesTheRoundPlusItsCorner() {
    XCTAssertGreaterThanOrEqual(
      TouchHistoryPlacement.trailingReserve,
      PhoneEntryButton.diameter + PhoneEntryButton.sideMargin)
    XCTAssertEqual(TouchHistoryPlacement.sideMargin, PhoneMetrics.screenMargin)
  }

  func testFloatingTheStripDoesNotChangeTheSizeOfTheScreenUnderIt() throws {
    let content = Color.clear.frame(width: 390, height: 700)
    let before = UIHostingController(rootView: content)
      .sizeThatFits(in: CGSize(width: 390, height: 900))
    let with = UIHostingController(
      rootView: content.modifier(
        FloatingTouchHistory(
          bottomInset: 90, onPhone: true,
          bar: Color.red.frame(width: 120, height: 44))))
      .sizeThatFits(in: CGSize(width: 390, height: 900))
    XCTAssertEqual(with, before)
  }

  func testTheStripKeepsToOneRowInTheRoomLeftByThePlusAtEveryPhoneWidth() throws {
    let store = try historyStore()
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for language in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = language
      for width in [CGFloat(320), 375, 402, 440] {
        let room = width - TouchHistoryPlacement.sideMargin - TouchHistoryPlacement.trailingReserve
        let host = UIHostingController(
          rootView: TouchHistoryBar(store: store).appDependencies(
            AppDependencies(
              environment: environment, store: store,
              compute: ComputeStore(calendar: .system, rebuildsInline: true))))
        let size = host.sizeThatFits(in: CGSize(width: room, height: 400))
        XCTAssertLessThanOrEqual(size.width, room, "\(language.rawValue) \(Int(width))")
        // One row: it must not grow past the room the screen keeps clear at its bottom.
        XCTAssertLessThanOrEqual(
          size.height, PhoneEntryButton.scrollClearance,
          "\(language.rawValue) at \(Int(width)) pt: \(size)")
      }
    }
  }

  private func historyStore() throws -> TransactionsStore {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let store = TransactionsStore(
      repository: TransactionRepository(writer: stack.writer),
      references: ReferenceRepository(writer: stack.writer))
    func entry() throws -> TransactionEntry {
      var draft = TransactionDraft(
        occurredAt: CalendarContext.system.noon(of: DateOnly(year: 2026, month: 11, day: 11)),
        amount: AmountE4(whole: 100), note: "Coffee")
      draft.normalizeSinglePart()
      return try draft.materialize()
    }
    XCTAssertTrue(store.save(try entry()))
    XCTAssertTrue(store.save(try entry()))
    store.undo()
    return store
  }

  // MARK: The sentence of the card «Можно отложить» is never cut

  func testTheLongSentenceOfTheCardWrapsInAHalfWidthCard() throws {
    let store = try historyStore()
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    environment.language.choice = .russian
    let tile = CanSaveTile(
      figure: environment.language("overview.canSave.impossible", table: "Planning"),
      savedLabel: "Уже отложено", saved: "5 000 ₽", shortfall: "Не хватает от 7 441 до 268 141 ₽",
      hints: ["Можно взять из отложенного на цели: 122 106 ₽"])
    func height(width: CGFloat, figure: String) -> CGFloat {
      var copy = tile
      copy.figure = figure
      return UIHostingController(
        rootView: CanSaveTileBody(tile: copy, lowData: false)
          .appDependencies(
            AppDependencies(
              environment: environment, store: store,
              compute: ComputeStore(calendar: .system, rebuildsInline: true))
          )
      ).sizeThatFits(in: CGSize(width: width, height: 2_000)).height
    }
    for width in [CGFloat(150), 170, 340] {
      let long = height(width: width, figure: tile.figure)
      let short = height(width: width, figure: "≈ 9 000 ₽")
      XCTAssertGreaterThan(long, short, "the sentence takes more rows at \(Int(width)) pt")
    }
  }

  // MARK: The names of the tabs

  func testEveryTabNameHasOneSizeAndTheOpenOneFitsItsPill() {
    let colors = NavBarColors(theme: .fallback, colorScheme: .light, contrast: .standard)
    func size(_ active: Bool, _ title: String) -> CGSize {
      UIHostingController(
        rootView: NavBarButton(
          title: title, symbol: "list.bullet", isActive: active, colors: colors,
          labelsOnAll: true, action: {}
        ).fixedSize()
      ).sizeThatFits(in: CGSize(width: 500, height: 500))
    }
    XCTAssertEqual(size(true, "Обзор").height, size(false, "Обзор").height)
    XCTAssertEqual(size(true, "Планирование").height, size(false, "Обзор").height)
    // The pill is as tall as the tab: the symbol and the name are inside it.
    XCTAssertEqual(size(true, "Обзор").height, NavBarButton.tabHeight)
    XCTAssertGreaterThanOrEqual(NavBarButton.labelPointSize, 9)
  }

  func testEveryNameFitsItsTabAtTheOneSizeAndOnlyTheLongestMayShrinkSlightly() {
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    let font = UIFont.systemFont(ofSize: NavBarButton.labelPointSize, weight: .medium)
    for language in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = language
      let titles =
        NavItem.defaultPhoneTabs.map {
          environment.language($0.phoneBarKey.key, table: $0.phoneBarKey.table)
        } + [environment.language("phone.tab.more", table: "Phone")]
      for width in [CGFloat(375), 402, 440] {
        let tab = (width - 2 * PhoneMetrics.screenMargin - 2 * PhoneTabBar.innerPadding) / 5
        let room = tab - 2 * NavBarButton.horizontalPadding(isActive: false, labelsOnAll: true)
        for title in titles {
          let needed = (title as NSString).size(withAttributes: [.font: font]).width
          XCTAssertLessThanOrEqual(
            needed * NavBarButton.labelMinimumScale, room,
            "«\(title)» \(language.rawValue) at \(Int(width)): \(needed) > \(room)")
          // The short «Планы» means no name shrinks.
          XCTAssertLessThanOrEqual(
            needed, room + 0.5, "«\(title)» \(language.rawValue) at \(Int(width)) shrinks")
        }
      }
    }
  }

  /// On the phone the Planning tab is called «Планы» / «Plans»; the full word stays on the Mac
  /// and in the sidebar of the iPad, and no other tab is renamed.
  func testThePlanningTabHasAShortNameOnThePhoneOnly() {
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    environment.language.choice = .russian
    let short = NavItem.planning.phoneBarKey
    XCTAssertEqual(environment.language(short.key, table: short.table), "Планы")
    XCTAssertEqual(
      environment.language(NavItem.planning.titleKey, table: "Common"), "Планирование")
    environment.language.choice = .english
    XCTAssertEqual(environment.language(short.key, table: short.table), "Plans")
    for item in NavItem.allCases where item != .planning {
      XCTAssertEqual(item.phoneBarKey.key, item.titleKey)
    }
  }

  // MARK: One grouping of thousands in the card «Можно отложить»

  func testEveryNumberOfTheCanSaveCardGroupsThousandsTheSameWay() {
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    var canSave = CanSave(
      CanSaveInputs(
        income: MonthIncomeEstimate(
          month: DateOnly(year: 2026, month: 11, day: 14).monthKey, received: .zero,
          expectedRemaining: .zero, median3: nil, monthsInMedian: 0, value: .zero,
          source: .receivedOnly, lowData: false),
        spentWithoutGoals: .zero, plannedStillDue: .zero,
        remainder: MonthForecast.Remainder(
          p10: .zero, middle: .zero, p90: .zero, lowData: false,
          computedFor: DateOnly(year: 2026, month: 11, day: 14), daysLeft: 10, windowDays: 90),
        alreadySaved: AmountE4(whole: 5_000)))
    canSave.low = AmountE4(whole: -268_141)
    canSave.high = AmountE4(whole: -7_441)
    canSave.p50 = AmountE4(whole: -100_000)
    canSave.fundingHints = [
      .goals(AmountE4(whole: 122_106)), .cushion(AmountE4(whole: 1_234_567)),
    ]
    for style in [NumberStyle.point, .space] {
      NumberText.style = style
      for language in [AppLanguage.Choice.russian, .english] {
        environment.language.choice = language
        let tile = CanSaveTile.make(canSave, environment)
        let lines = ([tile.shortfall].compactMap { $0 } + tile.hints + [tile.saved])
        let separators = Set(lines.flatMap(groupSeparators))
        XCTAssertEqual(
          separators.count, 1, "\(style) \(language.rawValue): \(lines) mix \(separators)")
      }
    }
  }

  /// The characters standing between a digit and exactly three digits (a group of thousands).
  private func groupSeparators(_ text: String) -> [Character] {
    let chars = Array(text)
    var found: [Character] = []
    for index in chars.indices.dropFirst() where index + 3 < chars.count + 0 {
      guard !chars[index].isNumber, chars[index - 1].isNumber else { continue }
      let tail = chars[(index + 1)...].prefix(3)
      guard tail.count == 3, tail.allSatisfy(\.isNumber) else { continue }
      found.append(chars[index] == "\u{00A0}" || chars[index] == "\u{202F}" ? " " : chars[index])
    }
    return found
  }
}
