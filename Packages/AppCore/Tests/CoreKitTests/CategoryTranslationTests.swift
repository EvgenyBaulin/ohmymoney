import Foundation
import Testing

@testable import CoreKit

/// The English name of a category: kept beside the owner's name, valid only for the name it was
/// made of, and only what looks like a name is taken from a translator's answer.
@Suite("Английское название категории")
struct CategoryTranslationTests {
  @Test func theEnglishNameIsOfTheNameItWasMadeOf() {
    var category = Category(
      kind: .expense, name: "Кафе",
      translation: CategoryTranslation(english: "Cafes", source: "Кафе"))
    #expect(category.englishName == "Cafes")
    #expect(category.name == "Кафе", "the owner's name is never replaced")
    category.name = "Кафе и бары"
    #expect(category.englishName == nil, "a renamed category waits for a new English name")
    #expect(Category(kind: .expense, name: "Такси").englishName == nil)
  }

  @Test func whatIsKeptOfAnAnswer() {
    #expect(CategoryTranslation.cleaned("Groceries") == "Groceries")
    #expect(CategoryTranslation.cleaned("  \"Groceries\".  ") == "Groceries")
    #expect(CategoryTranslation.cleaned("«Taxi»") == "Taxi")
    #expect(CategoryTranslation.cleaned("\n\nCoffee shops\nThis is a category of…") == "Coffee shops")
    #expect(CategoryTranslation.cleaned("   ") == nil)
    #expect(CategoryTranslation.cleaned("") == nil)
    #expect(CategoryTranslation.cleaned(String(repeating: "word ", count: 30)) == nil)
  }
}
