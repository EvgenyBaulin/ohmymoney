import CoreKit
import Foundation

// The guide is data: cards, scenarios and tasks with the condition that says a task is done.
// The Mac shows them with SwiftUI; the iPhone, Windows and Android versions will show the same
// data their own way — gestures instead of keys — and nothing here knows how it is drawn.

/// A text of the guide in both languages of the app.
public struct GuideText: Hashable, Sendable, Codable {
  public var russian: String
  public var english: String

  public init(_ russian: String, _ english: String) {
    self.russian = russian
    self.english = english
  }

  /// The text in the language of the interface: Russian for Russian, English for the rest.
  public func text(russian isRussian: Bool) -> String { isRussian ? russian : english }

  public var isComplete: Bool {
    !russian.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// One thought: a title, a sentence or two and a picture — an SF Symbol on the Mac — read in
/// ten to fifteen seconds.
public struct GuideCard: Hashable, Sendable, Identifiable {
  public var id: String
  public var title: GuideText
  public var body: GuideText
  /// An SF Symbol name; other platforms map it to their own picture.
  public var symbol: String
  /// How long the card takes to read, in seconds.
  public var seconds: Int
  /// The place on the screen the card speaks of, when it speaks of one: «Показать, где» darkens
  /// the window around it.
  public var target: String?

  public init(
    id: String, title: GuideText, body: GuideText, symbol: String, seconds: Int = 12,
    target: String? = nil
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.symbol = symbol
    self.seconds = seconds
    self.target = target
  }
}

/// One step of where to press: the element the window is darkened around, what to do there,
/// why, the keys on a Mac and the gesture on a touch screen.
public struct GuideHint: Hashable, Sendable {
  /// The id the element marks itself with in the app. A place the app does not mark, or does
  /// not show now (a toolbar button, another window), gets the words alone, in the middle.
  public var target: String
  /// What to press or type: one short sentence.
  public var text: GuideText
  /// Why: what it gives, for someone who would rather not read the rest.
  public var why: GuideText?
  /// Keys on a Mac, such as «⌘N»; nil when the step is a click.
  public var keys: String?
  /// The same step on a touch screen.
  public var gesture: GuideText?
  /// A click on the element moves to the next step. Off where the step is typed, not clicked:
  /// a click into a line only puts the cursor there.
  public var advancesOnClick: Bool

  public init(
    target: String, text: GuideText, why: GuideText? = nil, keys: String? = nil,
    gesture: GuideText? = nil, advancesOnClick: Bool = true
  ) {
    self.target = target
    self.text = text
    self.why = why
    self.keys = keys
    self.gesture = gesture
    self.advancesOnClick = advancesOnClick
  }
}

/// What has happened since the tutorial began, as the app sees it: events it reported and
/// what is in the data. Counts and words only — the guide never reads more than it checks.
public struct GuideFacts: Hashable, Sendable {
  /// Tokens of what the owner did (`GuideEvent`).
  public var events: Set<String>
  /// Operations recorded since the tutorial began.
  public var operations: [GuideOperation]
  public var scheduledPaymentsAdded: Int
  public var countsMade: Int
  public var transfersAdded: Int
  public var debtsAdded: Int
  public var goalsAdded: Int
  public var cashbackRulesAdded: Int

  public init(
    events: Set<String> = [], operations: [GuideOperation] = [], scheduledPaymentsAdded: Int = 0,
    countsMade: Int = 0, transfersAdded: Int = 0, debtsAdded: Int = 0, goalsAdded: Int = 0,
    cashbackRulesAdded: Int = 0
  ) {
    self.events = events
    self.operations = operations
    self.scheduledPaymentsAdded = scheduledPaymentsAdded
    self.countsMade = countsMade
    self.transfersAdded = transfersAdded
    self.debtsAdded = debtsAdded
    self.goalsAdded = goalsAdded
    self.cashbackRulesAdded = cashbackRulesAdded
  }
}

/// An operation as the guide checks it.
public struct GuideOperation: Hashable, Sendable {
  public var text: String
  public var amountE4: Int64
  public var currency: CurrencyCode
  public var kind: TransactionKind
  /// A part of it is paid for somebody else (`reimbursable`) or is shared with somebody.
  public var forSomebodyElse: Bool

  public init(
    text: String, amountE4: Int64, currency: CurrencyCode = .rub, kind: TransactionKind = .expense,
    forSomebodyElse: Bool = false
  ) {
    self.text = text
    self.amountE4 = amountE4
    self.currency = currency
    self.kind = kind
    self.forSomebodyElse = forSomebodyElse
  }
}

/// What makes a task done. Checked against `GuideFacts`, never against a «Done» button.
public indirect enum GuideCondition: Hashable, Sendable {
  /// The app reported this event (`GuideEvent`).
  case event(String)
  /// An expense whose words contain `words` (case and «ё» aside) and, when given, of this
  /// amount in rubles.
  case operation(words: String, amountE4: Int64?)
  /// An income whose words contain `words` (case and «ё» aside).
  case income(words: String)
  case operationForSomebodyElse
  case scheduledPaymentAdded
  case countMade
  case transferAdded
  case debtAdded
  case goalAdded
  case cashbackRuleAdded
  case any([GuideCondition])

  public func isMet(by facts: GuideFacts) -> Bool {
    switch self {
    case .event(let token): return facts.events.contains(token)
    case .operation(let words, let amount):
      let wanted = Self.fold(words)
      return facts.operations.contains { operation in
        operation.kind == .expense && Self.fold(operation.text).contains(wanted)
          && (amount.map { operation.amountE4 == $0 && operation.currency == .rub } ?? true)
      }
    case .income(let words):
      let wanted = Self.fold(words)
      return facts.operations.contains { operation in
        operation.kind == .income && Self.fold(operation.text).contains(wanted)
      }
    case .operationForSomebodyElse:
      return facts.operations.contains { $0.forSomebodyElse }
    case .scheduledPaymentAdded: return facts.scheduledPaymentsAdded > 0
    case .countMade: return facts.countsMade > 0
    case .transferAdded: return facts.transfersAdded > 0
    case .debtAdded: return facts.debtsAdded > 0
    case .goalAdded: return facts.goalsAdded > 0
    case .cashbackRuleAdded: return facts.cashbackRulesAdded > 0
    case .any(let conditions): return conditions.contains { $0.isMet(by: facts) }
    }
  }

  static func fold(_ text: String) -> String {
    text.lowercased().replacingOccurrences(of: "ё", with: "е")
  }
}

/// One task of the tutorial.
public struct GuideTask: Hashable, Sendable, Identifiable {
  public var id: String
  public var title: GuideText
  public var hints: [GuideHint]
  public var done: GuideCondition
  /// Whose tutorial has the task: everyone's, or only the one the starter set speaks of.
  public var audience: GuideAudience

  public init(
    id: String, title: GuideText, hints: [GuideHint], done: GuideCondition,
    audience: GuideAudience = .everyone
  ) {
    self.id = id
    self.title = title
    self.hints = hints
    self.done = done
    self.audience = audience
  }
}

/// A sequence the guide shows: the first launch, what is new in a version, the tutorial.
public struct GuideScenario: Hashable, Sendable, Identifiable {
  public enum Kind: Hashable, Sendable {
    case firstLaunch
    case whatsNew(version: GuideVersion)
    case tutorial
  }

  public var kind: Kind
  /// Grows when the scenario changes enough to be shown again.
  public var revision: Int
  public var cards: [GuideCard]
  public var tasks: [GuideTask]

  public var id: String {
    switch kind {
    case .firstLaunch: "firstLaunch"
    case .whatsNew(let version): "whatsNew.\(version)"
    case .tutorial: "tutorial"
    }
  }

  public init(kind: Kind, revision: Int = 1, cards: [GuideCard] = [], tasks: [GuideTask] = []) {
    self.kind = kind
    self.revision = revision
    self.cards = cards
    self.tasks = tasks
  }
}

/// A version of the app as «Что нового» counts them: major and minor, the patch aside — a
/// fix release has nothing new to show.
public struct GuideVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
  public var major: Int
  public var minor: Int

  public init(major: Int, minor: Int) {
    self.major = major
    self.minor = minor
  }

  /// «1.4.0», «1.4», «v1.4.2» — nil for anything else.
  public init?(_ text: String) {
    let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
    // Empty pieces are kept, so «1..2» or «1.4.» is no version rather than 1.2 or 1.4.
    let numbers = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard numbers.count >= 2, numbers.count <= 3, numbers.allSatisfy({ $0 != nil }),
      let major = numbers[0], let minor = numbers[1]
    else { return nil }
    self.init(major: major, minor: minor)
  }

  public static func < (left: Self, right: Self) -> Bool {
    (left.major, left.minor) < (right.major, right.minor)
  }

  public var description: String { "\(major).\(minor)" }
}
