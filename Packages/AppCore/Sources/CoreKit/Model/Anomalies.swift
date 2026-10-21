import Foundation

/// The seven anomaly rules. The raw values are stored in `anomaly_dismissals.rule`,
/// so they are part of the data and the Windows port must read the same strings.
public enum AnomalyRule: String, Codable, Sendable, CaseIterable, Hashable {
  /// Above the steady threshold of its own category.
  case largeExpense
  /// The same amount in the same category within ten minutes.
  case possibleDuplicate
  /// A subscription cost more this time than last time.
  case subscriptionPriceRise
  /// A week of a category well above its usual level.
  case categorySpike
  /// A week of bad spending well above its usual level.
  case badSpendingRise
  /// A part paid for somebody else has been waiting too long.
  case slowReimbursement
  /// An event over its budget, or heading there at its current pace.
  case eventOverBudget

  /// The first five look at my own spending only: a system category and a part paid for
  /// somebody else are out. The last two are *about* those very things.
  public var isAboutMyOwnSpending: Bool {
    switch self {
    case .slowReimbursement, .eventOverBudget: false
    default: true
    }
  }
}

/// How eager the rules are. One setting for all of them; what each level means in numbers
/// belongs to the rules themselves.
public enum AnomalySensitivity: String, Codable, Sendable, CaseIterable, Hashable {
  /// Only what is plainly out of place.
  case low
  case normal
  /// Everything that looks unusual, at the price of more to read.
  case high

  public static let standard = AnomalySensitivity.normal
}

/// «Это нормально»: one anomaly the owner has waved away (`anomaly_dismissals`).
///
/// Four of the seven rules are not about one operation but about a category and a week, a
/// person, an event or a subscription, so what is hidden is `rule` **and** `subject` — the
/// rest of the anomaly's identity. `transactionId` is kept where there is
/// one so that deleting the operation takes the dismissal with it.
public struct AnomalyDismissal: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var rule: AnomalyRule
  public var subject: String
  public var transactionId: UUID?
  public var at: Date

  public init(
    id: UUID = UUID(), rule: AnomalyRule, subject: String, transactionId: UUID? = nil, at: Date
  ) {
    self.id = id
    self.rule = rule
    self.subject = subject
    self.transactionId = transactionId
    self.at = at
  }

  /// What identifies the anomaly this hides, and what `Anomaly.id` gives.
  public var key: String { "\(rule.rawValue):\(subject)" }
}
