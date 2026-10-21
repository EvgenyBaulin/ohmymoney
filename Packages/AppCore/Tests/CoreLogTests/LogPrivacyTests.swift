import Foundation
import Testing

@testable import CoreLog

/// The privacy of the journal is checked by a test: the journal is run through a filter, and
/// the test fails when an amount, a title or a name got into a line. This is that filter,
/// checked on its own before it is trusted with a journal.
@Suite("The filter a journal is checked with")
struct LogPrivacyTests {
  @Test func aNameACategoryAndANoteAreFound() {
    let line = "2026-09-20T09:28:43.456+03:00 info db operation.saved \"saved Coffee for Alex\""

    #expect(
      LogPrivacy.offences(in: line, forbidding: ["Alex", "Coffee", "Groceries"]).sorted()
        == ["Alex", "Coffee"])
  }

  /// A name written without its spaces is the same leak.
  @Test func spacingDoesNotHideAValue() {
    let line = "… note=CoffeeAndABun"

    #expect(
      LogPrivacy.offences(in: line, forbidding: ["Coffee and a bun"]) == ["Coffee and a bun"])
  }

  /// An amount survives losing its separators: 12 345,67 is 1234567 in the line.
  @Test func anAmountIsFoundByItsDigits() {
    let line = "… total=1234567"

    #expect(LogPrivacy.offences(in: line, forbidding: ["12 345,67"]) == ["12 345,67"])
  }

  /// The amount is looked for in each number of the line, not in every digit of it strung
  /// together: `upserted=15 removed=0 ms=0ms` is not «1500», and neither is the second 15 and
  /// the milliseconds 004 of a stamp. Both made a clean line fail at random.
  @Test func theDigitsOfUnrelatedNumbersDoNotMakeAnAmount() {
    let counts =
      "2026-09-20T09:28:43.456+03:00 info db store.wrote \"the store wrote\" upserted=15 "
      + "removed=0 ms=0ms"
    let stamp = "2026-09-20T09:28:15.004+03:00 info app app.started \"the application started\""

    #expect(LogPrivacy.offences(in: counts, forbidding: ["1500"]) == [])
    #expect(LogPrivacy.offences(in: stamp, forbidding: ["1 500"]) == [])
  }

  /// An amount is still found by its digits inside one number, whatever separates them.
  @Test func anAmountIsFoundWhateverSeparatesItsDigits() {
    for line in ["… total=1500", "… 1 500,00 …", "… 1\u{00A0}500 …", "… 1\u{202F}500.00 …"] {
      #expect(LogPrivacy.offences(in: line, forbidding: ["1 500"]) == ["1 500"], "\(line)")
    }
  }

  @Test func aLineOfIdentifiersAndCountsIsClean() {
    let line =
      "2026-09-20T09:28:43.456+03:00 info db operation.saved \"an operation was saved\" "
      + "parts=2 category=6C7B5E1A-0000-0000-0000-000000000000 ms=12"

    #expect(
      LogPrivacy.offences(in: line, forbidding: ["Alex", "Coffee", "12 345,67", "Groceries"]) == [])
  }

  /// Something too short is not evidence: a two-letter name would match half the alphabet.
  @Test func aValueTooShortToMeanAnythingIsNotReported() {
    #expect(LogPrivacy.offences(in: "info db saved", forbidding: ["Jo", "5"]) == [])
  }

  @Test func aWholeJournalIsCheckedAtOnce() {
    let lines = ["nothing here", "… place=Пятёрочка", "… ms=12"]

    #expect(
      LogPrivacy.offences(inLines: lines, forbidding: ["Пятёрочка", "Alex"]) == ["Пятёрочка"])
  }
}

/// Five files of two megabytes, the oldest thrown away.
@Suite("Five files of two megabytes, the oldest thrown away")
struct LogRotationTests {
  @Test func theLiveFileHasNoNumberAndTheOlderOnesDo() {
    let rotation = LogRotation()
    #expect(
      rotation.names == [
        "ohmymoney.log", "ohmymoney.1.log", "ohmymoney.2.log", "ohmymoney.3.log", "ohmymoney.4.log",
      ])
  }

  @Test func aFileIsRolledOnlyWhenTheLineWouldNotFit() {
    let rotation = LogRotation(maximumBytes: 100)
    #expect(!rotation.shouldRoll(current: 0, adding: 4_000), "an empty file takes the line")
    #expect(!rotation.shouldRoll(current: 40, adding: 60))
    #expect(rotation.shouldRoll(current: 41, adding: 60))
  }

  /// Oldest first, so nothing is written over a file that has not moved yet.
  @Test func theRenamesGoFromTheOldestDown() {
    let renames = LogRotation(keep: 3).renames()
    #expect(renames.map(\.from) == ["ohmymoney.1.log", "ohmymoney.log"])
    #expect(renames.map(\.to) == ["ohmymoney.2.log", "ohmymoney.1.log"])
  }

  @Test func theOldestFileIsDroppedBeforeTheRenames() {
    #expect(LogRotation(keep: 3).dropped() == ["ohmymoney.2.log"])
  }
}
