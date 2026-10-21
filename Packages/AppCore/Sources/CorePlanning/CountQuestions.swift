import CoreAccounting
import CoreKit
import Foundation

/// «Это было до сверки в 10:00?» — and, when the day holds several counts of the balances a
/// movement moves, the next one after «Нет»: an operation or a transfer is never put inside or
/// after a count the owner was not asked about, oldest count first.
///
/// An answer remembered for a reconciliation («Больше не спрашивать для этой сверки») answers
/// its count without a question, and every count it decides with it: «после» a count is after
/// every earlier one too, «до» a count is before every later one (`start`).
public struct CountQuestions: Sendable {
  public enum Step: Sendable {
    /// The next count to ask about.
    case ask(CountQuestions)
    /// The moment the answers give the movement.
    case stamp(Date)
  }

  /// The counts of the day, oldest first; never empty.
  public let counts: [Date]
  /// The reconciliation of each count, in the same order; `nil` — or a list shorter than
  /// `counts` — where it is not known.
  public let reconciliations: [UUID?]
  /// The one asked about now.
  public private(set) var index = 0
  /// The moment the movement would get without the questions.
  public let occurredAt: Date
  /// The owner's calendar: no answer moves the movement to another day.
  public let calendar: CalendarContext
  /// The first count whose «до» is remembered — the counts from it on are answered — or
  /// `counts.count` when none is.
  private var answeredBefore: Int
  /// The reconciliations an answer can be remembered for (`BeforeCountAnswers.keeps`); `nil`
  /// when not known, and then every known one can.
  public var remembering: Set<UUID>? = nil

  public init(
    counts: [Date], reconciliations: [UUID?] = [], occurredAt: Date, calendar: CalendarContext
  ) {
    self.counts = counts
    self.reconciliations = reconciliations
    self.occurredAt = occurredAt
    self.calendar = calendar
    answeredBefore = counts.count
  }

  /// The moment of the count asked about now.
  public var count: Date { counts[index] }

  /// The reconciliation of the count asked about now, when it is known.
  public var reconciliation: UUID? { reconciliation(at: index) }

  /// Whether the question about the count asked about now offers «Больше не спрашивать для
  /// этой сверки»: its reconciliation is known, and an answer for it would be kept.
  public var remembers: Bool {
    guard let reconciliation else { return false }
    return remembering?.contains(reconciliation) ?? true
  }

  /// «Да» puts the movement just before this count — after the one before it, if any — unless
  /// it is dated before the count already, as an operation keeps its moment; «Нет» asks about
  /// the next count still open, or puts the movement after the last one — a count whose «до» is
  /// remembered is not asked: «Нет» to the count before it puts the movement between the two.
  /// No answer leaves the day of the counts in the owner's `calendar`: a count at midnight
  /// answered «Да» keeps the movement on its day, one in the day's last second answered «Нет»
  /// too.
  public func answer(wasBefore: Bool) -> Step {
    func stamped(_ count: Date, wasBefore: Bool) -> Date {
      AccountReconciliation.stamped(
        occurredAt: occurredAt, count: count, wasBefore: wasBefore, calendar: calendar)
    }
    if wasBefore {
      guard index > 0 else { return .stamp(min(occurredAt, stamped(count, wasBefore: true))) }
      let previous = counts[index - 1]
      let between = min(stamped(previous, wasBefore: false), stamped(count, wasBefore: true))
      // Two counts less than a second apart at the start of the day leave no whole second
      // before the later one on that day: the middle of the two is after the one and before
      // the other.
      return .stamp(
        between > previous
          ? between : previous.addingTimeInterval(count.timeIntervalSince(previous) / 2))
    }
    guard index + 1 < answeredBefore else {
      guard answeredBefore < counts.count else {
        return .stamp(stamped(count, wasBefore: false))
      }
      // The next count is answered «до» already: the movement is between this one and it.
      var next = self
      next.index = answeredBefore
      return next.answer(wasBefore: true)
    }
    var next = self
    next.index += 1
    return .ask(next)
  }

  /// The walk with the remembered answers applied (`remembered`: reconciliation → «до»). «после»
  /// remembered for a count answers it and every count before it; «до» remembered for a count
  /// after those answers it and every count after it. `.stamp` when that settles it all, else
  /// `.ask` at the first count still open; `nil` for no counts.
  ///
  /// Where two remembered answers disagree — «до» an earlier count and «после» a later one —
  /// the «после» decides, and the «до» of a count before it is not read.
  public static func start(
    counts: [Date], reconciliations: [UUID?], occurredAt: Date, calendar: CalendarContext,
    remembered: [UUID: Bool]
  ) -> Step? {
    guard !counts.isEmpty else { return nil }
    var questions = CountQuestions(
      counts: counts, reconciliations: reconciliations, occurredAt: occurredAt,
      calendar: calendar)
    func answer(at position: Int) -> Bool? {
      questions.reconciliation(at: position).flatMap { remembered[$0] }
    }
    // The last count remembered «после»: every count up to it is answered.
    let after = counts.indices.last { answer(at: $0) == false }
    let open = after.map { $0 + 1 } ?? 0
    // The first count after those remembered «до»: every count from it on is answered.
    questions.answeredBefore =
      (open..<counts.count).first { answer(at: $0) == true } ?? counts.count
    guard open < questions.answeredBefore else {
      if questions.answeredBefore < counts.count {
        questions.index = questions.answeredBefore
        return questions.answer(wasBefore: true)
      }
      questions.index = counts.count - 1
      return questions.answer(wasBefore: false)
    }
    questions.index = open
    return .ask(questions)
  }

  private func reconciliation(at position: Int) -> UUID? {
    reconciliations.indices.contains(position) ? reconciliations[position] : nil
  }
}
