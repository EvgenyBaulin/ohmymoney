import AppCore
import XCTest

@testable import OhMyMoney

/// The words of «owed to me» and «I owe» on the Overview, the Debts and the Capital: three
/// screens count three different things, so no two of them may use one title for them, and the
/// «I owe» tile says what its figure leaves out or includes.
@MainActor
final class DebtFiguresLabelsTests: XCTestCase {
  private let environment = AppEnvironment()
  private var languageBefore: AppLanguage.Choice?

  override func setUp() {
    languageBefore = environment.language.choice
  }

  override func tearDown() {
    if let languageBefore { environment.language.choice = languageBefore }
  }

  func testTheThreeOwedToMeTitlesDiffer() {
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      let overview = environment.language("overview.tile.owedToMe", table: "Overview")
      let debts = environment.language("debts.owedToMe", table: "Debts")
      let capital = environment.language("capital.group.owedToMe", table: "Capital")
      XCTAssertEqual(Set([overview, debts, capital]).count, 3, "\(choice): \(overview) \(debts) \(capital)")
      XCTAssertEqual(
        environment.language("why.owed.total", table: "Overview"), overview, "\(choice)")
      XCTAssertEqual(
        environment.language("capital.shares.owedToMe", table: "Capital"), capital, "\(choice)")
    }
  }

  func testTheIOweTileSaysItsInstalmentsAndTheUnpaidInterest() {
    environment.language.choice = .russian
    var summary = DebtsBoard.Summary(
      iOwe: AmountE4(whole: 602_000), iOweCount: 5, instalmentCount: 1,
      accruedRub: AmountE4(whole: 719), monthly: .zero, nextPayment: nil, owedToMe: .zero,
      peopleCount: 0)
    let line = summary.iOweLine(environment)
    XCTAssertTrue(line.hasPrefix("5 долгов, из них рассрочек: 1"), line)
    XCTAssertTrue(line.contains("плюс проценты к выплате"), line)
    summary.instalmentCount = 0
    summary.accruedRub = .zero
    XCTAssertEqual(summary.iOweLine(environment), "5 долгов")
    environment.language.choice = .english
    summary.instalmentCount = 2
    XCTAssertEqual(summary.iOweLine(environment), "5 debts, of which instalments: 2")
  }
}
