import CoreKit
import Foundation
import Testing

@testable import CoreSample

@Suite("Starter marks for existing categories")
struct StarterAppearanceSuggestionsTests {
  @Test func bothNamesMatchWithoutCaseAndOnlyTheAppearanceChanges() {
    let named = CoreKit.Category(
      kind: .expense, name: "пРоДуКтЫ", sort: 7, quality: .good, essential: true)
    let translated = CoreKit.Category(
      kind: .expense, name: "My home",
      translation: CategoryTranslation(english: "hOmE", source: "My home"))
    let result = StarterAppearance.suggestions(for: [named, translated])
    var expected = named
    expected.appearance = CategoryAppearance(icon: "cart", color: "tone1")
    #expect(result.first == expected)
    #expect(result.last?.icon == "house")
    #expect(result.last?.translation == translated.translation)
    #expect(StarterAppearance.suggestions(for: result).isEmpty)
  }

  @Test func ownMarksChildrenUnknownNamesAndWrongKindsAreLeftAlone() {
    let own = CoreKit.Category(
      kind: .expense, name: "Home", appearance: CategoryAppearance(icon: "star", color: nil))
    let future = CoreKit.Category(
      kind: .expense, name: "Home",
      appearance: CategoryAppearance(icon: "future.symbol", color: "tone2"))
    let child = CoreKit.Category(parentId: UUID(), kind: .expense, name: "Home")
    let unknown = CoreKit.Category(kind: .expense, name: "My own category")
    let wrongKind = CoreKit.Category(kind: .income, name: "Groceries")
    let stale = CoreKit.Category(
      kind: .expense, name: "Renamed",
      translation: CategoryTranslation(english: "Home", source: "Old name"))
    #expect(
      StarterAppearance.suggestions(for: [own, future, child, unknown, wrongKind, stale]).isEmpty)
  }

  @Test func everyTopLevelSeedIncludingLifestyleSetsUsesTheStarterTable() {
    let seeds =
      StarterSets.starterSeeds + Lifestyle.allCases.flatMap { StarterSets.categories(of: $0) }
    for seed in seeds where seed.parentEnglish == nil {
      for name in [seed.english.uppercased(), seed.russian.uppercased()] {
        let bare = CoreKit.Category(kind: seed.kind, name: name)
        #expect(StarterAppearance.suggestions(for: [bare]).first?.appearance == seed.appearance)
      }
    }
  }

  @Test func aColourWithoutAnIconAndAnArchivedRootCanReceiveAStarterMark() {
    let bare = CoreKit.Category(
      kind: .expense, name: "Home", archived: true,
      appearance: CategoryAppearance(icon: nil, color: "tone3"))
    #expect(
      StarterAppearance.suggestions(for: [bare]).first?.appearance
        == CategoryAppearance(icon: "house", color: "tone5"))
  }
}
