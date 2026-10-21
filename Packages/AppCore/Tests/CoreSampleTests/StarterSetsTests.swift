import CoreKit
import Foundation
import Testing

@testable import CoreSample

@Suite("Starter sets only add, and a new database has «Зарплата» and «Налоги и сборы»")
struct StarterSetsTests {
  private let month = MonthKey(year: 2026, month: 10)

  @Test func aNewDatabaseHasSalaryUnderWorkAndTaxes() {
    let tree = SampleCatalog.makeCategories(language: "ru", seeds: StarterSets.starterSeeds)
    let work = tree.first { $0.kind == .income && $0.name == "Заработок" && $0.parentId == nil }
    let salary = tree.first { $0.name == "Зарплата" }
    #expect(work != nil && salary?.parentId == work?.id && salary?.sort == 0)
    let taxes = tree.first { $0.kind == .expense && $0.name == "Налоги и сборы" }
    #expect(taxes?.parentId == nil && taxes?.quality == .neutral)
    let under = Set(tree.filter { $0.parentId == taxes?.id }.map(\.name))
    #expect(under == ["Транспортный налог", "Имущественный налог", "НДФЛ"])
  }

  /// The samples keep the catalog they had: their digests hold every id.
  @Test func theSamplesKeepTheirCatalog() {
    #expect(!SampleCatalog.categorySeeds.contains { $0.english == "Salary" })
    #expect(StarterSets.starterSeeds.count == SampleCatalog.categorySeeds.count + 5)
  }

  @Test func onAnOldDatabaseASetAddsOnlyWhatIsMissing() {
    let old = SampleCatalog.makeCategories(language: "ru")
    let plan = StarterSets.additions(
      for: StarterChoice(lifestyles: [.kids, .working]), language: "ru", existing: old,
      budgets: [], tiles: OverviewTiles.standard, startMonth: month)
    let names = plan.categories.map(\.name)
    #expect(
      names.contains("Зарплата") && names.contains("Налоги и сборы") && names.contains("Дети"))
    #expect(names.contains("Обеды") && names.contains("Премия"))
    // Nothing that is there comes again.
    #expect(!names.contains("Продукты") && !names.contains("Заработок"))
    // Children hang under parents that exist or come in the same plan.
    let ids = Set(old.map(\.id) + plan.categories.map(\.id))
    #expect(plan.categories.allSatisfy { $0.parentId.map(ids.contains) ?? true })
    let kids = plan.categories.first { $0.name == "Дети" }
    #expect(plan.categories.filter { $0.parentId == kids?.id }.count == 4)
    // The limits go on categories, the kids' one on the category the plan adds.
    #expect(
      plan.budgets.contains {
        $0.categoryId == kids?.id && $0.amountE4 == AmountE4(raw: 200_000_000)
      })
  }

  @Test func applyingTwiceAddsNothingTheSecondTime() {
    let old = SampleCatalog.makeCategories(language: "ru")
    let choice = StarterChoice(
      lifestyles: Set(Lifestyle.allCases), hasLoans: true, hasSubscriptions: true,
      tracksCashback: true, wantsACushion: true)
    let first = StarterSets.additions(
      for: choice, language: "ru", existing: old, budgets: [], tiles: [.monthToDate],
      startMonth: month)
    #expect(!first.isEmpty)
    let second = StarterSets.additions(
      for: choice, language: "ru", existing: old + first.categories, budgets: first.budgets,
      tiles: [.monthToDate] + first.tiles, startMonth: month)
    #expect(second.isEmpty)
  }

  /// A name in the other language, another case or with «ё» is the same category.
  @Test func aCategoryOfTheSameNameIsNotDoubled() {
    var old = SampleCatalog.makeCategories(language: "en")
    old.append(CoreKit.Category(kind: .expense, name: "налоги и сборы", archived: true))
    let plan = StarterSets.additions(
      for: StarterChoice(), language: "ru", existing: old, budgets: [], tiles: [],
      startMonth: month)
    #expect(!plan.categories.contains { NameKey.fold($0.name) == "налоги и сборы" })
    #expect(
      !plan.categories.contains { $0.name == "Транспортный налог" },
      "nothing is added under a category in the archive")
  }

  @Test func noLimitOnACategoryThatHasOneOrOnTheAppsOwn() {
    let old = SampleCatalog.makeCategories(language: "en")
    let groceries = old.first { $0.name == "Groceries" }!
    let plan = StarterSets.additions(
      for: StarterChoice(lifestyles: [.family, .alone, .partner]), language: "en", existing: old,
      budgets: [Budget(scope: .category, categoryId: groceries.id, amountE4: AmountE4(raw: 1))],
      tiles: [],
      startMonth: month)
    #expect(!plan.budgets.contains { $0.categoryId == groceries.id })
    let system = Set(old.filter { $0.systemRole != nil }.map(\.id))
    #expect(!plan.budgets.contains { $0.categoryId.map(system.contains) ?? false })
  }

  @Test func tilesAreAddedOnlyWhenNotShownYet() {
    let full = OverviewTile.allCases
    let plan = StarterSets.additions(
      for: StarterChoice(hasLoans: true), language: "en", existing: [], budgets: [], tiles: full,
      startMonth: month)
    #expect(plan.tiles.isEmpty)
    let allButTheLoan = OverviewTile.allCases.filter { $0 != .iOwe }
    let one = StarterSets.additions(
      for: StarterChoice(hasLoans: true), language: "en", existing: [], budgets: [],
      tiles: allButTheLoan, startMonth: month)
    #expect(one.tiles == [.iOwe], "there is no limit: a hidden tile is always shown again")
    let roomy = StarterSets.additions(
      for: StarterChoice(hasLoans: true), language: "en", existing: [], budgets: [],
      tiles: [.monthToDate], startMonth: month)
    #expect(roomy.tiles == [.iOwe])
  }

  @Test func everySetHasBothLanguages() {
    for lifestyle in Lifestyle.allCases {
      for seed in StarterSets.categories(of: lifestyle) {
        #expect(!seed.english.isEmpty && !seed.russian.isEmpty)
      }
    }
  }
}
