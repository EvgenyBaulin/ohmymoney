import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Anonymizer")
struct AnonymizerTests {
  let fx = PrivacyFixture()

  @Test("no marker word of the original survives anywhere in the copy")
  func noWordSurvives() {
    let copy = Anonymizer.apply(to: fx.dataset)
    let printed = String(describing: copy)
    for marker in PrivacyFixture.markers {
      #expect(!printed.contains(marker), "«\(marker)» is still in the copy")
    }
    for text in Anonymizer.sensitiveTexts(of: fx.dataset) {
      #expect(!printed.contains(text), "«\(text)» is still in the copy")
    }
    #expect(!printed.contains("BANK-REF-77"))
    #expect(copy.cards.allSatisfy { $0.last4 == nil && $0.details == nil })
  }

  @Test("the same data gives the same copy")
  func deterministic() {
    let a = Anonymizer.apply(to: fx.dataset)
    let b = Anonymizer.apply(to: fx.dataset)
    #expect(a.people == b.people)
    #expect(a.places == b.places)
    #expect(a.events == b.events)
    #expect(a.paymentMethods == b.paymentMethods)
    #expect(a.entries == b.entries)
    #expect(a.rules == b.rules)
    #expect(a.planning == b.planning)
  }

  @Test("names become numbered neutral words, in the order of the records")
  func neutralNames() {
    var data = fx.dataset
    data.people.append(Person(name: "Second Person"))
    data.places.append(Place(name: "Second Place"))
    let copy = Anonymizer.apply(to: data)
    #expect(copy.people.map(\.name) == ["Человек 1", "Человек 2"])
    #expect(copy.places.map(\.name) == ["Место 1", "Место 2"])
    #expect(copy.events.map(\.name) == ["Событие 1"])
    #expect(copy.paymentMethods.map(\.name) == ["Счёт 1", "Счёт 2"])
    #expect(copy.banks.map(\.name) == ["Банк 1", "Банк 2"])
    #expect(copy.cards.map(\.name) == ["Карта 1", "Карта 2"])
    let english = Anonymizer.apply(to: data, labels: .english)
    #expect(english.people.map(\.name) == ["Person 1", "Person 2"])
  }

  @Test("sums, dates, currencies, kinds and categories do not change")
  func numbersStay() {
    let copy = Anonymizer.apply(to: fx.dataset)
    #expect(copy.entries.count == fx.dataset.entries.count)
    for (before, after) in zip(fx.dataset.entries, copy.entries) {
      #expect(before.transaction.amountE4 == after.transaction.amountE4)
      #expect(before.transaction.amountRubE4 == after.transaction.amountRubE4)
      #expect(before.transaction.occurredAt == after.transaction.occurredAt)
      #expect(before.transaction.currency == after.transaction.currency)
      #expect(before.transaction.kind == after.transaction.kind)
      #expect(before.parts.map(\.categoryId) == after.parts.map(\.categoryId))
      #expect(before.parts.map(\.amountE4) == after.parts.map(\.amountE4))
    }
    #expect(copy.categories == fx.dataset.categories)
    #expect(copy.transfers.map(\.fromAmountE4) == fx.dataset.transfers.map(\.fromAmountE4))
    #expect(copy.transfers.map(\.occurredAt) == fx.dataset.transfers.map(\.occurredAt))
    #expect(copy.goals.map(\.targetE4) == fx.dataset.goals.map(\.targetE4))
    #expect(
      copy.planning.scheduled.map(\.amountE4) == fx.dataset.planning.scheduled.map(\.amountE4))
  }

  @Test("every id and every link between records stays")
  func linksStay() {
    let copy = Anonymizer.apply(to: fx.dataset)
    #expect(copy.entries.map(\.id) == fx.dataset.entries.map(\.id))
    #expect(copy.people.map(\.id) == fx.dataset.people.map(\.id))
    let part = copy.entries[0].parts[0]
    #expect(part.forPersonId == fx.personId)
    #expect(part.eventId == fx.eventId)
    #expect(copy.entries[0].transaction.placeId == fx.placeId)
    #expect(copy.entries[1].parts[0].refundOfPartId == fx.purchasePartId)
    #expect(copy.tagBook.links == fx.dataset.tagBook.links)
    #expect(copy.cards.map(\.accountId) == fx.dataset.cards.map(\.accountId))
    #expect(copy.planning.debtEntries.map(\.debtId) == [fx.debtId])
  }

  @Test("an outside key is dropped and the app's own key stays")
  func externalKeys() {
    let copy = Anonymizer.apply(to: fx.dataset)
    #expect(copy.entries[0].transaction.externalId == nil)
    #expect(copy.entries[1].transaction.externalId == "sched:abc")
    #expect(copy.entries[0].transaction.dedupKey == nil)
  }

  @Test("the text a rule looks for is replaced, its other conditions stay")
  func ruleConditions() {
    let copy = Anonymizer.apply(to: fx.dataset)
    guard case .textContains(let text) = copy.rules[0].conditions[0] else {
      Issue.record("the text condition is gone")
      return
    }
    #expect(!text.lowercased().contains("kiosk"))
    #expect(copy.rules[0].conditions[1] == fx.dataset.rules[0].conditions[1])
    #expect(copy.rules[0].actions == fx.dataset.rules[0].actions)
  }

  @Test("the lists that name things are dropped")
  func droppedLists() {
    let copy = Anonymizer.apply(to: fx.dataset)
    #expect(copy.dismissals.isEmpty)
    #expect(copy.feedback.map(\.text) == [""])
    #expect(copy.dayNotes.map(\.text) == ["Заметка 1"])
  }

  @Test("the original is not touched and the copy has a new version")
  func originalUntouched() {
    let before = fx.dataset
    let copy = Anonymizer.apply(to: before)
    #expect(before.people[0].name == "Marina Ivanova")
    #expect(before.entries[0].transaction.note == "coffee at Kiosk with Marina")
    #expect(copy.version != before.version)
  }

  @Test("a copy of a copy is the same copy")
  func idempotent() {
    let once = Anonymizer.apply(to: fx.dataset)
    let twice = Anonymizer.apply(to: once)
    #expect(once.people == twice.people)
    #expect(once.entries == twice.entries)
    #expect(once.paymentMethods == twice.paymentMethods)
  }

  @Test("the report of covered fields is not empty and names the main ones")
  func coverage() {
    #expect(Anonymizer.coveredFields.contains("transaction.note"))
    #expect(Anonymizer.coveredFields.contains("person.name"))
  }
}
