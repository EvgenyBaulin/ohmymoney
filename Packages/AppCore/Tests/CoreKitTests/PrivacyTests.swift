import Foundation
import Testing

@testable import CoreKit

// Synthetic data only.

@Suite("The privacy settings and the journal of openings")
struct PrivacyTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private static func entry(
    daysAgo: Double, _ event: PrivacyJournalEntry.Event
  )
    -> PrivacyJournalEntry
  {
    PrivacyJournalEntry(at: now.addingTimeInterval(-daysAgo * 86_400), event: event)
  }

  // MARK: Settings

  @Test func everyKeyReadsItsDefaultWhenAbsent() {
    let settings = PrivacySettings(storedValues: [:])
    #expect(settings.autoHideOnCapture)
    #expect(!settings.readOnly)
    #expect(settings.journalDays == 365)
    #expect(settings == PrivacySettings())
  }

  @Test func storedTextsRoundTripAndUnreadableOnesGiveTheDefault() {
    let changed = PrivacySettings(autoHideOnCapture: false, readOnly: true, journalDays: 30)
    #expect(PrivacySettings(storedValues: changed.storedValues) == changed)
    let broken = PrivacySettings(storedValues: [
      PrivacySettings.autoHideOnCaptureKey: "maybe", PrivacySettings.readOnlyKey: "",
      PrivacySettings.journalDaysKey: "a year",
    ])
    #expect(broken == PrivacySettings())
  }

  @Test func theDaysOfTheJournalStayInsideTheirRange() {
    #expect(PrivacySettings(journalDays: 0).journalDays == 1)
    #expect(PrivacySettings(journalDays: -5).journalDays == 1)
    #expect(PrivacySettings(journalDays: 100_000).journalDays == 3650)
    #expect(Set(PrivacySettings.storageKeys).count == 3)
  }

  // MARK: Entries

  @Test func everyEventHasATokenThatReadsBack() {
    var events: [PrivacyJournalEntry.Event] = [
      .opened, .locked, .hiddenShown, .exportedCopy, .readOnlyOn, .readOnlyOff,
    ]
    for method in PrivacyJournalEntry.UnlockMethod.allCases {
      events.append(.unlocked(method: method))
    }
    for event in events {
      #expect(PrivacyJournalEntry.Event(token: event.token) == event, "\(event.token)")
    }
    #expect(Set(events.map(\.token)).count == events.count, "no two events share a token")
    #expect(PrivacyJournalEntry.Event(token: "unlocked:face") == nil)
    #expect(PrivacyJournalEntry.Event(token: "somethingNew") == nil)
  }

  @Test func aLineIsJSONWithSortedKeysAndNoAmountOrName() throws {
    let line = try PrivacyJournal.line(
      for: PrivacyJournalEntry(
        at: Date(timeIntervalSince1970: 1_800_000_000), event: .unlocked(method: .touchID)))
    #expect(line == #"{"at":"2027-01-15T08:00:00Z","event":"unlocked:touchID"}"#)
    #expect(!line.contains("\n"))
  }

  @Test func aLineRoundTripsToTheSecond() throws {
    let entry = PrivacyJournalEntry(
      at: Date(timeIntervalSince1970: 1_800_000_000.75), event: .hiddenShown)
    let line = try PrivacyJournal.line(for: entry)
    #expect(PrivacyJournal.entries(in: line) == [entry])
    #expect(entry.at.timeIntervalSince1970 == 1_800_000_000)
  }

  @Test func aTornOrUnknownLineIsSkippedAndTheRestStillReads() throws {
    let good = try PrivacyJournal.line(for: Self.entry(daysAgo: 1, .opened))
    let later = try PrivacyJournal.line(for: Self.entry(daysAgo: 0, .locked))
    let text =
      good + "\n" + #"{"at":"2027-01-15T08:0"# + "\n"
      + #"{"at":"2027-01-15T08:00:00Z","event":"fromTheFuture"}"# + "\n" + later + "\n"
    let read = PrivacyJournal.entries(in: text)
    #expect(read.map(\.event) == [.opened, .locked])
    #expect(PrivacyJournal.entries(in: "").isEmpty)
  }

  // MARK: Keeping

  @Test func aLineOlderThanTheDaysKeptGoesAndTheRestStayInOrder() {
    let entries = [
      Self.entry(daysAgo: 400, .opened), Self.entry(daysAgo: 366, .locked),
      Self.entry(daysAgo: 300, .opened), Self.entry(daysAgo: 10, .exportedCopy),
      Self.entry(daysAgo: 0, .opened),
    ]
    let kept = PrivacyJournal.kept(entries, now: Self.now)
    #expect(kept.count == 3)
    #expect(kept.map(\.event) == [.opened, .exportedCopy, .opened])
    #expect(kept == kept.sorted { $0.at < $1.at })
  }

  @Test func theLineOfTheLastKeptDayStaysAndTheNextOneGoes() {
    let edge = PrivacyJournalEntry(
      at: PrivacyJournal.cutoff(now: Self.now, days: 365), event: .opened)
    let beyond = PrivacyJournalEntry(
      at: PrivacyJournal.cutoff(now: Self.now, days: 365).addingTimeInterval(-1), event: .opened)
    #expect(PrivacyJournal.kept([edge, beyond], now: Self.now) == [edge])
  }

  @Test func theDaysKeptFollowTheSettingAndAreClamped() {
    let entries = [Self.entry(daysAgo: 40, .opened), Self.entry(daysAgo: 5, .opened)]
    #expect(PrivacyJournal.kept(entries, now: Self.now, days: 30).count == 1)
    #expect(PrivacyJournal.kept(entries, now: Self.now, days: 90).count == 2)
    #expect(PrivacyJournal.kept(entries, now: Self.now, days: 0).isEmpty, "a day at the least")
  }
}
