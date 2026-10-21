import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Whether each compared count of a sheet written before the update records its difference,
/// read from what the sheet left behind: 1.1 wrote an operation for every row that differed
/// when «Записать разницу» was chosen, none with «Сохранить без записи», and none for a row at
/// zero.
@Suite("The mode of a count written before the update")
struct CountsMigrationTests {
  private static let r1 = UUID()
  private static let r2 = UUID()
  private static let r3 = UUID()
  private static let r4 = UUID()

  private static func row(
    _ sheet: UUID, _ difference: Int64?, _ operation: MigratingCount.Operation
  ) -> MigratingCount {
    MigratingCount(
      id: UUID(), reconciliationId: sheet, differenceE4: difference.map { AmountE4(whole: $0) },
      operation: operation)
  }

  // The rows of the four sheets, one per line of the table of the rule.
  private static let a = row(r1, -500, .live)
  private static let b = row(r1, 0, .none)
  private static let c = row(r1, 300, .binned)
  private static let d = row(r2, 0, .none)
  private static let e = row(r2, 0, .none)
  private static let f = row(r3, -200, .none)
  private static let g = row(r3, 0, .none)
  private static let h = row(r4, 10, .none)
  private static let i = row(r4, -1_000, .live)

  private static let all = [a, b, c, d, e, f, g, h, i]
  private let modes = CountsMigration.recordsDifference(all)

  @Test func itsOwnLiveOperationRecords() {
    #expect(modes[Self.a.id] == true)
  }

  @Test func aZeroRowOfASheetWithAnOperationRecords() {
    #expect(modes[Self.b.id] == true)
  }

  @Test func itsOwnBinnedOperationKeeps() {
    #expect(modes[Self.c.id] == false)
  }

  @Test func aSheetAllAtZeroRecords() {
    #expect(modes[Self.d.id] == true)
    #expect(modes[Self.e.id] == true)
  }

  @Test func aDifferenceWithoutAnyOperationKeeps() {
    #expect(modes[Self.f.id] == false)
  }

  @Test func aZeroRowOfASheetSavedWithoutRecordingKeeps() {
    #expect(modes[Self.g.id] == false)
  }

  /// A difference in dollars had no rate in 1.1 and so no operation; its sheet recorded.
  @Test func aDifferenceWithoutARateOfARecordingSheetRecords() {
    #expect(modes[Self.h.id] == true)
  }

  @Test func theLiveRowOfThatSheetRecords() {
    #expect(modes[Self.i.id] == true)
  }

  @Test func everyRowGetsAMode() {
    #expect(Set(modes.keys) == Set(Self.all.map(\.id)))
    #expect(modes.values.filter { $0 }.count == 6)
    #expect(modes.values.filter { !$0 }.count == 3)
  }

  /// A difference that does not read is not zero: it proves nothing of «nothing to decline».
  @Test func anUnreadableDifferenceCountsAsNotZero() {
    let sheet = UUID()
    let zero = Self.row(sheet, 0, .none)
    let unreadable = Self.row(sheet, nil, .none)
    let modes = CountsMigration.recordsDifference([zero, unreadable])
    #expect(modes[zero.id] == false)
    #expect(modes[unreadable.id] == false)
    // Alone at zero, the same sheet would have recorded.
    #expect(CountsMigration.recordsDifference([zero])[zero.id] == true)
    // And an operation still proves the sheet recorded.
    let paid = Self.row(sheet, 50, .binned)
    #expect(CountsMigration.recordsDifference([unreadable, paid])[unreadable.id] == true)
  }

  /// One sheet says nothing about another: the operation of R1 does not make R3 record.
  @Test func sheetsAreJudgedApart() {
    let alone = CountsMigration.recordsDifference([Self.f, Self.g])
    let together = CountsMigration.recordsDifference([Self.a, Self.f, Self.g, Self.d])
    #expect(alone[Self.f.id] == false && alone[Self.g.id] == false)
    #expect(together[Self.f.id] == false && together[Self.g.id] == false)
    #expect(together[Self.a.id] == true && together[Self.d.id] == true)
    // The order the rows come in changes nothing.
    #expect(CountsMigration.recordsDifference(Self.all.reversed()) == modes)
  }

  @Test func noRowsNoModes() {
    #expect(CountsMigration.recordsDifference([]).isEmpty)
  }
}
