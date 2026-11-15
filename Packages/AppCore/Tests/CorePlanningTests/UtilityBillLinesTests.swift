import CoreKit
import Foundation
import Testing

@testable import CorePlanning

// Synthetic data only.

@Suite("Utilities: editing the lines of a bill")
struct UtilityBillLinesTests {
  static let at = Date(timeIntervalSince1970: 1_790_000_000)
  static let bill = UtilityBill(
    provider: "Provider", period: MonthKey(year: 2026, month: 11),
    totalE4: AmountE4(whole: 999), recordedAt: at)

  static func charge(_ service: String, _ amount: Int64, sort: Int) -> UtilityCharge {
    UtilityCharge(
      billId: bill.id, service: service, amountE4: AmountE4(whole: amount), sort: sort)
  }

  @Test func theTotalFollowsTheLinesAndARecalculationBelowZeroLowersIt() {
    let drafts = [
      UtilityBillLines.Draft(service: "Water", amountE4: AmountE4(whole: 300)),
      UtilityBillLines.Draft(service: "Heat", amountE4: AmountE4(whole: 1_200)),
      UtilityBillLines.Draft(service: "Recalculation", amountE4: AmountE4(whole: -100)),
    ]
    let edit = UtilityBillLines.edit(bill: Self.bill, drafts: drafts, stored: [])
    #expect(edit.bill.totalE4 == AmountE4(whole: 1_400))
    #expect(edit.charges.map(\.sort) == [0, 1, 2])
    #expect(edit.deletedChargeIDs.isEmpty)
  }

  @Test func aBillWithoutLinesKeepsItsTypedTotalAndABlankLineIsNotWritten() {
    let blank = UtilityBillLines.Draft(service: "  ", amountE4: AmountE4(whole: 5))
    let edit = UtilityBillLines.edit(bill: Self.bill, drafts: [blank], stored: [])
    #expect(edit.bill.totalE4 == AmountE4(whole: 999))
    #expect(edit.charges.isEmpty)
  }

  @Test func changingAddingAndRemovingLinesWritesTheRightRowsAndTotal() {
    let water = Self.charge("Water", 300, sort: 0)
    let heat = Self.charge("Heat", 1_200, sort: 1)
    let other = UtilityCharge(
      billId: UUID(), service: "Other bill", amountE4: AmountE4(whole: 7))
    var drafts = UtilityBillLines.lines(of: Self.bill, in: [heat, other, water])
    #expect(drafts.map(\.service) == ["Water", "Heat"])
    drafts[0].amountE4 = AmountE4(whole: 350)  // change
    drafts[0].quantityE4 = AmountE4(whole: 7)
    drafts.removeLast()  // remove the heat line
    drafts.append(.init(service: "Gas", amountE4: AmountE4(whole: 80)))  // add
    let edit = UtilityBillLines.edit(
      bill: Self.bill, drafts: drafts, stored: [water, heat, other])
    #expect(edit.bill.totalE4 == AmountE4(whole: 430))
    #expect(edit.charges.map(\.service) == ["Water", "Gas"])
    #expect(edit.charges[0].id == water.id && edit.charges[0].quantityE4 == AmountE4(whole: 7))
    #expect(edit.deletedChargeIDs == [heat.id], "only a line of this bill is deleted")
  }

  @Test func removingEveryLineKeepsTheLastTotalAsTheBillStandsAndDeletesTheLines() {
    let water = Self.charge("Water", 300, sort: 0)
    let edit = UtilityBillLines.edit(bill: Self.bill, drafts: [], stored: [water])
    #expect(edit.bill.totalE4 == Self.bill.totalE4)
    #expect(edit.deletedChargeIDs == [water.id])
  }
}
