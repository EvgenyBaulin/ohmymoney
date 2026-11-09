import CoreKit
import Foundation
import Testing

@testable import CoreParse

@Suite("Entry words in every language")
struct EntryLanguageTests {
  private static let today = DateOnly(year: 2026, month: 11, day: 9)
  private static let accountA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private static let accountB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private static let debt = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
  private static let goal = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

  private func parser(_ language: StarterLanguage) -> InputLineParser {
    let code = EntryLanguageWords.all[language]?.currencyCode ?? "EUR"
    return InputLineParser(
      vocabulary: ParserVocabulary(
        paymentMethods: [
          .init(id: Self.accountA, name: "Alpha"), .init(id: Self.accountB, name: "Beta"),
        ],
        goals: [.init(id: Self.goal, name: "Holiday")],
        debts: [.init(id: Self.debt, name: "Mortgage")],
        enabledCurrencies: [CurrencyCode(code)]), calendar: .utc, language: language.rawValue)
  }

  @Test(arguments: StarterLanguage.allCases)
  func datesTypesAndAmounts(_ language: StarterLanguage) throws {
    let parser = parser(language)
    if let words = EntryLanguageWords.all[language] {
      for (text, offset) in [
        (words.today, 0), (words.yesterday, -1), (words.dayBeforeYesterday, -2),
      ] {
        for date in EntryLanguageWords.alternatives(text) {
          let parsed = parser.parse("\(date) 1 250,50", today: Self.today)
          #expect(parsed.date == CalendarContext.utc.adding(days: offset, to: Self.today))
          #expect(parsed.amount == Decimal(string: "1250.50"))
          #expect(parsed.note.isEmpty)
        }
      }
      for (text, kind) in [
        (words.income, TransactionKind.income), (words.salary, .income),
        (words.expense, .expense), (words.refund, .refund), (words.reimbursement, .reimbursement),
      ] {
        for word in EntryLanguageWords.alternatives(text) {
          let parsed = parser.parse("\(word) 250", today: Self.today)
          #expect(parsed.kind == kind)
          #expect(parsed.amount == 250)
          #expect(parsed.note.isEmpty)
          #expect(parser.read("\(word) 250", today: Self.today).parsed == parsed)
        }
      }
      for word in EntryLanguageWords.alternatives(words.thousand) {
        let spaced = parser.parse("2 \(word)", today: Self.today)
        #expect(spaced.amount == 2000)
        #expect(spaced.note.isEmpty)
        #expect(parser.parse("2\(word)", today: Self.today).amount == 2000)
      }
      for word in EntryLanguageWords.alternatives(words.currency) {
        let parsed = parser.parse("250 \(word)", today: Self.today)
        #expect(parsed.currency == CurrencyCode(words.currencyCode))
        #expect(parsed.amount == 250)
      }
    } else {
      let date = language == .ru ? "вчера" : "yesterday"
      let kind = language == .ru ? "зарплата" : "salary"
      let parsed = parser.parse("\(date) \(kind) 250", today: Self.today)
      #expect(parsed.date == CalendarContext.utc.adding(days: -1, to: Self.today))
      #expect(parsed.kind == .income)
      #expect(parsed.amount == 250)
      #expect(parsed.note.isEmpty)
    }
  }

  @Test(arguments: StarterLanguage.allCases)
  func transferDebtAndGoal(_ language: StarterLanguage) {
    let words = EntryLanguageWords.all[language]
    let parser = parser(language)
    let transfer = words?.transfer ?? (language == .ru ? "перевод" : "transfer")
    for word in EntryLanguageWords.alternatives(transfer) {
      let parsed = parser.parse("\(word) Alpha Beta 250", today: Self.today)
      #expect(parsed.transfer?.fromAccountId == Self.accountA)
      #expect(parsed.transfer?.toAccountId == Self.accountB)
      #expect(parsed.amount == 250)
      #expect(parsed.note.isEmpty)
      // Reversed order still follows explicit direction markers.
      let from = EntryLanguageWords.alternatives(words?.from ?? "from")[0]
      let to = EntryLanguageWords.alternatives(words?.to ?? "to")[0]
      let reversed = parser.parse("\(word) \(to) Beta \(from) Alpha 250", today: Self.today)
      #expect(reversed.transfer?.fromAccountId == Self.accountA)
      #expect(reversed.transfer?.toAccountId == Self.accountB)
    }
    for word in EntryLanguageWords.alternatives(words?.debt ?? "debt") {
      let parsed = parser.parse("\(word) Mortgage 250", today: Self.today)
      #expect(parsed.debtId == Self.debt)
      #expect(parsed.note.isEmpty)
    }
    for word in EntryLanguageWords.alternatives(words?.goal ?? "goal") {
      let parsed = parser.parse("\(word) Holiday 250", today: Self.today)
      #expect(parsed.goalId == Self.goal)
      #expect(parsed.note.isEmpty)
    }
  }

  @Test(arguments: ["ar", "hi", "th", "zh-Hans"])
  func localDigits(_ language: String) {
    let parser = parser(StarterLanguage(identifier: language))
    for amount in ["١٬٢٥٠٫٥٠", "۱۲۵۰٫۵۰", "१२५०.५०", "๑๒๕๐.๕๐", "１２５０.５０"] {
      let parsed = parser.parse(amount, today: Self.today)
      #expect(parsed.amount == Decimal(string: "1250.50"))
      #expect(parsed.note.isEmpty)
    }
  }

  @Test(arguments: [
    ("uk", "вчора дохід 250"), ("be", "учора даход 250"), ("kk", "кеше кіріс 250"),
    ("uz", "kecha daromad 250"), ("ky", "кечээ киреше 250"), ("tg", "дирӯз даромад 250"),
    ("hy", "երեկ եկամուտ 250"), ("ka", "გუშინ შემოსავალი 250"), ("az", "dünən gəlir 250"),
    ("de", "gestern einkommen 250"), ("fr", "hier revenu 250"), ("es", "ayer ingreso 250"),
    ("it", "ieri entrata 250"), ("pt-PT", "ontem rendimento 250"), ("pl", "wczoraj dochód 250"),
    ("cs", "včera příjem 250"), ("nl", "gisteren inkomen 250"), ("tr", "dün gelir 250"),
    ("zh-Hans", "昨天收入250"), ("zh-Hant", "昨天收入250"), ("ja", "昨日収入250"),
    ("ko", "어제수입250"), ("vi", "hôm qua thu nhập 250"), ("id", "kemarin pendapatan 250"),
    ("th", "เมื่อวานรายได้250"), ("hi", "कल आय २५०"), ("pt-BR", "ontem renda 250"),
    ("ar", "أمس دخل ٢٥٠"), ("he", "אתמול הכנסה 250"),
    ("ru", "вчера доход 250"), ("en", "yesterday income 250"),
  ])
  func independentExamples(_ language: String, _ line: String) {
    let parsed = parser(StarterLanguage(identifier: language)).parse(line, today: Self.today)
    #expect(parsed.kind == .income)
    #expect(parsed.date == CalendarContext.utc.adding(days: -1, to: Self.today))
    #expect(parsed.amount == 250)
    #expect(parsed.note.isEmpty)
  }

  @Test func bilingualCompatibilityAndIsolation() {
    let lines = (InputLineParserTests.russian + InputLineParserTests.english).map(\.line)
    let original = InputLineParser(vocabulary: Fixture.vocabulary, calendar: .utc)
    for line in lines {
      for language in ["ru", "en", "en-US", "ru_RU", "unknown"] {
        let parser = InputLineParser(
          vocabulary: Fixture.vocabulary, calendar: .utc, language: language)
        #expect(
          parser.parse(line, today: Fixture.today) == original.parse(line, today: Fixture.today))
        #expect(
          parser.read(line, today: Fixture.today) == original.read(line, today: Fixture.today))
      }
    }
    #expect(original.parse("gestern gehalt 250", today: Self.today).note == "gestern gehalt")
    #expect(EntryLanguageWords.all.count == 29)
    #expect(
      Set(EntryLanguageWords.all.keys) == Set(StarterLanguage.allCases).subtracting([.ru, .en]))
  }
}
