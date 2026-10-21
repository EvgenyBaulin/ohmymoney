import CoreKit
import Foundation
import Testing

@testable import CoreSample

@Suite("Starter categories: system roles, default qualities, one tree in both languages")
struct SampleCatalogTests {
  @Test func systemRolesArePresentForBothKinds() {
    let categories = SampleCatalog.makeCategories(language: "en")
    let roles = Set(categories.compactMap(\.systemRole))
    #expect(roles == Set<SystemRole>([.goals, .loans, .unknown, .surcharges]))

    #expect(categories.contains { $0.systemRole == .goals && $0.kind == .expense })
    #expect(categories.contains { $0.systemRole == .loans && $0.kind == .expense })
    #expect(categories.contains { $0.systemRole == .unknown && $0.kind == .expense })
    #expect(categories.contains { $0.systemRole == .unknown && $0.kind == .income })
    #expect(categories.contains { $0.systemRole == .surcharges && $0.kind == .income })
  }

  @Test func defaultQualitiesOfTheStarterCategories() {
    let categories = SampleCatalog.makeCategories(language: "en")
    func quality(_ english: String) -> Quality? {
      categories.first { $0.kind == .expense && $0.name == english }?.quality
    }

    // good — Goals (locked), Education, Health.
    #expect(quality("Goals") == .good)
    #expect(quality("Education") == .good)
    #expect(quality("Health") == .good)

    // bad — Car → Fines, Other → Fees.
    #expect(quality("Fines") == .bad)
    #expect(quality("Fees") == .bad)

    // Everything else on a top-level expense category defaults to neutral.
    #expect(quality("Groceries") == .neutral)
    #expect(quality("Car") == .neutral)
    #expect(quality("Loans") == .neutral)
    #expect(quality("Unknown") == .neutral)

    // Income never carries a quality («У доходов оценки нет»).
    for category in categories where category.kind == .income {
      #expect(category.quality == nil)
    }
  }

  @Test func subcategoriesHaveAParentAndInheritQualityWhenNotOverridden() {
    let categories = SampleCatalog.makeCategories(language: "en")
    let byId = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })

    for seed in SampleCatalog.categorySeeds where seed.parentEnglish != nil {
      guard
        let category = categories.first(where: { $0.kind == seed.kind && $0.name == seed.english }
        )
      else {
        Issue.record("missing generated category for seed \(seed.english)")
        continue
      }
      guard let parentId = category.parentId else {
        Issue.record("\(seed.english) has no parentId")
        continue
      }
      #expect(byId[parentId] != nil)
      if seed.quality == nil {
        #expect(category.quality == nil, "\(seed.english) should inherit its parent's quality")
      } else {
        #expect(category.quality == seed.quality)
      }
    }
  }

  @Test func topLevelCategoriesHaveNoParent() {
    let categories = SampleCatalog.makeCategories(language: "en")
    for seed in SampleCatalog.categorySeeds where seed.parentEnglish == nil {
      let category = categories.first { $0.kind == seed.kind && $0.name == seed.english }
      #expect(category?.parentId == nil)
    }
  }

  @Test func sortIsZeroBasedAndConsecutivePerParent() {
    let categories = SampleCatalog.makeCategories(language: "en")
    // Top-level categories of both kinds share `parentId == nil`, so group by kind too —
    // expense and income each number their top-level categories from zero independently.
    struct GroupKey: Hashable { let kind: CategoryKind; let parentId: UUID? }
    let grouped = Dictionary(
      grouping: categories, by: { GroupKey(kind: $0.kind, parentId: $0.parentId) })
    for (_, siblings) in grouped {
      let sorts = siblings.map(\.sort).sorted()
      #expect(sorts == Array(0..<siblings.count))
    }
  }

  @Test func englishAndRussianTreesShareTheSameStructure() {
    let english = SampleCatalog.makeCategories(language: "en")
    let russian = SampleCatalog.makeCategories(language: "ru")
    #expect(english.count == russian.count)

    for (enCategory, ruCategory) in zip(english, russian) {
      #expect(enCategory.kind == ruCategory.kind)
      #expect(enCategory.sort == ruCategory.sort)
      #expect(enCategory.systemRole == ruCategory.systemRole)
      #expect(enCategory.quality == ruCategory.quality)
      #expect((enCategory.parentId == nil) == (ruCategory.parentId == nil))
      #expect(enCategory.name != ruCategory.name)
    }
  }

  @Test func idGeneratorIsUsedForEveryCategory() {
    var calls = 0
    let categories = SampleCatalog.makeCategories(language: "en") {
      calls += 1
      return UUID()
    }
    #expect(calls == categories.count)
    #expect(calls == SampleCatalog.categorySeeds.count)
  }
}
