import CoreKit
import Testing

@testable import CoreAnalytics

@Suite struct ChangeBaseTests {
  private func rub(_ value: Int64) -> AmountE4 { AmountE4(whole: value) }

  @Test func aOneRubleBaseIsNotComparable() {
    let change = Change(current: rub(3_000), previous: rub(1))
    #expect(change.base == .negligible)
    #expect(change.basisPoints == nil)
    #expect(change.delta == rub(2_999))
  }

  @Test func underOneHundredRublesIsNotComparable() {
    let change = Change(current: rub(150), previous: rub(99))
    #expect(change.base == .negligible)
    #expect(change.basisPoints == nil)
  }

  @Test func exactlyOneHundredRublesIsComparable() {
    let change = Change(current: rub(150), previous: rub(100))
    #expect(change.base == .comparable)
    #expect(change.basisPoints == 5_000)
  }

  @Test func underOnePercentOfCurrentIsNotComparable() {
    // 1 % of 50 000 is 500: 400 is under it, 500 is not.
    #expect(Change(current: rub(50_000), previous: rub(400)).base == .negligible)
    #expect(Change(current: rub(50_000), previous: rub(500)).base == .comparable)
  }

  @Test func nothingLastTimeIsNone() {
    #expect(Change(current: rub(500), previous: .zero).base == .none)
  }

  @Test func aNegativeBaseIsJudgedBySize() {
    #expect(Change(current: .zero, previous: rub(-100)).basisPoints == 10_000)
    #expect(Change(current: rub(10), previous: rub(-50)).base == .negligible)
  }
}
