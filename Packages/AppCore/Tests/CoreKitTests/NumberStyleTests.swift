import Foundation
import Testing

@testable import CoreKit

@Suite("Number style")
struct NumberStyleTests {
  private let nbsp = "\u{00A0}"

  @Test func pointStyleIsTheDefaultWriting() {
    #expect(NumberText.amount(AmountE4(raw: 12_345_600), style: .point) == "1,234.56")
    #expect(NumberText.amount(AmountE4(raw: 12_345_600)) == "1,234.56")
  }

  @Test func spaceStyleGroupsWithNoBreakSpaceAndCommaFraction() {
    #expect(NumberText.amount(AmountE4(raw: 12_345_600), style: .space) == "1\(nbsp)234,56")
    #expect(NumberText.amount(AmountE4(raw: -12_345_600), style: .space) == "\u{2212}1\(nbsp)234,56")
    #expect(NumberText.amount(AmountE4(raw: 12_345_000_000), style: .space) == "1\(nbsp)234\(nbsp)500")
    #expect(NumberText.integer(-3_400, style: .space) == "\u{2212}3\(nbsp)400")
    #expect(NumberText.decimal(Decimal(string: "1234.5")!, fractionDigits: 2...2, style: .space) == "1\(nbsp)234,50")
  }

  @Test func textForFieldsKeepsThePointInEveryStyle() {
    #expect(NumberText.amount(AmountE4(raw: 12_345_600), grouping: false, style: .space) == "1234.56")
    #expect(NumberText.decimal(Decimal(string: "81.4321")!, grouping: false, style: .space) == "81.4321")
    #expect(NumberText.plain(Decimal(string: "1234.5")!) == "1234.5")
    #expect(TypedNumber.read("1234,56")?.canonical == "1,234.56")
  }

  @Test func countsInASentenceFollowTheStyle() {
    #expect(NumberText.groupingCounts([1250], in: "Delete 1250 rows", style: .space) == "Delete 1\(nbsp)250 rows")
    #expect(NumberText.groupingCounts([1250], in: "Delete 1250 rows", style: .point) == "Delete 1,250 rows")
  }

  @Test func theTwoStylesReadBackAsTheSameNumber() {
    let point = NumberText.amount(AmountE4(raw: 12_345_600), style: .point)
    let space = NumberText.amount(AmountE4(raw: 12_345_600), style: .space)
    #expect(TypedNumber.parse(point) == TypedNumber.parse(space.replacingOccurrences(of: nbsp, with: " ")))
  }
}
