import CoreKit
import Foundation

/// The cashback a line names behind its word: «кэшбек 9.76» is money, in the currency of the
/// operation; «кэшбек 3%» is a share of it.
public enum CashbackReading: Hashable, Sendable {
  /// Money, read by the rules of amounts typed by hand: «9,76», «1,5к». Above zero.
  case amount(Decimal)
  /// Percent, above zero and no more than a hundred: «3%», «1,5 %», "5 percent".
  case percent(Decimal)
}

/// What `InputLineParser.read` makes of a line: everything `parse` reads, and the time of day
/// and the cashback, which leave the note.
public struct InputLineReading: Hashable, Sendable {
  /// The line as `parse` reads it, without the words of the time and of the cashback in the
  /// note.
  public var parsed: ParsedInput
  /// «в 18:09», "at 6:09pm", «18:09»: the time on a clock, of the day the line names or of
  /// today when it names none.
  public var timeOfDay: TimeOfDay?
  /// A word shaped as a time that no clock shows — «25:00», «18:61», "13pm" —, as typed. The
  /// line is refused with it, as it is for a day the calendar has not; `timeOfDay` is nil.
  public var timeProblem: String?
  /// The words that named the time or its problem, the marker included, as typed: «в 18:09».
  public var timePhrase: String?
  /// «кэшбек 9.76», «кэшбек 3%».
  public var cashback: CashbackReading?
  /// The words that named the cashback, as typed, for an operation that has no cashback to
  /// give back to its note.
  public var cashbackPhrase: String?
  /// «смз 15000»: income of the self-employed — `parsed.kind` is `.income` —, which the app
  /// files under the category taxed as professional income from individuals.
  public var selfEmployed: Bool

  public init(
    parsed: ParsedInput, timeOfDay: TimeOfDay? = nil, timeProblem: String? = nil,
    timePhrase: String? = nil, cashback: CashbackReading? = nil, cashbackPhrase: String? = nil,
    selfEmployed: Bool = false
  ) {
    self.selfEmployed = selfEmployed
    self.parsed = parsed
    self.timeOfDay = timeOfDay
    self.timeProblem = timeProblem
    self.timePhrase = timePhrase
    self.cashback = cashback
    self.cashbackPhrase = cashbackPhrase
  }

  /// Nothing is saved without an amount, on a day the calendar has not, or at a time no
  /// clock shows.
  public var isSaveable: Bool { parsed.isSaveable && timeProblem == nil }
}
