import CoreAnalytics
import CoreKit
import Foundation

extension Challenge {
  /// How many days the challenge lasts.
  public var dayCount: Int { start.days(to: end) + 1 }
}

/// Where a challenge stands on a day.
public enum ChallengeState: Hashable, Sendable {
  case upcoming
  case running
  /// The last day passed and it was kept.
  case succeeded
  /// It was broken: spent against it, over the limit, or a new subscription.
  case failed
  /// The owner gave it up.
  case stopped
}

/// Where the base of «сэкономлено» came from.
public enum ChallengeBaselineSource: Hashable, Sendable {
  /// The owner said what he would have spent.
  case owner
  /// The median of the periods of the same length before the challenge.
  case median
}

/// How a challenge is going: the spending it is about, the days kept, the streak and what it saved.
public struct ChallengeProgress: Hashable, Sendable {
  public var state: ChallengeState
  /// My expenses the challenge is about over the days gone, never below zero.
  public var spent: AmountE4
  /// The days of the challenge gone by the day asked about, the last one included.
  public var elapsedDays: Int
  public var dayCount: Int
  /// The days gone that kept the challenge. For «avoid» a day with nothing of the kind bought;
  /// for a limit and for subscriptions every day until it broke.
  public var keptDays: Int
  /// The run of kept days ending on the last day gone, and the longest run.
  public var currentStreak: Int
  public var bestStreak: Int
  /// The day it broke; `nil` if it did not, or for a new subscription (no day is known).
  public var brokenOn: DateOnly?
  /// What is left of the limit; `nil` without a limit.
  public var remaining: AmountE4?
  /// The base the saving is counted from, and where it came from; `nil` — no base.
  public var baseline: AmountE4?
  public var baselineSource: ChallengeBaselineSource?
  /// What was not spent against the base so far; `nil` when there is no base, and for
  /// subscriptions, whose saving is not a sum that can be told.
  public var saved: AmountE4?
  /// The subscriptions started after it began.
  public var newSubscriptionIds: [UUID]
  /// A limit challenge saved without a limit: not set yet, so nothing can break it.
  public var limitIsMissing: Bool

  public init(
    state: ChallengeState, spent: AmountE4, elapsedDays: Int, dayCount: Int, keptDays: Int,
    currentStreak: Int, bestStreak: Int, brokenOn: DateOnly?, remaining: AmountE4?,
    baseline: AmountE4?, baselineSource: ChallengeBaselineSource?, saved: AmountE4?,
    newSubscriptionIds: [UUID], limitIsMissing: Bool = false
  ) {
    self.state = state
    self.spent = spent
    self.elapsedDays = elapsedDays
    self.dayCount = dayCount
    self.keptDays = keptDays
    self.currentStreak = currentStreak
    self.bestStreak = bestStreak
    self.brokenOn = brokenOn
    self.remaining = remaining
    self.baseline = baseline
    self.baselineSource = baselineSource
    self.saved = saved
    self.newSubscriptionIds = newSubscriptionIds
    self.limitIsMissing = limitIsMissing
  }

  /// Whether the challenge is over, one way or the other.
  public var isFinished: Bool {
    switch state {
    case .succeeded, .failed, .stopped: true
    case .upcoming, .running: false
    }
  }
}

/// The rule of the challenges, in the core: one `Ledger` gives the spending (my expenses, not what
/// is paid for others until written off and not a refund as income), so a challenge and a screen of
/// analytics never disagree.
public enum ChallengeRules {
  /// The challenge with its missing limit set; `nil` for a kind without a limit or a sum that is
  /// not above zero.
  public static func settingLimit(_ limit: AmountE4, on challenge: Challenge) -> Challenge? {
    guard challenge.kind == .cap, limit.raw > 0 else { return nil }
    var made = challenge
    made.limit = limit
    return made
  }

  /// The most periods of the same length before a challenge that the median is taken over.
  public static let medianPeriods = 6
  /// The fewest such periods with history in them the median needs; with fewer there is no base.
  public static let minimumPeriods = 2

  /// Whether a row is something the challenge is about.
  static func matches(_ row: LedgerRow, _ challenge: Challenge, ledger: Ledger) -> Bool {
    if challenge.categoryIds.isEmpty && challenge.keywords.isEmpty { return true }
    if let id = row.categoryId, challenge.categoryIds.contains(id) { return true }
    if let id = row.rootCategoryId, challenge.categoryIds.contains(id) { return true }
    guard !challenge.keywords.isEmpty, let key = ledger.searchKey(of: row.transactionId)
    else { return false }
    return challenge.keywords.contains { word in
      let folded = NameKey.fold(word)
      return !folded.isEmpty && key.contains(folded)
    }
  }

  /// My expenses the challenge is about, by day, over `range`.
  static func spending(
    _ challenge: Challenge, in range: DayRange, ledger: Ledger
  ) -> [DateOnly: AmountE4] {
    guard !range.isEmpty else { return [:] }
    var byDay: [DateOnly: AmountE4] = [:]
    for row in ledger.rows(in: range)
    where !row.contribution.isZero && matches(row, challenge, ledger: ledger) {
      byDay[row.day, default: .zero] += row.contribution
    }
    return byDay
  }

  /// The subscriptions running that were not when the challenge began.
  public static func newSubscriptions(
    _ challenge: Challenge, in book: PlanningBook
  ) -> [UUID] {
    let known = Set(challenge.knownSubscriptionIds)
    return book.scheduled
      .filter {
        $0.kind == .subscription && $0.active && !$0.isOneOff && !known.contains($0.id)
      }
      .map(\.id)
  }

  /// The ids of the subscriptions running now: what a challenge stores as «known» when it begins.
  public static func runningSubscriptionIds(in book: PlanningBook) -> [UUID] {
    book.scheduled.filter { $0.kind == .subscription && $0.active && !$0.isOneOff }.map(\.id)
  }

  /// The base for a challenge: what the owner said, else the median over the periods of the same
  /// length just before it that lie wholly inside the history. `nil` when neither is there.
  public static func baseline(
    for challenge: Challenge, ledger: Ledger
  ) -> (amount: AmountE4, source: ChallengeBaselineSource)? {
    guard challenge.kind != .noNewSubscriptions else { return nil }
    if let owner = challenge.baseline { return (owner, .owner) }
    guard let firstDay = ledger.firstDay else { return nil }
    let length = challenge.dayCount
    var totals: [Int64] = []
    for index in 1...medianPeriods {
      let first = challenge.start.adding(days: -index * length)
      let last = first.adding(days: length - 1)
      guard first >= firstDay else { break }
      let sum = AmountE4.sum(spending(challenge, in: DayRange(first, last), ledger: ledger).values)
      totals.append(max(0, sum.raw))
    }
    guard totals.count >= minimumPeriods else { return nil }
    totals.sort()
    let middle = totals.count / 2
    let raw =
      totals.count % 2 == 1 ? totals[middle] : (totals[middle - 1] + totals[middle] + 1) / 2
    return (AmountE4(raw: raw), .median)
  }

  /// How the challenge stands on `today`.
  public static func progress(
    of challenge: Challenge, ledger: Ledger, planning: PlanningBook, today: DateOnly
  ) -> ChallengeProgress {
    let dayCount = challenge.dayCount
    let lastDay = min(today, challenge.stoppedOn ?? challenge.end, challenge.end)
    let elapsed = today < challenge.start ? 0 : max(0, min(dayCount, challenge.start.days(to: lastDay) + 1))
    let kind = challenge.kind ?? .avoid

    let byDay =
      kind == .noNewSubscriptions
      ? [:] : spending(challenge, in: DayRange(challenge.start, lastDay), ledger: ledger)
    let spent = AmountE4(raw: max(0, AmountE4.sum(byDay.values).raw))

    // Walk the days gone: which of them kept the challenge, and when it broke.
    var kept = 0
    var streak = 0
    var best = 0
    var brokenOn: DateOnly?
    var running = AmountE4.zero
    let newSubscriptions = kind == .noNewSubscriptions ? newSubscriptions(challenge, in: planning) : []
    for offset in 0..<elapsed {
      let day = challenge.start.adding(days: offset)
      let net = byDay[day] ?? .zero
      running += net
      let dayKept: Bool
      switch kind {
      case .avoid: dayKept = net <= .zero
      // A limit that was passed stays passed even when a later refund brings the sum down.
      case .cap:
        dayKept = brokenOn == nil && challenge.limit.map { running <= $0 } ?? true
      case .noNewSubscriptions: dayKept = newSubscriptions.isEmpty
      }
      if dayKept {
        kept += 1
        streak += 1
        best = max(best, streak)
      } else {
        streak = 0
        if brokenOn == nil && kind != .noNewSubscriptions { brokenOn = day }
      }
    }

    let broken = kind == .noNewSubscriptions ? !newSubscriptions.isEmpty : brokenOn != nil

    let state: ChallengeState
    if challenge.stoppedOn != nil {
      state = .stopped
    } else if elapsed == 0 {
      state = .upcoming
    } else if broken {
      state = .failed
    } else if today > challenge.end {
      state = .succeeded
    } else {
      state = .running
    }

    var baseline: AmountE4?
    var source: ChallengeBaselineSource?
    var saved: AmountE4?
    if let base = Self.baseline(for: challenge, ledger: ledger) {
      baseline = base.amount
      source = base.source
      if elapsed > 0 {
        // The base is for the whole period: on the way only the share of the days gone is due.
        let due = (base.amount.raw * Int64(elapsed) * 2 + Int64(dayCount)) / (2 * Int64(dayCount))
        saved = AmountE4(raw: max(0, due - spent.raw))
      } else {
        saved = .zero
      }
    }

    var remaining: AmountE4?
    if kind == .cap, let limit = challenge.limit {
      remaining = AmountE4(raw: max(0, limit.raw - spent.raw))
    }

    return ChallengeProgress(
      state: state, spent: spent, elapsedDays: elapsed, dayCount: dayCount, keptDays: kept,
      currentStreak: streak, bestStreak: best, brokenOn: brokenOn, remaining: remaining,
      baseline: baseline, baselineSource: source, saved: saved,
      newSubscriptionIds: newSubscriptions,
      limitIsMissing: kind == .cap && challenge.limit == nil)
  }
}
