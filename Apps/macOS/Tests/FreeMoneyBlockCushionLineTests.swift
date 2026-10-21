import AppCore
import XCTest

@testable import OhMyMoney

/// The safety cushion in «Свободная сумма»: the grey line of the cushion the main figure leaves
/// out, only when it leaves something out, and the switch that keeps it out, only once an
/// account is marked as the cushion — as the switch of the events' budgets.
@MainActor
final class FreeMoneyBlockCushionLineTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 11)

  private func ready() -> FreeMoney {
    var free = DataSnapshot.build(
      dataset: Dataset(), calendar: .utc, today: today, context: SnapshotContext(),
      version: DataVersion(load: 1)
    ).planning.freeMoney
    free.state = .ready
    free.moneyNow = AmountE4(whole: 500_000)
    free.main = AmountE4(whole: 500_000)
    free.grey = AmountE4(whole: 450_000)
    return free
  }

  /// With the switch off the cushion takes nothing off: no line, the main figure is the money
  /// on the accounts, and the switch is offered only when there is a cushion to keep out.
  func testOffNothingChangesAndTheSwitchNeedsACushion() {
    let free = ready()
    XCTAssertEqual(
      FreeMoneyBlock.parts(of: free), FreeMoneyBlock.parts(of: free, hasCushion: false))
    XCTAssertFalse(FreeMoneyBlock.parts(of: free).map(\.name).contains("cushion"))
    XCTAssertFalse(FreeMoneyBlock.parts(of: free).map(\.name).contains("cushionSwitch"))
    let marked = FreeMoneyBlock.parts(of: free, hasCushion: true).map(\.name)
    XCTAssertFalse(marked.contains("cushion"))
    XCTAssertEqual(
      marked.firstIndex(of: "cushionSwitch"), marked.firstIndex(of: "reserveSwitch").map { $0 + 1 },
      "the cushion's switch stands after the switches of the plans")
  }

  /// With the cushion kept out, the main figure is «можно тратить сейчас» and the grey line of
  /// the cushion stands right after what the goals hold — or after the main figure.
  func testOnTheLineSaysWhatTheCushionTakesOff() {
    var free = ready()
    free.cushion = AmountE4(whole: 300_000)
    free.main = AmountE4(whole: 200_000)
    let parts = FreeMoneyBlock.parts(of: free, hasCushion: true)
    XCTAssertEqual(parts.first, .main(AmountE4(whole: 200_000), spendable: true))
    XCTAssertEqual(parts[1], .cushion(AmountE4(whole: 300_000)))
    XCTAssertFalse(parts.map(\.name).contains("moneyAndGoals"), "no goal money: no goals line")

    free.goalSavings = AmountE4(whole: 50_000)
    let withGoals = FreeMoneyBlock.parts(of: free, hasCushion: true).map(\.name)
    XCTAssertEqual(
      withGoals.firstIndex(of: "cushion"), withGoals.firstIndex(of: "moneyAndGoals").map { $0 + 1 })

    free.state = .noReconciliation
    XCTAssertEqual(FreeMoneyBlock.parts(of: free, hasCushion: true), [.firstCount])
  }

  /// The words of the line and of the switch, in both languages.
  func testTheWords() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.format("free.cushion", table: "Planning", "300,000 ₽"),
      "Подушка безопасности −300,000 ₽: не считается свободной")
    XCTAssertEqual(
      environment.language("settings.planning.cushionOut", table: "Settings"),
      "Не считать подушку в свободной сумме")
    environment.language.choice = .english
    XCTAssertEqual(
      environment.language("settings.planning.cushionOut", table: "Settings"),
      "Keep the cushion out of the free sum")
  }
}
