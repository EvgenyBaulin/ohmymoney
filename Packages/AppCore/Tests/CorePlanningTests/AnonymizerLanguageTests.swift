import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The neutral words of an anonymized copy follow the language of the interface: Russian for a
/// Russian interface, English for any other.
@Suite("Anonymizer language")
struct AnonymizerLanguageTests {
  let fx = PrivacyFixture()

  @Test("the language of the interface picks the words")
  func languagePicksTheWords() {
    #expect(AnonymizerLabels.forLanguage("ru") == .russian)
    #expect(AnonymizerLabels.forLanguage("ru-RU") == .russian)
    #expect(AnonymizerLabels.forLanguage("RU") == .russian)
    #expect(AnonymizerLabels.forLanguage("en") == .english)
    #expect(AnonymizerLabels.forLanguage("de") == .english)
    #expect(AnonymizerLabels.forLanguage("") == .english)
  }

  @Test("every English word is English and every Russian word Russian")
  func everyWordIsInItsLanguage() {
    let english = Self.words(.english)
    let russian = Self.words(.russian)
    #expect(english.count == russian.count)
    for word in english {
      #expect(!word.isEmpty)
      #expect(word.unicodeScalars.allSatisfy { $0.isASCII }, "\(word)")
    }
    for word in russian {
      #expect(word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }, "\(word)")
    }
    // Two kinds never share a word: «Account 1» must not be both an account and a card.
    #expect(Set(english).count == english.count)
    #expect(Set(russian).count == russian.count)
  }

  @Test("an English copy names every kind in English and keeps the numbering")
  func englishCopy() {
    var data = fx.dataset
    data.people.append(Person(name: "Second Person"))
    let labels = AnonymizerLabels.forLanguage("en")
    let copy = Anonymizer.apply(to: data, labels: labels)
    #expect(copy.people.map(\.name) == ["Person 1", "Person 2"])
    #expect(copy.places.map(\.name).allSatisfy { $0.hasPrefix("Place ") })
    #expect(copy.events.map(\.name).allSatisfy { $0.hasPrefix("Event ") })
    #expect(copy.paymentMethods.map(\.name).allSatisfy { $0.hasPrefix("Account ") })
    #expect(copy.banks.map(\.name).allSatisfy { $0.hasPrefix("Bank ") })
    #expect(copy.cards.map(\.name).allSatisfy { $0.hasPrefix("Card ") })
    #expect(!copy.goals.isEmpty && copy.goals.allSatisfy { $0.name.hasPrefix("Goal ") })
    let cyrillic = Anonymizer.sensitiveTexts(of: copy).filter { text in
      text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
    #expect(cyrillic.isEmpty, "\(cyrillic)")
  }

  @Test("a Russian copy is as it always was")
  func russianCopy() {
    let copy = Anonymizer.apply(to: fx.dataset, labels: AnonymizerLabels.forLanguage("ru"))
    #expect(copy.people.first?.name == "Человек 1")
    #expect(copy.places.first?.name == "Место 1")
    #expect(copy.paymentMethods.first?.name == "Счёт 1")
    let byDefault = Anonymizer.apply(to: fx.dataset)
    #expect(copy.people.map(\.name) == byDefault.people.map(\.name))
    #expect(copy.cards.map(\.name) == byDefault.cards.map(\.name))
  }

  private static func words(_ labels: AnonymizerLabels) -> [String] {
    [
      labels.person, labels.place, labels.event, labels.account, labels.bank,
      labels.accountGroup, labels.card, labels.goal, labels.debt, labels.debtGroup,
      labels.asset, labels.ownedItem, labels.wish, labels.shoppingItem, labels.tag, labels.rule,
      labels.scheduledPayment, labels.expectedIncome, labels.dayNote, labels.eventItem,
      labels.eventTemplate, labels.ruleText,
    ]
  }
}
