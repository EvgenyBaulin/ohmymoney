import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Cashback paid as points to a separate account.
@Suite("Cashback paid as points")
struct CashbackPointsTests {
  let tBank = id(1)
  let points = id(2)
  let alfa = id(3)

  func accounts(
    tBankPoints: UUID? = nil, alfaPoints: UUID? = nil, pointsArchived: Bool = false
  ) -> [PaymentMethod] {
    [
      PaymentMethod(id: tBank, name: "T-Bank", cashbackPointsAccountId: tBankPoints),
      PaymentMethod(id: points, name: "Bonus", archived: pointsArchived),
      PaymentMethod(id: alfa, name: "Alfa", cashbackPointsAccountId: alfaPoints),
    ]
  }

  @Test func anAccountThatNamesNoneHasNothingToCheck() {
    #expect(CashbackPoints.issues(for: tBank, pointsAccountId: nil, accounts: accounts()).isEmpty)
  }

  @Test func aLiveOtherAccountIsFine() {
    #expect(
      CashbackPoints.issues(for: tBank, pointsAccountId: points, accounts: accounts()).isEmpty)
  }

  @Test func anAccountCannotBeItsOwnPointsAccount() {
    #expect(
      CashbackPoints.issues(for: tBank, pointsAccountId: tBank, accounts: accounts()) == [
        .isItself
      ])
  }

  @Test func anAccountThatIsNotThereOrIsArchived() {
    #expect(
      CashbackPoints.issues(for: tBank, pointsAccountId: id(99), accounts: accounts()) == [
        .notFound
      ])
    #expect(
      CashbackPoints.issues(
        for: tBank, pointsAccountId: points, accounts: accounts(pointsArchived: true)) == [
          .archived
        ])
  }

  /// The points of one account belong to it.
  @Test func aPointsAccountNamedOnceBelongsToThatAccount() {
    let owners = CashbackPoints.owners(among: accounts(tBankPoints: points))
    #expect(owners == [points: tBank])
  }

  /// Named by two accounts, nobody can tell whose points an income there is: left out.
  @Test func aPointsAccountNamedTwiceBelongsToNobody() {
    #expect(
      CashbackPoints.owners(among: accounts(tBankPoints: points, alfaPoints: points)).isEmpty)
    #expect(CashbackPoints.owners(among: accounts()).isEmpty)
  }

  @Test func theChoicesAreTheLiveOthers() {
    let all = accounts(pointsArchived: true)
    #expect(CashbackPoints.choices(for: tBank, among: all).map(\.id) == [alfa])
    #expect(
      CashbackPoints.choices(for: tBank, among: accounts()).map(\.id) == [points, alfa])
  }
}
