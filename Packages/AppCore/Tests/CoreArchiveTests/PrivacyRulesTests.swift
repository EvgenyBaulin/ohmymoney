import Foundation
import Testing

@testable import CoreArchive

@Suite("Recording policy")
struct RecordingPolicyTests {
  @Test("nothing watches and nothing was pressed: amounts stay")
  func idle() {
    let decision = RecordingPolicy.decide(.init())
    #expect(!decision.hide)
    #expect(decision.reason == nil)
  }

  @Test("a capture hides the amounts when the setting is on")
  func captureHides() {
    for capture: RecordingPolicy.Capture in [.recording, .mirroring, .sharing, [.recording, .sharing]] {
      let decision = RecordingPolicy.decide(.init(capture: capture, autoHideOnCapture: true))
      #expect(decision.hide)
      #expect(decision.reason == .capture)
    }
  }

  @Test("a capture does nothing when the setting is off")
  func captureIgnoredWhenOff() {
    let decision = RecordingPolicy.decide(.init(capture: .recording, autoHideOnCapture: false))
    #expect(!decision.hide)
  }

  @Test("the owner's own press always hides and is named first")
  func manualWins() {
    let alone = RecordingPolicy.decide(.init(autoHideOnCapture: false, manuallyHidden: true))
    #expect(alone.hide && alone.reason == .manual)
    let both = RecordingPolicy.decide(
      .init(capture: .recording, autoHideOnCapture: true, manuallyHidden: true))
    #expect(both.reason == .manual)
  }

  @Test("reasons are tokens and the default is on")
  func tokens() {
    #expect(RecordingPolicy.Reason.allCases.allSatisfy { $0.rawValue.hasPrefix("privacy.hide.") })
    #expect(PrivacySettings.autoHideOnCaptureDefault)
    #expect(PrivacySettings.autoHideOnCaptureKey == "privacy.autoHideOnCapture")
  }
}

@Suite("Read-only mode")
struct ReadOnlyModeTests {
  @Test("off allows every action")
  func off() {
    let mode = ReadOnlyMode()
    for action in ReadOnlyAction.allCases { #expect(mode.allows(action)) }
    #expect(mode.forbidden.isEmpty)
  }

  @Test("on forbids writing, editing, deleting, undo, import, restore and moving data")
  func on() {
    let mode = ReadOnlyMode().turnedOn()
    for action in ReadOnlyAction.allCases { #expect(!mode.allows(action)) }
    #expect(Set(mode.forbidden) == [.write, .edit, .delete, .undo, .importData, .restore, .moveData])
  }

  @Test("leaving needs a confirmation from Touch ID or the password of the Mac")
  func leaving() {
    let on = ReadOnlyMode(isOn: true)
    #expect(on.leaving(unlockedByAuthentication: false).isOn)
    #expect(!on.leaving(unlockedByAuthentication: true).isOn)
    let off = ReadOnlyMode()
    #expect(!off.leaving(unlockedByAuthentication: false).isOn)
  }

  @Test("an unconfirmed attempt does not unlock any action")
  func attemptDoesNotUnlock() {
    let after = ReadOnlyMode(isOn: true).leaving(unlockedByAuthentication: false)
    for action in ReadOnlyAction.allCases { #expect(!after.allows(action)) }
  }
}

@Suite("Storage report")
struct StorageReportTests {
  let facts = StorageFacts(
    tableRows: ["transactions": 1200, "people": 4, "places": 0, "tags": 4],
    databaseBytes: 12_345_678, attachmentCount: 3, attachmentBytes: 4_500_000, backupCount: 20,
    backupBytes: 250_000_000, journalCount: 2, journalBytes: 900)

  @Test("records add up and empty tables are left out")
  func records() {
    let report = StorageReport(facts)
    #expect(report.totalRecords == 1208)
    #expect(report.tables.map(\.name) == ["transactions", "people", "tags"])
    #expect(report.line(.records).count == 1208)
    #expect(report.line(.records).key == "privacy.storage.records")
  }

  @Test("the lines come in the order of the sections with counts and sizes")
  func lines() {
    let report = StorageReport(facts)
    #expect(report.lines.map(\.section) == StorageReport.Section.allCases)
    #expect(report.line(.attachments).count == 3)
    #expect(report.line(.attachments).bytes == 4_500_000)
    #expect(report.line(.backups).count == 20)
    #expect(report.line(.journal).size?.unit == .bytes)
    #expect(report.totalBytes == 12_345_678 + 4_500_000 + 250_000_000 + 900)
  }

  @Test("sizes are decimal with one digit and a point")
  func sizes() {
    #expect(StorageSize(bytes: 0).number == "0")
    #expect(StorageSize(bytes: 999).number == "999")
    #expect(StorageSize(bytes: 12_345_678).number == "12.3")
    #expect(StorageSize(bytes: 12_345_678).unit == .megabytes)
    #expect(StorageSize(bytes: 1_000).number == "1.0")
    #expect(StorageSize(bytes: 2_560_000_000).unit == .gigabytes)
    #expect(StorageSize(bytes: -5).number == "0")
  }

  @Test("negative numbers are read as zero")
  func negatives() {
    let report = StorageReport(StorageFacts(databaseBytes: -1, attachmentCount: -2))
    #expect(report.totalBytes == 0)
    #expect(report.line(.attachments).count == 0)
  }

  @Test("equal counts are ordered by name")
  func order() {
    let report = StorageReport(StorageFacts(tableRows: ["b": 1, "a": 1, "c": 2]))
    #expect(report.tables.map(\.name) == ["c", "a", "b"])
  }
}

@Suite("Privacy journal rules")
struct PrivacyJournalRulesTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  func event(daysAgo: Double, kind: PrivacyEventKind = .unlocked) -> PrivacyEvent {
    PrivacyEvent(at: now.addingTimeInterval(-daysAgo * 86_400), kind: kind)
  }

  @Test("the term is 365 days by default and is kept inside 1…3650")
  func term() {
    #expect(PrivacyJournalRules.days(stored: nil) == 365)
    #expect(PrivacyJournalRules.days(stored: 90) == 90)
    #expect(PrivacyJournalRules.days(stored: 0) == 1)
    #expect(PrivacyJournalRules.days(stored: -4) == 1)
    #expect(PrivacyJournalRules.days(stored: 100_000) == 3650)
    #expect(PrivacySettings.journalDaysKey == "privacy.journalDays")
  }

  @Test("only lines older than the term are cut, the rest stays in order")
  func retention() {
    let events = [event(daysAgo: 400), event(daysAgo: 366), event(daysAgo: 365), event(daysAgo: 1)]
    let kept = PrivacyJournalRules.retained(events, now: now, days: 365)
    #expect(kept.map(\.id) == [events[2].id, events[3].id])
    #expect(PrivacyJournalRules.expiredIds(events, now: now, days: 365) == [events[0].id, events[1].id])
  }

  @Test("a shorter term cuts more")
  func shorter() {
    let events = [event(daysAgo: 40), event(daysAgo: 10)]
    #expect(PrivacyJournalRules.retained(events, now: now, days: 30).count == 1)
    #expect(PrivacyJournalRules.retained(events, now: now, days: 365).count == 2)
  }

  @Test("a line holds a token and a counter, never a sum or a name")
  func tokensOnly() throws {
    #expect(PrivacyEventKind.allCases.allSatisfy { $0.rawValue.hasPrefix("privacy.event.") })
    let line = PrivacyEvent(at: now, kind: .copyExportedAnonymized, count: 1200)
    let data = try JSONEncoder().encode(line)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["id", "at", "kind", "count"])
    #expect(object["kind"] as? String == "privacy.event.copyExportedAnonymized")
  }
}
