import Testing

@testable import CoreKit

@Suite("The kinds of the form stand two to a row, the most used alone when they are odd")
struct EntryKindTilesTests {
  @Test func fiveTilesPutTheMostUsedAloneOnTop() {
    let rows = EntryKindTiles.rows(of: EntryKindTiles.all, mostUsed: .kind(.expense))
    #expect(
      rows == [
        [.kind(.expense)], [.kind(.income), .kind(.reimbursement)], [.kind(.refund), .transfer],
      ])
  }

  @Test func theMostUsedIsTheOneThatStretches() {
    let rows = EntryKindTiles.rows(of: EntryKindTiles.all, mostUsed: .kind(.income))
    #expect(rows.first == [.kind(.income)])
    #expect(rows.dropFirst().allSatisfy { $0.count == 2 })
    #expect(Set(rows.flatMap { $0 }) == Set(EntryKindTiles.all), "every tile is in sight")
  }

  @Test func anEvenNumberIsPairsInTheUsualOrder() {
    let four = Array(EntryKindTiles.all.prefix(4))
    let rows = EntryKindTiles.rows(of: four, mostUsed: .kind(.refund))
    #expect(rows == [[.kind(.expense), .kind(.income)], [.kind(.reimbursement), .kind(.refund)]])
  }

  @Test func aMostUsedThatIsNotShownLetsTheFirstStretch() {
    let three: [EntryKindTile] = [.kind(.expense), .kind(.income), .kind(.refund)]
    #expect(EntryKindTiles.rows(of: three, mostUsed: .transfer).first == [.kind(.expense)])
  }

  @Test func theMostUsedKindIsCountedAndExpenseWinsATie() {
    #expect(EntryKindTiles.mostUsed(among: []) == .kind(.expense))
    #expect(EntryKindTiles.mostUsed(among: [.income, .income, .expense]) == .kind(.income))
    #expect(EntryKindTiles.mostUsed(among: [.income, .expense]) == .kind(.expense))
  }
}
