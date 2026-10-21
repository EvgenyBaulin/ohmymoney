import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The starter set as the owner meets it on the demo copy, whose categories are the sample's:
/// the section of Settings, the ways of living and the four questions of the sheet, what «С
/// детьми» and «Есть кредиты» will add, one ⌘Z that takes the categories and the limit and
/// leaves the tiles, «Ничего — всё уже есть.» the second time, and «Позже» that adds nothing.
@MainActor
final class StarterSetFlowTests: XCTestCase {
  private var store: TransactionsStore!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private var environment: AppEnvironment!
  private var windows: [NSWindow] = []
  private let month = MonthKey(year: 2026, month: 10)

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer), references: references, planning: planning)
    environment = AppEnvironment()
    // The demo's catalog: the sample's, without the categories the starter sets bring.
    try references.seedCategoriesIfEmpty(SampleCatalog.makeCategories(language: "ru"))
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
  }

  private static func russian(_ key: String, table: String) -> String {
    GuideFlowTests.russian(key, table: table)
  }

  private func plan(
    _ choice: StarterChoice, tiles: [OverviewTile] = OverviewTile.allCases
  ) throws -> StarterAdditions {
    StarterSets.additions(
      for: choice, language: "ru", existing: try references.categories(includeArchived: true),
      budgets: try planning.book().budgets, tiles: tiles, startMonth: month)
  }

  /// «Настройки → Основные»: «Стартовый набор», «Выбрать стартовый набор…», «Только добавляет;
  /// ⌘Z отменяет», and «Больше не показывать подсказки» below.
  func testSettingsOfferTheStarterSet() {
    XCTAssertEqual(Self.russian("settings.starter", table: "Settings"), "Стартовый набор")
    XCTAssertEqual(
      Self.russian("settings.starter.open", table: "Settings"), "Выбрать стартовый набор…")
    XCTAssertTrue(
      Self.russian("settings.starter.hint", table: "Settings")
        .contains("Только добавляет; ⌘Z отменяет"))
    XCTAssertEqual(
      Self.russian("settings.tips.off", table: "Settings"), "Больше не показывать подсказки")
  }

  /// The sheet: seven ways of living and four questions.
  func testTheSheetOffersTheWaysOfLivingAndFourQuestions() {
    XCTAssertEqual(
      Lifestyle.allCases.map {
        Self.russian("starter.lifestyle.\($0.rawValue)", table: "Onboarding")
      },
      [
        "Студент", "Работаю", "Фриланс или самозанятость", "Семья", "Живу один", "С партнёром",
        "С детьми",
      ])
    XCTAssertEqual(
      ["starter.loans", "starter.subscriptions", "starter.cashback", "starter.cushion"].map {
        Self.russian($0, table: "Onboarding")
      },
      ["Есть кредиты", "Есть подписки", "Учитываю кэшбэк", "Нужна подушка безопасности"])
    XCTAssertEqual(Self.russian("starter.title", table: "Onboarding"), "Стартовый набор")
    XCTAssertEqual(Self.russian("starter.later", table: "Onboarding"), "Позже")
    XCTAssertEqual(Self.russian("starter.apply", table: "Onboarding"), "Добавить")
  }

  /// «С детьми» and «Есть кредиты» on the demo's catalog: «Зарплата», «Налоги и сборы» with three
  /// taxes, «Дети» with four below it and «Детские пособия»; the limit «Дети — 20,000 ₽»; the
  /// tile «Я должен» only while Overview has room for it.
  func testKidsAndLoansSayWhatTheyWillAdd() throws {
    let choice = StarterChoice(lifestyles: [.kids], hasLoans: true)
    let full = try plan(choice)
    let names = Set(full.categories.map(\.name))
    for name in [
      "Зарплата", "Налоги и сборы", "Транспортный налог", "Имущественный налог", "НДФЛ", "Дети",
      "Сад и школа", "Детская одежда", "Игрушки", "Кружки", "Детские пособия",
    ] {
      XCTAssertTrue(names.contains(name), "«\(name)» is not in «Добавится»: \(names.sorted())")
    }
    XCTAssertEqual(
      StarterSetActions.limitNames(full, environment: environment, dataset: nil),
      ["Дети — " + environment.money.rounded(AmountE4(whole: 20_000))])
    XCTAssertTrue(full.tiles.isEmpty, "every tile shown leaves nothing to add")
    let roomy = try plan(choice, tiles: OverviewTile.allCases.filter { $0 != .iOwe })
    XCTAssertEqual(roomy.tiles, [.iOwe])
    XCTAssertEqual(Self.russian("starter.categories", table: "Onboarding"), "Категории:")
    XCTAssertEqual(Self.russian("starter.limits", table: "Onboarding"), "Лимиты:")
    XCTAssertEqual(Self.russian("starter.tiles", table: "Onboarding"), "Плитки «Обзора»:")
  }

  /// «Добавить»: «Зарплата» inside «Заработок», «Налоги и сборы» with three taxes, «Дети» with
  /// its four; nothing gone or renamed. One ⌘Z takes every category and the limit; the tiles —
  /// a setting, not data — stay.
  func testApplyingAddsUnderTheRightParentsAndOneUndoKeepsTheTiles() throws {
    let before = try references.categories(includeArchived: true)
    environment.overviewTiles = Array(OverviewTiles.standard.prefix(11))
    let choice = StarterChoice(lifestyles: [.kids], hasLoans: true)
    let plan = try plan(choice, tiles: environment.overviewTiles)
    XCTAssertTrue(StarterSetActions.apply(plan, store: store, environment: environment))

    let after = try references.categories(includeArchived: true)
    func id(_ name: String) throws -> UUID { try XCTUnwrap(after.first { $0.name == name }?.id) }
    XCTAssertEqual(after.first { $0.name == "Зарплата" }?.parentId, try id("Заработок"))
    XCTAssertEqual(
      Set(after.filter { $0.parentId == (try? id("Налоги и сборы")) }.map(\.name)),
      ["Транспортный налог", "Имущественный налог", "НДФЛ"])
    XCTAssertEqual(
      Set(after.filter { $0.parentId == (try? id("Дети")) }.map(\.name)),
      ["Сад и школа", "Детская одежда", "Игрушки", "Кружки"])
    for old in before {
      XCTAssertEqual(after.first { $0.id == old.id }?.name, old.name, "renamed or gone")
    }
    XCTAssertEqual(try planning.book().budgets.count, 1)
    XCTAssertTrue(environment.overviewTiles.contains(.iOwe))

    store.undo()
    XCTAssertEqual(
      Set(try references.categories(includeArchived: true).map(\.id)), Set(before.map(\.id)),
      "one ⌘Z did not take every category")
    XCTAssertTrue(try planning.book().budgets.isEmpty, "the limit «Дети» stayed")
    XCTAssertTrue(environment.overviewTiles.contains(.iOwe), "⌘Z took the tiles too")
  }

  /// «С детьми» twice: the second time «Добавится» says «Ничего — всё уже есть.» and «Добавить»
  /// is off; nothing is doubled.
  func testTheSecondTimeThereIsNothingToAdd() throws {
    let choice = StarterChoice(lifestyles: [.kids])
    XCTAssertTrue(
      StarterSetActions.apply(try plan(choice), store: store, environment: environment))
    let count = try references.categories(includeArchived: true).count
    let again = try plan(choice)
    XCTAssertTrue(again.isEmpty)
    XCTAssertEqual(
      Self.russian("starter.nothingToAdd", table: "Onboarding"), "Ничего — всё уже есть.")
    XCTAssertTrue(StarterSetActions.apply(again, store: store, environment: environment))
    XCTAssertEqual(try references.categories(includeArchived: true).count, count)
    let names = try references.categories(includeArchived: true).map(\.name)
    XCTAssertEqual(names.filter { $0 == "Дети" }.count, 1, "«Дети» doubled")
  }

  /// «Позже» (Esc) closes the sheet and adds nothing.
  func testLaterAddsNothing() throws {
    let asked = UserDefaults.standard.object(forKey: StarterSetActions.askedKey)
    defer {
      if let asked {
        UserDefaults.standard.set(asked, forKey: StarterSetActions.askedKey)
      } else {
        UserDefaults.standard.removeObject(forKey: StarterSetActions.askedKey)
      }
    }
    let before = try references.categories(includeArchived: true).count
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .utc))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 600, height: 660), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: StarterSetSheet().appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    StarterSetOffer.shared.isRequested = true

    let escape = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
      isARepeat: false, keyCode: 53)!
    XCTAssertTrue(window.performKeyEquivalent(with: escape), "Esc reached no «Позже»")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertFalse(StarterSetOffer.shared.isRequested, "«Позже» did not close the sheet")
    XCTAssertEqual(try references.categories(includeArchived: true).count, before)
    XCTAssertTrue(try planning.book().budgets.isEmpty)
    XCTAssertFalse(store.canUndo, "«Позже» left a step of ⌘Z")
  }
}
