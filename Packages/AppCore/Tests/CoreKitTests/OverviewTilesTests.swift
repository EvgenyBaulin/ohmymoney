import Foundation
import Testing

@testable import CoreKit

/// The tiles of Overview as the flat list of the builds before groups kept them: twenty-four kinds,
/// all of them can be shown at once, the twelve of 1.2 in their order first by default, and a
/// stored line from anywhere — another build, an archive of another Mac, a hand edit — that
/// always reads as a list the grid can show.
@Suite("The tiles of Overview")
struct OverviewTilesTests {
  /// Forty-three kinds, in the order of the settings: the twenty-four of the builds before, the
  /// eighteen of 2.0, then the financial health of 2.2; the raw values are what is stored, and a case is never renamed.
  @Test func fortyTwoKindsInTheOrderOfTheSettings() {
    #expect(
      OverviewTile.allCases.map(\.rawValue) == [
        "monthToDate", "topCategories", "qualities", "canSave", "spendingForecast",
        "incomeForecast", "balanceForecast", "limits", "upcoming", "expectedIncome", "owedToMe",
        "iOwe", "event", "lastCount", "lastRecord", "lastCountAndRecord", "worthALook",
        "freeMoney", "currencyChart", "spendingCalendar", "capital", "cushion", "installments",
        "selfEmployment", "currencyBalances", "spendToday", "weekOverWeek", "averageDaily",
        "monthIncome", "savingsRate", "monthRest", "weekdaySpending", "monthlySpending",
        "incomeSources", "topPlaces", "spendingByPerson", "categoryGrew", "categoryShrank",
        "smallPurchases", "backups", "integrity", "ratesStatus", "weekendPrice", "usualDay",
        "smallPurchases", "backups", "integrity", "ratesStatus", "financialHealth",
      ])
  }

  /// The instalments and the self-employment are chosen, never shown by default, and wait in
  /// «План»; a stored line reads them back.
  @Test func theInstalmentsAndTheSelfEmploymentAreChosenNotStandard() {
    #expect(!OverviewTiles.standard.contains(.installments))
    #expect(!OverviewTiles.standard.contains(.selfEmployment))
    #expect(OverviewTile.installments.defaultGroup == .plan)
    #expect(OverviewTile.selfEmployment.defaultGroup == .plan)
    #expect(
      !OverviewTile.installments.isShownUnnamed && !OverviewTile.selfEmployment.isShownUnnamed)
    // Waiting with them: every tile of 2.0 and the health of 2.2, which no kept layout names.
    #expect(
      OverviewTile.allCases.filter { !$0.isShownUnnamed }
        == [.installments, .selfEmployment] + OverviewTile.allCases.suffix(20))
        == [.installments, .selfEmployment] + OverviewTile.allCases.suffix(19))
    #expect(
      OverviewTiles.decode("installments,selfEmployment,limits")
        == [.installments, .selfEmployment, .limits])
  }

  /// The capital and the cushion are chosen, never shown by default, and read back from a stored
  /// line; a build that does not know them drops them as any unknown word.
  @Test func theCapitalAndTheCushionAreChosenNotStandard() {
    #expect(!OverviewTiles.standard.contains(.capital))
    #expect(!OverviewTiles.standard.contains(.cushion))
    #expect(OverviewTiles.decode("capital,cushion,limits") == [.capital, .cushion, .limits])
    #expect(OverviewTiles.encode([.cushion, .capital]) == "cushion,capital")
  }

  /// By default exactly the twelve cards Overview had, in their order: nothing moves for an owner
  /// who never opens the setting.
  @Test func standardIsTheTwelveCardsOfOnePointTwo() {
    #expect(
      OverviewTiles.standard == [
        .monthToDate, .topCategories, .qualities, .canSave, .spendingForecast, .limits, .upcoming,
        .expectedIncome, .owedToMe, .event, .lastCount, .worthALook,
      ])
    #expect(OverviewTiles.maximum == OverviewTile.allCases.count)
    #expect(OverviewTiles.standard.count == 12)
    #expect(OverviewTiles.isStandard(OverviewTiles.standard))
  }

  /// Every choice written reads back as itself.
  @Test func encodeDecodeRoundTrip() {
    let chosen: [OverviewTile] = [.freeMoney, .lastCountAndRecord, .iOwe, .monthToDate]
    #expect(OverviewTiles.decode(OverviewTiles.encode(chosen)) == chosen)
    #expect(OverviewTiles.encode(chosen) == "freeMoney,lastCountAndRecord,iOwe,monthToDate")
    #expect(
      OverviewTiles.decode(OverviewTiles.encode(OverviewTiles.standard))
        == OverviewTiles.standard)
  }

  /// A word no build knows is skipped, a tile named twice keeps its first place, and nothing at
  /// all — no key, an empty text, only unknown words — is the standard choice.
  @Test func unknownAndRepeatedTilesAreSkipped() {
    #expect(
      OverviewTiles.decode("iOwe, tilesOfTomorrow ,limits,iOwe,,") == [.iOwe, .limits])
    #expect(OverviewTiles.decode(nil) == OverviewTiles.standard)
    #expect(OverviewTiles.decode("") == OverviewTiles.standard)
    #expect(OverviewTiles.decode("tilesOfTomorrow") == OverviewTiles.standard)
  }

  /// There is no limit: a stored line of every tile keeps every tile.
  @Test func aLineOfEveryTileKeepsThemAll() {
    let all = OverviewTiles.encode(OverviewTile.allCases)
    #expect(OverviewTiles.decode(all) == OverviewTile.allCases)
  }

  /// A thirteenth tile is switched on like any other, at the end; a tile already shown is not
  /// added twice.
  @Test func aThirteenthTileIsAdded() {
    let full = OverviewTiles.standard
    #expect(OverviewTiles.canAdd(.freeMoney, to: full))
    #expect(OverviewTiles.adding(.freeMoney, to: full) == full + [.freeMoney])
    #expect(OverviewTiles.adding(.limits, to: full) == nil)
    #expect(!OverviewTiles.canAdd(.limits, to: OverviewTile.allCases))
  }

  /// A tile is switched off where it stands; the last one stays, so Overview is never left empty.
  @Test func theLastTileStays() {
    #expect(
      OverviewTiles.removing(.qualities, from: [.monthToDate, .qualities, .limits])
        == [.monthToDate, .limits])
    #expect(OverviewTiles.removing(.limits, from: [.limits]) == nil)
    #expect(!OverviewTiles.canRemove(.limits, from: [.limits]))
    #expect(OverviewTiles.removing(.iOwe, from: [.limits, .event]) == nil)
  }

  /// A drag moves the rows as a list moves them; indices outside the choice are passed over.
  @Test func dragMovesTheRows() {
    let tiles: [OverviewTile] = [.monthToDate, .limits, .event, .freeMoney]
    #expect(
      OverviewTiles.moving(tiles, from: IndexSet(integer: 3), to: 0)
        == [.freeMoney, .monthToDate, .limits, .event])
    #expect(
      OverviewTiles.moving(tiles, from: IndexSet(integer: 0), to: 4)
        == [.limits, .event, .freeMoney, .monthToDate])
    #expect(
      OverviewTiles.moving(tiles, from: IndexSet(integer: 1), to: 3)
        == [.monthToDate, .event, .limits, .freeMoney])
    #expect(OverviewTiles.moving(tiles, from: IndexSet(integer: 9), to: 0) == tiles)
  }

  /// What a drag of the settings list hands over: a row dropped onto its own place — before
  /// itself or before the row after it — leaves the choice as it was; a drop past the end goes
  /// last, before the start goes first; several rows keep their order.
  @Test func aDragOfTheSettingsListKeepsTheChoiceWhole() {
    let tiles: [OverviewTile] = [.monthToDate, .limits, .event, .freeMoney]
    for index in tiles.indices {
      #expect(OverviewTiles.moving(tiles, from: IndexSet(integer: index), to: index) == tiles)
      #expect(OverviewTiles.moving(tiles, from: IndexSet(integer: index), to: index + 1) == tiles)
    }
    #expect(
      OverviewTiles.moving(tiles, from: IndexSet(integer: 1), to: 99)
        == [.monthToDate, .event, .freeMoney, .limits])
    #expect(
      OverviewTiles.moving(tiles, from: IndexSet(integer: 2), to: -3)
        == [.event, .monthToDate, .limits, .freeMoney])
    #expect(
      OverviewTiles.moving(tiles, from: IndexSet([0, 2]), to: 4)
        == [.limits, .freeMoney, .monthToDate, .event])
  }

  /// A tile dropped onto another row takes that row's place: dragged down it lands after the
  /// row, dragged up before it; onto itself, or with a tile not shown, nothing moves.
  @Test func aTileDroppedOnARowTakesItsPlace() {
    let tiles: [OverviewTile] = [.monthToDate, .limits, .event, .freeMoney]
    #expect(
      OverviewTiles.dropping(.monthToDate, onto: .event, in: tiles)
        == [.limits, .event, .monthToDate, .freeMoney])
    #expect(
      OverviewTiles.dropping(.freeMoney, onto: .limits, in: tiles)
        == [.monthToDate, .freeMoney, .limits, .event])
    #expect(
      OverviewTiles.dropping(.monthToDate, onto: .freeMoney, in: tiles)
        == [.limits, .event, .freeMoney, .monthToDate])
    #expect(
      OverviewTiles.dropping(.freeMoney, onto: .monthToDate, in: tiles)
        == [.freeMoney, .monthToDate, .limits, .event])
    #expect(OverviewTiles.dropping(.limits, onto: .limits, in: tiles) == tiles)
    #expect(OverviewTiles.dropping(.iOwe, onto: .limits, in: tiles) == tiles)
    #expect(OverviewTiles.dropping(.limits, onto: .iOwe, in: tiles) == tiles)
    // Every drop keeps the tiles, and the tile ends where the target was.
    for tile in tiles {
      for target in tiles {
        let dropped = OverviewTiles.dropping(tile, onto: target, in: tiles)
        #expect(Set(dropped) == Set(tiles) && dropped.count == tiles.count)
        #expect(dropped.firstIndex(of: tile) == tiles.firstIndex(of: target))
      }
    }
  }

  /// Seeded: every drag of every choice the list can hand over gives the choice a list gives —
  /// the same tiles, each once, the moved ones together and in their order before the row they
  /// were dropped on.
  @Test func randomDragsMoveAsAListMoves() {
    var state: UInt64 = 0x7469_6C65
    func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    for _ in 0..<2_000 {
      var pool = OverviewTile.allCases
      var tiles: [OverviewTile] = []
      for _ in 0..<(1 + next(OverviewTiles.maximum)) {
        tiles.append(pool.remove(at: next(pool.count)))
      }
      var source = IndexSet()
      for _ in 0..<(1 + next(3)) { source.insert(next(tiles.count)) }
      let destination = next(tiles.count + 1)
      // A list's move: the rows leave, and go in before the row that was at `destination`.
      let taken = source.map { tiles[$0] }
      var rest = tiles.enumerated().filter { !source.contains($0.offset) }.map(\.element)
      let before = source.filter { $0 < destination }.count
      rest.insert(contentsOf: taken, at: destination - before)
      let moved = OverviewTiles.moving(tiles, from: source, to: destination)
      #expect(moved == rest, "\(tiles) \(Array(source)) → \(destination)")
      #expect(Set(moved) == Set(tiles) && moved.count == tiles.count)
    }
  }
}
