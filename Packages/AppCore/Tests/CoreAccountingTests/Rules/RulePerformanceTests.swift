import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Rules: size and speed", .serialized)
struct RulePerformanceTests {
  let book = RuleBook()

  /// 20 000 operations over two years, the size `make sample-large` writes.
  private func history() -> [TransactionEntry] {
    let shops = ["Пятёрочка", "Магнит", "Лента", "Яндекс Go", "Кофейня", "Аптека"]
    return (0..<20_000).map { index in
      var entry = book.expense(
        "\(shops[index % shops.count]) \(index)", rub: Int64(50 + index % 4_000),
        category: index % 3 == 0 ? book.cafe : book.groceries, day: -(index % 730))
      entry.transaction.createdAt = entry.transaction.occurredAt
      return entry
    }
  }

  private func rules(_ count: Int) -> [Rule] {
    let shops = ["пятёрочка", "магнит", "лента", "яндекс", "кофейня", "аптека"]
    return (0..<count).map { index in
      book.rule(
        [.textContains(shops[index % shops.count]), .amountAbove(AmountE4(whole: Int64(index)))],
        [.setCategory(index % 2 == 0 ? book.groceries.id : book.transport.id), .addTag(UUID())],
        position: index)
    }
  }

  /// The always-on check is generous (a debug build on a loaded runner): it catches work that
  /// grows with the square of the history, not a slow machine.
  @Test func twentyThousandOperationsAgainstFiftyRulesFinish() {
    let entries = history()
    let rules = rules(50)
    let clock = ContinuousClock()
    var plan: RuleBackfillPlan?
    let elapsed = clock.measure {
      plan = RuleBackfill.plan(
        rules: rules, entries: entries, tree: book.tree, places: book.places,
        calendar: book.calendar, now: Date())
    }
    #expect(plan?.scanned == 20_000)
    #expect((plan?.matched ?? 0) > 10_000)
    #expect(elapsed < .seconds(60), "took \(elapsed)")
  }

  @Test func doublingTheHistoryAboutDoublesTheTime() {
    let entries = history()
    let rules = rules(20)
    let clock = ContinuousClock()
    func run(_ slice: [TransactionEntry]) -> Duration {
      clock.measure {
        _ = RuleBackfill.plan(
          rules: rules, entries: slice, tree: book.tree, places: book.places,
          calendar: book.calendar, now: Date())
      }
    }
    _ = run(Array(entries.prefix(500)))  // warm-up
    let small = run(Array(entries.prefix(2_000)))
    let large = run(Array(entries.prefix(8_000)))
    #expect(large < small * 12, "4× the history cost \(large) against \(small)")
  }

  /// The release budget (about 2.5 s measured for 20 000 operations × 50 rules, every rule matching
  /// a share of them and tagging): only in release runs with `OHMYMONEY_BENCH=1`.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["OHMYMONEY_BENCH"] == "1"))
  func theTightBudgetInRelease() {
    let entries = history()
    let rules = rules(50)
    let elapsed = ContinuousClock().measure {
      _ = RuleBackfill.plan(
        rules: rules, entries: entries, tree: book.tree, places: book.places,
        calendar: book.calendar, now: Date())
    }
    #expect(elapsed < .seconds(5), "took \(elapsed)")
  }
}
