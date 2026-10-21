import CoreArchive
import CoreKit
import Foundation
import Testing

@testable import CoreSample

/// The generator's sequence of random draws, pinned.
///
/// Hundreds of tests across the project rest on the sample being the same sample: the golden
/// numbers, `SampleExpectations`, the fixtures of `make eval-model`. One extra call to the
/// random source anywhere in the writer shifts every draw after it, and all of them go red at
/// once with no hint of why. This says why.
///
/// The digest covers what the draws decide — the identity of every operation and part, its
/// moment and its money — and nothing that a change may legitimately add: not a note, not a
/// link, not a category source. So a text made out of what was already drawn, or an operation
/// tied to the payment that explains it, leaves this test green; a new roll does not.
@Suite("The generator's sequence of draws")
struct SampleSequenceTests {
  static let endingOn = DateOnly(year: 2026, month: 9, day: 18)

  static func digest(_ set: SampleDataSet) -> String {
    var text = ""
    for entry in set.entries {
      let transaction = entry.transaction
      text += transaction.id.uuidString.lowercased()
      text += "|\(Int(transaction.occurredAt.timeIntervalSince1970))"
      text += "|\(transaction.currency.code)|\(transaction.amountE4.raw)"
      text += "|\(transaction.deletedAt == nil ? 0 : 1)\n"
      for part in entry.parts {
        text += "  \(part.id.uuidString.lowercased())|\(part.amountE4.raw)"
        text += "|\(part.categoryId?.uuidString.lowercased() ?? "-")\n"
      }
    }
    return SHA256.hexDigest(Data(text.utf8))
  }

  /// Six months, the size every other test of the project generates.
  @Test func sixMonthsDrawTheSameSequence() {
    let set = SampleDataGenerator(seed: 20_260_920).generate(
      months: 6, endingOn: Self.endingOn, calendar: .moscow, language: "en")

    #expect(set.entries.count == 419, "the number of operations moved")
    #expect(
      Self.digest(set) == "682cbd41b46464a5c93abb831598382e7cad43c2303c7516d9e3ee9232a253aa",
      """
      The generator drew a different sequence. If this was meant — a new operation, another
      amount — put the digest printed by the failure here and say why in the commit.
      If it was not, something asked the random source for one more value: find it, and take
      what it needed out of values already drawn instead.
      """)
  }

  /// The large set too: its density path draws far more, and a shift there is just as costly.
  @Test func theLargeSetDrawsTheSameSequence() {
    let set = SampleDataGenerator(seed: 20_260_918).generate(
      months: SampleDataGenerator.largeSetMonths, endingOn: Self.endingOn, calendar: .moscow,
      language: "en", density: SampleDataGenerator.largeSetDensity)

    #expect(Self.digest(set) == "76f6ce60c4f8439d005ff83c7cc0a8c5027ec78cdfc2a0133a60ea48c57ac69f")
  }
}
