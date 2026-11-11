import Foundation
import Testing

@testable import CoreKit

// Synthetic data only.

@Suite("The mark of a category")
struct CategoryAppearanceTests {
  @Test func theIconListHasNoDuplicatesAndIsNotEmpty() {
    #expect(!CategoryIcon.all.isEmpty)
    #expect(Set(CategoryIcon.all).count == CategoryIcon.all.count)
  }

  @Test func onlyAListedSymbolIsKnown() {
    #expect(CategoryIcon.known("cart") == "cart")
    #expect(CategoryIcon.known("not.a.symbol") == nil)
    #expect(CategoryIcon.known("") == nil)
    #expect(CategoryIcon.known(nil) == nil)
  }

  @Test func aToneIsReadFromItsKeyAndAnUnknownKeyIsNone() {
    for tone in CategoryTone.allCases {
      #expect(CategoryTone(key: tone.key) == tone)
    }
    #expect(CategoryTone(key: "#FF0000") == nil, "a colour value is never a key")
    #expect(CategoryTone(key: "tone9") == nil)
    #expect(CategoryTone(key: nil) == nil)
  }

  @Test func theToneKeysAreTheStoredWords() {
    #expect(
      CategoryTone.allCases.map(\.key)
        == ["accent", "tone1", "tone2", "tone3", "tone4", "tone5", "neutral"])
    #expect(Set(CategoryTone.allCases.map(\.nameKey)).count == CategoryTone.allCases.count)
  }

  @Test func aCategoryHoldsItsMarkAsTwoOptionalFields() throws {
    var category = Category(kind: .expense, name: "Еда")
    #expect(category.appearance.isEmpty)
    category.appearance = CategoryAppearance(icon: "cart", color: "tone1")
    #expect(category.icon == "cart" && category.color == "tone1")
    let data = try JSONEncoder().encode(category)
    #expect(try JSONDecoder().decode(Category.self, from: data) == category)
  }

  @Test func aCategorySavedBeforeTheMarkExistedStillDecodes() throws {
    let plain = Category(kind: .expense, name: "Еда")
    var object =
      try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
    object["icon"] = nil
    object["color"] = nil
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(Category.self, from: data) == plain)
  }
}
