import Foundation
import Testing

@testable import CoreArchive

/// The rule of keeping copies (day, week, month) and the plan of freeing space.
@Suite("Thinning of the copies of the database")
struct BackupThinningTests {
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
  }()

  /// Noon of 2026-10-20, Moscow.
  static let now = date(2026, 10, 20, 12, 0)

  static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
  }

  static func days(ago: Int, hour: Int = 10, minute: Int = 0) -> Date {
    let day = calendar.date(byAdding: .day, value: -ago, to: calendar.startOfDay(for: now))!
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
  }

  static func entry(
    _ id: String, ago: Int, hour: Int = 10, kind: BackupEntry.Kind = .change,
    verified: Bool = true, bytes: Int64 = 1_000
  ) -> BackupEntry {
    BackupEntry(
      id: id, moment: days(ago: ago, hour: hour), kind: kind, isVerified: verified, bytes: bytes)
  }

  static func deleted(_ entries: [BackupEntry]) -> Set<String> {
    Set(BackupThinning.deletions(of: entries, now: now, calendar: calendar).map(\.id))
  }

  static func ageInDays(_ entry: BackupEntry) -> Int {
    calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: entry.moment), to: calendar.startOfDay(for: now)
    ).day ?? 0
  }

  @Test func everyCopyOfTodayStays() {
    let copies = (0..<12).map { Self.entry("t\($0)", ago: 0, hour: $0) }
    #expect(Self.deleted(copies).isEmpty)
  }

  @Test func theLastWeekKeepsTheLatestOfEachDay() {
    let copies = [
      Self.entry("a", ago: 1, hour: 9), Self.entry("b", ago: 1, hour: 18),
      Self.entry("c", ago: 3, hour: 8), Self.entry("d", ago: 3, hour: 9),
    ]
    #expect(Self.deleted(copies) == ["a", "c"])
  }

  @Test func thePastYearKeepsTheLatestOfEachWeek() {
    // 2026-10-05 is a Monday, 15 days ago: Monday to Sunday (9 days ago) is one week, and
    // Sunday 4 Oct (16 days ago) is the week before.
    let copies = [
      Self.entry("mon", ago: 15), Self.entry("tue", ago: 14), Self.entry("sun", ago: 9),
      Self.entry("prev", ago: 16),
    ]
    let gone = Self.deleted(copies)
    #expect(gone.contains("mon") && gone.contains("tue"))
    #expect(!gone.contains("sun") && !gone.contains("prev"))
  }

  @Test func olderThanAYearKeepsTheLatestOfEachMonth() {
    let copies = [
      Self.entry("x1", ago: 500), Self.entry("x2", ago: 499), Self.entry("x3", ago: 470),
    ]
    let gone = Self.deleted(copies)
    let months = Set(copies.map { Self.calendar.component(.month, from: $0.moment) })
    for month in months {
      let ofMonth = copies.filter { Self.calendar.component(.month, from: $0.moment) == month }
      let kept = ofMonth.filter { !gone.contains($0.id) }
      #expect(kept.count == 1)
      #expect(kept.first?.id == ofMonth.sorted(by: BackupThinning.newer).first?.id)
    }
  }

  @Test func aCopyBeforeAnUpdateIsNeverDeleted() {
    let copies = (0..<5).map { Self.entry("u\($0)", ago: 400 + $0, kind: .beforeUpdate) }
    #expect(Self.deleted(copies).isEmpty)
  }

  /// The copy of the morning is not pushed out by the copies after changes of the evening: from
  /// the next day on it is still the copy of its day.
  @Test func theCopyOfTheDayKeepsItsPlaceAgainstTheCopiesAfterChanges() {
    var copies = [Self.entry("daily", ago: 3, hour: 9, kind: .daily)]
    copies += (10...22).map { Self.entry("change\($0)", ago: 3, hour: $0) }
    let gone = Self.deleted(copies)
    #expect(!gone.contains("daily"))
    #expect(gone == Set((10...21).map { "change\($0)" }))
  }

  @Test func theCopiesOfTheDayAreThinnedAmongThemselves() {
    let copies = [
      Self.entry("d1", ago: 3, hour: 6, kind: .daily),
      Self.entry("d2", ago: 3, hour: 15, kind: .daily),
      Self.entry("w1", ago: 40, hour: 6, kind: .daily),
      Self.entry("w2", ago: 47, hour: 6, kind: .daily),
      Self.entry("o1", ago: 40, hour: 7), Self.entry("o2", ago: 47, hour: 7),
    ]
    let gone = Self.deleted(copies)
    #expect(gone.contains("d1") && !gone.contains("d2"))
    // Dailies in different weeks each keep their week; so do the others of those weeks.
    #expect(!gone.contains("w1") && !gone.contains("w2"))
    #expect(!gone.contains("o1") && !gone.contains("o2"))
  }

  @Test func aCopyIsNotDeletedWhileANewerOneIsNotVerified() {
    let copies = [
      Self.entry("new", ago: 2, hour: 20, verified: false),
      Self.entry("mid", ago: 2, hour: 12),
      Self.entry("old", ago: 2, hour: 8),
    ]
    #expect(Self.deleted(copies).isEmpty)
    let fine = copies.map { copy -> BackupEntry in
      var copy = copy
      copy.isVerified = true
      return copy
    }
    #expect(Self.deleted(fine) == ["mid", "old"])
  }

  @Test func anUnverifiedCopyIsNeverDeleted() {
    let copies = [
      Self.entry("a", ago: 3, hour: 20), Self.entry("bad", ago: 3, hour: 10, verified: false),
    ]
    #expect(!Self.deleted(copies).contains("bad"))
  }

  /// Years of synthetic copies: the invariants of the rule, on many random histories.
  @Test func propertiesHoldOverYearsOfCopies() {
    var random = SplitMix(seed: 20_261_020)
    let kinds: [BackupEntry.Kind] = [
      .change, .change, .change, .daily, .beforeUpdate, .beforeRestore, .beforeImport,
    ]
    for round in 0..<60 {
      var copies: [BackupEntry] = []
      let count = Int(random.next() % 700) + 20
      for index in 0..<count {
        copies.append(
          Self.entry(
            "r\(round)-\(index)", ago: Int(random.next() % 1_100),
            hour: Int(random.next() % 24),
            kind: kinds[Int(random.next() % UInt64(kinds.count))],
            verified: random.next() % 40 != 0))
      }
      let gone = Self.deleted(copies)
      let byId = Dictionary(uniqueKeysWithValues: copies.map { ($0.id, $0) })
      let sorted = copies.sorted(by: BackupThinning.newer)
      for id in gone {
        let copy = byId[id]!
        #expect(copy.kind != .beforeUpdate)
        #expect(copy.isVerified)
        let newer = sorted.prefix(while: { $0.id != id })
        #expect(newer.allSatisfy { $0.isVerified })
      }
      for copy in copies where Self.ageInDays(copy) <= 0 {
        #expect(!gone.contains(copy.id))
      }
      if let newest = sorted.first(where: { $0.kind != .beforeUpdate }) {
        #expect(!gone.contains(newest.id))
      }
      // The week keeps the latest verified copy of every day, of the copies of the day and of
      // the others each on its own.
      let kept = copies.filter { !gone.contains($0.id) }
      for age in 1...BackupThinning.dailyDays {
        for daily in [true, false] {
          let ofDay = copies.filter {
            $0.kind != .beforeUpdate && $0.isVerified && Self.ageInDays($0) == age
              && ($0.kind == .daily) == daily
          }
          if let latest = ofDay.sorted(by: BackupThinning.newer).first {
            #expect(kept.contains(latest), "\(daily ? "daily" : "other") of \(age) days ago")
          }
        }
      }
      // A copy of the day is still there however old, one a month: the one older than a year
      // that the button for space may take.
      let oldDailies = copies.filter {
        $0.kind == .daily && $0.isVerified && Self.ageInDays($0) > BackupThinning.weeklyDays
      }
      if let latest = oldDailies.sorted(by: BackupThinning.newer).first {
        #expect(kept.contains(latest))
      }
      // A second pass over what is left has nothing more to delete when nothing is unverified.
      if copies.allSatisfy { $0.isVerified } {
        #expect(Self.deleted(kept).isEmpty)
      }
    }
  }

  // MARK: Free space

  static let gigabyte: Int64 = 1_000_000_000

  @Test func theWarningStartsBelowAGigabyteExactly() {
    #expect(BackupSpace.isLow(freeBytes: Self.gigabyte - 1))
    #expect(!BackupSpace.isLow(freeBytes: Self.gigabyte))
    #expect(!BackupSpace.isLow(freeBytes: Self.gigabyte + 1))
  }

  @Test func freeingTakesTheOldestChangesFirstThenDailiesOlderThanAYear() {
    let entries = [
      Self.entry("c-new", ago: 0, bytes: 100), Self.entry("c-mid", ago: 30, bytes: 100),
      Self.entry("c-old", ago: 200, bytes: 100),
      Self.entry("d-old", ago: 500, kind: .daily, bytes: 100),
      Self.entry("d-young", ago: 100, kind: .daily, bytes: 100),
      Self.entry("u", ago: 800, kind: .beforeUpdate, bytes: 100),
      Self.entry("r", ago: 700, kind: .beforeRestore, bytes: 100),
    ]
    let plan = BackupSpace.freeUp(
      entries: entries, freeBytes: 0, now: Self.now, calendar: Self.calendar)
    #expect(plan.removals.map(\.id) == ["c-old", "c-mid", "d-old"])
    #expect(plan.staysLow)
    #expect(plan.bytes == 300)
  }

  @Test func freeingStopsOnceThereIsRoom() {
    let entries = [
      Self.entry("a", ago: 300, bytes: 600_000_000),
      Self.entry("b", ago: 200, bytes: 600_000_000),
      Self.entry("c", ago: 100, bytes: 600_000_000), Self.entry("n", ago: 0, bytes: 1),
    ]
    let plan = BackupSpace.freeUp(
      entries: entries, freeBytes: 500_000_000, now: Self.now, calendar: Self.calendar)
    #expect(plan.removals.map(\.id) == ["a"])
    #expect(!plan.staysLow)
  }

  @Test func nothingToFreeWhenThereIsRoomOrNothingMayGo() {
    let entries = [Self.entry("only", ago: 0), Self.entry("u", ago: 900, kind: .beforeUpdate)]
    #expect(
      BackupSpace.freeUp(
        entries: entries, freeBytes: Self.gigabyte, now: Self.now, calendar: Self.calendar
      ).isEmpty)
    let plan = BackupSpace.freeUp(
      entries: entries, freeBytes: 10, now: Self.now, calendar: Self.calendar)
    #expect(plan.isEmpty && plan.staysLow)
  }

  @Test func freeingNeverTouchesAnUnverifiedOrAShadowedCopy() {
    let entries = [
      Self.entry("bad", ago: 5, verified: false), Self.entry("older", ago: 50),
      Self.entry("newest", ago: 0),
    ]
    let plan = BackupSpace.freeUp(
      entries: entries, freeBytes: 0, now: Self.now, calendar: Self.calendar)
    #expect(plan.isEmpty)
  }

  @Test func beforeUpdateCleanupLeavesTheNewestAndAnythingUnderAYear() {
    let entries = [
      Self.entry("u1", ago: 900, kind: .beforeUpdate),
      Self.entry("u2", ago: 500, kind: .beforeUpdate),
      Self.entry("u3", ago: 100, kind: .beforeUpdate), Self.entry("c", ago: 900),
    ]
    let gone = BackupSpace.beforeUpdateOlderThanAYear(
      entries: entries, now: Self.now, calendar: Self.calendar)
    #expect(gone.map(\.id) == ["u1", "u2"])
    let single = [Self.entry("only", ago: 900, kind: .beforeUpdate)]
    #expect(
      BackupSpace.beforeUpdateOlderThanAYear(
        entries: single, now: Self.now, calendar: Self.calendar
      ).isEmpty)
  }

  @Test func theDailyRunIsAtThreeLocal() {
    let next = BackupSpace.nextDailyRun(after: Self.now, calendar: Self.calendar)
    #expect(next == Self.date(2026, 10, 21, 3, 0))
    let early = Self.date(2026, 10, 20, 1, 0)
    #expect(
      BackupSpace.nextDailyRun(after: early, calendar: Self.calendar)
        == Self.date(2026, 10, 20, 3, 0))
  }
}

@Suite("The weekly check of the database")
struct IntegrityScheduleTests {
  let now = Date(timeIntervalSince1970: 1_790_000_000)

  @Test func neverCheckedIsDue() {
    #expect(IntegritySchedule.isDue(lastCheck: nil, now: now))
  }

  @Test func aWeekMakesItDueAndLessDoesNot() {
    let week = IntegritySchedule.interval
    #expect(!IntegritySchedule.isDue(lastCheck: now.addingTimeInterval(-week + 1), now: now))
    #expect(IntegritySchedule.isDue(lastCheck: now.addingTimeInterval(-week), now: now))
    #expect(IntegritySchedule.isDue(lastCheck: now.addingTimeInterval(-week - 1), now: now))
    #expect(!IntegritySchedule.isDue(lastCheck: now, now: now))
  }

  @Test func aCheckFromTheFutureMeansNothing() {
    #expect(IntegritySchedule.isDue(lastCheck: now.addingTimeInterval(86_400), now: now))
  }
}

private struct SplitMix {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
