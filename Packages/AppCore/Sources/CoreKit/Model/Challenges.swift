import Foundation

/// What a challenge asks of the owner.
public enum ChallengeKind: String, CaseIterable, Hashable, Sendable, Codable {
  /// Nothing of the chosen kind is bought in the period («неделя без доставки»).
  case avoid
  /// What goes on the chosen kind stays within a limit («кафе не больше 5 000 ₽»).
  case cap
  /// No subscription is started in the period («месяц без новых подписок»).
  case noNewSubscriptions
}

/// A challenge the owner took on (kept in the book `ChallengeBook`). It is about his own
/// spending only: nothing compares him with anybody.
public struct Challenge: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var title: String
  /// The kind as stored; `kind` reads it. A kind a newer build writes is kept and shown as nothing.
  public var kindText: String
  /// The first and the last day of the challenge, both counted.
  public var start: DateOnly
  public var end: DateOnly
  /// Which of my expenses the challenge is about: a part in one of these categories (or under
  /// one) or whose operation mentions one of the keywords. With neither, all of them.
  public var categoryIds: [UUID]
  public var keywords: [String]
  /// The most the challenge lets be spent; `nil` for the kinds without a limit.
  public var limit: AmountE4?
  /// What the owner says he would have spent in the whole period; `nil` — take the median of the
  /// periods of the same length before it.
  public var baseline: AmountE4?
  /// The subscriptions running when the challenge began; any other one is a new one.
  public var knownSubscriptionIds: [UUID]
  /// The day the owner gave it up; `nil` while it is his to finish.
  public var stoppedOn: DateOnly?
  public var createdOn: DateOnly

  public init(
    id: UUID = UUID(), title: String, kind: ChallengeKind, start: DateOnly, end: DateOnly,
    categoryIds: [UUID] = [], keywords: [String] = [], limit: AmountE4? = nil,
    baseline: AmountE4? = nil, knownSubscriptionIds: [UUID] = [], stoppedOn: DateOnly? = nil,
    createdOn: DateOnly? = nil
  ) {
    self.id = id
    self.title = title
    self.kindText = kind.rawValue
    self.start = start
    self.end = max(start, end)
    self.categoryIds = categoryIds
    self.keywords = keywords
    self.limit = limit
    self.baseline = baseline
    self.knownSubscriptionIds = knownSubscriptionIds
    self.stoppedOn = stoppedOn
    self.createdOn = createdOn ?? start
  }

  /// `nil` for a kind this build does not know.
  public var kind: ChallengeKind? { ChallengeKind(rawValue: kindText) }
}

/// The challenges of the owner, the only thing the feature keeps. It lives as one text under a
/// key of the `settings` table, so it travels with the archive and between devices like the
/// other settings; an unreadable text reads as no challenges.
public struct ChallengeBook: Hashable, Sendable, Codable {
  public static let storageKey = "challenges.items"

  /// Oldest first.
  public var items: [Challenge]

  public init(items: [Challenge] = []) { self.items = items }

  public func challenge(_ id: UUID) -> Challenge? { items.first { $0.id == id } }

  public init(storedText: String?) {
    guard let data = storedText?.data(using: .utf8),
      let items = try? JSONDecoder().decode([Challenge].self, from: data)
    else {
      self.init()
      return
    }
    self.init(items: items)
  }

  /// The text kept; stable for the same challenges so two devices agree.
  public var storedText: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(items), let text = String(data: data, encoding: .utf8)
    else { return "[]" }
    return text
  }
}
