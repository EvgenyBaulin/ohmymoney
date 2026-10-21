import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// Незнакомое имя после «для» / «в» уходит из описания, но разбор отдаёт и сами слова, как они
/// набраны: приложение возвращает их в описание, пока из имени ничего не заведено.
@Suite("Незнакомые имена в строке")
struct InputLineUnknownNamesTests {
  @Test("Место за «в» / «at» отдаётся вместе с предлогом")
  func anUnknownPlaceComesWithItsMarker() {
    let russian = Fixture.parse("кофе 300 в Кофемании")
    #expect(russian.unknownPlaceName == "Кофемании")
    #expect(russian.unknownPlacePhrase == "в Кофемании")
    #expect(russian.note == "кофе")

    let english = Fixture.parse("lunch 500 at Kofemania.")
    #expect(english.unknownPlaceName == "Kofemania")
    #expect(english.unknownPlacePhrase == "at Kofemania")
  }

  @Test("Человек за «для» / «for» отдаётся вместе с предлогом")
  func anUnknownPersonComesWithItsMarker() {
    let russian = Fixture.parse("обед 700 для Пети")
    #expect(russian.unknownPersonName == "Пети")
    #expect(russian.unknownPersonPhrase == "для Пети")

    let english = Fixture.parse("gift 700 For Peter,")
    #expect(english.unknownPersonName == "Peter")
    #expect(english.unknownPersonPhrase == "For Peter")
  }

  /// Притяжательное слово или артикль между маркером и именем уходит из описания вместе с
  /// маркером, поэтому и в набранных словах оно есть: иначе «в нашей столовой» вернулось бы в
  /// описание как «в столовой».
  @Test("Слово между маркером и именем отдаётся вместе с ними")
  func aPossessiveBetweenTheMarkerAndTheNameComesWithThem() {
    let ritz = Fixture.parse("dinner 3000 at the Ritz")
    #expect(ritz.unknownPlaceName == "Ritz")
    #expect(ritz.unknownPlacePhrase == "at the Ritz")

    let canteen = Fixture.parse("обед 500 в нашей столовой")
    #expect(canteen.unknownPlacePhrase == "в нашей столовой")

    let petya = Fixture.parse("подарок 700 для моего Пети")
    #expect(petya.unknownPersonName == "Пети")
    #expect(petya.unknownPersonPhrase == "для моего Пети")
  }

  @Test("Известное имя слов не отдаёт")
  func aKnownNameHasNoPhrase() {
    let result = Fixture.parse("coffee 250 at Starbucks для Ани")
    #expect(result.unknownPlacePhrase == nil)
    #expect(result.unknownPersonPhrase == nil)
  }
}
