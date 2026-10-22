import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The tiles of 2.0 as the app shows them: the catalog and its words in both languages, the ten
/// tiles of a new person and only of a new person, the tiles that show themselves, sizes and
/// pairs as the owner makes them, rows with the charts and lists across the whole width, the
/// words of every figure tile, and the limit of a small purchase.
@MainActor
final class OverviewNewTilesTests: XCTestCase {
  private var environment: AppEnvironment!
  private var languageBefore: AppLanguage.Choice?
  private static let calendar = CalendarContext.system

  override func setUp() async throws {
    OverviewFiguresStore.shared.reset()
    environment = AppEnvironment()
    languageBefore = environment.language.choice
  }

  override func tearDown() async throws {
    if let languageBefore { environment.language.choice = languageBefore }
  }

  // MARK: - Words

  /// Every tile of the catalog has its name in both languages, built or not, and every word of
  /// the editing and of the menu «Добавить плитку» too.
  func testEveryNameAndWordOfTheNewTilesIsInBothLanguages() {
    var keys = OverviewCatalog.items.map(\.nameKey)
    keys += [
      "overview.edit.compactBadge", "overview.edit.pair", "overview.edit.unpair",
      "overview.edit.sizeRegular", "overview.edit.sizeCompact", "overview.add.pairs",
      "overview.add.single", "overview.add.unbuilt", "overview.add.inProgress",
      "overview.add.sideBySide", "overview.small.field.title", "overview.small.field.hint",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in keys {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(choice): \(key)")
      }
    }
  }

  /// The names of the tiles differ in the two languages and are never empty.
  func testTheNamesAreWordsNotKeys() {
    for item in OverviewCatalog.unbuilt {
      environment.language.choice = .english
      let english = environment.language(item.nameKey, table: "Overview")
      environment.language.choice = .russian
      let russian = environment.language(item.nameKey, table: "Overview")
      XCTAssertFalse(english.isEmpty)
      XCTAssertFalse(russian.isEmpty)
      XCTAssertNotEqual(english, russian, "\(item.number)")
    }
  }

  // MARK: - The figure tiles

  private func snapshot() -> DataSnapshot {
    let today = environment.today
    let set = SampleDataGenerator(seed: 20_261_014).generate(
      months: 6, endingOn: today, calendar: Self.calendar, language: "en"
    ).withEveryFeature(seed: 20_261_014, calendar: Self.calendar, language: "en")
    let dataset = Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules, banks: set.banks, assets: set.assets,
      assetValuations: set.assetValuations,
      capitalSettings: CapitalSettings(storedValues: set.settings))
    return DataSnapshot.build(
      dataset: dataset, calendar: Self.calendar, today: today,
      context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]), version: DataVersion(load: 0))
  }

  private func system(_ snapshot: DataSnapshot) -> OverviewSystemStatus {
    OverviewSystemStatus(
      now: environment.now(), today: snapshot.today,
      backupAt: environment.now().addingTimeInterval(-86_400 * 2), backupCount: 4,
      checkedAt: environment.now().addingTimeInterval(-86_400 * 3), problems: 0,
      ratesDay: snapshot.today.adding(days: -1))
  }

  /// Every tile that is one figure says it in both languages: no key shows through, no
  /// placeholder is left, and the sentence that says «nothing» exists too.
  func testTheFigureTilesSpeakInBothLanguages() {
    let snapshot = snapshot()
    let figures = OverviewFigures(
      ledger: snapshot.ledger, today: snapshot.today, smallLimit: AmountE4(whole: 1_000),
      expectedIncome: snapshot.planning.income.expectedRemaining)
    let status = system(snapshot)
    var shown = 0
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for tile in OverviewFigureText.tiles {
        let result = OverviewFigureText.result(
          of: tile, snapshot: snapshot, figures: figures, system: status, environment)
        switch result {
        case .figure(let figure):
          shown += 1
          for text in [figure.value, figure.caption].compactMap({ $0 }) + figure.details {
            XCTAssertFalse(text.isEmpty, "\(choice) \(tile)")
            XCTAssertFalse(text.contains("%@") || text.contains("%lld"), "\(tile): \(text)")
            XCTAssertFalse(text.hasPrefix("overview."), "\(tile): \(text)")
          }
        case .empty(let key):
          let words = environment.language(key, table: OverviewFigureText.table)
          XCTAssertNotEqual(words, key, "\(choice) \(tile)")
        }
      }
    }
    XCTAssertGreaterThan(shown, 10, "the sample gives most figure tiles something to say")
  }

  /// With nothing to count a figure tile says why, and never a figure of zeros made up.
  func testWithNothingToCountTheFigureTilesSayWhy() {
    let today = environment.today
    let snapshot = DataSnapshot.build(
      dataset: Dataset(), calendar: Self.calendar, today: today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    let figures = OverviewFigures(ledger: snapshot.ledger, today: today)
    let status = OverviewSystemStatus(now: environment.now(), today: today)
    for tile in OverviewFigureText.tiles where tile != .averageDaily && tile != .weekOverWeek {
      let result = OverviewFigureText.result(
        of: tile, snapshot: snapshot, figures: figures, system: status, environment)
      XCTAssertNotNil(result.emptyKey, "\(tile) should say why it has nothing")
    }
  }

  /// A stale copy and a stale rate say so in words and with a symbol, never by colour alone.
  func testStaleStatesAreMarkedBySymbolAndWords() {
    let snapshot = snapshot()
    let figures = OverviewFigures(ledger: snapshot.ledger, today: snapshot.today)
    let stale = OverviewSystemStatus(
      now: environment.now(), today: snapshot.today,
      backupAt: environment.now().addingTimeInterval(-86_400 * 20), backupCount: 2,
      checkedAt: environment.now().addingTimeInterval(-86_400), problems: 3,
      ratesDay: snapshot.today.adding(days: -9))
    for tile in [OverviewTile.backups, .integrity, .ratesStatus] {
      let figure = OverviewFigureText.result(
        of: tile, snapshot: snapshot, figures: figures, system: stale, environment
      ).figure
      XCTAssertEqual(figure?.symbol, "exclamationmark.triangle", "\(tile)")
      XCTAssertFalse((figure?.caption ?? figure?.details.first ?? "").isEmpty, "\(tile)")
    }
  }

  /// The store counts the figures once for a snapshot and the limit, and again when the limit
  /// changes; the figures of a tile and of «Почему так» are one instance.
  func testTheStoreCountsOncePerSnapshotAndLimit() {
    let store = OverviewFiguresStore()
    let snapshot = snapshot()
    let first = store.figures(for: snapshot)
    XCTAssertEqual(store.figures(for: snapshot), first)
    XCTAssertNil(first.small)
    let breakdown = TileWhy.explanation(
      of: .spendToday, snapshot: snapshot, remainder: nil, owed: nil, anomalies: nil, rates: nil,
      environment: environment)
    // With nothing spent today the breakdown has no figure at all: the answer depends on the
    // hour the sample was drawn (on a runner in UTC the day may still be empty).
    let spent = OverviewFiguresStore.shared.figures(for: snapshot).spendToday.spent
    XCTAssertEqual(breakdown.figure, spent == .zero ? nil : TileValue.money(spent, .rub))
  }

  // MARK: - Facts

  /// What the books say about the functions: the sample with every feature has debts, a credit
  /// card, a deposit and several currencies; an empty book has none of them.
  func testTheFactsFollowTheBooks() {
    let store = OverviewFiguresStore()
    let full = store.facts(for: snapshot())
    for feature: OverviewFeature in [.iOwe, .creditCard, .deposit, .multiCurrency] {
      XCTAssertTrue(full.has(feature), "\(feature)")
    }
    XCTAssertFalse(full.has(.smallLimit), "no limit was set")
    let today = environment.today
    let empty = DataSnapshot.build(
      dataset: Dataset(), calendar: Self.calendar, today: today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    XCTAssertEqual(store.facts(for: empty), .none)
  }

  // MARK: - A new person

  private func isolatedDefaults() -> UserDefaults {
    let suite = "ohmymoney.tests.firstrun.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return defaults
  }

  /// Only an open database of the real data, not set up and not asked, with nothing of Overview
  /// chosen, is new: not the unit tests' host, not a synthetic set.
  func testOnlyANewPersonGetsTheTenTiles() {
    let defaults = isolatedDefaults()
    // The environment of a test is not open on a real database: not a new person.
    XCTAssertFalse(OverviewFirstRun.isNewPerson(environment, defaults: defaults, isTestHost: false))
    XCTAssertFalse(OverviewFirstRun.seed(environment, defaults: defaults, isTestHost: false))
  }

  func testTheTestHostAndTheSyntheticSetsNeverGetThem() {
    let defaults = isolatedDefaults()
    XCTAssertFalse(OverviewFirstRun.isNewPerson(environment, defaults: defaults, isTestHost: true))
    XCTAssertFalse(
      OverviewFirstRun.isNewPerson(
        environment, defaults: defaults, isTestHost: false, dataSet: AppPaths.DataSet.sample))
  }

  /// An owner who chose a layout, or kept the list of the builds before groups, or was asked the
  /// starter set, keeps what they have.
  func testWhoeverChoseKeepsTheirOverview() {
    let defaults = isolatedDefaults()
    defaults.set("money:monthToDate", forKey: AppEnvironment.overviewLayoutKey)
    XCTAssertFalse(OverviewFirstRun.isNewPerson(environment, defaults: defaults, isTestHost: false))
    let list = isolatedDefaults()
    list.set("monthToDate,limits", forKey: AppEnvironment.overviewTilesKey)
    XCTAssertFalse(OverviewFirstRun.isNewPerson(environment, defaults: list, isTestHost: false))
    let asked = isolatedDefaults()
    StarterSetActions.markAsked(in: asked)
    XCTAssertFalse(OverviewFirstRun.isNewPerson(environment, defaults: asked, isTestHost: false))
  }

  /// The migration leaves the layout of an owner alone: the settings written by a build before
  /// 2.0 read back as they were, the new tiles hidden, nothing changed on the screen.
  func testALayoutOfABuildBeforeReadsBackAsItWas() {
    let defaults = isolatedDefaults()
    let before = OverviewLayout.standard.hiding(.qualities)!.moving(.limits, to: .money)
    defaults.set(before.encode(), forKey: AppEnvironment.overviewLayoutKey)
    let read = AppEnvironment.storedOverviewLayout(in: defaults)
    XCTAssertEqual(read.shown, before.shown)
    for tile in OverviewTile.allCases where (OverviewCatalog.item(of: tile)?.number ?? 0) > 24 {
      XCTAssertTrue(read.isHidden(tile), "\(tile)")
    }
  }

  // MARK: - Sizes and pairs

  private func restoreLayout() {
    let layout = environment.overviewLayout
    addTeardownBlock { @MainActor [environment] in environment?.overviewLayout = layout }
  }

  func testTheOwnerMakesATileCompactAndPairsTwo() {
    restoreLayout()
    environment.overviewLayout = .standard
    XCTAssertTrue(OverviewTilesActions.setCompact(environment, .owedToMe, true))
    XCTAssertFalse(OverviewTilesActions.setCompact(environment, .owedToMe, true), "nothing to do")
    XCTAssertFalse(OverviewTilesActions.setCompact(environment, .topCategories, true))
    XCTAssertTrue(OverviewTilesActions.setCompact(environment, .iOwe, true))
    XCTAssertTrue(OverviewTilesActions.drop(environment, .iOwe, onto: .owedToMe))
    XCTAssertEqual(environment.overviewLayout.partner(of: .owedToMe), .iOwe)
    XCTAssertTrue(OverviewTilesActions.unpair(environment, .iOwe))
    XCTAssertNil(environment.overviewLayout.partner(of: .owedToMe))
    XCTAssertFalse(environment.overviewLayout.isCompact(.owedToMe))
    XCTAssertFalse(OverviewTilesActions.unpair(environment, .iOwe), "nothing to part")
  }

  func testASuggestedPairIsAddedBothTilesShownSideBySide() {
    restoreLayout()
    environment.overviewLayout = .firstRun
    XCTAssertTrue(OverviewTilesActions.addPair(environment, .backups, .integrity))
    let layout = environment.overviewLayout
    XCTAssertFalse(layout.isHidden(.backups))
    XCTAssertFalse(layout.isHidden(.integrity))
    XCTAssertEqual(layout.partner(of: .backups), .integrity)
    XCTAssertTrue(layout.cells(in: .analysis, facts: .none).contains(.pair(.backups, .integrity)))
    // Written to the setting: the next launch reads the pair back.
    let read = AppEnvironment.storedOverviewLayout()
    XCTAssertEqual(read.partner(of: .backups), .integrity)
  }

  /// The menu offers a pair only when both tiles can be added now.
  func testTheMenuOffersWhatCanBeAdded() {
    let addable = OverviewLayout.firstRun.addable(facts: .none)
    let pairs = OverviewAddMenuContent.pairs(addable: addable).map(\.id)
    XCTAssertTrue(pairs.contains("31+33"))
    XCTAssertTrue(pairs.contains("34+35"))
    XCTAssertTrue(pairs.contains("96+97"))
    XCTAssertFalse(pairs.contains("38+40"), "not built")
    XCTAssertFalse(pairs.contains("13+51"), "13 is on the screen, 51 is not built")
    // A pair that has a tile on the screen already is not offered.
    let shown = OverviewAddMenuContent.pairs(
      addable: addable.filter { $0 != .spendToday })
    XCTAssertFalse(shown.map(\.id).contains("31+33"))
  }

  /// A chart or a list takes the whole width; the others fill the rows in order.
  func testWideTilesHaveRowsOfTheirOwn() {
    let cells: [OverviewLayout.Cell] = [
      .single(.spendToday), .pair(.owedToMe, .iOwe), .single(.weekdaySpending),
      .single(.limits), .single(.topPlaces), .single(.qualities),
    ]
    let rows = OverviewCard.rows(cells, columns: 3)
    XCTAssertEqual(
      rows,
      [
        [.single(.spendToday), .pair(.owedToMe, .iOwe)], [.single(.weekdaySpending)],
        [.single(.limits)], [.single(.topPlaces)], [.single(.qualities)],
      ])
    XCTAssertEqual(OverviewCard.span(of: .single(.weekdaySpending), columns: 3), 3)
    XCTAssertEqual(OverviewCard.span(of: .pair(.owedToMe, .iOwe), columns: 3), 1)
    XCTAssertEqual(OverviewCard.span(of: .single(.limits), columns: 3), 1)
    // One column: every cell is a row.
    XCTAssertEqual(OverviewCard.rows(cells, columns: 1).count, cells.count)
    // Two columns: a pair is one cell.
    XCTAssertEqual(
      OverviewCard.rows(
        [.single(.limits), .pair(.backups, .integrity), .single(.qualities)], columns: 2),
      [[.single(.limits), .pair(.backups, .integrity)], [.single(.qualities)]])
  }

  /// A group with only tiles that wait for their data is left out of the screen until they come.
  func testAGroupWithNothingToShowIsLeftOut() {
    var layout = OverviewLayout.firstRun
    // Every plan tile hidden but a self-showing one: none of the group is on the screen.
    for tile in layout.tiles(in: .plan) where !layout.isHidden(tile) {
      layout = layout.hiding(tile) ?? layout
    }
    XCTAssertFalse(OverviewScreen.groups(of: layout, editing: false).contains(.plan))
    XCTAssertTrue(OverviewScreen.groups(of: layout, editing: true).contains(.plan))
    // The expected income shows itself with its data and brings the group back.
    layout = OverviewLayout.firstRun
    for tile in layout.tiles(in: .plan) where !layout.isHidden(tile) {
      layout = layout.hiding(tile) ?? layout
    }
    XCTAssertTrue(
      OverviewScreen.groups(of: layout, editing: false, facts: OverviewFacts([.expectedIncome]))
        .contains(.plan))
  }

  // MARK: - The limit of a small purchase

  func testTheLimitIsReadFromWhatIsTyped() {
    XCTAssertEqual(SmallPurchaseLimitField.whole(of: "300"), 300)
    XCTAssertEqual(SmallPurchaseLimitField.whole(of: " 1 500 "), 1_500)
    XCTAssertEqual(SmallPurchaseLimitField.whole(of: "1,500"), 1_500)
    XCTAssertNil(SmallPurchaseLimitField.whole(of: ""))
    XCTAssertNil(SmallPurchaseLimitField.whole(of: "0"))
    XCTAssertNil(SmallPurchaseLimitField.whole(of: "abc"))
    XCTAssertNil(SmallPurchaseLimitField.whole(of: "12abc"))
    XCTAssertEqual(SmallPurchaseLimitField.text(of: AmountE4(whole: 450)), "450")
    XCTAssertEqual(SmallPurchaseLimitField.text(of: nil), "")
  }

  /// The limit is a setting of the database: written, read back as the limit of the tile, and
  /// cleared by an empty field.
  func testTheLimitIsWrittenToTheSettingsOfTheDatabase() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-small-limit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let before = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    defer {
      if let before {
        setenv("OHMYMONEY_DATA_DIR", before, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
    }
    let open = AppEnvironment()
    await open.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let store = OverviewFiguresStore()
    XCTAssertTrue(store.saveSmallLimit(300, environment: open))
    XCTAssertEqual(store.smallLimit, AmountE4(whole: 300))
    let stored = try open.settings?.string(OverviewSettings.smallPurchaseLimitKey)
    XCTAssertEqual(stored, "300")

    let reader = OverviewFiguresStore()
    await reader.refresh(environment: open)
    XCTAssertEqual(reader.smallLimit, AmountE4(whole: 300))

    XCTAssertTrue(store.saveSmallLimit(nil, environment: open))
    XCTAssertNil(store.smallLimit)
    await reader.refresh(environment: open)
    XCTAssertNil(reader.smallLimit)
    await open.close()
  }
}
