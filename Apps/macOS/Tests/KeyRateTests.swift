import AppCore
import XCTest

@testable import OhMyMoney

/// The key rate on the Mac: the words of the lines in both languages, and the daily read of the
/// page of the Bank of Russia with its cache. No window and no network.
@MainActor
final class KeyRateTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 11, day: 14)

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func rate(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? 0
  }

  private func defaults() throws -> UserDefaults {
    let name = "keyrate-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    return defaults
  }

  func testTheRefinanceLineNamesTheDebtAndBothRatesInBothLanguages() {
    let drop = KeyRateDrop(
      from: rate("17"), to: rate("15.5"), since: DateOnly(year: 2026, month: 10, day: 1))
    let id = UUID()
    let note = KeyRateNote.refinance(debtId: id, debtRate: rate("22"), drop: drop)
    for choice in [AppLanguage.Choice.russian, .english] {
      let text = KeyRateText.note(note, debts: [id: "Кредит"], environment(choice))
      for part in ["Кредит", "17", "15.5", "22"] {
        XCTAssertTrue(text.contains(part), "\(choice) \(part): \(text)")
      }
      XCTAssertFalse(text.contains("look.keyRate"))
    }
  }

  func testTheFallLineIsUnderADepositThatEnds() {
    let drop = KeyRateDrop(
      from: rate("17"), to: rate("16"), since: DateOnly(year: 2026, month: 10, day: 1))
    let advice = DepositEndAdvice(
      accountId: UUID(), endsOn: DateOnly(year: 2026, month: 11, day: 16), picks: [],
      keyRateFall: drop)
    for choice in [AppLanguage.Choice.russian, .english] {
      let text = DepositText.endsLine(
        advice, accounts: [advice.accountId: "Вклад"], environment(choice))
      XCTAssertEqual(text.components(separatedBy: "\n").count, 2, "\(choice)")
      XCTAssertTrue(text.contains("16"))
    }
  }

  func testTheTableIsReadOncePerDayAndKeptEvenWhenItFailed() async throws {
    let defaults = try defaults()
    let calls = CallCounter()
    let page = Data(
      "<table><tr><td>01.11.2026</td><td>14,50</td></tr></table>".utf8)
    let client = KeyRateClient(fetch: { _ in
      await calls.bump()
      return page
    })
    let service = KeyRateService(client: client, defaults: defaults)
    XCTAssertEqual(service.table(), KeyRateTable.builtIn)
    let first = await service.load(today: today)
    XCTAssertEqual(first.rate(on: today), rate("14.5"))
    _ = await service.load(today: today)
    let count = await calls.count
    XCTAssertEqual(count, 1)
    service.forget()
    XCTAssertEqual(service.table(), KeyRateTable.builtIn)
  }

  func testAClosedPageLeavesTheBuiltInTable() async throws {
    let defaults = try defaults()
    let client = KeyRateClient(fetch: { _ in throw RateFetchError.unavailable(status: 403) })
    let service = KeyRateService(client: client, defaults: defaults)
    let table = await service.load(today: today)
    XCTAssertEqual(table, KeyRateTable.builtIn)
    XCTAssertEqual(service.cached()?.changes.count, 0)
  }
}

private actor CallCounter {
  private(set) var count = 0
  func bump() { count += 1 }
}
