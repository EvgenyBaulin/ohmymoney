import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Объединить с…» of a card asks before it merges: the sheet says how many operations — those
/// in the bin too — and scheduled payments move to the kept card, how many cashback rules move
/// and how many give way. «Объединить с…» is offered only on an account with two live cards.
@MainActor
final class CardMergeQuestionTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-card-merge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var actions: CardActions { CardActions(environment: environment, store: store) }

  private func purchase(_ whole: Int64, account: UUID, card: UUID) throws -> TransactionEntry {
    let entry = try TransactionDraft(
      amount: AmountE4(whole: whole), paymentMethodId: account,
      parts: [PartDraft(amount: AmountE4(whole: whole))], cardId: card
    ).materialize()
    XCTAssertTrue(store.save(entry))
    return entry
  }

  func testTheQuestionCountsWhatMovesToTheKeptCard() throws {
    let tBank = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub)
    try XCTUnwrap(environment.references).save(tBank)
    let cafe = CoreKit.Category(kind: .expense, name: "Кафе")
    try XCTUnwrap(environment.references).save(cafe)
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    let virtual = PaymentCard(accountId: tBank.id, name: "Virtual")
    XCTAssertFalse(CardMerge.offered(for: black, cards: [black]), "one card, nothing to merge")
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    XCTAssertEqual(actions.save(virtual, previous: nil), .done)
    XCTAssertTrue(CardMerge.offered(for: virtual, cards: actions.cards))
    XCTAssertEqual(actions.mergeTargets(for: virtual).map(\.id), [black.id])

    let percent = { (e4: Int64) in CashbackPercent(e4: e4)! }
    XCTAssertEqual(
      actions.saveRules(
        of: [.card(black.id), .card(virtual.id)],
        [
          CashbackRule(
            accountId: tBank.id, cardId: black.id, categoryId: cafe.id, percent: percent(50_000)),
          CashbackRule(
            accountId: tBank.id, cardId: virtual.id, categoryId: cafe.id,
            percent: percent(100_000)),
          CashbackRule(accountId: tBank.id, cardId: virtual.id, percent: percent(20_000)),
        ]), .done)
    _ = try purchase(100, account: tBank.id, card: virtual.id)
    _ = try purchase(200, account: tBank.id, card: virtual.id)
    let binned = try purchase(300, account: tBank.id, card: virtual.id)
    XCTAssertTrue(store.delete(id: binned.id))
    _ = try purchase(400, account: tBank.id, card: black.id)
    let payment = ScheduledPayment(
      name: "Телефон", amountE4: AmountE4(whole: 500), paymentMethodId: tBank.id,
      cardId: virtual.id)
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(scheduled: [payment]))))

    let usage = try XCTUnwrap(actions.mergeUsage(virtual.id))
    XCTAssertEqual(usage.operations, 3, "two live operations and one in the bin")
    XCTAssertEqual(usage.scheduled, 1)
    let plan = try actions.mergePlan(virtual.id, into: black.id).get()
    XCTAssertEqual(plan.movedRules.count, 1)
    XCTAssertEqual(plan.droppedRules.count, 1, "Black has its own rule for «Кафе»")

    let language = environment.language
    let before = language.choice
    defer { language.choice = before }
    language.choice = .russian
    XCTAssertEqual(
      environment.format(
        "card.merge.moves", table: CardText.table, counts: usage.operations, usage.scheduled),
      "Перейдут на оставшуюся карту: операций — 3, плановых платежей — 1")
    XCTAssertEqual(
      environment.format("card.merge.rulesMoved", table: CardText.table, counts: 1),
      "Правил кэшбэка перейдёт на оставшуюся карту: 1")
    XCTAssertTrue(
      environment.format("card.merge.rulesDropped", table: CardText.table, counts: 1)
        .hasSuffix(": 1"))
    language.choice = .english
    XCTAssertEqual(
      environment.format("card.merge.moves", table: CardText.table, counts: 1_250, 2),
      "Moving to the kept card: operations — 1,250, scheduled payments — 2")

    // The merge moves what the question counted.
    XCTAssertEqual(actions.merge(virtual.id, into: black.id), .done)
    XCTAssertEqual(try XCTUnwrap(actions.mergeUsage(black.id)).operations, 4)
    XCTAssertEqual(try XCTUnwrap(actions.mergeUsage(black.id)).scheduled, 1)
    XCTAssertEqual(try XCTUnwrap(actions.mergeUsage(virtual.id)).operations, 0)
  }
}
