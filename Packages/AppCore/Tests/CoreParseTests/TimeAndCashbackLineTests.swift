import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// `InputLineParser.read` reads, on top of everything `parse` reads, the time of day — «в
/// 18:09», "at 6:09pm" — and the cashback the bank gave — «кэшбек 9.76», "cashback 3%". Both
/// leave the note, and neither is ever the amount. `parse` keeps reading the line as it always
/// did. «Today» is 18 September 2026.
@Suite("The time of day and the cashback in the entry line")
struct TimeAndCashbackLineTests {
  static func read(_ line: String, kind: TransactionKind? = nil) -> InputLineReading {
    Fixture.parser.read(line, today: Fixture.today, kind: kind)
  }

  // MARK: - The owner's line

  @Test("«груша вчера в 18:09 325 кэшбек 9.76»: amount, day, time, cashback and the note")
  func theOwnersLine() {
    let reading = Self.read("груша вчера в 18:09 325 кэшбек 9.76")
    #expect(reading.parsed.amount == dec("325"))
    #expect(reading.parsed.date == DateOnly(year: 2026, month: 9, day: 17))
    #expect(reading.timeOfDay == TimeOfDay(hour: 18, minute: 9))
    #expect(reading.cashback == .amount(dec("9.76")))
    #expect(reading.parsed.note == "груша")
    #expect(reading.timeProblem == nil)
    #expect(reading.isSaveable)
    #expect(reading.timePhrase == "в 18:09")
    #expect(reading.cashbackPhrase == "кэшбек 9.76")
  }

  // MARK: - Time of day

  struct TimeCase: Sendable, CustomTestStringConvertible {
    let line: String
    let hour: Int
    let minute: Int
    let amount: String
    let date: DateOnly?
    let note: String
    var testDescription: String { line }
  }

  static let yesterday = DateOnly(year: 2026, month: 9, day: 17)
  static let today = DateOnly(year: 2026, month: 9, day: 18)

  @Test(
    "A time of day is read with a day word, a written day or alone",
    arguments: [
      TimeCase(
        line: "кофе вчера в 18:09 250", hour: 18, minute: 9, amount: "250", date: yesterday,
        note: "кофе"),
      TimeCase(
        line: "кофе в 9:30 250", hour: 9, minute: 30, amount: "250", date: nil, note: "кофе"),
      TimeCase(
        line: "кофе 18:09 250", hour: 18, minute: 9, amount: "250", date: nil, note: "кофе"),
      TimeCase(
        line: "кофе 250 сегодня в 07:05", hour: 7, minute: 5, amount: "250", date: today,
        note: "кофе"),
      TimeCase(
        line: "обед 12.09 в 13:45 900", hour: 13, minute: 45, amount: "900",
        date: DateOnly(year: 2026, month: 9, day: 12), note: "обед"),
      TimeCase(
        line: "обед 500 в 12:30", hour: 12, minute: 30, amount: "500", date: nil, note: "обед"),
      TimeCase(
        line: "coffee yesterday at 6:09pm 250", hour: 18, minute: 9, amount: "250",
        date: yesterday, note: "coffee"),
      TimeCase(
        line: "coffee at 18:09 250", hour: 18, minute: 9, amount: "250", date: nil,
        note: "coffee"),
      TimeCase(
        line: "coffee 250 at 9am", hour: 9, minute: 0, amount: "250", date: nil, note: "coffee"),
      TimeCase(
        line: "taxi 700 at 11:45pm", hour: 23, minute: 45, amount: "700", date: nil,
        note: "taxi"),
      TimeCase(
        line: "taxi 700 at 12am", hour: 0, minute: 0, amount: "700", date: nil, note: "taxi"),
      TimeCase(
        line: "lunch today 12pm 900", hour: 12, minute: 0, amount: "900", date: today,
        note: "lunch"),
      TimeCase(
        line: "taxi 700 at 6:30 pm", hour: 18, minute: 30, amount: "700", date: nil,
        note: "taxi"),
      TimeCase(
        line: "кофе 0:00 250", hour: 0, minute: 0, amount: "250", date: nil, note: "кофе"),
      TimeCase(
        line: "кофе 23:59, 250", hour: 23, minute: 59, amount: "250", date: nil, note: "кофе"),
    ])
  func aTimeOfDayIsRead(_ example: TimeCase) {
    let reading = Self.read(example.line)
    #expect(reading.timeOfDay == TimeOfDay(hour: example.hour, minute: example.minute))
    #expect(reading.timeProblem == nil)
    #expect(reading.parsed.amount == dec(example.amount))
    #expect(reading.parsed.date == example.date)
    #expect(reading.parsed.note == example.note)
  }

  @Test("A time is never the amount, even when it is the only number of the line")
  func aTimeIsNeverTheAmount() {
    let alone = Self.read("кофе в 18:09")
    #expect(alone.timeOfDay == TimeOfDay(hour: 18, minute: 9))
    #expect(alone.parsed.amount == nil)
    #expect(alone.parsed.note == "кофе")
    #expect(!alone.isSaveable)

    let first = Self.read("18:09 кофе 250")
    #expect(first.parsed.amount == dec("250"))
    #expect(first.timeOfDay == TimeOfDay(hour: 18, minute: 9))
  }

  @Test(
    "A clock-shaped word with an hour or a minute no clock has is refused with the word",
    arguments: [
      ("кофе 250 в 25:00", "25:00"), ("кофе 18:61 250", "18:61"), ("кофе 24:00 250", "24:00"),
      ("taxi 700 at 13pm", "13pm"), ("taxi 700 at 0am", "0am"),
      ("taxi 700 at 11:75pm", "11:75pm"),
    ])
  func anImpossibleTimeIsRefused(_ line: String, _ written: String) {
    let reading = Self.read(line)
    #expect(reading.timeOfDay == nil)
    #expect(reading.timeProblem == written)
    #expect(!reading.isSaveable)
    #expect(reading.parsed.amount != nil)
    #expect(!reading.parsed.note.contains(written))
  }

  @Test(
    "Words that only look a little like a time stay what they were",
    arguments: [
      // One digit after the colon, three parts, three digits: no clock writes them so.
      ("кофе 2:1 250", "кофе 2:1"), ("кофе 18:09:30 250", "кофе 18:09:30"),
      ("кофе 180:09 250", "кофе 180:09"),
    ])
  func notATime(_ line: String, _ note: String) {
    let reading = Self.read(line)
    #expect(reading.timeOfDay == nil)
    #expect(reading.timeProblem == nil)
    #expect(reading.parsed.note == note)
  }

  @Test("A place behind «в» is still a place when a time stands elsewhere")
  func aPlaceAndATime() {
    let reading = Self.read("кофе в Пятёрочке в 18:09 250")
    #expect(reading.parsed.placeId == Fixture.pyaterochka)
    #expect(reading.timeOfDay == TimeOfDay(hour: 18, minute: 9))
    #expect(reading.parsed.note == "кофе")

    let unknown = Self.read("кофе в 18:09 в Кофемании 250")
    #expect(unknown.parsed.unknownPlaceName == "Кофемании")
    #expect(unknown.timeOfDay == TimeOfDay(hour: 18, minute: 9))
  }

  @Test("The time is a token of the date role, with its marker")
  func theTimeToken() {
    let reading = Self.read("кофе в 18:09 250")
    #expect(reading.parsed.tokens.contains(ParsedToken(role: .date, text: "в 18:09")))
  }

  // MARK: - Cashback

  struct CashbackCase: Sendable, CustomTestStringConvertible {
    let line: String
    let cashback: CashbackReading
    let amount: String
    let note: String
    var testDescription: String { line }
  }

  @Test(
    "The cashback is read after its word, by the rules of amounts",
    arguments: [
      CashbackCase(
        line: "груша 325 кэшбек 9.76", cashback: .amount(dec("9.76")), amount: "325",
        note: "груша"),
      CashbackCase(
        line: "груша 325 кэшбэк 9,76", cashback: .amount(dec("9.76")), amount: "325",
        note: "груша"),
      CashbackCase(
        line: "кешбек 10 груша 325", cashback: .amount(dec("10")), amount: "325", note: "груша"),
      CashbackCase(
        line: "кешбэк: 10, груша 325", cashback: .amount(dec("10")), amount: "325",
        note: "груша"),
      CashbackCase(
        line: "pear 325 cashback 9.76", cashback: .amount(dec("9.76")), amount: "325",
        note: "pear"),
      CashbackCase(
        line: "телевизор 45000 кэшбэк 1,350", cashback: .amount(dec("1350")), amount: "45000",
        note: "телевизор"),
      CashbackCase(
        line: "телевизор 45000 кэшбэк 1,5к", cashback: .amount(dec("1500")), amount: "45000",
        note: "телевизор"),
      CashbackCase(
        line: "груша 325 кэшбек 3%", cashback: .percent(dec("3")), amount: "325",
        note: "груша"),
      CashbackCase(
        line: "груша 325 кэшбек 1,5 %", cashback: .percent(dec("1.5")), amount: "325",
        note: "груша"),
      CashbackCase(
        line: "pear 325 cashback 5 percent", cashback: .percent(dec("5")), amount: "325",
        note: "pear"),
      CashbackCase(
        line: "груша 325 кэшбек 7 процентов", cashback: .percent(dec("7")), amount: "325",
        note: "груша"),
      // A percent can never be the amount, so it is read even before it.
      CashbackCase(
        line: "кэшбек 5% груша 325", cashback: .percent(dec("5")), amount: "325",
        note: "груша"),
      // A day-shaped number behind the word is the cashback, not the day.
      CashbackCase(
        line: "груша 325 кэшбек 3.10", cashback: .amount(dec("3.10")), amount: "325",
        note: "груша"),
    ])
  func theCashbackIsRead(_ example: CashbackCase) {
    let reading = Self.read(example.line)
    #expect(reading.cashback == example.cashback)
    #expect(reading.parsed.amount == dec(example.amount))
    #expect(reading.parsed.note == example.note)
    #expect(reading.parsed.date == nil)
  }

  /// "cash back" is two words; a name the dictionary knows comes first, so with an account
  /// called "Cash" its first word is the account, as in every other line.
  @Test("\"cash back\" in two words")
  func cashBackInTwoWords() {
    let bare = InputLineParser(vocabulary: .empty, calendar: .utc)
      .read("pear 325 cash back 9.76", today: Fixture.today)
    #expect(bare.cashback == .amount(dec("9.76")))
    #expect(bare.parsed.amount == dec("325"))
    #expect(bare.parsed.note == "pear")

    let withCash = Self.read("pear 325 cash back 9.76")
    #expect(withCash.parsed.paymentMethodId == Fixture.cash)
    #expect(withCash.cashback == nil)
    #expect(withCash.parsed.amount == dec("325"))
  }

  @Test(
    "The cashback word without a number of its own stays in the note",
    arguments: [
      ("груша 325 кэшбек", "груша кэшбек"), ("кэшбек груша 325", "кэшбек груша"),
      ("pear 325 cashback", "pear cashback"),
    ])
  func theWordAloneStays(_ line: String, _ note: String) {
    let reading = Self.read(line)
    #expect(reading.cashback == nil)
    #expect(reading.parsed.amount == dec("325"))
    #expect(reading.parsed.note == note)
  }

  @Test("The only number behind the word is the amount: the line is the cashback that came")
  func theOnlyNumberIsTheAmount() {
    let alone = Self.read("кэшбэк 250")
    #expect(alone.cashback == nil)
    #expect(alone.parsed.amount == dec("250"))
    #expect(alone.parsed.note == "кэшбэк")

    let signed = Self.read("кэшбэк +250")
    #expect(signed.cashback == nil)
    #expect(signed.parsed.kind == .income)
    #expect(signed.parsed.amount == dec("250"))

    let glued = Self.read("+кэшбэк 250 вчера")
    #expect(glued.cashback == nil)
    #expect(glued.parsed.kind == .income)
    #expect(glued.parsed.amount == dec("250"))
  }

  @Test("Income and money back have no cashback: the word and its number stay as they were")
  func incomeHasNoCashback() {
    let income = Self.read("+ зарплата 100000 кэшбэк 50")
    #expect(income.cashback == nil)
    #expect(income.parsed.amount == dec("100000"))

    let panel = Self.read("кэшбэк 50 сбер 300", kind: .income)
    #expect(panel.cashback == nil)
  }

  @Test(
    "A cashback number no cashback can be stays where it was",
    arguments: [
      // Zero, a percent above a hundred, a sign in front.
      ("груша 325 кэшбек 0", "груша кэшбек 0"),
      ("груша 325 кэшбек 150%", "груша кэшбек 150%"),
      ("груша 325 кэшбек -5", "груша кэшбек -5"),
    ])
  func anImpossibleCashbackIsNotRead(_ line: String, _ note: String) {
    let reading = Self.read(line)
    #expect(reading.cashback == nil)
    #expect(reading.parsed.amount == dec("325"))
    #expect(reading.parsed.note == note)
  }

  @Test("The time and the cashback together, in English")
  func togetherInEnglish() {
    let reading = Self.read("pear yesterday at 6:09pm 325 cashback 9.76")
    #expect(reading.parsed.amount == dec("325"))
    #expect(reading.parsed.date == Self.yesterday)
    #expect(reading.timeOfDay == TimeOfDay(hour: 18, minute: 9))
    #expect(reading.cashback == .amount(dec("9.76")))
    #expect(reading.parsed.note == "pear")
  }

  // MARK: - `parse` is unchanged

  @Test("`parse` reads neither: its note and amount are what they always were")
  func parseIsUnchanged() {
    let parsed = Fixture.parse("груша вчера в 18:09 325 кэшбек 9.76")
    #expect(parsed.amount == dec("325"))
    #expect(parsed.note == "груша в 18:09 кэшбек 9.76")
    let reading = Self.read("груша 325")
    #expect(reading.parsed == Fixture.parse("груша 325"))
  }
}
