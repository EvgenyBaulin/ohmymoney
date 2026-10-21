import AppCore
import CoreKit
import Foundation
import Testing

@testable import AppDatabase

/// «Это нормально» on an anomaly: what is stored, what is replaced and what is forgotten.
@Suite("Storage of the anomalies waved away")
struct AnomalyStorageTests {
  private func repository() throws -> (AnomalyRepository, DatabaseStack) {
    let stack = try TestSupport.makeStack()
    return (AnomalyRepository(writer: stack.writer), stack)
  }

  @Test("A dismissal is stored once per rule and subject")
  func oneRowPerThing() throws {
    let (anomalies, _) = try repository()
    let at = Date(timeIntervalSince1970: 1_789_000_000)

    try anomalies.dismiss(rule: .categorySpike, subject: "food:2026-09-07", at: at)
    try anomalies.dismiss(
      rule: .categorySpike, subject: "food:2026-09-07", at: at.addingTimeInterval(60))
    try anomalies.dismiss(rule: .badSpendingRise, subject: "2026-09-07", at: at)

    let stored = try anomalies.all()
    #expect(stored.count == 2, "the same anomaly was hidden twice and stored twice")
    #expect(
      Set(stored.map(\.key)) == ["categorySpike:food:2026-09-07", "badSpendingRise:2026-09-07"])
  }

  /// The same subject under two rules is two different things, and hiding one leaves the
  /// other alone — the whole reason the column exists.
  @Test("The subject belongs to its rule")
  func theSubjectBelongsToItsRule() throws {
    let (anomalies, _) = try repository()
    let at = Date(timeIntervalSince1970: 1_789_000_000)

    try anomalies.dismiss(rule: .categorySpike, subject: "2026-09-07", at: at)
    try anomalies.dismiss(rule: .badSpendingRise, subject: "2026-09-07", at: at)
    try anomalies.restore(rule: .categorySpike, subject: "2026-09-07")

    #expect(try anomalies.all().map(\.rule) == [.badSpendingRise])
  }

  /// A dismissal of something that no longer happens is forgotten when the next one is
  /// written, exactly the way a put-off reminder is.
  @Test("Dismissals of anomalies that no longer arise are forgotten")
  func staleOnesAreForgotten() throws {
    let (anomalies, _) = try repository()
    let at = Date(timeIntervalSince1970: 1_789_000_000)
    try anomalies.dismiss(rule: .largeExpense, subject: "gone", at: at)
    try anomalies.dismiss(rule: .categorySpike, subject: "still-here", at: at)

    try anomalies.dismiss(
      rule: .possibleDuplicate, subject: "new", at: at,
      active: ["categorySpike:still-here", "possibleDuplicate:new"])

    #expect(
      Set(try anomalies.all().map(\.key))
        == ["categorySpike:still-here", "possibleDuplicate:new"])
  }

  /// Without the list of what still happens nothing is forgotten: an empty list would
  /// otherwise mean «forget everything».
  @Test("Without a list of what still happens nothing is forgotten")
  func nothingIsForgottenBlind() throws {
    let (anomalies, _) = try repository()
    let at = Date(timeIntervalSince1970: 1_789_000_000)
    try anomalies.dismiss(rule: .largeExpense, subject: "old", at: at)

    try anomalies.dismiss(rule: .possibleDuplicate, subject: "new", at: at)

    #expect(try anomalies.all().count == 2)
  }

  /// Four of the rules are about one operation, and the dismissal names it: the row must
  /// reach the operation it points at (the key is the operation's id, stored as every other
  /// record stores it), and go when the operation is purged.
  @Test("An anomaly about an operation can be waved away and goes with the operation")
  func aDismissalAboutAnOperation() throws {
    let (anomalies, stack) = try repository()
    let transactions = TransactionRepository(writer: stack.writer)
    let entry = try TestSupport.makeEntry()
    try transactions.save(entry)
    let subject = entry.parts[0].id.uuidString.lowercased()

    try anomalies.dismiss(
      rule: .largeExpense, subject: subject, transactionId: entry.id,
      at: Date(timeIntervalSince1970: 1_789_000_000))

    let stored = try anomalies.all()
    #expect(stored.map(\.key) == ["largeExpense:\(subject)"])
    #expect(stored.first?.transactionId == entry.id)

    try transactions.purge(id: entry.id)
    #expect(try anomalies.all().isEmpty, "the dismissal outlived the operation it was about")
  }

  /// A dismissal under a rule this build does not know — written by a newer one, the book
  /// opened again by an older one — is about nothing this build finds. It hides nothing,
  /// least of all a large expense that happens to share its subject, and it is not this
  /// build's to forget.
  @Test("A dismissal under an unknown rule hides nothing and stays")
  func aDismissalUnderAnUnknownRule() throws {
    let (anomalies, stack) = try repository()
    let subject = UUID().uuidString.lowercased()
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO anomaly_dismissals (id, rule, at, subject)
          VALUES (?, 'aRuleFromANewerBuild', '2026-09-24 12:00:00.000', ?)
          """,
        arguments: [UUID().uuidString.lowercased(), subject])
    }

    #expect(try anomalies.all().isEmpty, "an unknown rule was read as another one")

    try anomalies.dismiss(rule: .categorySpike, subject: "week", active: ["categorySpike:week"])
    let rules = try stack.writer.read { db in
      try String.fetchAll(db, sql: "SELECT rule FROM anomaly_dismissals ORDER BY rule")
    }
    #expect(rules == ["aRuleFromANewerBuild", "categorySpike"])
  }

  /// The dismissals and the sensitivity come with the rest of the data, in the one read the
  /// pipeline makes: the rules must not go to the database on their own.
  @Test("The dataset carries what the rules need")
  func theDatasetCarriesThem() async throws {
    let (anomalies, stack) = try repository()
    let settings = SettingsRepository(writer: stack.writer)
    try anomalies.dismiss(
      rule: .slowReimbursement, subject: "part", at: Date(timeIntervalSince1970: 1_789_000_000))
    try settings.set(AnalyticsSettings.anomalySensitivityKey, to: AnomalySensitivity.high.rawValue)

    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)

    #expect(dataset.dismissals.map(\.key) == ["slowReimbursement:part"])
    #expect(dataset.settings.anomalySensitivity == .high)
  }
}
