import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

/// The time of day and the cashback the entry line reads: «груша вчера в 18:09 325 кэшбек 9.76»
/// is 325 yesterday at 18:09 with 9.76 of cashback, described «груша»; a time no clock shows is
/// refused with the word; an operation without a cashback keeps the words in its note.
@MainActor
final class EntryLineTimeCashbackTests: XCTestCase {
  private var host: EntryHost?

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  private func interpreter(_ environment: AppEnvironment) -> CoreLineInterpreter {
    CoreLineInterpreter(vocabulary: environment.vocabulary, calendar: environment.calendar)
  }

  /// The owner's own line, typed and saved with Return.
  func testTheOwnersLineSavesTimeAmountCashbackAndWords() async throws {
    let host = try await EntryHost(opensDetails: false) { try EntryHost.history("груша", in: $0) }
    self.host = host
    let line = "груша вчера в 18:09 325 кэшбек 9.76"
    try host.type(line, into: try host.line()).insertNewline(nil)
    host.settle()

    let saved = try XCTUnwrap(
      try host.transactions.recentEntries(limit: 5).first {
        $0.transaction.amountE4 == AmountE4(whole: 325)
      }, "the line was saved")
    let calendar = host.environment.calendar
    let yesterday = calendar.adding(days: -1, to: host.environment.today)
    XCTAssertEqual(
      saved.transaction.occurredAt, calendar.moment(yesterday, hour: 18, minute: 9),
      "yesterday at 18:09")
    XCTAssertEqual(saved.transaction.note, "груша")
    XCTAssertEqual(
      saved.transaction.cashback?.amount, try AmountE4(decimal: Decimal(string: "9.76")!))
  }

  /// «в 25:00»: nothing is saved, and the caption names the time.
  func testATimeNoClockShowsIsRefused() async throws {
    let host = try await EntryHost(opensDetails: false) { try EntryHost.history("кофе", in: $0) }
    self.host = host
    try host.type("кофе в 25:00 300", into: try host.line()).insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 1, "only the operation of the history")
    XCTAssertEqual(try host.line().stringValue, "кофе в 25:00 300", "the line stays to correct")
    let reading = interpreter(host.environment).read(
      "кофе в 25:00 300", today: host.environment.today, kind: nil)
    XCTAssertEqual(reading.timeProblem, "25:00")
    XCTAssertTrue(
      EntryLineMessage.time("25:00").text(host.environment).contains("25:00"))
    XCTAssertTrue(EntryLineMessage.time("25:00").isError)
  }

  /// Both languages say it.
  func testTheRefusalIsWordedInBothLanguages() {
    func phrase(_ language: String) -> String? {
      Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))?
        .localizedString(forKey: "entry.error.noSuchTime", value: nil, table: "Entry")
    }
    XCTAssertEqual(phrase("ru").map { String(format: $0, "25:00") }, "Такого времени нет: 25:00")
    XCTAssertEqual(
      phrase("en").map { String(format: $0, "25:00") }, "There is no such time: 25:00")
  }

  /// A percent goes into «Кэшбэк» as typed there, and the operation earns it in money by the
  /// account's rounding.
  func testAPercentOfCashbackIsTheFieldsPercent() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let model = EntryDraftModel(environment: host.environment)
    model.reload()
    model.prepareForPanel(today: host.environment.today)
    let reading = interpreter(host.environment).read(
      "кофе 300 кэшбек 3%", today: host.environment.today, kind: nil)
    model.apply(
      reading, amount: AmountE4(whole: 300), today: host.environment.today, text: "кофе 300")
    XCTAssertTrue(model.showsCashback, "a purchase on the main account has a cashback")
    XCTAssertEqual(model.cashbackField.text, "3%")
    XCTAssertEqual(model.draft.cashback?.amount, AmountE4(whole: 9))
    XCTAssertEqual(model.draft.note, "кофе")

    // The next line without the word takes the figure back; one typed in the panel stays.
    let plain = interpreter(host.environment).read(
      "кофе 300", today: host.environment.today, kind: nil)
    model.apply(plain, amount: AmountE4(whole: 300), today: host.environment.today)
    XCTAssertEqual(model.cashbackField.text, "")
    model.cashbackField.text = "5"
    model.apply(reading, amount: AmountE4(whole: 300), today: host.environment.today)
    XCTAssertEqual(model.cashbackField.text, "5", "the panel's figure is the owner's")
  }

  /// An operation that has no cashback gets the words back in its note.
  func testAnOperationWithoutCashbackKeepsTheWordsInItsNote() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let model = EntryDraftModel(environment: host.environment)
    model.reload()
    model.prepareForPanel(today: host.environment.today)
    var reading = interpreter(host.environment).read(
      "+5000 премия", today: host.environment.today, kind: nil)
    reading.cashback = .amount(50)
    reading.cashbackPhrase = "кэшбек 50"
    model.apply(reading, amount: AmountE4(whole: 5000), today: host.environment.today)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertEqual(model.cashbackField.text, "")
    XCTAssertEqual(model.draft.note, "премия кэшбек 50")
  }

  /// A time of today: the moment is that time today, and a line without it follows the clock
  /// again.
  func testATimeOfTodaySetsTheMoment() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let environment = host.environment
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.prepareForPanel(today: environment.today)
    let reading = interpreter(environment).read(
      "чай в 7:05 120", today: environment.today, kind: nil)
    XCTAssertEqual(reading.timeOfDay, TimeOfDay(hour: 7, minute: 5))
    model.apply(reading, amount: AmountE4(whole: 120), today: environment.today, whileTyping: true)
    XCTAssertEqual(
      model.draft.occurredAt, environment.calendar.moment(environment.today, hour: 7, minute: 5))
    let without = interpreter(environment).read("чай 120", today: environment.today, kind: nil)
    model.apply(without, amount: AmountE4(whole: 120), today: environment.today, whileTyping: true)
    XCTAssertEqual(model.draft.occurredAt.timeIntervalSinceNow, 0, accuracy: 60)
  }
}
