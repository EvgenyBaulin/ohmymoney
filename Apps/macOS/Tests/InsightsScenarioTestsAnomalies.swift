import AppCore
import XCTest

@testable import OhMyMoney

/// «Стоит посмотреть» on books written by hand: a large expense against its category's steady
/// threshold and the ten operations it needs, a possible duplicate within ten minutes (and an
/// invented noon that is no time), a part for somebody else waiting more than thirty days, a
/// week of a category or of bad spending over eight usual weeks, the three sensitivities, and
/// «Это нормально» hiding exactly the pair it names.
final class InsightsScenarioAnomaliesTests: XCTestCase {
  private func rub(_ value: Int64) -> AmountE4 { AmountE4(whole: value) }

  private func report(
    _ book: InsightsBook, today: DateOnly = .d(9, 16), dismissals: [AnomalyDismissal] = [],
    sensitivity: AnomalySensitivity = .normal
  ) -> AnomalyReport {
    AnomalyRules.build(
      ledger: book.ledger, today: today, dismissals: dismissals,
      options: .standard(sensitivity))
  }

  /// Ten coffees of 100 on ten days of August, then one more.
  private func coffees(then amount: AmountE4, count: Int = 10) -> (InsightsBook, UUID) {
    var book = InsightsBook()
    for day in 1...count { book.add(.expense, rub(100), on: .d(8, day)) }
    let last = book.add(.expense, amount, on: .d(8, 20))
    return (book, last.parts[0].id)
  }

  // MARK: - Large expense

  /// 1,000 among coffees of 100: above the steady threshold (median 100, spread at least 10 %,
  /// 3.5 spreads) — 135.
  func testALargeExpenseStandsAboveItsCategory() throws {
    let (book, part) = coffees(then: rub(1_000))
    let found = report(book).visible.filter { $0.rule == .largeExpense }
    let anomaly = try XCTUnwrap(found.first)
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(anomaly.partId, part)
    XCTAssertEqual(anomaly.reference, rub(135))
    XCTAssertEqual(anomaly.subject, part.uuidString.lowercased())
    XCTAssertEqual(anomaly.excessBp, 74_074)
  }

  /// Exactly the threshold is not above it.
  func testExactlyTheThresholdIsNoAnomaly() {
    let (book, _) = coffees(then: rub(135))
    XCTAssertFalse(report(book).all.contains { $0.rule == .largeExpense })
  }

  /// Fewer than ten operations in a category say nothing about what is large there.
  func testACategoryNeedsTenOperations() {
    let (book, _) = coffees(then: rub(5_000), count: 8)
    XCTAssertFalse(report(book).all.contains { $0.rule == .largeExpense })
  }

  /// The three sensitivities: 140 is large at «обычная» (135) and «высокая» (125), not at
  /// «низкая» (150) — but it still arises there, so the screen knows a higher level would show it.
  func testTheSensitivitiesMoveTheThreshold() throws {
    let (book, part) = coffees(then: rub(140))
    XCTAssertTrue(report(book).all.contains { $0.partId == part })
    XCTAssertTrue(report(book, sensitivity: .high).all.contains { $0.partId == part })
    let low = report(book, sensitivity: .low)
    XCTAssertFalse(low.all.contains { $0.partId == part })
    let key = "largeExpense:\(part.uuidString.lowercased())"
    XCTAssertTrue(low.activeKeys.contains(key))
  }

  /// A purchase refunded in full is no longer large.
  func testARefundedPurchaseIsNoLongerLarge() {
    let made = coffees(then: rub(1_000))
    var book = made.0
    let part = made.1
    book.add(.refund, rub(1_000), on: .d(8, 22), refundOf: part)
    XCTAssertFalse(report(book).all.contains { $0.rule == .largeExpense })
  }

  /// Money for somebody else is not mine, so it is never large among my spending.
  func testMoneyForOthersIsNeverLarge() {
    var book = coffees(then: rub(100)).0
    book.add(.expense, rub(9_000), on: .d(8, 25), reimbursable: true, status: .expected)
    XCTAssertFalse(report(book).all.contains { $0.rule == .largeExpense })
  }

  // MARK: - Possible duplicate

  /// The same amount in the same category nine minutes apart: the later one is the duplicate.
  func testTheSameAmountWithinTenMinutesIsADuplicate() throws {
    var book = InsightsBook()
    book.add(.expense, rub(450), on: .d(9, 10), at: 9 * 3600)
    let later = book.add(.expense, rub(450), on: .d(9, 10), at: 9 * 3600 + 540)
    let found = report(book).all.filter { $0.rule == .possibleDuplicate }
    XCTAssertEqual(found.map(\.transactionId), [later.id])
  }

  /// Eleven minutes apart is no duplicate; another category or another amount neither.
  func testElevenMinutesOrAnotherCategoryIsNoDuplicate() {
    var book = InsightsBook()
    book.add(.expense, rub(450), on: .d(9, 10), at: 9 * 3600)
    book.add(.expense, rub(450), on: .d(9, 10), at: 9 * 3600 + 660)
    book.add(.expense, rub(450), on: .d(9, 11), category: book.fun.id, at: 9 * 3600)
    book.add(.expense, rub(450), on: .d(9, 11), at: 9 * 3600 + 60)
    book.add(.expense, rub(451), on: .d(9, 11), at: 9 * 3600 + 120)
    XCTAssertFalse(report(book).all.contains { $0.rule == .possibleDuplicate })
  }

  /// Two purchases written without a time stand at noon: an invented time is no time.
  func testTwoPurchasesAtAnInventedNoonAreNoDuplicate() {
    var book = InsightsBook()
    book.add(.expense, rub(300), on: .d(9, 10))
    book.add(.expense, rub(300), on: .d(9, 10))
    XCTAssertFalse(report(book).all.contains { $0.rule == .possibleDuplicate })
  }

  /// Duplicates over midnight are still ten minutes apart.
  func testADuplicateOverMidnight() {
    var book = InsightsBook()
    book.add(.expense, rub(77), on: .d(9, 30), at: 86_400 - 120)
    let later = book.add(.expense, rub(77), on: .d(10, 1), at: 180)
    let found = report(book, today: .d(10, 2)).all.filter { $0.rule == .possibleDuplicate }
    XCTAssertEqual(found.map(\.transactionId), [later.id])
    XCTAssertEqual(found.first?.day, .d(10, 1))
  }

  // MARK: - Slow reimbursement

  /// A part for somebody else waited 31 days: it is late; 30 days is not yet.
  func testAReimbursementIsLateAfterThirtyDays() throws {
    var book = InsightsBook()
    let anna = Person(name: "Anna")
    book.people = [anna]
    let late = book.add(
      .expense, rub(600), on: .d(8, 16), reimbursable: true, debtor: anna.id, status: .expected)
    book.add(
      .expense, rub(200), on: .d(8, 17), reimbursable: true, debtor: anna.id, status: .expected)
    let found = report(book, today: .d(9, 16)).all.filter { $0.rule == .slowReimbursement }
    let anomaly = try XCTUnwrap(found.first)
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(anomaly.transactionId, late.id)
    XCTAssertEqual(anomaly.days, 31)
    XCTAssertEqual(anomaly.personId, anna.id)
    XCTAssertEqual(anomaly.amount, rub(600))
  }

  /// Money that came back for part of it leaves the rest waiting; returned and written off
  /// are not late.
  func testOnlyWhatIsStillWaitedIsLate() throws {
    var book = InsightsBook()
    let part = book.add(.expense, rub(600), on: .d(7, 1), reimbursable: true, status: .expected)
    let back = book.add(.reimbursement, rub(250), on: .d(7, 20))
    book.links = [
      ReimbursementLink(reimbursementTxId: back.id, partId: part.parts[0].id, amountE4: rub(250))
    ]
    book.add(.expense, rub(90), on: .d(7, 1), reimbursable: true, status: .returned)
    book.add(.expense, rub(80), on: .d(7, 1), reimbursable: true, status: .writtenOff)
    let found = report(book).all.filter { $0.rule == .slowReimbursement }
    XCTAssertEqual(found.map(\.amount), [rub(350)])
  }

  // MARK: - Weeks

  /// Eight usual weeks of 1,000 in «Transport», then a week of `last`; today is Wednesday
  /// 16 September, so the week judged is 7–13 September.
  private func weeks(
    last: AmountE4, category: KeyPath<InsightsBook, CoreKit.Category>
  )
    -> InsightsBook
  {
    var book = InsightsBook()
    let id = book[keyPath: category].id
    for week in 1...8 {
      book.add(.expense, rub(1_000), on: DateOnly.d(9, 7).adding(days: -7 * week), category: id)
    }
    book.add(.expense, last, on: .d(9, 9), category: id)
    return book
  }

  /// A week twice the usual one is a spike of its category.
  func testAWeekWellAboveTheUsualIsASpike() throws {
    let book = weeks(last: rub(2_000), category: \.transport)
    let spike = try XCTUnwrap(report(book).all.first { $0.rule == .categorySpike })
    XCTAssertEqual(spike.day, .d(9, 7))
    XCTAssertEqual(spike.amount, rub(2_000))
    XCTAssertEqual(spike.reference, rub(1_000))
    XCTAssertEqual(spike.categoryId, book.transport.id)
  }

  /// One and a half times the usual week is not above it at «обычная»; it is at «высокая».
  func testOneAndAHalfWeeksIsTheEdgeOfASpike() {
    let book = weeks(last: rub(1_500), category: \.transport)
    XCTAssertFalse(report(book).all.contains { $0.rule == .categorySpike })
    XCTAssertTrue(report(book, sensitivity: .high).all.contains { $0.rule == .categorySpike })
  }

  /// Without eight weeks of history nothing is usual, so nothing is a spike.
  func testAShortHistoryHasNoSpike() {
    var book = InsightsBook()
    for week in 1...3 {
      book.add(.expense, rub(1_000), on: DateOnly.d(9, 7).adding(days: -7 * week))
    }
    book.add(.expense, rub(9_000), on: .d(9, 9))
    XCTAssertFalse(report(book).all.contains { $0.rule == .categorySpike })
  }

  /// Usual weeks below 500 are too small to rise from.
  func testSmallWeeksDoNotRise() {
    let book = weeks(last: rub(5_000), category: \.transport)
    var small = InsightsBook()
    for entry in book.entries {
      small.add(
        .expense, AmountE4(raw: entry.transaction.amountE4.raw / 10),
        on: CalendarContext.utc.day(of: entry.transaction.occurredAt),
        category: small.transport.id)
    }
    XCTAssertFalse(report(small).all.contains { $0.rule == .categorySpike })
  }

  /// A week of bad spending well above usual: both the bad rise and its category's spike.
  func testBadSpendingRisesWithItsCategory() {
    let book = weeks(last: rub(3_000), category: \.fun)
    let rules = Set(report(book).all.map(\.rule))
    XCTAssertTrue(rules.contains(.badSpendingRise))
    XCTAssertTrue(rules.contains(.categorySpike))
  }

  // MARK: - «Это нормально»

  /// «Это нормально» hides exactly the pair it names: the same part stays a duplicate.
  func testDismissingHidesOnlyThatPair() throws {
    var book = InsightsBook()
    for day in 1...10 { book.add(.expense, rub(100), on: .d(8, day)) }
    book.add(.expense, rub(2_000), on: .d(8, 20), at: 10 * 3600)
    let twin = book.add(.expense, rub(2_000), on: .d(8, 20), at: 10 * 3600 + 60)
    let subject = twin.parts[0].id.uuidString.lowercased()
    let dismissal = AnomalyDismissal(
      rule: .largeExpense, subject: subject, at: InsightsBook.noon(.d(9, 1)))
    let result = report(book, dismissals: [dismissal])
    XCTAssertTrue(result.hidden.contains { $0.rule == .largeExpense && $0.subject == subject })
    XCTAssertTrue(
      result.visible.contains { $0.rule == .possibleDuplicate && $0.subject == subject })
    XCTAssertEqual(result.hidden.count, 1)
  }

  /// A dismissal of something that no longer arises hides nothing.
  func testAStaleDismissalHidesNothing() {
    let (book, _) = coffees(then: rub(1_000))
    let stale = AnomalyDismissal(
      rule: .largeExpense, subject: UUID().uuidString.lowercased(), at: Date())
    let result = report(book, dismissals: [stale])
    XCTAssertTrue(result.hidden.isEmpty)
    XCTAssertEqual(result.visible.count, result.all.count)
  }

  // MARK: - The report

  /// Newest day first; a period shows only its visible anomalies.
  func testTheReportIsNewestFirstAndCutByPeriod() {
    var book = InsightsBook()
    for day in 1...10 { book.add(.expense, rub(100), on: .d(7, day)) }
    book.add(.expense, rub(5_000), on: .d(7, 15))
    book.add(.expense, rub(5_000), on: .d(8, 15))
    let result = report(book)
    XCTAssertEqual(result.all.map(\.day), result.all.map(\.day).sorted(by: >))
    XCTAssertEqual(result.inside(.month(MonthKey(year: 2026, month: 8))).count, 1)
    XCTAssertEqual(result.inside(.month(MonthKey(year: 2026, month: 6))).count, 0)
  }

  /// An empty book has nothing to look at.
  func testAnEmptyBookHasNoAnomalies() {
    let result = report(InsightsBook())
    XCTAssertTrue(result.all.isEmpty)
    XCTAssertTrue(result.activeKeys.isEmpty)
  }

  /// A reference of zero has no excess.
  func testAnAnomalyWithoutAReferenceHasNoExcess() {
    let anomaly = Anomaly(rule: .slowReimbursement, subject: "x", day: .d(9, 1), amount: rub(5))
    XCTAssertNil(anomaly.excessBp)
    XCTAssertEqual(anomaly.id, "slowReimbursement:x")
  }
}
