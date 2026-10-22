import Testing

@testable import CoreParse

@Suite("Tags in the entry line")
struct TagTextTests {
  @Test func tagsAreTakenOutInTheOrderWritten() {
    let read = TagText.extract(from: "ужин 3500 #отпуск #турция")
    #expect(read.text == "ужин 3500")
    #expect(read.tags == ["отпуск", "турция"])
  }

  @Test func caseDoesNotMakeASecondTag() {
    let read = TagText.extract(from: "#Отпуск кофе 250 #отпуск")
    #expect(read.tags == ["Отпуск"])
    #expect(read.text == "кофе 250")
  }

  @Test func aTagMayBeInTheMiddleAndMayHaveDashAndUnderscore() {
    let read = TagText.extract(from: "подарок #день-рождения_маши 2000")
    #expect(read.tags == ["день-рождения_маши"])
    #expect(read.text == "подарок 2000")
  }

  @Test func punctuationAfterATagIsNotPartOfIt() {
    #expect(TagText.extract(from: "кофе 250 #работа, потом").tags == ["работа"])
  }

  @Test func whatIsNotATagStaysInTheText() {
    for line in ["заказ #1 500", "a#b 100", "кофе # 250", "кофе 250 #", "ключ ##x 10", "кофе #a#b"]
    {
      let read = TagText.extract(from: line)
      #expect(read.tags.isEmpty, "\(line)")
      #expect(read.text == line)
    }
  }

  @Test func englishTagsWork() {
    #expect(TagText.extract(from: "dinner 40 #Trip #trip2026").tags == ["Trip", "trip2026"])
  }

  @Test func aLineWithoutTagsIsUntouched() {
    let read = TagText.extract(from: "кофе   250")
    #expect(read.tags.isEmpty)
    #expect(read.text == "кофе 250", "only the spacing is closed up")
  }
}
