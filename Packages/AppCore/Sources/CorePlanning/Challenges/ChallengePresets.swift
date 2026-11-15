import CoreAnalytics
import CoreKit
import Foundation

/// The challenges offered ready-made. The owner may change anything before he starts one, and
/// may write his own.
public enum ChallengePreset: String, CaseIterable, Hashable, Sendable {
  /// A week without delivery.
  case deliveryWeek
  /// A month without new subscriptions.
  case noNewSubscriptionsMonth
  /// A month of cafés within 5 000.
  case cafeCap

  /// The words found in an operation of this kind; the owner can narrow it with a category.
  public var keywords: [String] {
    switch self {
    case .deliveryWeek: ["доставк", "delivery", "яндекс еда", "delivery club", "yandex eats"]
    case .cafeCap: ["кафе", "cafe", "café", "ресторан", "restaurant", "кофе", "coffee"]
    case .noNewSubscriptionsMonth: []
    }
  }

  public var kind: ChallengeKind {
    switch self {
    case .deliveryWeek: .avoid
    case .cafeCap: .cap
    case .noNewSubscriptionsMonth: .noNewSubscriptions
    }
  }

  /// How many days it lasts.
  public var days: Int {
    switch self {
    case .deliveryWeek: 7
    case .noNewSubscriptionsMonth, .cafeCap: 30
    }
  }

  /// The limit it begins with, for the preset that has one.
  public var limit: AmountE4? {
    self == .cafeCap ? AmountE4(whole: 5_000) : nil
  }

  /// A challenge of this kind beginning on `start`. `title` is what the screen calls it (the
  /// text is the screen's, so it follows the language).
  public func challenge(
    title: String, start: DateOnly, categoryIds: [UUID] = [], planning: PlanningBook
  ) -> Challenge {
    Challenge(
      title: title, kind: kind, start: start, end: start.adding(days: days - 1),
      categoryIds: categoryIds, keywords: keywords, limit: limit,
      knownSubscriptionIds: kind == .noNewSubscriptions
        ? ChallengeRules.runningSubscriptionIds(in: planning) : [])
  }
}

/// The challenges of the book the screens list, by where they stand.
public enum ChallengeLists {
  /// Running and upcoming first (soonest end first), then the finished (latest end first).
  public static func ordered(
    _ book: ChallengeBook, ledger: Ledger, planning: PlanningBook, today: DateOnly
  ) -> [(challenge: Challenge, progress: ChallengeProgress)] {
    let all = book.items.map {
      ($0, ChallengeRules.progress(of: $0, ledger: ledger, planning: planning, today: today))
    }
    let open = all.filter { !$0.1.isFinished }.sorted { $0.0.end < $1.0.end }
    let done = all.filter { $0.1.isFinished }.sorted { $0.0.end > $1.0.end }
    return (open + done).map { (challenge: $0.0, progress: $0.1) }
  }

  /// What all the finished challenges saved, in rubles; zero when none has a base.
  public static func totalSaved(
    _ items: [(challenge: Challenge, progress: ChallengeProgress)]
  ) -> AmountE4 {
    AmountE4.sum(items.filter { $0.progress.isFinished }.compactMap(\.progress.saved))
  }
}
