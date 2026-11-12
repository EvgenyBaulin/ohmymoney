import AppCore
import XCTest

@testable import OhMyMoney

/// «Добавить» of the people in Settings → General: a name that says something always adds a
/// new person; a namesake, live or archived, only gets advice on the screen.
@MainActor
final class PeopleSettingsTests: XCTestCase {
  private let anna = Person(name: "Anna", relation: .friend)
  private let boris = Person(name: "Boris", relation: .family, aliases: ["Borya"], archived: true)

  func testANameOfTheArchiveStillAddsANewPerson() throws {
    let person = try XCTUnwrap(
      GeneralSettingsView.person(toAdd: " boris ", among: [anna, boris]),
      "the archived name added nothing")

    XCTAssertNotEqual(person.id, boris.id, "the archived person came back without being asked")
    XCTAssertFalse(person.archived)
    XCTAssertEqual(person.name, "boris")
    XCTAssertEqual(person.relation, .other)
    XCTAssertTrue(person.aliases.isEmpty)
  }

  func testALiveNameStillAddsANewPersonAndAnEmptyOneNothing() throws {
    XCTAssertNotEqual(
      try XCTUnwrap(GeneralSettingsView.person(toAdd: "ANNA", among: [anna, boris])).id, anna.id)
    XCTAssertNil(GeneralSettingsView.person(toAdd: "   ", among: [anna, boris]))
  }

  func testANewNameIsANewPerson() throws {
    let person = try XCTUnwrap(GeneralSettingsView.person(toAdd: " Vera ", among: [anna, boris]))
    XCTAssertEqual(person.name, "Vera")
    XCTAssertFalse([anna.id, boris.id].contains(person.id))
  }
}
