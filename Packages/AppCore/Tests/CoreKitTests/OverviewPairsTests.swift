import Foundation
import Testing

@testable import CoreKit

/// The size of a tile and the pairs: a compact tile dropped on another compact one makes a pair
/// in one cell, «Разъединить» takes it apart, and the layout keeps all of it in `overview.layout`
/// in a way a build that does not know it reads as before.
@Suite("Compact tiles and pairs")
struct OverviewPairsTests {
  private let base = OverviewLayout.firstRun

  private func shownAll() -> OverviewLayout {
    // Every tile shown, so the pairs are seen without any facts.
    OverviewLayout.standard
  }

  @Test func onlyATileThatCanBeCompactBecomesOne() throws {
    let layout = shownAll()
    let compact = try #require(layout.setting(.owedToMe, compact: true))
    #expect(compact.isCompact(.owedToMe))
    #expect(layout.setting(.topCategories, compact: true) == nil)
    #expect(layout.setting(.weekdaySpending, compact: true) == nil)
  }

  @Test func aCompactTileDroppedOnAnotherMakesAPairNextToIt() throws {
    var layout = shownAll()
    layout = try #require(layout.setting(.owedToMe, compact: true))
    layout = try #require(layout.setting(.iOwe, compact: true))
    layout = layout.dropping(.iOwe, onto: .owedToMe)
    #expect(layout.partner(of: .owedToMe) == .iOwe)
    #expect(layout.partner(of: .iOwe) == .owedToMe)
    let tiles = layout.tiles(in: .money)
    let first = try #require(tiles.firstIndex(of: .owedToMe))
    #expect(tiles[first + 1] == .iOwe)
  }

  @Test func aPairIsOneCellOfTheGrid() throws {
    var layout = shownAll()
    layout = try #require(layout.pairing(.iOwe, with: .owedToMe))
    let cells = layout.cells(in: .money, facts: .none)
    #expect(cells.contains(.pair(.owedToMe, .iOwe)))
    #expect(cells.flatMap(\.tiles).count == layout.visibleTiles(in: .money, facts: .none).count)
    // Both are compact because they are a pair.
    #expect(layout.isCompact(.owedToMe))
    #expect(layout.isCompact(.iOwe))
  }

  @Test func aTileThatCannotBeCompactCannotBePaired() {
    let layout = shownAll()
    #expect(layout.pairing(.topCategories, with: .qualities) == nil)
    #expect(layout.pairing(.owedToMe, with: .spendingCalendar) == nil)
    #expect(layout.pairing(.owedToMe, with: .owedToMe) == nil)
  }

  @Test func unpairingReturnsBothToRegular() throws {
    var layout = shownAll()
    layout = try #require(layout.pairing(.iOwe, with: .owedToMe))
    layout = layout.unpairing(.owedToMe)
    #expect(layout.partner(of: .owedToMe) == nil)
    #expect(layout.partner(of: .iOwe) == nil)
    #expect(!layout.isCompact(.owedToMe))
    #expect(!layout.isCompact(.iOwe))
    // Taken apart from either side.
    var again = shownAll()
    again = try #require(again.pairing(.iOwe, with: .owedToMe))
    again = again.unpairing(.iOwe)
    #expect(!again.isCompact(.owedToMe))
  }

  @Test func makingATileRegularPartsItsPair() throws {
    var layout = shownAll()
    layout = try #require(layout.pairing(.iOwe, with: .owedToMe))
    layout = try #require(layout.setting(.iOwe, compact: false))
    #expect(layout.partner(of: .owedToMe) == nil)
    #expect(!layout.isCompact(.owedToMe))
  }

  @Test func aTileTakenFromItsPairLeavesThePairApart() throws {
    var layout = shownAll()
    layout = try #require(layout.pairing(.iOwe, with: .owedToMe))
    // Dragged onto a regular tile elsewhere: no longer beside its partner.
    layout = layout.dropping(.iOwe, onto: .capital)
    #expect(layout.partner(of: .owedToMe) == nil)
    #expect(layout.partner(of: .iOwe) == nil)
  }

  @Test func aTileInAPairCanBePairedAgainAndLeavesTheOldPartnerCompact() throws {
    var layout = shownAll()
    layout = try #require(layout.pairing(.iOwe, with: .owedToMe))
    layout = try #require(layout.setting(.lastCount, compact: true))
    layout = try #require(layout.pairing(.lastCount, with: .iOwe))
    #expect(layout.partner(of: .iOwe) == .lastCount)
    #expect(layout.partner(of: .owedToMe) == nil)
    #expect(layout.isCompact(.owedToMe))
  }

  @Test func aPairWithAHiddenMemberLeavesTheOtherAlone() throws {
    var layout = shownAll()
    layout = try #require(layout.pairing(.iOwe, with: .owedToMe))
    layout = try #require(layout.hiding(.iOwe))
    let cells = layout.cells(in: .money, facts: .none)
    #expect(cells.contains(.single(.owedToMe)))
    #expect(!cells.flatMap(\.tiles).contains(.iOwe))
    // Shown again, the pair is back.
    layout = try #require(layout.showing(.iOwe))
    #expect(layout.cells(in: .money, facts: .none).contains(.pair(.owedToMe, .iOwe)))
  }

  @Test func theSuggestedPairsCanBeMadeFromTheCatalog() throws {
    var layout = shownAll()
    for suggestion in OverviewCatalog.suggestedPairs {
      guard let (a, b) = suggestion.tiles else { continue }
      layout = try #require(layout.pairing(a, with: b), "\(suggestion.id)")
      #expect(layout.partner(of: a) == b)
    }
  }

  // MARK: - Kept in the setting

  @Test func sizesPairsAndWaitingTilesRoundTripThroughTheText() throws {
    var layout = OverviewLayout.firstRun
    layout = try #require(layout.pairing(.backups, with: .integrity))
    layout = try #require(layout.showing(.backups))
    layout = try #require(layout.showing(.integrity))
    layout = try #require(layout.setting(.spendToday, compact: true))
    let text = layout.encode()
    #expect(text.contains("pairs:"))
    #expect(text.contains("compact:"))
    #expect(text.contains("auto:"))
    let read = try #require(OverviewLayout.decode(text))
    #expect(read == layout)
    #expect(read.partner(of: .backups) == .integrity)
    #expect(read.isCompact(.spendToday))
    #expect(read.showsItself(.owedToMe))
  }

  @Test func aBuildThatKnowsNoPairsReadsTheGroupsAsBefore() throws {
    var layout = shownAll()
    layout = try #require(layout.pairing(.iOwe, with: .owedToMe))
    layout = try #require(layout.setting(.lastCount, compact: true))
    let text = layout.encode()
    // What an older build sees: the parts it does not know are skipped, the groups stay. The
    // tile lists name every tile plainly, with no mark inside a tile's name.
    let groups = text.split(separator: ";").filter {
      OverviewTileGroup(rawValue: String($0.split(separator: ":")[0])) != nil
    }
    for part in groups {
      #expect(!part.contains("+"))
      #expect(!part.contains("?"))
    }
    let old = groups.joined(separator: ";")
    let older = try #require(OverviewLayout.decode(old))
    #expect(older.shown == layout.shown)
    #expect(older.groups == layout.groups)
    for group in layout.groups {
      #expect(older.tiles(in: group) == layout.tiles(in: group))
    }
  }

  @Test func aSelfShowingTileIsHiddenForABuildThatDoesNotKnowIt() throws {
    let text = OverviewLayout.firstRun.encode()
    let groups = text.split(separator: ";").filter {
      OverviewTileGroup(rawValue: String($0.split(separator: ":")[0])) != nil
    }
    let older = try #require(OverviewLayout.decode(groups.joined(separator: ";")))
    #expect(older.isHidden(.owedToMe))
    #expect(older.shown == OverviewLayout.firstRun.shown)
  }

  @Test func damagedPartsAreMadeWhole() throws {
    let text =
      "money:monthToDate,owedToMe,iOwe;pairs:owedToMe+iOwe,owedToMe+topCategories,nonsense+iOwe,"
      + "monthToDate+owedToMe;compact:topCategories,unknown,lastCount;auto:capital,iOwe"
    let layout = try #require(OverviewLayout.decode(text))
    // The first pair holds; the rest name a tile twice, a tile that cannot be compact or none.
    #expect(layout.partner(of: .owedToMe) == .iOwe)
    #expect(layout.partner(of: .monthToDate) == nil)
    #expect(!layout.isCompact(.topCategories))
    #expect(layout.isCompact(.lastCount))
    // A tile that is shown does not wait; one that does not show itself never does.
    #expect(!layout.showsItself(.iOwe))
    #expect(!layout.showsItself(.capital))
  }

  @Test func aPairWhoseMembersAreNotNeighboursIsDropped() throws {
    let text = "money:owedToMe,monthToDate,iOwe;pairs:owedToMe+iOwe"
    let layout = try #require(OverviewLayout.decode(text))
    #expect(layout.partner(of: .owedToMe) == nil)
  }

  @Test func showingOnlyKeepsTheSizesAndTheWaitingTiles() throws {
    var layout = OverviewLayout.firstRun
    layout = try #require(layout.setting(.spendToday, compact: true))
    let chosen = layout.showingOnly(layout.shown + [.spendToday])
    #expect(chosen.isCompact(.spendToday))
    #expect(chosen.showsItself(.owedToMe))
  }
}
