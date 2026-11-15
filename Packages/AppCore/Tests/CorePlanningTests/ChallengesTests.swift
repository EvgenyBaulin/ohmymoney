import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Synthetic operations for the challenges, in the UTC calendar.
enum ChallengeFixture {
  static let calendar = CalendarContext.utc
  static let cafe = CoreKit.Category(kind: .expense, name: "Cafe")
  static let food = CoreKit.Category(kind: .expense, name: "Food")

  static func day(_ month: Int, _ day: Int) -> DateOnly {
    DateOnly(year: 2026, month: month, day: day)
  }

  static func entry(
    _ whole: Int64, on day: DateOnly, note: String? = nil, category: CoreKit.Category = food,
    kind: TransactionKind = .expense
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: kind, occurredAt: calendar.startOfDay(day).addingTimeInterval(3600),
      amount: AmountE4(whole: whole))
    draft.note = note
    draft.parts = [PartDraft(categoryId: category.id, amount: AmountE4(whole: whole))]
    return try draft.materialize(timeZone: calendar.timeZone)
  }

  static func ledger(_ entries: [TransactionEntry], planning: PlanningBook = .empty) -> Ledger {
    Ledger(
      dataset: Dataset(entries: entries, categories: [cafe, food], planning: planning),
      calendar: calendar)
  }

  static func progress(
    _ challenge: Challenge, _ entries: [TransactionEntry], today: DateOnly,
    planning: PlanningBook = .empty
  ) -> ChallengeProgress {
    ChallengeRules.progress(
      of: challenge, ledger: ledger(entries, planning: planning), planning: planning, today: today)
  }
}

@Suite("Challenges: a kind avoided")
struct ChallengeAvoidTests {
  typealias F = ChallengeFixture
  let week = Challenge(
    title: "No delivery", kind: .avoid, start: F.day(11, 2), end: F.day(11, 8),
    keywords: ["доставка"])

  @Test("days with nothing of the kind bought build the streak and the week is kept")
  func kept() throws {
    let entries = [try F.entry(900, on: F.day(11, 1), note: "Доставка суши")]  // before: not counted
    let midway = F.progress(week, entries, today: F.day(11, 4))
    #expect(midway.state == .running)
    #expect(midway.elapsedDays == 3 && midway.keptDays == 3 && midway.currentStreak == 3)
    let done = F.progress(week, entries, today: F.day(11, 9))
    #expect(done.state == .succeeded)
    #expect(done.keptDays == 7 && done.bestStreak == 7 && done.spent == .zero)
  }

  @Test("a purchase of the kind breaks it on its day and the streak starts again")
  func broken() throws {
    let entries = [try F.entry(700, on: F.day(11, 4), note: "доставка пиццы")]
    let progress = F.progress(week, entries, today: F.day(11, 6))
    #expect(progress.state == .failed)
    #expect(progress.brokenOn == F.day(11, 4))
    #expect(progress.spent == AmountE4(whole: 700))
    // Days 2, 3, 5 and 6 are kept; the run after the break is two days.
    #expect(progress.keptDays == 4 && progress.currentStreak == 2 && progress.bestStreak == 2)
  }

  @Test("the kind is found by category as well as by the words, and other spending does not count")
  func byCategory() throws {
    var byCategory = week
    byCategory.keywords = []
    byCategory.categoryIds = [F.cafe.id]
    let entries = [
      try F.entry(300, on: F.day(11, 3), category: F.food),
      try F.entry(400, on: F.day(11, 5), category: F.cafe),
    ]
    let progress = F.progress(byCategory, entries, today: F.day(11, 5))
    #expect(progress.brokenOn == F.day(11, 5))
    #expect(progress.spent == AmountE4(whole: 400))
  }

  @Test("a day not yet begun is upcoming and a challenge the owner stopped is stopped")
  func upcomingAndStopped() throws {
    #expect(F.progress(week, [], today: F.day(11, 1)).state == .upcoming)
    var stopped = week
    stopped.stoppedOn = F.day(11, 4)
    let progress = F.progress(stopped, [], today: F.day(11, 10))
    #expect(progress.state == .stopped)
    #expect(progress.elapsedDays == 3)
    #expect(progress.isFinished)
  }
}

@Suite("Challenges: a limit")
struct ChallengeCapTests {
  typealias F = ChallengeFixture
  let month = Challenge(
    title: "Cafe", kind: .cap, start: F.day(11, 1), end: F.day(11, 30),
    categoryIds: [F.cafe.id], limit: AmountE4(whole: 5_000))

  @Test("within the limit it runs and says what is left; over it, it fails on that day")
  func limit() throws {
    let entries = [
      try F.entry(2_000, on: F.day(11, 3), category: F.cafe),
      try F.entry(2_500, on: F.day(11, 9), category: F.cafe),
    ]
    let within = F.progress(month, entries, today: F.day(11, 10))
    #expect(within.state == .running)
    #expect(within.remaining == AmountE4(whole: 500))
    let over = F.progress(
      month, entries + [try F.entry(600, on: F.day(11, 12), category: F.cafe)],
      today: F.day(11, 13))
    #expect(over.state == .failed)
    #expect(over.brokenOn == F.day(11, 12))
    #expect(over.remaining == .zero)
    #expect(over.keptDays == 11)
  }

  @Test("a refund after the limit was passed does not undo the failure")
  func refundAfter() throws {
    let entries = [
      try F.entry(5_500, on: F.day(11, 3), category: F.cafe)
    ]
    var later = month
    later.limit = AmountE4(whole: 5_000)
    let progress = F.progress(later, entries, today: F.day(11, 4))
    #expect(progress.state == .failed)
  }

  @Test("the end of the month with the limit kept is a success")
  func succeeded() throws {
    let entries = [try F.entry(1_000, on: F.day(11, 3), category: F.cafe)]
    let progress = F.progress(month, entries, today: F.day(12, 1))
    #expect(progress.state == .succeeded)
    #expect(progress.keptDays == 30)
  }
}

@Suite("Challenges: subscriptions")
struct ChallengeSubscriptionTests {
  typealias F = ChallengeFixture
  private func subscription(_ name: String) -> ScheduledPayment {
    ScheduledPayment(
      name: name, kind: .subscription, amountE4: AmountE4(whole: 299),
      nextDate: F.day(12, 1))
  }

  @Test("a subscription started after the challenge began fails it; the known ones do not")
  func newSubscription() {
    let old = subscription("Music")
    var book = PlanningBook()
    book.scheduled = [old]
    let challenge = ChallengePreset.noNewSubscriptionsMonth.challenge(
      title: "No new", start: F.day(11, 1), planning: book)
    #expect(challenge.knownSubscriptionIds == [old.id])
    let quiet = F.progress(challenge, [], today: F.day(11, 10), planning: book)
    #expect(quiet.state == .running && quiet.currentStreak == 10 && quiet.saved == nil)
    let fresh = subscription("Video")
    book.scheduled.append(fresh)
    let broken = F.progress(challenge, [], today: F.day(11, 10), planning: book)
    #expect(broken.state == .failed)
    #expect(broken.newSubscriptionIds == [fresh.id])
  }
}

@Suite("Challenges: what was saved")
struct ChallengeSavingTests {
  typealias F = ChallengeFixture

  /// A week of delivery for four weeks before, 1 000, 3 000, 2 000 and 4 000.
  private func history() throws -> [TransactionEntry] {
    let weeks: [(Int, Int64)] = [(-4, 1_000), (-3, 3_000), (-2, 2_000), (-1, 4_000)]
    let start = F.day(11, 16)
    return try weeks.map { offset, whole in
      try F.entry(whole, on: start.adding(days: offset * 7), note: "доставка")
    }
  }

  @Test("with no word from the owner the base is the median of the weeks before")
  func median() throws {
    let challenge = Challenge(
      title: "No delivery", kind: .avoid, start: F.day(11, 16), end: F.day(11, 22),
      keywords: ["доставка"])
    let progress = F.progress(challenge, try history(), today: F.day(11, 23))
    // 1 000, 2 000, 3 000, 4 000: the median of an even count is the mean of the middle two.
    #expect(progress.baseline == AmountE4(whole: 2_500))
    #expect(progress.baselineSource == .median)
    #expect(progress.saved == AmountE4(whole: 2_500))
  }

  @Test("what the owner said is the base, and what was spent is taken off it")
  func ownerBase() throws {
    var challenge = Challenge(
      title: "Cafe", kind: .cap, start: F.day(11, 16), end: F.day(11, 22),
      keywords: ["доставка"], limit: AmountE4(whole: 1_000), baseline: AmountE4(whole: 3_000))
    let entries = [try F.entry(800, on: F.day(11, 17), note: "доставка")]
    var progress = F.progress(challenge, entries, today: F.day(11, 23))
    #expect(progress.baselineSource == .owner)
    #expect(progress.saved == AmountE4(whole: 2_200))
    // Spending above the base saves nothing, never a negative sum.
    challenge.baseline = AmountE4(whole: 500)
    progress = F.progress(challenge, entries, today: F.day(11, 23))
    #expect(progress.saved == .zero)
  }

  @Test("on the way only the share of the days gone is due from the base")
  func prorated() throws {
    let challenge = Challenge(
      title: "x", kind: .avoid, start: F.day(11, 16), end: F.day(11, 22),
      keywords: ["доставка"], baseline: AmountE4(whole: 7_000))
    let progress = F.progress(challenge, [], today: F.day(11, 18))
    #expect(progress.saved == AmountE4(whole: 3_000))
  }

  @Test("fewer than two earlier weeks inside the history give no base and no saving")
  func noBase() throws {
    let challenge = Challenge(
      title: "x", kind: .avoid, start: F.day(11, 16), end: F.day(11, 22),
      keywords: ["доставка"])
    let entries = [try F.entry(1_000, on: F.day(11, 12), note: "доставка")]
    let progress = F.progress(challenge, entries, today: F.day(11, 23))
    #expect(progress.baseline == nil && progress.saved == nil)
  }
}

@Suite("Challenges: storage and lists")
struct ChallengeStorageTests {
  typealias F = ChallengeFixture

  @Test("the book reads back what it wrote and an unreadable text reads as none")
  func roundTrip() {
    let one = Challenge(
      title: "Мой", kind: .cap, start: F.day(11, 1), end: F.day(11, 30), categoryIds: [UUID()],
      keywords: ["кофе"], limit: AmountE4(whole: 100), baseline: AmountE4(whole: 900))
    let book = ChallengeBook(items: [one])
    #expect(ChallengeBook(storedText: book.storedText) == book)
    #expect(ChallengeBook(storedText: "not json").items.isEmpty)
    #expect(ChallengeBook(storedText: nil).items.isEmpty)
  }

  @Test("an unknown kind is kept as text and has no kind")
  func unknownKind() {
    var one = Challenge(title: "x", kind: .avoid, start: F.day(11, 1), end: F.day(11, 2))
    one.kindText = "future"
    let back = ChallengeBook(storedText: ChallengeBook(items: [one]).storedText)
    #expect(back.items.first?.kind == nil)
  }

  @Test("open challenges come first, then the finished, and the total counts only finished ones")
  func ordering() throws {
    let done = Challenge(
      title: "done", kind: .avoid, start: F.day(10, 1), end: F.day(10, 7), baseline: AmountE4(whole: 1_000))
    let open = Challenge(
      title: "open", kind: .avoid, start: F.day(11, 10), end: F.day(11, 20),
      baseline: AmountE4(whole: 5_000))
    let book = ChallengeBook(items: [done, open])
    let items = ChallengeLists.ordered(
      book, ledger: F.ledger([]), planning: .empty, today: F.day(11, 12))
    #expect(items.map(\.challenge.title) == ["open", "done"])
    #expect(ChallengeLists.totalSaved(items) == AmountE4(whole: 1_000))
  }

  @Test("the challenges travel in the dataset")
  func dataset() {
    var dataset = Dataset()
    let one = Challenge(title: "x", kind: .avoid, start: F.day(11, 1), end: F.day(11, 2))
    dataset.challenges = ChallengeBook(items: [one])
    #expect(dataset.challenges.items == [one])
  }
}

@Suite("Challenges: a limit that is not set")
struct ChallengeUnsetLimitTests {
  typealias F = ChallengeFixture

  @Test("a limit challenge without a limit is not set, not broken")
  func unset() throws {
    let challenge = Challenge(
      title: "Cafe", kind: .cap, start: F.day(11, 1), end: F.day(11, 30), limit: nil)
    let progress = F.progress(
      challenge, [try F.entry(500, on: F.day(11, 3))], today: F.day(11, 5))
    #expect(progress.limitIsMissing)
    #expect(progress.state != .failed)
    #expect(progress.brokenOn == nil)
    #expect(progress.remaining == nil)
  }
}
