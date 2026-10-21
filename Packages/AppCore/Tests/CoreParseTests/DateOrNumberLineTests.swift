import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// A word of the entry line that looks like a day — «12.09», «31.09», «12/09» — is a day when
/// another number is left for the amount; otherwise it is a number, and the first number of the
/// line is the amount. A day-shaped word the calendar does not have — «31.09», 29 February of a
/// common year — is not taken for a price: the line is refused with the reason. Each reading is
/// pinned here so that changing it is a choice made on purpose, not an accident of some other
/// change. «Today» is 18 September 2026.
@Suite("A day or a number in the entry line")
struct DateOrNumberLineTests {
  struct Reading: Sendable, CustomTestStringConvertible {
    let line: String
    let amount: String?
    let date: String?
    let note: String
    let expression: String?
    var testDescription: String { line }
    init(
      _ line: String, amount: String?, date: String? = nil, note: String = "кофе",
      expression: String? = nil
    ) {
      self.line = line
      self.amount = amount
      self.date = date
      self.note = note
      self.expression = expression
    }
  }

  @Test(
    "How a word that looks like a day is read",
    arguments: [
      // A real day with an amount beside it, on either side: the day and the amount.
      Reading("кофе 1.09 250", amount: "250", date: "2026-09-01"),
      Reading("кофе 250 12.09", amount: "250", date: "2026-09-12"),
      Reading("кофе 5.05 300", amount: "300", date: "2026-05-05"),
      Reading("кофе 28.02 250", amount: "250", date: "2026-02-28"),
      // A day later in the year than today is last year's.
      Reading("10.10 2500", amount: "2500", date: "2025-10-10", note: ""),
      // Shaped like a day the calendar does not have: the day is taken, and refused
      // (`impossibleDaysAreRefusedWithTheReason`); the other number is the amount.
      Reading("кофе 29.02 250", amount: "250"),
      Reading("кофе 31.09 250", amount: "250"),
      Reading("кофе 30.02 250", amount: "250"),
      Reading("кофе 31.04 250", amount: "250"),
      // A month above 12 is no day at all: a number, and the first number is the amount.
      Reading("кофе 12.13 250", amount: "12.13", note: "кофе 250"),
      // A day is written with a point and a month of two digits; anything else is a number.
      Reading("кофе 12,09 250", amount: "12.09", note: "кофе 250"),
      Reading("кофе 12.9 250", amount: "12.9", note: "кофе 250"),
      // The only number of the line is the amount, whatever it looks like.
      Reading("кофе 12.09", amount: "12.09"), Reading("кофе 10.10", amount: "10.1"),
      // A slash is a division, and a space before three digits groups thousands.
      Reading("кофе 12/09 250", amount: "0.0013", expression: "12/09 250"),
      Reading("кофе 250/2 100", amount: "0.119", expression: "250/2 100"),
      Reading("кофе 05 300", amount: "5300"),
    ])
  func howAWordThatLooksLikeADayIsRead(_ reading: Reading) {
    let result = Fixture.parse(reading.line)
    #expect(result.amount == reading.amount.map(dec))
    #expect(result.date?.iso == reading.date)
    #expect(result.note == reading.note)
    #expect(result.amountExpression == reading.expression)
  }

  /// What shows the amount before Enter where a day and a number are easy to mix up: a comma
  /// that is not how the app writes it, a formula, a number grouped by a space. A day-shaped
  /// number written the app's way shows nothing.
  @Test("What is shown before Enter for day-shaped numbers")
  func previewsOfDayShapedNumbers() {
    #expect(Fixture.parse("кофе 12,09 250").amountToPreview == "12,09")
    #expect(Fixture.parse("кофе 12/09 250").amountToPreview == "12/09 250")
    #expect(Fixture.parse("кофе 05 300").amountToPreview == "05 300")
    #expect(Fixture.parse("кофе 12.09").amountToPreview == nil)
    #expect(Fixture.parse("кофе 12.13 250").amountToPreview == nil)
  }

  struct Impossible: Sendable, CustomTestStringConvertible {
    let line: String
    let problem: ParsedInput.DateProblem
    let amount: String?
    var testDescription: String { line }
    init(_ line: String, _ problem: ParsedInput.DateProblem, amount: String? = "250") {
      self.line = line
      self.problem = problem
      self.amount = amount
    }
  }

  /// A day the calendar does not have is refused with the reason — the word as typed, or the
  /// year that has no 29 February — whether the day is bare, has its year or is written the
  /// ISO way. Nothing is dated, the word is not in the note, and the line cannot be saved.
  @Test(
    "An impossible day is refused with the reason",
    arguments: [
      Impossible("кофе 31.09 250", .noSuchDate(written: "31.09")),
      Impossible("кофе 30.02 250", .noSuchDate(written: "30.02")),
      Impossible("кофе 31.04 250", .noSuchDate(written: "31.04")),
      Impossible("кофе 31.06 250", .noSuchDate(written: "31.06")),
      Impossible("кофе 250 31.11", .noSuchDate(written: "31.11")),
      Impossible("кофе 31.09.2026 250", .noSuchDate(written: "31.09.2026")),
      Impossible("кофе 2026-04-31 250", .noSuchDate(written: "2026-04-31")),
      Impossible("кофе 29.02 250", .notInYear(day: 29, month: 2, year: 2026)),
      Impossible("кофе 29.02.2026 250", .notInYear(day: 29, month: 2, year: 2026)),
      Impossible("кофе 2026-02-29 250", .notInYear(day: 29, month: 2, year: 2026)),
      Impossible("кофе 31.09.2026", .noSuchDate(written: "31.09.2026"), amount: nil),
    ])
  func impossibleDaysAreRefusedWithTheReason(_ impossible: Impossible) {
    let result = Fixture.parse(impossible.line)
    #expect(result.dateProblem == impossible.problem)
    #expect(result.date == nil)
    #expect(result.amount == impossible.amount.map(dec))
    #expect(result.note == "кофе")
    #expect(!result.isSaveable)
    #expect(result.tokens.contains { $0.role == .date })
  }

  /// A count or a day of the month — «2 шт», «3 бутылки», «к 8 марта» — is not the amount while
  /// another number is there, so it leaves no amount behind a day-shaped number either: «3.10»
  /// beside «2 шт» is the price, not the third of October with an amount of 2. With an amount
  /// beside them a day is a day as before.
  @Test(
    "A count beside a day-shaped number leaves it the amount",
    arguments: [
      Reading("круассаны 2 шт 3.10", amount: "3.1", note: "круассаны 2 шт"),
      Reading("пиво 3 бутылки 5.10 EUR", amount: "5.1", note: "пиво 3 бутылки"),
      Reading("подарок к 8 марта 12.03", amount: "12.03", note: "подарок к 8 марта"),
      Reading("кофе 3 шт 250 12.09", amount: "250", date: "2026-09-12", note: "кофе 3 шт"),
      Reading("кофе 12.09 3 шт 250", amount: "250", date: "2026-09-12", note: "кофе 3 шт"),
    ])
  func aCountBesideADayShapedNumberLeavesItTheAmount(_ reading: Reading) {
    let result = Fixture.parse(reading.line)
    #expect(result.amount == reading.amount.map(dec))
    #expect(result.date?.iso == reading.date)
    #expect(result.note == reading.note)
  }

  /// Not shaped like a day: a month above 12, a day of 0, one digit after the point, a comma.
  /// The only number of a line is its amount, whatever it looks like.
  @Test(
    "Numbers that are no day stay numbers",
    arguments: ["кофе 12.13 250", "кофе 1.50 250", "кофе 0.09 250", "кофе 12,09 250", "кофе 31.09"])
  func numbersThatAreNoDayStayNumbers(_ line: String) {
    let result = Fixture.parse(line)
    #expect(result.dateProblem == nil)
    #expect(result.isSaveable)
  }
  /// A written year is a date only inside the window a two-digit year is read in: no more than
  /// twenty years after today and less than eighty before it (1947…2046 while today is
  /// 2026). Outside it the word is no date at all, and the line reads as if it had never looked
  /// like one: «ужин 2500-10-5» costs 2500 − 10 − 5, not a dinner on 5 October 2500.
  @Test(
    "A year far from today makes no date",
    arguments: [
      Reading("ужин 2500-10-5", amount: "2485", note: "ужин", expression: "2500-10-5"),
      Reading("ужин 9999-12-31", amount: "9956", note: "ужин", expression: "9999-12-31"),
      Reading("кофе 250 2099-01-01", amount: "250", note: "кофе 2099-01-01"),
      Reading("кофе 250 12.09.2500", amount: "250", note: "кофе 12.09.2500"),
      Reading("кофе 250 12.09.2047", amount: "250", note: "кофе 12.09.2047"),
      Reading("кофе 250 1946-12-31", amount: "250", note: "кофе 1946-12-31"),
      Reading("кофе 250 31.09.2500", amount: "250", note: "кофе 31.09.2500"),
      // The edges of the window are dates.
      Reading("кофе 250 12.09.2046", amount: "250", date: "2046-09-12"),
      Reading("кофе 250 1947-01-01", amount: "250", date: "1947-01-01"),
      Reading("кофе 250 2026-10-05", amount: "250", date: "2026-10-05"),
    ])
  func aYearFarFromTodayMakesNoDate(_ reading: Reading) {
    let result = Fixture.parse(reading.line)
    #expect(result.amount == reading.amount.map(dec))
    #expect(result.date?.iso == reading.date)
    #expect(result.dateProblem == nil)
    #expect(result.note == reading.note)
    #expect(result.amountExpression == reading.expression)
  }
}
