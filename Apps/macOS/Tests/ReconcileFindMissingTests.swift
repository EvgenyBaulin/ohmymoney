import AppCore
import XCTest

@testable import OhMyMoney

/// «Найти пропущенные…» in the reconciliation sheet shows «Операции» from the day of the last
/// reconciliation to today, and the sheet steps aside so the table can be seen. What the owner
/// typed into the sheet is not lost: it is kept, and the sheet opened again starts from it.
@MainActor
final class ReconcileFindMissingTests: XCTestCase {
  private let sber = UUID()

  override func tearDown() async throws {
    _ = ReconcileDraftKeeper.shared.take()
  }

  private var typing: ReconcileTyping {
    ReconcileTyping(
      typed: [BalanceKey(accountId: sber, currency: .rub): AmountE4(whole: 1_500)],
      blank: [], unticked: [])
  }

  func testFindingMissedOperationsClosesTheSheetAndAsksForThePeriod() {
    let environment = AppEnvironment()
    environment.showsReconciliation = true
    let last = DateOnly(year: 2026, month: 9, day: 1)
    let today = DateOnly(year: 2026, month: 9, day: 18)

    ReconcileSheet.findMissing(since: last, today: today, typing: typing, in: environment)

    XCTAssertFalse(environment.showsReconciliation)
    XCTAssertEqual(environment.pendingTransactionsRange, DayRange(last, today))
  }

  func testWhatWasTypedComesBackWhenTheSheetOpensAgain() {
    let environment = AppEnvironment()
    environment.showsReconciliation = true
    let day = DateOnly(year: 2026, month: 9, day: 18)

    ReconcileSheet.findMissing(since: day, today: day, typing: typing, in: environment)

    XCTAssertEqual(ReconcileDraftKeeper.shared.take(), typing)
    // Taken once: a sheet opened after that starts from the books again.
    XCTAssertNil(ReconcileDraftKeeper.shared.take())
  }

  func testAnUntouchedSheetKeepsNothing() {
    let environment = AppEnvironment()
    environment.showsReconciliation = true
    let day = DateOnly(year: 2026, month: 9, day: 18)

    ReconcileSheet.findMissing(
      since: day, today: day, typing: ReconcileTyping(typed: [:], blank: [], unticked: []),
      in: environment)

    XCTAssertFalse(environment.showsReconciliation)
    XCTAssertNil(ReconcileDraftKeeper.shared.take())
  }
}
