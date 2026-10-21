import Foundation
import Testing

@testable import CoreKit

/// A name as names are compared: «Отпуск» and «отпуск», «Ёлка» and «елка», « Сбер » and «Сбер»
/// are one name; anything else stays a name of its own.
@Suite("Names compared as the entry line compares them")
struct NameKeyTests {
  /// The case does not count, in either alphabet.
  @Test func theCaseDoesNotCount() {
    #expect(NameKey.fold("Отпуск") == NameKey.fold("отпуск"))
    #expect(NameKey.fold("ОТПУСК") == "отпуск")
    #expect(NameKey.fold("Trip") == NameKey.fold("TRIP"))
    #expect(NameKey.fold("Trip") == "trip")
  }

  /// «ё» is «е», whatever its case.
  @Test func yoIsYe() {
    #expect(NameKey.fold("Ёлка") == "елка")
    #expect(NameKey.fold("ёлка") == NameKey.fold("Елка"))
    #expect(NameKey.fold("Лёша") == "леша")
  }

  /// The spaces around a name do not count; the spaces inside it do.
  @Test func onlyTheSpacesAroundItGo() {
    #expect(NameKey.fold("  Сбер ") == "сбер")
    #expect(NameKey.fold("\tСбер") == "сбер")
    #expect(NameKey.fold("Т Банк") == "т банк")
    #expect(NameKey.fold("Т Банк") != NameKey.fold("ТБанк"))
    #expect(NameKey.fold("Т  Банк") != NameKey.fold("Т Банк"))
  }

  /// Different names stay different; an empty name and one of spaces fold to nothing.
  @Test func otherNamesStayApart() {
    #expect(NameKey.fold("Отпуск") != NameKey.fold("Отпуски"))
    #expect(NameKey.fold("Е") != NameKey.fold("Э"))
    #expect(NameKey.fold("") == "")
    #expect(NameKey.fold("   ") == "")
  }

  /// Folding twice changes nothing more: a key is its own key.
  @Test(arguments: ["Отпуск", " Ёлка ", "Т-Банк", "Cash", "Лёша и Ёжик", ""])
  func aKeyIsItsOwnKey(_ name: String) {
    let key = NameKey.fold(name)
    #expect(NameKey.fold(key) == key)
  }
}
