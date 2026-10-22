import Foundation
import Testing

@testable import CoreKit

/// The layout of Overview: three fixed groups in the owner's order, every tile in one of them,
/// hidden tiles keeping their place, never all of them hidden — and a kept text from anywhere
/// that always reads as a layout the screen can show.
@Suite("The layout of Overview")
struct OverviewLayoutTests {
  private let all = Set(OverviewTile.allCases)

  /// Every tile is placed exactly once, and at least one is shown.
  private func isWhole(_ layout: OverviewLayout) -> Bool {
    let placed = layout.sections.flatMap(\.tiles)
    return placed.count == OverviewTile.allCases.count && Set(placed) == all
      && Set(layout.groups) == Set(OverviewTileGroup.allCases) && layout.groups.count == 3
      && !layout.shown.isEmpty && layout.hidden.isSubset(of: all)
  }

  /// The groups and their raw values, which the text keeps: never renamed.
  @Test func threeGroupsWithStableNames() {
    #expect(OverviewTileGroup.allCases.map(\.rawValue) == ["money", "plan", "analysis"])
  }

  /// The default group of every tile.
  @Test func everyTileHasADefaultGroup() {
    let money = OverviewTile.allCases.filter { $0.defaultGroup == .money }
    let plan = OverviewTile.allCases.filter { $0.defaultGroup == .plan }
    let analysis = OverviewTile.allCases.filter { $0.defaultGroup == .analysis }
    #expect(
      money == [
        .monthToDate, .canSave, .balanceForecast, .owedToMe, .iOwe, .lastCount, .lastRecord,
        .lastCountAndRecord, .freeMoney, .capital, .cushion,
        // The tiles of 2.0 follow the older ones.
        .currencyBalances, .spendToday, .weekOverWeek, .averageDaily, .monthIncome,
        .savingsRate,
      ])
    #expect(
      plan == [
        .limits, .upcoming, .expectedIncome, .event, .spendingCalendar, .installments,
        .selfEmployment, .monthRest,
      ])
    #expect(
      analysis == [
        .topCategories, .qualities, .spendingForecast, .incomeForecast, .worthALook, .currencyChart,
        .weekdaySpending, .monthlySpending, .incomeSources, .topPlaces, .spendingByPerson,
        .categoryGrew, .categoryShrank, .smallPurchases, .backups, .integrity, .ratesStatus,
        .weekendPrice, .usualDay,
        .financialHealth,
      ])
  }

  /// No choice kept: the twelve cards of the first Overview first, then the rest, each in its
  /// default group, every one of the twenty-two shown; the ones that came later — the credits,
  /// the self-employment and the tiles of 2.0 — wait hidden at the end of their groups until the
  /// owner adds them.
  @Test func theStandardLayoutShowsEveryTile() {
    let layout = OverviewLayout.standard
    #expect(isWhole(layout))
    #expect(layout.hidden == Set(OverviewTile.allCases.filter { !$0.isShownUnnamed }))
    #expect(layout.shown.count == 22)
    #expect(layout.groups == [.money, .plan, .analysis])
    #expect(
      layout.tiles(in: .money) == [
        .monthToDate, .canSave, .owedToMe, .lastCount, .balanceForecast, .iOwe, .lastRecord,
        .lastCountAndRecord, .freeMoney, .capital, .cushion, .currencyBalances, .spendToday,
        .weekOverWeek, .averageDaily, .monthIncome, .savingsRate,
      ])
    #expect(
      layout.tiles(in: .plan) == [
        .limits, .upcoming, .expectedIncome, .event, .spendingCalendar, .installments,
        .selfEmployment, .monthRest,
      ])
    #expect(
      layout.tiles(in: .analysis) == [
        .topCategories, .qualities, .spendingForecast, .worthALook, .incomeForecast, .currencyChart,
        .weekdaySpending, .monthlySpending, .incomeSources, .topPlaces, .spendingByPerson,
        .categoryGrew, .categoryShrank, .smallPurchases, .backups, .integrity, .ratesStatus,
        .weekendPrice, .usualDay,
        .financialHealth,
      ])
    #expect(layout.isStandard)
  }

  /// The flat list of the builds before groups: its tiles keep their order, the ones it lacks
  /// follow in the order of the catalog, all shown but the ones that wait to be added.
  @Test func aFlatListKeepsItsOrderAndGetsTheRestAtTheEnd() {
    let layout = OverviewLayout(tiles: [.freeMoney, .limits, .monthToDate, .qualities])
    #expect(isWhole(layout))
    #expect(layout.hidden == Set(OverviewTile.allCases.filter { !$0.isShownUnnamed }))
    #expect(Array(layout.tiles(in: .money).prefix(2)) == [.freeMoney, .monthToDate])
    #expect(layout.tiles(in: .money).count == 17)
    #expect(layout.tiles(in: .plan).first == .limits)
    #expect(layout.tiles(in: .analysis).first == .qualities)
    #expect(
      Array(layout.tiles(in: .analysis).dropFirst()) == [
        .topCategories, .spendingForecast, .incomeForecast, .worthALook, .currencyChart,
        .weekdaySpending, .monthlySpending, .incomeSources, .topPlaces, .spendingByPerson,
        .categoryGrew, .categoryShrank, .smallPurchases, .backups, .integrity, .ratesStatus,
        .weekendPrice, .usualDay,
        .financialHealth,
      ])
    #expect(
      OverviewLayout(tiles: [])
        == OverviewLayout(tiles: OverviewTile.allCases.filter(\.isShownUnnamed)))
    // A list that names one of them shows it.
    #expect(!OverviewLayout(tiles: [.installments]).isHidden(.installments))
    #expect(OverviewLayout(tiles: [.installments]).isHidden(.selfEmployment))
  }

  /// A tile that came after a layout was kept waits hidden at the end of its group: the two of
  /// the credits and the self-employment, which nothing names yet, appear only when added.
  @Test func aTileTheTextDoesNotNameWaitsHiddenWhenItWaitsToBeAdded() throws {
    let layout = try #require(OverviewLayout.decode("money:monthToDate;plan:limits"))
    #expect(isWhole(layout))
    #expect(layout.isHidden(.installments) && layout.isHidden(.selfEmployment))
    #expect(layout.isHidden(.monthRest), "a tile of 2.0 the text does not name waits too")
    #expect(
      Array(layout.tiles(in: .plan).suffix(3)) == [.installments, .selfEmployment, .monthRest])
    #expect(!layout.isHidden(.capital), "an older tile not named is still shown")
    let added = try #require(layout.showing(.selfEmployment))
    #expect(OverviewLayout.decode(added.encode()) == added)
    #expect(!(try #require(OverviewLayout.decode(added.encode()))).isHidden(.selfEmployment))
  }

  /// The text: groups in order, tiles in order, «-» before a hidden tile; it reads back as itself.
  @Test func theTextRoundTrips() throws {
    var layout = OverviewLayout.standard
    layout = try #require(layout.hiding(.lastRecord))
    layout = try #require(layout.movingGroup(.analysis, by: -1))
    layout = layout.moving(.currencyChart, to: .money, at: 0)
    let text = layout.encode()
    #expect(text.hasPrefix("money:currencyChart,monthToDate,"))
    #expect(text.contains(",-lastRecord,"))
    #expect(text.contains(";analysis:topCategories,"))
    #expect(
      text.hasSuffix(
        ";plan:limits,upcoming,expectedIncome,event,spendingCalendar,-installments,-selfEmployment,"
          + "-monthRest"
      ))
    #expect(OverviewLayout.decode(text) == layout)
    #expect(OverviewLayout.decode(OverviewLayout.standard.encode()) == .standard)
  }

  /// No text, an empty one, one naming no group: no layout — the flat list is read instead.
  @Test func aTextWithoutGroupsIsNoLayout() {
    #expect(OverviewLayout.decode(nil) == nil)
    #expect(OverviewLayout.decode("") == nil)
    #expect(OverviewLayout.decode("monthToDate,limits") == nil)
    #expect(OverviewLayout.decode("tomorrow:limits;;") == nil)
  }

  /// Unknown groups and tiles go, the second mention of a group or a tile is passed over, groups
  /// not named follow, tiles not named are shown at the end of their default group.
  @Test func aTextFromAnywhereReadsAsAWholeLayout() throws {
    let layout = try #require(
      OverviewLayout.decode(
        " plan : -limits, tilesOfTomorrow ,monthToDate,limits;tomorrow:iOwe;plan:event;"
          + "analysis:-qualities,event"))
    #expect(isWhole(layout))
    #expect(layout.groups == [.plan, .analysis, .money])
    #expect(Array(layout.tiles(in: .plan).prefix(2)) == [.limits, .monthToDate])
    #expect(layout.isHidden(.limits))
    #expect(layout.isHidden(.qualities))
    #expect(layout.tiles(in: .analysis).first == .qualities)
    #expect(layout.group(of: .event) == .analysis, "the first mention of a tile wins")
    #expect(layout.group(of: .iOwe) == .money, "a tile of an unknown group goes to its own")
    #expect(!layout.isHidden(.iOwe))
    #expect(layout.tiles(in: .money).last == .savingsRate)
    #expect(!layout.tiles(in: .money).contains(.monthToDate))
  }

  /// A repeated mention of a tile is passed over whole: its mark of hidden does not hide the tile
  /// the first mention showed, in the same group or in another; nor does a shown repeat show a
  /// tile the first mention hid.
  @Test func aRepeatedTileKeepsTheVisibilityOfItsFirstMention() throws {
    let same = try #require(OverviewLayout.decode("money:monthToDate,-monthToDate;plan:limits"))
    #expect(!same.isHidden(.monthToDate), "the second mention hid the tile")
    #expect(same.group(of: .monthToDate) == .money)

    let across = try #require(OverviewLayout.decode("money:monthToDate;plan:-monthToDate,limits"))
    #expect(!across.isHidden(.monthToDate), "a mention in another group hid the tile")
    #expect(across.group(of: .monthToDate) == .money)

    let hiddenFirst = try #require(OverviewLayout.decode("money:-limits,monthToDate;plan:limits"))
    #expect(hiddenFirst.isHidden(.limits), "the second mention showed the tile")
    #expect(hiddenFirst.group(of: .limits) == .money)
    #expect(OverviewLayout.decode(same.encode()) == same)
  }

  /// A text that hides every tile shows the first one.
  @Test func aTextHidingEverythingShowsTheFirstTile() throws {
    let text = OverviewTileGroup.allCases.map { group in
      group.rawValue + ":"
        + OverviewTile.allCases.filter { $0.defaultGroup == group }.map { "-" + $0.rawValue }
        .joined(separator: ",")
    }.joined(separator: ";")
    let layout = try #require(OverviewLayout.decode(text))
    #expect(layout.shown == [.monthToDate])
    #expect(layout.hidden.count == OverviewTile.allCases.count - 1)
  }

  /// A hidden tile keeps its place and comes back there; the last shown tile cannot be hidden.
  @Test func hidingAndShowing() throws {
    var layout = OverviewLayout.standard
    layout = try #require(layout.hiding(.canSave))
    #expect(!layout.shown.contains(.canSave))
    #expect(layout.tiles(in: .money)[1] == .canSave)
    #expect(layout.hiddenInOrder.first == .canSave)
    #expect(
      Set(layout.hiddenInOrder)
        == Set([.canSave] + OverviewTile.allCases.filter { !$0.isShownUnnamed }))
    #expect(layout.hiding(.canSave) == nil, "hidden already")
    #expect(layout.showing(.limits) == nil, "shown already")
    layout = try #require(layout.showing(.canSave))
    #expect(layout == .standard)

    var one = OverviewLayout.standard.showingOnly([.event])
    #expect(one.shown == [.event])
    #expect(!one.canHide(.event))
    #expect(one.hiding(.event) == nil)
    one = try #require(one.showing(.capital))
    #expect(one.canHide(.event))
  }

  /// A flat list asked of the layout: exactly those tiles shown, each in its group, the listed
  /// ones first in the order of the list; nothing listed changes nothing.
  @Test func showingOnlyAFlatList() {
    let layout = OverviewLayout.standard.showingOnly([.spendingCalendar, .limits, .monthToDate])
    #expect(isWhole(layout))
    #expect(layout.shown == [.monthToDate, .spendingCalendar, .limits])
    #expect(layout.tiles(in: .plan).prefix(2) == [.spendingCalendar, .limits])
    #expect(OverviewLayout.standard.showingOnly([]) == .standard)
  }

  /// A tile moves into another group at a place or at its end; within its group to a place.
  @Test func movingATileBetweenGroups() {
    let layout = OverviewLayout.standard
    let moved = layout.moving(.limits, to: .money, at: 1)
    #expect(isWhole(moved))
    #expect(moved.tiles(in: .money).prefix(3) == [.monthToDate, .limits, .canSave])
    #expect(!moved.tiles(in: .plan).contains(.limits))
    let atEnd = layout.moving(.limits, to: .analysis)
    #expect(atEnd.tiles(in: .analysis).last == .limits)
    let inPlace = layout.moving(.monthToDate, to: .money, at: 3)
    #expect(inPlace.tiles(in: .money).prefix(4) == [.canSave, .owedToMe, .monthToDate, .lastCount])
    #expect(layout.moving(.monthToDate, to: .money, at: 0) == layout)
    #expect(layout.moving(.monthToDate, to: .money, at: 1) == layout)
  }

  /// A hidden tile moved stays hidden.
  @Test func aHiddenTileMovedStaysHidden() throws {
    let layout = try #require(OverviewLayout.standard.hiding(.limits))
    let moved = layout.moving(.limits, to: .money, at: 0)
    #expect(moved.isHidden(.limits))
    #expect(moved.group(of: .limits) == .money)
  }

  /// A tile dropped onto another takes its place: in one group down lands after, up before; from
  /// another group before it; onto itself nothing.
  @Test func droppingATileOntoAnother() {
    let layout = OverviewLayout.standard
    let down = layout.dropping(.monthToDate, onto: .owedToMe)
    #expect(down.tiles(in: .money).prefix(3) == [.canSave, .owedToMe, .monthToDate])
    let up = layout.dropping(.owedToMe, onto: .monthToDate)
    #expect(up.tiles(in: .money).prefix(3) == [.owedToMe, .monthToDate, .canSave])
    let across = layout.dropping(.limits, onto: .canSave)
    #expect(across.tiles(in: .money).prefix(3) == [.monthToDate, .limits, .canSave])
    #expect(layout.dropping(.limits, onto: .limits) == layout)
    for tile in OverviewTile.allCases {
      for target in OverviewTile.allCases {
        let dropped = layout.dropping(tile, onto: target)
        #expect(isWhole(dropped))
        if tile != target {
          #expect(dropped.group(of: tile) == layout.group(of: target))
          #expect(
            dropped.tiles(in: dropped.group(of: tile)).firstIndex(of: tile)
              == layout.tiles(in: layout.group(of: target)).firstIndex(of: target))
        }
      }
    }
  }

  /// «Выше» and «Ниже» trade places with the neighbour in the group; on Overview the hidden ones
  /// are skipped; nothing past the edge of the group.
  @Test func oneStepUpAndDown() throws {
    let layout = OverviewLayout.standard
    let down = try #require(layout.moving(.monthToDate, by: 1, amongShown: false))
    #expect(down.tiles(in: .money).prefix(2) == [.canSave, .monthToDate])
    let up = try #require(down.moving(.monthToDate, by: -1, amongShown: false))
    #expect(up == layout)
    #expect(layout.moving(.monthToDate, by: -1, amongShown: true) == nil)
    #expect(layout.moving(.cushion, by: 1, amongShown: true) == nil)

    let hidden = try #require(layout.hiding(.canSave))
    let skipping = try #require(hidden.moving(.monthToDate, by: 1, amongShown: true))
    #expect(skipping.tiles(in: .money).prefix(3) == [.canSave, .owedToMe, .monthToDate])
    #expect(hidden.neighbour(of: .monthToDate, by: 1, amongShown: false) == .canSave)
  }

  /// The groups reorder by a step or by a drop; the tiles go with them.
  @Test func reorderingGroups() throws {
    let layout = OverviewLayout.standard
    let up = try #require(layout.movingGroup(.analysis, by: -1))
    #expect(up.groups == [.money, .analysis, .plan])
    #expect(up.tiles(in: .analysis) == layout.tiles(in: .analysis))
    #expect(layout.movingGroup(.money, by: -1) == nil)
    #expect(layout.movingGroup(.analysis, by: 1) == nil)
    #expect(layout.droppingGroup(.analysis, onto: .money).groups == [.analysis, .money, .plan])
    #expect(layout.droppingGroup(.money, onto: .analysis).groups == [.plan, .analysis, .money])
    #expect(layout.droppingGroup(.plan, onto: .plan) == layout)
  }

  /// Collapsed groups as this Mac keeps them.
  @Test func collapsedGroups() {
    #expect(OverviewLayout.encodeCollapsed([.analysis, .money]) == "money,analysis")
    #expect(OverviewLayout.decodeCollapsed("analysis, tomorrow,money") == [.analysis, .money])
    #expect(OverviewLayout.decodeCollapsed(nil).isEmpty)
    #expect(OverviewLayout.decodeCollapsed("").isEmpty)
  }

  /// Seeded: any chain of edits keeps the layout whole, and its text reads back as itself.
  @Test func randomEditsKeepTheLayoutWhole() {
    var state: UInt64 = 0x6C61_796F
    func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    let tiles = OverviewTile.allCases
    let groups = OverviewTileGroup.allCases
    var layout = OverviewLayout.standard
    for _ in 0..<3_000 {
      let tile = tiles[next(tiles.count)]
      switch next(7) {
      case 0: layout = layout.hiding(tile) ?? layout
      case 1: layout = layout.showing(tile) ?? layout
      case 2: layout = layout.moving(tile, to: groups[next(3)], at: next(25) - 2)
      case 3: layout = layout.dropping(tile, onto: tiles[next(tiles.count)])
      case 4:
        layout =
          layout.moving(tile, by: next(2) == 0 ? -1 : 1, amongShown: next(2) == 0) ?? layout
      case 5: layout = layout.droppingGroup(groups[next(3)], onto: groups[next(3)])
      default: layout = layout.movingGroup(groups[next(3)], by: next(2) == 0 ? -1 : 1) ?? layout
      }
      #expect(isWhole(layout))
      #expect(OverviewLayout.decode(layout.encode()) == layout)
    }
  }
}
