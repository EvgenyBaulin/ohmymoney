import Foundation
import Testing

@testable import CoreKit

/// The catalog of the tiles of 2.0 and the rules around it: what is built, what is only listed,
/// the ten of a new person, the tiles that show themselves, and that an owner's choice never
/// changes because a build brought new tiles.
@Suite("The catalog of the tiles of Overview")
struct OverviewCatalogTests {
  @Test func theCatalogHoldsTheFortyEightChosenAndTheSixKept() {
    let numbers = OverviewCatalog.items.map(\.number)
    #expect(Set(numbers).count == numbers.count)
    #expect(OverviewCatalog.chosenNumbers.count == 48)
    #expect(OverviewCatalog.chosenNumbers.isSubset(of: Set(numbers)))
    let kept = Set(numbers).subtracting(OverviewCatalog.chosenNumbers)
    #expect(kept.subtracting(OverviewCatalog.laterNumbers) == [10, 11, 15, 17, 18, 24])
    #expect(OverviewCatalog.laterNumbers == [101, 102, 103, 128])
    #expect(numbers.count == 58)
    #expect(kept == [10, 11, 15, 17, 18, 24, 101, 102, 103, 128])
  }

  @Test func everyTileOfTheEnumIsInTheCatalogOnce() {
    for tile in OverviewTile.allCases {
      #expect(OverviewCatalog.items.filter { $0.tile == tile }.count == 1, "\(tile)")
    }
    #expect(OverviewCatalog.built.count == OverviewTile.allCases.count)
  }

  @Test func theFirstTwentyFourKeepTheirNumbers() {
    let expected: [Int: OverviewTile] = [
      1: .monthToDate, 2: .canSave, 3: .balanceForecast, 4: .owedToMe, 5: .iOwe,
      6: .lastCount, 7: .lastRecord, 8: .lastCountAndRecord, 9: .freeMoney, 10: .capital,
      11: .cushion, 12: .limits, 13: .upcoming, 14: .expectedIncome, 15: .event,
      16: .spendingCalendar, 17: .installments, 18: .selfEmployment, 19: .topCategories,
      20: .qualities, 21: .spendingForecast, 22: .incomeForecast, 23: .worthALook,
      24: .currencyChart,
    ]
    for (number, tile) in expected {
      #expect(OverviewCatalog.item(number: number)?.tile == tile)
    }
  }

  @Test func theTilesNotBuiltAreListedWithoutATile() {
    let stubs = OverviewCatalog.unbuilt.map(\.number)
    #expect(stubs == [38, 39, 40, 48, 51, 52, 55, 58, 62, 67, 68, 71])
    for item in OverviewCatalog.unbuilt {
      #expect(item.tile == nil)
      #expect(!item.isAvailable)
      #expect(item.nameKey == "overview.tile.stub.\(item.number)")
    }
  }

  @Test func aChartOrAListIsNeverCompact() {
    for item in OverviewCatalog.items where item.isWide {
      #expect(!item.canBeCompact, "\(item.number)")
    }
    for tile in [OverviewTile.weekdaySpending, .monthlySpending, .incomeSources, .topPlaces] {
      #expect(OverviewCatalog.isWide(tile))
      #expect(!OverviewCatalog.canBeCompact(tile))
    }
  }

  @Test func theSevenSuggestedPairsAreCompactAndInOneGroup() {
    #expect(OverviewCatalog.suggestedPairs.count == 7)
    for pair in OverviewCatalog.suggestedPairs {
      let a = OverviewCatalog.item(number: pair.first)
      let b = OverviewCatalog.item(number: pair.second)
      #expect(a?.canBeCompact == true, "\(pair.id)")
      #expect(b?.canBeCompact == true, "\(pair.id)")
      #expect(a?.group == b?.group, "\(pair.id)")
    }
    // Two of them wait for tiles that are not built.
    let waiting = OverviewCatalog.suggestedPairs.filter { $0.tiles == nil }.map(\.id)
    #expect(waiting == ["38+40", "13+51"])
  }

  @Test func aSuggestedPartnerIsFoundFromEitherSide() {
    #expect(OverviewCatalog.suggestedPartner(of: .owedToMe) == .iOwe)
    #expect(OverviewCatalog.suggestedPartner(of: .iOwe) == .owedToMe)
    #expect(OverviewCatalog.suggestedPartner(of: .backups) == .integrity)
    #expect(OverviewCatalog.suggestedPartner(of: .topCategories) == nil)
  }

  // MARK: - A new person

  @Test func aNewPersonSeesTheTenTilesOfTheAnswerInTheirOrder() {
    let layout = OverviewLayout.firstRun
    #expect(
      layout.shown
        == [
          .monthToDate, .freeMoney, .canSave, .balanceForecast, .upcoming, .limits, .monthRest,
          .topCategories, .qualities, .worthALook,
        ])
    #expect(layout.shown.count == 10)
    #expect(layout.groups == [.money, .plan, .analysis])
  }

  @Test func theTilesThatShowThemselvesWaitHiddenForTheirData() {
    let layout = OverviewLayout.firstRun
    let waiting: Set<OverviewTile> = [
      .owedToMe, .iOwe, .expectedIncome, .currencyBalances, .smallPurchases, .ratesStatus,
    ]
    for tile in waiting {
      #expect(layout.isHidden(tile))
      #expect(layout.showsItself(tile))
    }
    // Nothing else waits.
    for tile in OverviewTile.allCases where !waiting.contains(tile) {
      #expect(!layout.showsItself(tile), "\(tile)")
    }
  }

  @Test func aSelfShowingTileAppearsWhenItsFunctionHasData() {
    let layout = OverviewLayout.firstRun
    let none = OverviewFacts.none
    #expect(!layout.isVisible(.owedToMe, facts: none))
    #expect(layout.isVisible(.owedToMe, facts: OverviewFacts([.owedToMe])))
    #expect(!layout.isVisible(.iOwe, facts: OverviewFacts([.owedToMe])))
    #expect(layout.isVisible(.iOwe, facts: OverviewFacts([.iOwe])))
    #expect(layout.isVisible(.expectedIncome, facts: OverviewFacts([.expectedIncome])))
    // Two tiles hang on more than one currency, one on the limit of a small purchase.
    let currencies = OverviewFacts([.multiCurrency])
    #expect(layout.isVisible(.currencyBalances, facts: currencies))
    #expect(layout.isVisible(.ratesStatus, facts: currencies))
    #expect(!layout.isVisible(.smallPurchases, facts: currencies))
    #expect(layout.isVisible(.smallPurchases, facts: OverviewFacts([.smallLimit])))
    // The ten are visible whatever the facts say.
    for tile in layout.shown { #expect(layout.isVisible(tile, facts: none)) }
  }

  @Test func aTileThatDoesNotShowItselfNeedsTheOwner() {
    let layout = OverviewLayout.firstRun
    let everything = OverviewFacts(Set(OverviewFeature.allCases))
    #expect(layout.isHidden(.weekdaySpending))
    #expect(!layout.isVisible(.weekdaySpending, facts: everything))
    #expect(!layout.isVisible(.spendToday, facts: everything))
    // Nor does a tile of a build before: hidden stays hidden.
    #expect(!layout.isVisible(.capital, facts: everything))
  }

  @Test func addingASelfShowingTileMakesItAlwaysShownAndHidingItKeepsItAway() throws {
    var layout = OverviewLayout.firstRun
    layout = try #require(layout.showing(.owedToMe))
    #expect(!layout.showsItself(.owedToMe))
    #expect(layout.isVisible(.owedToMe, facts: .none))

    let hidden = try #require(OverviewLayout.firstRun.hiding(.iOwe))
    #expect(hidden.isHidden(.iOwe))
    #expect(!hidden.showsItself(.iOwe))
    #expect(!hidden.isVisible(.iOwe, facts: OverviewFacts([.iOwe])))
  }

  @Test func theAddMenuOffersWhatTheScreenDoesNotShow() {
    let layout = OverviewLayout.firstRun
    let offered = layout.addable(facts: OverviewFacts([.owedToMe]))
    #expect(!offered.contains(.owedToMe))
    #expect(offered.contains(.iOwe))
    #expect(!offered.contains(.monthToDate))
    #expect(offered.count == OverviewTile.allCases.count - 10 - 1)
  }

  // MARK: - An owner's choice

  /// What a build before 2.0 wrote for an owner who chose: every tile of that build named.
  private let storedBefore =
    "money:monthToDate,-canSave,balanceForecast,owedToMe;plan:limits,upcoming;"
    + "analysis:topCategories,qualities"

  @Test func aLayoutKeptBeforeShowsTheSameTilesNowAndHidesTheNewOnes() throws {
    let layout = try #require(OverviewLayout.decode(storedBefore))
    // The tiles the text names come first in their groups, as written, canSave hidden.
    #expect(Array(layout.shown.prefix(3)) == [.monthToDate, .balanceForecast, .owedToMe])
    #expect(layout.isHidden(.canSave))
    #expect(layout.shown.contains(.limits))
    // Every tile of the builds before that the text did not name is still shown, as ever.
    for tile in OverviewTile.allCases where tile.isShownUnnamed && tile != .canSave {
      #expect(layout.shown.contains(tile), "\(tile)")
    }
    for tile in [
      OverviewTile.currencyBalances, .spendToday, .weekOverWeek, .averageDaily, .monthIncome,
      .savingsRate, .monthRest, .weekdaySpending, .monthlySpending, .incomeSources, .topPlaces,
      .spendingByPerson, .categoryGrew, .categoryShrank, .smallPurchases, .backups, .integrity,
      .ratesStatus,
    ] {
      #expect(layout.isHidden(tile), "\(tile)")
      #expect(!layout.showsItself(tile), "\(tile)")
      #expect(!layout.isVisible(tile, facts: OverviewFacts(Set(OverviewFeature.allCases))))
    }
  }

  @Test func theFlatListOfTheOldestBuildsShowsTheSameTilesAsBefore() {
    let layout = OverviewLayout(tiles: OverviewTiles.standard)
    // The old behaviour: the twelve first, every other tile of those builds after them; the
    // tiles of 2.0 are not among them.
    #expect(layout.shown.count == 22)
    for tile in OverviewTile.allCases where !tile.isShownUnnamed {
      #expect(layout.isHidden(tile), "\(tile)")
    }
  }

  @Test func aLayoutWithoutTheNewPartsEncodesAsItAlwaysDid() throws {
    let layout = try #require(OverviewLayout.decode(storedBefore))
    let text = layout.encode()
    #expect(!text.contains("compact"))
    #expect(!text.contains("pairs"))
    #expect(!text.contains("auto"))
    #expect(OverviewLayout.decode(text) == layout)
  }

  @Test func theStandardLayoutIsStillTheOldOne() {
    #expect(OverviewLayout.standard.shown.count == 22)
    #expect(OverviewLayout.standard != OverviewLayout.firstRun)
    #expect(OverviewLayout.standard.isStandard)
    #expect(!OverviewLayout.firstRun.isStandard)
  }
}
