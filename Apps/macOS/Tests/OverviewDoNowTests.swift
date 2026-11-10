import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Что сделать сейчас» on Overview, from the data of a snapshot: at most three things, the
/// things to sort out before the statements to load, the rest counted for «Все»; nothing to do —
/// no card at all; a covered hidden account asks for nothing; every row has its words and its
/// button.
@MainActor
final class OverviewDoNowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var languageBefore: AppLanguage.Choice?
  private let food = CoreKit.Category(kind: .expense, name: "Продукты", quality: .neutral)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-donow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    languageBefore = environment.language.choice
    environment.language.choice = .russian
  }

  override func tearDown() async throws {
    if let languageBefore { environment?.language.choice = languageBefore }
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func entry(
    daysAgo: Int, categorized: Bool = true, statementOf account: UUID? = nil
  ) throws -> TransactionEntry {
    let calendar = CalendarContext.system
    let day = calendar.adding(days: -daysAgo, to: environment.today)
    var draft = TransactionDraft(
      kind: .expense, occurredAt: calendar.startOfDay(day).addingTimeInterval(12 * 3600),
      amount: AmountE4(whole: 100))
    draft.paymentMethodId = account
    draft.parts = [
      PartDraft(categoryId: categorized ? food.id : nil, amount: AmountE4(whole: 100))
    ]
    var entry = try draft.materialize()
    if account != nil { entry.transaction.source = "statement" }
    return entry
  }

  private func snapshot(_ entries: [TransactionEntry]) -> DataSnapshot {
    DataSnapshot.build(
      dataset: Dataset(entries: entries, categories: [food]),
      calendar: .system, today: environment.today, context: SnapshotContext(),
      version: DataVersion(load: 0))
  }

  /// Nothing waits: the list is empty and Overview puts no card in its grid.
  func testWithNothingToDoThereIsNoCard() throws {
    let calm = snapshot([try entry(daysAgo: 1), try entry(daysAgo: 30)])
    XCTAssertTrue(OverviewDoNow.list(snapshot: calm, environment: environment).isEmpty)
    XCTAssertFalse(OverviewGroupedGrid.extras(calm, environment).contains(.doNow))
    XCTAssertFalse(OverviewGroupedGrid.extras(nil, environment).contains(.doNow))
  }

  /// Operations of this week without a category: one «Разобрать» with how many wait, and the
  /// card is in the grid.
  func testOperationsToSortOutBringTheCard() throws {
    let waiting = snapshot([
      try entry(daysAgo: 0, categorized: false), try entry(daysAgo: 2, categorized: false),
    ])
    let list = OverviewDoNow.list(snapshot: waiting, environment: environment)
    XCTAssertEqual(list.items.map(\.action), [.review])
    XCTAssertEqual(list.items.first?.count, 2)
    XCTAssertTrue(OverviewGroupedGrid.extras(waiting, environment).contains(.doNow))
    let text = try XCTUnwrap(
      list.items.first.map {
        OverviewDoNow.text($0, snapshot: waiting, environment: environment)
      })
    XCTAssertFalse(text.title.isEmpty)
    XCTAssertFalse(text.button.isEmpty)
    XCTAssertTrue(text.urgent)
  }

  /// Four things wait: three are shown — «Разобрать» first, then the banks whose statement is
  /// old —, and the fourth is counted for «Все».
  func testAtMostThreeInTheirOrderAndTheRestCounted() throws {
    let banks = [UUID(), UUID(), UUID()]
    var entries = [try entry(daysAgo: 1, categorized: false)]
    for bank in banks { entries.append(try entry(daysAgo: 20, statementOf: bank)) }
    let list = OverviewDoNow.list(snapshot: snapshot(entries), environment: environment)
    XCTAssertEqual(list.items.count, WhatToDoNow.limit)
    XCTAssertEqual(list.items.map(\.action), [.review, .load, .load])
    XCTAssertEqual(list.more, 1)
  }

  /// A covered hidden account asks for no statement: its operations stay out of the lists.
  func testAHiddenAccountAsksForNothing() throws {
    let hidden = UUID()
    let shown = snapshot([try entry(daysAgo: 20, statementOf: hidden)])
    let open = OverviewDoNow.list(snapshot: shown, environment: environment)
    XCTAssertEqual(open.items.map(\.action), [.load], "uncovered, the account asks")
    let covered = shown.presented(hiding: HiddenAccounts(ids: [hidden]))
    XCTAssertTrue(OverviewDoNow.list(snapshot: covered, environment: environment).isEmpty)
    XCTAssertFalse(OverviewGroupedGrid.extras(covered, environment).contains(.doNow))
  }
}
