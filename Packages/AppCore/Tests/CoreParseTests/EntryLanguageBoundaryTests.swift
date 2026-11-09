import CoreKit
import CoreParse
import Foundation
import Testing

@Suite("Localized entry boundaries")
struct EntryLanguageBoundaryTests {
  private let today = DateOnly(year: 2026, month: 11, day: 9)

  @Test func amountsKeepTheirOriginalSpelling() {
    for (language, line, amount) in [
      ("ar", "٢٥٠", Decimal(250)), ("de", "2 tausend", Decimal(2000)),
    ] {
      let parsed = InputLineParser(vocabulary: .empty, calendar: .utc, language: language)
        .parse(line, today: today)
      #expect(parsed.amount == amount)
      #expect(parsed.tokens.first { $0.role == .amount }?.text == line)
    }
  }

  @Test func compactKnownNamesWinOverKeywords() {
    let account = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    for (language, name) in [("ja", "給与口座"), ("zh-Hans", "工资卡"), ("th", "เงินเดือนบัญชี")] {
      let parser = InputLineParser(
        vocabulary: ParserVocabulary(paymentMethods: [.init(id: account, name: name)]),
        calendar: .utc, language: language)
      let parsed = parser.parse(name + "250", today: today)
      #expect(parsed.paymentMethodId == account)
      #expect(parsed.kind == .expense)
      #expect(parsed.amount == 250)
      #expect(parsed.note.isEmpty)
    }
  }
}
