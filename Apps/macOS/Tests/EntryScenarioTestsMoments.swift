import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The moment an operation is written at when the count of its day is answered — «до сверки» a
/// second before it, «после» after it, never into another day even for a count at midnight or a
/// second before it —, and the card of the quick line in the form at the side: «Будет
/// записано: кофе, 300 ₽, …» on the first Return, the write on the second, a transfer told as
/// «A → B», and the latest alike operations offered under the line.
@MainActor
final class EntryScenarioMomentsTests: EntryScenarioCase {
  // MARK: Before or after the count

  func testBeforeTheCountIsASecondBeforeIt() throws {
    let model = book.model()
    try book.enter("кофе 300", into: model)
    let count = book.calendar.moment(book.today, hour: 14, minute: 5)
    model.draft.occurredAt = count.addingTimeInterval(600)
    model.answerCount(count, wasBefore: true)
    XCTAssertLessThan(model.draft.occurredAt, count)
    XCTAssertEqual(book.calendar.day(of: model.draft.occurredAt), book.today)
  }

  func testAfterTheCountIsAfterIt() throws {
    let model = book.model()
    try book.enter("кофе 300", into: model)
    let count = book.calendar.moment(book.today, hour: 14, minute: 5)
    model.draft.occurredAt = count.addingTimeInterval(-600)
    model.answerCount(count, wasBefore: false)
    XCTAssertGreaterThan(model.draft.occurredAt, count)
  }

  func testAPanelTimeAlreadyBeforeTheCountIsKept() throws {
    let model = book.model()
    try book.enter("кофе 300 в 09:00", into: model)
    let set = model.draft.occurredAt
    model.answerCount(book.calendar.moment(book.today, hour: 14, minute: 5), wasBefore: true)
    XCTAssertEqual(model.draft.occurredAt, set)
  }

  func testACountAtMidnightAnsweredBeforeStaysOnItsDay() throws {
    let model = book.model()
    try book.enter("кофе 300", into: model)
    let midnight = book.calendar.startOfDay(book.today)
    model.draft.occurredAt = midnight.addingTimeInterval(3600)
    model.answerCount(midnight, wasBefore: true)
    XCTAssertEqual(book.calendar.day(of: model.draft.occurredAt), book.today)
  }

  func testACountASecondBeforeMidnightAnsweredAfterStaysOnItsDay() throws {
    let model = book.model()
    try book.enter("кофе 300", into: model)
    let late = book.calendar.startOfDay(book.today.adding(days: 1)).addingTimeInterval(-1)
    model.draft.occurredAt = late.addingTimeInterval(-3600)
    model.answerCount(late, wasBefore: false)
    XCTAssertEqual(book.calendar.day(of: model.draft.occurredAt), book.today)
  }

  func testTheStampedMomentIsNotAskedAgain() throws {
    let model = book.model()
    try book.enter("кофе 300", into: model)
    let moment = book.calendar.moment(book.today, hour: 10, minute: 0)
    model.stampCount(moment)
    XCTAssertEqual(model.draft.occurredAt, moment)
    guard case .none = model.countAsk(savedAt: Date(), balances: .empty, remembered: [:]) else {
      return XCTFail("the stamped moment was asked about again")
    }
  }

  // MARK: The quick line

  func testTheFirstReturnShowsTheCardTheSecondWrites() {
    var flow = QuickEntryFlow()
    XCTAssertEqual(flow.submit(lineIsReadable: true), .confirm)
    XCTAssertTrue(flow.confirming)
    XCTAssertEqual(flow.submit(lineIsReadable: true), .save)
    XCTAssertFalse(flow.confirming)
    XCTAssertEqual(flow.submit(lineIsReadable: false), .refuse)
    XCTAssertFalse(flow.confirming)
  }

  func testTheCardSaysWhatWillBeWritten() throws {
    let model = book.model()
    try book.enter("кофе 300 т-банк", into: model)
    model.setCategory(book.coffeeShops.id, forPartAt: 0)
    let text = QuickEntrySummary.text(of: model, environment: book.environment)
    for word in ["кофе", "300", "Кофейни", "Т-Банк"] {
      XCTAssertTrue(text.contains(word), "\(word) in «\(text)»")
    }
  }

  func testTheCardOfATransferNamesBothSides() throws {
    var form = TransferForm(
      from: book.sber, accounts: [book.sber, book.tBank], day: book.today)
    form.chooseTo(book.tBank)
    form.sent = AmountE4(whole: 5_000)
    let text = QuickEntrySummary.text(
      of: form, accounts: [book.sber, book.tBank], environment: book.environment)
    XCTAssertTrue(text.contains("Сбер → Т-Банк"), text)
    var half = TransferForm(from: book.sber, accounts: [book.sber], day: book.today)
    half.sent = AmountE4(whole: 10)
    XCTAssertTrue(
      QuickEntrySummary.text(of: half, accounts: [book.sber], environment: book.environment)
        .contains("Сбер → ?"))
  }

  func testTheSuggestionsAreTheLatestPurchasesOfTheSameWords() throws {
    for (line, category) in [
      ("кофе 250", book.coffeeShops.id), ("кофе 300", book.coffeeShops.id),
      ("кофе 300", book.coffeeShops.id), ("хлеб 60", book.groceries.id),
    ] {
      let model = book.model()
      try book.enter(line, into: model)
      model.setCategory(category, forPartAt: 0)
      model.repeatConfirmed = true
      try book.save(model)
    }
    let lines = QuickEntrySuggestions.lines(
      typed: "ко",
      entries: try book.entries().sorted {
        $0.transaction.createdAt < $1.transaction.createdAt
      }, money: book.environment.money)
    XCTAssertEqual(lines.count, 2, "\(lines)")
    XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("кофе") })
    XCTAssertTrue(
      QuickEntrySuggestions.lines(
        typed: "250", entries: try book.entries(), money: book.environment.money
      ).isEmpty, "a number alone suggests nothing")
  }
}
