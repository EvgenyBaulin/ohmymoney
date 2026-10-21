import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// How Overview lays out its tiles, as the app keeps the layout: in `UserDefaults` beside the
/// order of the ↓ panel, read back by the next launch, carried by the archive and read from it as
/// a whole layout; the flat list of the builds before groups read where no layout is kept.
/// Settings show and hide tiles — never the last one off —, move them within and between groups
/// and move the groups. The keys are the owner's own: `AppDefaultsGuard` clears them before every
/// test and puts the owner's back afterwards.
@MainActor
final class OverviewTilesSettingTests: XCTestCase {
  private var directory: URL!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-overview-tiles-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var stored: String? {
    UserDefaults.standard.string(forKey: AppEnvironment.overviewTilesKey)
  }

  private var storedLayout: String? {
    UserDefaults.standard.string(forKey: AppEnvironment.overviewLayoutKey)
  }

  /// Nothing chosen: every tile shown, the twelve cards of 1.2 first in their groups, and nothing
  /// written. A change is written at once — the layout and, beside it, the flat list of the tiles
  /// shown — and a new launch reads it back.
  func testTheLayoutIsKeptAndReadBackByTheNextLaunch() {
    XCTAssertEqual(AppEnvironment.overviewTilesKey, "overview.tiles")
    XCTAssertEqual(AppEnvironment.overviewLayoutKey, "overview.layout")
    XCTAssertEqual(AppEnvironment.overviewCollapsedKey, "overview.collapsed")
    let environment = AppEnvironment()
    XCTAssertEqual(environment.overviewLayout, .standard)
    XCTAssertEqual(
      environment.overviewTiles.count, OverviewTile.allCases.filter(\.isShownUnnamed).count)
    XCTAssertNil(stored)
    XCTAssertNil(storedLayout)

    XCTAssertTrue(OverviewTilesActions.hide(environment, .qualities))
    XCTAssertTrue(OverviewTilesActions.move(environment, .limits, to: .money))
    XCTAssertTrue(OverviewTilesActions.moveGroup(environment, .analysis, by: -1))
    XCTAssertEqual(storedLayout, environment.overviewLayout.encode())
    XCTAssertEqual(stored, OverviewTiles.encode(environment.overviewLayout.shown))
    XCTAssertEqual(AppEnvironment().overviewLayout, environment.overviewLayout)
  }

  /// The flat list of a build before groups, with no layout kept: its tiles keep their order and
  /// the ones it lacked are shown at the end of their groups — every tile is shown.
  func testAStoredListOfABuildBeforeGroupsGetsTheMissingTilesAtTheEnd() {
    UserDefaults.standard.set(
      "freeMoney,limits,monthToDate", forKey: AppEnvironment.overviewTilesKey)
    let layout = AppEnvironment().overviewLayout
    XCTAssertEqual(layout, OverviewLayout(tiles: [.freeMoney, .limits, .monthToDate]))
    XCTAssertEqual(Array(layout.tiles(in: .money).prefix(2)), [.freeMoney, .monthToDate])
    XCTAssertEqual(layout.tiles(in: .plan).first, .limits)
    // Every tile but the ones that wait to be added.
    XCTAssertEqual(layout.shown.count, OverviewTile.allCases.filter(\.isShownUnnamed).count)
    XCTAssertEqual(layout.hidden, [.installments, .selfEmployment])

    UserDefaults.standard.set("tilesOfTomorrow,iOwe,iOwe", forKey: AppEnvironment.overviewTilesKey)
    XCTAssertEqual(AppEnvironment().overviewLayout, OverviewLayout(tiles: [.iOwe]))
    UserDefaults.standard.set("", forKey: AppEnvironment.overviewTilesKey)
    XCTAssertEqual(AppEnvironment().overviewLayout, .standard)

    // A layout, once kept, wins over the list.
    UserDefaults.standard.set("plan:event", forKey: AppEnvironment.overviewLayoutKey)
    XCTAssertEqual(AppEnvironment().overviewLayout.groups.first, .plan)
    XCTAssertEqual(AppEnvironment().overviewLayout.tiles(in: .plan).first, .event)
    // A layout no build could read is no layout: the list is read.
    UserDefaults.standard.set("tomorrow:event", forKey: AppEnvironment.overviewLayoutKey)
    XCTAssertEqual(AppEnvironment().overviewLayout, .standard)
  }

  /// The box hides and shows a tile at its place; the last tile shown cannot be hidden; «Сбросить»
  /// brings the standard layout back. There is no limit: every tile can be shown at once.
  func testTheBoxHidesAndShowsAndKeepsTheLastTile() {
    let environment = AppEnvironment()
    XCTAssertTrue(OverviewTilesActions.canSwitch(environment, .qualities))
    XCTAssertTrue(OverviewTilesActions.toggle(environment, .qualities))
    XCTAssertTrue(environment.overviewLayout.isHidden(.qualities))
    XCTAssertFalse(environment.overviewTiles.contains(.qualities))
    XCTAssertTrue(OverviewTilesActions.canSwitch(environment, .qualities))
    XCTAssertTrue(OverviewTilesActions.toggle(environment, .qualities))
    XCTAssertEqual(environment.overviewLayout, .standard, "shown again at its place")

    environment.overviewTiles = [.limits]
    XCTAssertEqual(environment.overviewTiles, [.limits])
    XCTAssertFalse(OverviewTilesActions.canSwitch(environment, .limits))
    XCTAssertFalse(OverviewTilesActions.toggle(environment, .limits))
    XCTAssertFalse(OverviewTilesActions.hide(environment, .limits))
    XCTAssertEqual(environment.overviewTiles, [.limits])
    XCTAssertTrue(OverviewTilesActions.show(environment, .currencyChart))
    XCTAssertFalse(OverviewTilesActions.show(environment, .currencyChart))

    OverviewTilesActions.reset(environment)
    XCTAssertEqual(environment.overviewLayout, .standard)
  }

  /// «Выше» and «Ниже» move a tile by one place in its group — in Settings past hidden rows too,
  /// on Overview past them; «Перенести в «…»» moves it to the end of another group; groups move
  /// by «Группу выше» and «Группу ниже».
  func testTilesAndGroupsMoveByOneStep() {
    let environment = AppEnvironment()
    XCTAssertEqual(OverviewTilesActions.moves(environment, .monthToDate, amongShown: false), [1])
    XCTAssertEqual(OverviewTilesActions.moves(environment, .canSave, amongShown: false), [-1, 1])
    XCTAssertEqual(OverviewTilesActions.moves(environment, .cushion, amongShown: false), [-1])
    XCTAssertTrue(OverviewTilesActions.move(environment, .canSave, by: -1, amongShown: false))
    XCTAssertEqual(
      Array(environment.overviewLayout.tiles(in: .money).prefix(2)), [.canSave, .monthToDate])
    XCTAssertFalse(OverviewTilesActions.move(environment, .canSave, by: -1, amongShown: false))

    OverviewTilesActions.hide(environment, .monthToDate)
    XCTAssertEqual(OverviewTilesActions.moves(environment, .canSave, amongShown: true), [1])
    XCTAssertEqual(OverviewTilesActions.moves(environment, .canSave, amongShown: false), [1])
    XCTAssertTrue(OverviewTilesActions.move(environment, .owedToMe, by: -1, amongShown: true))
    XCTAssertEqual(
      Array(environment.overviewLayout.tiles(in: .money).prefix(3)),
      [.owedToMe, .canSave, .monthToDate])

    XCTAssertEqual(OverviewTilesActions.otherGroups(environment, .limits), [.money, .analysis])
    XCTAssertTrue(OverviewTilesActions.move(environment, .limits, to: .analysis))
    XCTAssertEqual(environment.overviewLayout.tiles(in: .analysis).last, .limits)
    XCTAssertFalse(OverviewTilesActions.move(environment, .limits, to: .analysis))

    XCTAssertEqual(OverviewTilesActions.groupMoves(environment, .money), [1])
    XCTAssertEqual(OverviewTilesActions.groupMoves(environment, .plan), [-1, 1])
    XCTAssertTrue(OverviewTilesActions.moveGroup(environment, .analysis, by: -1))
    XCTAssertEqual(environment.overviewLayout.groups, [.money, .analysis, .plan])
    XCTAssertFalse(OverviewTilesActions.moveGroup(environment, .plan, by: 1))
  }

  /// The tiles and the groups are dragged: a tile dropped onto another takes its place, in its
  /// group or another one; onto a group's name it goes first in that group; a group dropped onto
  /// another group takes its place; text dragged in from elsewhere is nothing. The hint says to
  /// drag, and says nothing of a limit.
  func testTilesAndGroupsAreDragged() {
    let environment = AppEnvironment()
    for tile in OverviewTile.allCases {
      XCTAssertEqual(OverviewTilesActions.tile(OverviewTilesActions.payload(of: tile)), tile)
      XCTAssertNil(OverviewTilesActions.group(OverviewTilesActions.payload(of: tile)))
    }
    for group in OverviewTileGroup.allCases {
      XCTAssertEqual(OverviewTilesActions.group(OverviewTilesActions.payload(of: group)), group)
      XCTAssertNil(OverviewTilesActions.tile(OverviewTilesActions.payload(of: group)))
    }
    XCTAssertNil(OverviewTilesActions.tile("limits"))
    XCTAssertNil(OverviewTilesActions.tile("ohmymoney.overview.tile:tilesOfTomorrow"))
    XCTAssertNil(OverviewTilesActions.group("ohmymoney.overview.group:tomorrow"))

    XCTAssertTrue(OverviewTilesActions.drop(environment, .limits, onto: .canSave))
    XCTAssertEqual(
      Array(environment.overviewLayout.tiles(in: .money).prefix(3)),
      [.monthToDate, .limits, .canSave])
    XCTAssertFalse(OverviewTilesActions.drop(environment, .limits, onto: .limits))

    XCTAssertTrue(
      OverviewTilesActions.drop(
        environment, OverviewTilesActions.payload(of: .event), onto: .analysis))
    XCTAssertEqual(environment.overviewLayout.tiles(in: .analysis).first, .event)
    XCTAssertTrue(
      OverviewTilesActions.drop(
        environment, OverviewTilesActions.payload(of: OverviewTileGroup.analysis), onto: .money))
    XCTAssertEqual(environment.overviewLayout.groups, [.analysis, .money, .plan])
    XCTAssertFalse(OverviewTilesActions.drop(environment, "limits", onto: .money))

    environment.language.choice = .russian
    let hint = environment.language("settings.tiles.hint", table: "Settings")
    XCTAssertTrue(hint.contains("перетащите"), hint)
    XCTAssertTrue(hint.contains("групп"), hint)
    XCTAssertFalse(hint.contains("стрелк"), hint)
    XCTAssertFalse(hint.contains("12"), hint)
    XCTAssertEqual(
      environment.language("settings.tiles.drag", table: "Settings"),
      "Перетащите, чтобы переставить")
    environment.language.choice = .english
    let english = environment.language("settings.tiles.hint", table: "Settings")
    XCTAssertTrue(english.contains("drag"), english)
    XCTAssertFalse(english.contains("arrow"), english)
  }

  /// A collapsed group is kept on this Mac and read back by the next launch — and never carried by
  /// the archive.
  func testACollapsedGroupIsKeptOnThisMacOnly() {
    let environment = AppEnvironment()
    XCTAssertTrue(environment.overviewCollapsed.isEmpty)
    OverviewTilesActions.toggleCollapsed(environment, .analysis)
    XCTAssertEqual(environment.overviewCollapsed, [.analysis])
    XCTAssertEqual(
      UserDefaults.standard.string(forKey: AppEnvironment.overviewCollapsedKey), "analysis")
    XCTAssertEqual(AppEnvironment().overviewCollapsed, [.analysis])
    XCTAssertNil(environment.portableSettings()[AppEnvironment.overviewCollapsedKey])
    OverviewTilesActions.toggleCollapsed(environment, .analysis)
    XCTAssertTrue(AppEnvironment().overviewCollapsed.isEmpty)
  }

  /// The forecast of spending is named for what it forecasts, in both languages; the card is
  /// titled by the same name (`OverviewTileText.name`).
  func testTheForecastOfSpendingSaysItIsAboutSpending() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    XCTAssertEqual(
      OverviewTileText.name(of: .spendingForecast, environment), "Прогноз расхода до конца месяца")
    environment.language.choice = .english
    XCTAssertEqual(
      OverviewTileText.name(of: .spendingForecast, environment),
      "Spending forecast to the end of the month")
  }

  /// The layout travels with the archive through the one funnel both the archive and the problem
  /// report read — with the flat list beside it —, and an archive's layout is kept as a whole
  /// layout.
  func testTheLayoutTravelsWithTheArchive() throws {
    let environment = AppEnvironment()
    XCTAssertEqual(
      environment.portableSettings()[AppEnvironment.overviewLayoutKey],
      OverviewLayout.standard.encode())
    environment.overviewTiles = [.iOwe, .lastRecord]
    XCTAssertEqual(
      environment.portableSettings()[AppEnvironment.overviewTilesKey], "iOwe,lastRecord")
    XCTAssertEqual(
      environment.portableSettings()[AppEnvironment.overviewLayoutKey],
      environment.overviewLayout.encode())

    let stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let archive = directory.appendingPathComponent("tiles.ohmymoneyarchive")
    _ = try service.exportArchive(
      to: archive,
      settings: [
        AppEnvironment.overviewTilesKey: "freeMoney",
        AppEnvironment.overviewLayoutKey: "plan:-limits,tilesOfTomorrow;analysis:freeMoney",
      ])
    ArchiveImportFlow.applyPortableSettings(try service.openArchive(at: archive))
    let layout = AppEnvironment().overviewLayout
    XCTAssertEqual(layout.groups, [.plan, .analysis, .money])
    XCTAssertTrue(layout.isHidden(.limits))
    XCTAssertEqual(layout.group(of: .freeMoney), .analysis)
    XCTAssertEqual(storedLayout, layout.encode(), "kept as a whole layout")
  }

  /// An archive of a build before groups carries only the list: the layout of this Mac goes, and
  /// the next launch reads the list with every missing tile at the end.
  func testAnArchiveOfABuildBeforeGroupsReplacesTheLayoutByItsList() throws {
    UserDefaults.standard.set("plan:event", forKey: AppEnvironment.overviewLayoutKey)
    let stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let archive = directory.appendingPathComponent("old.ohmymoneyarchive")
    _ = try service.exportArchive(
      to: archive, settings: [AppEnvironment.overviewTilesKey: "freeMoney,tilesOfTomorrow"])
    ArchiveImportFlow.applyPortableSettings(try service.openArchive(at: archive))
    XCTAssertEqual(stored, "freeMoney")
    XCTAssertNil(storedLayout)
    XCTAssertEqual(AppEnvironment().overviewLayout, OverviewLayout(tiles: [.freeMoney]))
  }

  /// The guard of the owner's defaults holds this key too.
  func testTheGuardHoldsTheTiles() throws {
    let suite = "ohmymoney.tests.overview-tiles.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("iOwe", forKey: AppDefaultsGuard.overviewTilesKey)
    let guardian = AppDefaultsGuard(defaults: defaults, domain: suite)
    XCTAssertEqual(guardian.owner, AppDefaultsGuard.Snapshot(overviewTiles: "iOwe"))

    guardian.testCaseWillStart(self)
    XCTAssertNil(defaults.string(forKey: AppDefaultsGuard.overviewTilesKey))
    defaults.set("limits", forKey: AppDefaultsGuard.overviewTilesKey)
    guardian.testCaseDidFinish(self)
    XCTAssertEqual(defaults.string(forKey: AppDefaultsGuard.overviewTilesKey), "iOwe")

    defaults.set("plan:event", forKey: AppDefaultsGuard.overviewLayoutKey)
    defaults.set("money", forKey: AppDefaultsGuard.overviewCollapsedKey)
    let second = AppDefaultsGuard(defaults: defaults, domain: suite)
    XCTAssertEqual(
      second.owner,
      AppDefaultsGuard.Snapshot(
        overviewTiles: "iOwe", overviewLayout: "plan:event", overviewCollapsed: "money"))
    second.testCaseWillStart(self)
    XCTAssertNil(defaults.string(forKey: AppDefaultsGuard.overviewLayoutKey))
    XCTAssertNil(defaults.string(forKey: AppDefaultsGuard.overviewCollapsedKey))
    second.testCaseDidFinish(self)
    XCTAssertEqual(defaults.string(forKey: AppDefaultsGuard.overviewLayoutKey), "plan:event")
    XCTAssertEqual(defaults.string(forKey: AppDefaultsGuard.overviewCollapsedKey), "money")
  }

  /// Every tile has a name in both languages: the settings list them by it, and the new tiles are
  /// titled by it.
  func testEveryTileIsNamedInBothLanguages() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      var names: Set<String> = []
      for tile in OverviewTile.allCases {
        let name = OverviewTileText.name(of: tile, environment)
        XCTAssertNotEqual(name, OverviewTileText.nameKey(of: tile), "\(tile), \(choice)")
        names.insert(name)
      }
      XCTAssertEqual(names.count, OverviewTile.allCases.count, "two tiles share a name")
      let groups = Set(
        OverviewTileGroup.allCases.map { OverviewTileText.groupName(of: $0, environment) })
      XCTAssertEqual(groups.count, 3)
      for group in OverviewTileGroup.allCases {
        XCTAssertNotEqual(
          OverviewTileText.groupName(of: group, environment),
          OverviewTileText.groupNameKey(of: group))
      }
      for key in OverviewTileText.keys {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(key), \(choice)")
      }
      for key in [
        "settings.tiles", "settings.tiles.hint", "settings.tiles.reset", "settings.tiles.moveTo",
        "settings.tiles.groupUp", "settings.tiles.groupDown", "settings.tiles.groupDrag",
      ] {
        XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(key), \(choice)")
      }
    }
    environment.language.choice = .russian
    XCTAssertEqual(OverviewTileText.name(of: .monthToDate, environment), "С начала месяца")
    XCTAssertEqual(OverviewTileText.name(of: .freeMoney, environment), "Свободные средства")
    XCTAssertEqual(
      OverviewTileGroup.allCases.map { OverviewTileText.groupName(of: $0, environment) },
      ["Деньги", "План", "Анализ"])
  }
}
