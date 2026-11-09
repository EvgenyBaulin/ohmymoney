import CoreKit
import Foundation
import Testing

@testable import CoreSample

@Suite("Starter data in every language")
struct StarterLanguageTests {
  private let month = MonthKey(year: 2026, month: 11)
  private let choice = StarterChoice(lifestyles: Set(Lifestyle.allCases))

  @Test(arguments: StarterLanguage.allCases)
  func completeNamesAndMetadata(_ language: StarterLanguage) {
    let seeds = StarterSets.starterSeeds + Lifestyle.allCases.flatMap(StarterSets.categories)
    for seed in seeds {
      let name = seed.translation(language: language.rawValue)
      #expect(!name.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(name.verification == language.translationVerification)
      if language != .ru && language != .en {
        #expect(StarterCategoryNames.names[language]?[seed.english] == name.text)
      }
    }
    let tree = SampleCatalog.makeCategories(language: language.rawValue, seeds: seeds)
    let keys = tree.map {
      "\($0.kind.rawValue)|\($0.parentId?.uuidString ?? "root")|\(NameKey.fold($0.name))"
    }
    #expect(Set(keys).count == keys.count)
    let lifestyles = Lifestyle.allCases.map { $0.translation(language: language.rawValue) }
    #expect(
      lifestyles.allSatisfy {
        !$0.text.isEmpty && $0.verification == language.translationVerification
      })
    #expect(Set(lifestyles.map(\.text)).count == Lifestyle.allCases.count)
    #expect(Lifestyle.translations[language]?.count == Lifestyle.allCases.count)
    if language != .ru && language != .en {
      #expect(StarterCategoryNames.names[language]?.count == StarterCategoryNames.keys.count)
      #expect(
        StarterCategoryNames.rows[language]?.split(separator: "|").count
          == StarterCategoryNames.keys.count)
    }
  }

  @Test(arguments: StarterLanguage.allCases)
  func findsNamesAcrossLanguageChanges(_ language: StarterLanguage) {
    let original = SampleCatalog.makeCategories(language: language.rawValue)
    let first = StarterSets.additions(
      for: choice, language: language.rawValue, existing: original, budgets: [], tiles: [],
      startMonth: month)
    #expect(!first.categories.isEmpty)
    let all = original + first.categories
    let second = StarterSets.additions(
      for: choice, language: "en", existing: all, budgets: first.budgets, tiles: first.tiles,
      startMonth: month)
    #expect(second.isEmpty)
    let groceries = original.first {
      $0.name == SampleCatalog.categorySeeds[0].translation(language: language.rawValue).text
    }
    #expect(first.budgets.contains { $0.categoryId == groceries?.id })
    let taxes = StarterSets.newDatabaseSeeds[1].translation(language: language.rawValue).text
    var archived = original
    archived.append(CoreKit.Category(kind: .expense, name: taxes.uppercased(), archived: true))
    let plan = StarterSets.additions(
      for: StarterChoice(), language: "en", existing: archived, budgets: [], tiles: [],
      startMonth: month)
    #expect(!plan.categories.contains { $0.name == "Taxes & fees" || $0.name == "Vehicle tax" })
  }

  @Test func languageTagsAndOriginalNames() {
    for (tag, language) in [
      ("pt_BR", StarterLanguage.portugueseBrazil), ("pt-PT", .portuguesePortugal),
      ("zh_TW", .chineseTraditional), ("zh-Hans-CN", .chineseSimplified),
      ("zh-Hant-HK", .chineseTraditional), ("de_DE", .de), ("unknown", .en),
    ] { #expect(StarterLanguage(identifier: tag) == language) }
    for seed in StarterSets.starterSeeds {
      #expect(seed.translation(language: "ru-RU").text == seed.russian)
      #expect(seed.translation(language: "en-US").text == seed.english)
      #expect(seed.translation(language: "unknown").text == seed.english)
    }
    let seeds = StarterSets.starterSeeds
    for language in StarterLanguage.allCases {
      let tree = SampleCatalog.makeCategories(language: language.rawValue, seeds: seeds)
      #expect(tree.map(\.name) == seeds.map { $0.translation(language: language.rawValue).text })
    }
    #expect(StarterLanguage.allCases.count == 31)
  }
}
