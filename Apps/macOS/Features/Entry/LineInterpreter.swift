import AppCore
import Foundation

/// What the entry line hands to the store. The real implementation lives in `CoreParse`
/// and understands English and Russian, amounts as expressions, dates, places, people and
/// the rest; this protocol keeps the view independent of it.
protocol LineInterpreter: Sendable {
  /// `kind` is the kind the ↓ panel already chose, for a line that names none. Besides what
  /// `ParsedInput` holds: the time of day («в 18:09») and the cashback («кэшбек 9.76»).
  func read(_ text: String, today: DateOnly, kind: TransactionKind?) -> InputLineReading
}

extension LineInterpreter {
  /// The line without its time and cashback: their words are not in the note either.
  func interpret(_ text: String, today: DateOnly, kind: TransactionKind? = nil) -> ParsedInput {
    read(text, today: today, kind: kind).parsed
  }
}

/// The real interpreter: `CoreParse` understands English and Russian at the same time,
/// amounts written as expressions, dates, places, people, events, payment methods, goals
/// and debts.
struct CoreLineInterpreter: LineInterpreter {
  let vocabulary: ParserVocabulary
  let calendar: CalendarContext
  /// The owner's own currencies: their codes and symbols are read too.
  var catalog: CurrencyCatalog = .empty

  func read(_ text: String, today: DateOnly, kind: TransactionKind?) -> InputLineReading {
    InputLineParser(vocabulary: vocabulary, calendar: calendar, catalog: catalog).read(
      text, today: today, kind: kind)
  }
}

extension ParsedInput {
  /// What Enter says when the line has no amount to save: why the number that was typed is
  /// not one («Делений на ноль и мусора нет: понятная ошибка вместо сохранения»), or that
  /// there is no number at all.
  var missingAmountErrorKey: String {
    switch amountProblem {
    case .divisionByZero: "entry.error.divisionByZero"
    case .tooLarge: "entry.error.amountTooLarge"
    case .negative: "entry.error.amountNegative"
    case .malformed: "entry.error.badExpression"
    case nil: "entry.error.amountMissing"
    }
  }
}
