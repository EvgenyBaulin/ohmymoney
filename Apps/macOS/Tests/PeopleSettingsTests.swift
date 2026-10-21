import AppCore
import XCTest

@testable import OhMyMoney

/// «Добавить» of the people in Settings → General: a name already in the book adds
/// nothing, and a name the book has in its archive brings that person back rather than making
/// a second row with the same name.
@MainActor
final class PeopleSettingsTests: XCTestCase {
  private let anna = Person(name: "Anna", relation: .friend)
  private let boris = Person(name: "Boris", relation: .family, aliases: ["Borya"], archived: true)

  func testANameOfTheArchiveBringsThatPersonBack() throws {
    let person = try XCTUnwrap(
      GeneralSettingsView.person(toAdd: " boris ", among: [anna, boris]),
      "the archived name added nothing")

    XCTAssertEqual(person.id, boris.id, "a second «Boris» was made next to the archived one")
    XCTAssertFalse(person.archived)
    XCTAssertEqual(person.name, "Boris")
    XCTAssertEqual(person.relation, .family, "the person came back without what he had")
    XCTAssertEqual(person.aliases, ["Borya"])
  }

  func testALiveNameAddsNothing() {
    XCTAssertNil(GeneralSettingsView.person(toAdd: "ANNA", among: [anna, boris]))
    XCTAssertNil(GeneralSettingsView.person(toAdd: "   ", among: [anna, boris]))
  }

  func testANewNameIsANewPerson() throws {
    let person = try XCTUnwrap(GeneralSettingsView.person(toAdd: " Vera ", among: [anna, boris]))
    XCTAssertEqual(person.name, "Vera")
    XCTAssertFalse([anna.id, boris.id].contains(person.id))
  }
}
