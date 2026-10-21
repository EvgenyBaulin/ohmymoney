import AppCore
import AppDatabase
import Foundation

/// «Это нормально» and «Вернуть» on an anomaly. The dismissals the rules read come with the
/// data, so a write is followed by a new read of it: a hidden anomaly must stay hidden after
/// a restart, not only until one.
///
/// A write that did not go through is not swallowed: the journal says which one failed and
/// why, the owner is told, and the data is not read again — every card would blink through
/// «Считается» only to bring the same anomaly back without a word.
@MainActor
struct AnomalyActions {
  /// `anomaly_dismissals`; nil while the app has no database.
  let repository: AnomalyRepository?
  /// Reads the data again, so the rules run on the new dismissals:
  /// `compute.retry(ComputeStep.data)` in the app.
  let recount: () -> Void

  /// What the owner reads when a write failed: a key of the Analytics table.
  static let failureKey = "analytics.anomaly.writeFailed"

  /// Hides `anomaly`. `active` is every anomaly the last run found, hidden ones included.
  /// Returns the key of the message to show, or nil when the dismissal was written.
  func hide(_ anomaly: Anomaly, active: Set<String>?) -> String? {
    write("anomaly.dismiss.failed", anomaly) { repository in
      try repository.dismiss(
        rule: anomaly.rule, subject: anomaly.subject, transactionId: anomaly.transactionId,
        active: active)
    }
  }

  /// Puts `anomaly` back. Returns the key of the message to show, or nil when it was written.
  func show(_ anomaly: Anomaly) -> String? {
    write("anomaly.restore.failed", anomaly) { repository in
      try repository.restore(rule: anomaly.rule, subject: anomaly.subject)
    }
  }

  /// The rule is a word of ours; the subject may carry a category or a description, and
  /// never reaches the journal.
  private func write(
    _ failure: String, _ anomaly: Anomaly, _ body: (AnomalyRepository) throws -> Void
  ) -> String? {
    let rule = LogPair("rule", .token(anomaly.rule.rawValue))
    guard let repository else {
      AppLog.error(
        failure, .db, "no database to write the dismissal of an anomaly to",
        [rule, LogPair("reason", .token("noDatabase"))])
      return Self.failureKey
    }
    do {
      try body(repository)
    } catch {
      AppLog.error(
        failure, .db, "the dismissal of an anomaly was not written",
        [rule, LogPair("error", .error(error)), LogPair("code", .count((error as NSError).code))])
      return Self.failureKey
    }
    recount()
    return nil
  }
}
