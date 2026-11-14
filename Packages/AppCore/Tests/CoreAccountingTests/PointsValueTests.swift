import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Bank points counted in rubles at the rate of the currency of their account, against cashback
/// in money, and the notice before some of them burn. Synthetic numbers.
@Suite("Points are worth what their rate says")
struct PointsValueTests {
  func whole(_ value: Int) -> AmountE4 { AmountE4(whole: Int64(value)) }

  @Test func pointsAreWorthTheirRate() {
    #expect(
      PointsValue.rubles(points: whole(500), rubPerPoint: Decimal(string: "0.8")!) == whole(400))
    #expect(PointsValue.rubles(points: whole(500), rubPerPoint: 1) == whole(500))
  }

  @Test func fivePercentInPointsAgainstThreePercentInMoney() {
    // 5 % in points at 0.8 is 4 % of 10,000: 400 against 300.
    let better = PointsValue.compare(
      pointsPercent: 5, rubPerPoint: Decimal(string: "0.8")!, moneyPercent: 3, spent: whole(10_000))
    #expect(better.verdict == .points && better.pointsRubles == whole(400))
    #expect(better.moneyRubles == whole(300) && better.difference == whole(100))
    #expect(better.pointsEffectivePercent == 4)
    // At half a ruble a point, 2.5 % loses to 3 %.
    let worse = PointsValue.compare(
      pointsPercent: 5, rubPerPoint: Decimal(string: "0.5")!, moneyPercent: 3, spent: whole(10_000))
    #expect(worse.verdict == .money && worse.difference == whole(50))
    let tie = PointsValue.compare(
      pointsPercent: 5, rubPerPoint: Decimal(string: "0.6")!, moneyPercent: 3, spent: whole(10_000))
    #expect(tie.verdict == .same && tie.difference == .zero)
  }

  @Test func theBurningIsAnnouncedWithinThirtyDaysAndNeverAfterItsDay() {
    let today = DateOnly(iso: "2026-11-12")!
    let soon = PaymentMethod(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "A",
      pointsBurn: PointsBurn(on: DateOnly(iso: "2026-12-01")!, amountE4: whole(300)))
    let all = PaymentMethod(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "B",
      pointsBurn: PointsBurn(on: DateOnly(iso: "2026-11-12")!))
    let far = PaymentMethod(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "C",
      pointsBurn: PointsBurn(on: DateOnly(iso: "2027-03-01")!, amountE4: whole(10)))
    let past = PaymentMethod(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "D",
      pointsBurn: PointsBurn(on: DateOnly(iso: "2026-11-01")!, amountE4: whole(10)))
    let archived = PaymentMethod(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, name: "E", archived: true,
      pointsBurn: PointsBurn(on: DateOnly(iso: "2026-11-20")!, amountE4: whole(10)))
    let empty = PaymentMethod(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, name: "F",
      pointsBurn: PointsBurn(on: DateOnly(iso: "2026-11-20")!))
    let notices = PointsValue.burning(
      accounts: [far, past, soon, archived, all, empty], today: today,
      balances: [all.id: whole(80)],
      rubPerPoint: [soon.id: Decimal(string: "0.5")!])
    #expect(notices.map(\.accountId) == [all.id, soon.id])
    #expect(notices[0].daysLeft == 0 && notices[0].points == whole(80) && notices[0].rubles == nil)
    #expect(notices[1].daysLeft == 19 && notices[1].rubles == whole(150))
  }
}
