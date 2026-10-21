import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The actions on the cards of an account and on their cashback rules, against a real
/// database: each is one step of ⌘Z, a name another account or live card holds is refused in
/// words, a used card only goes to the archive, a card takes no rules from its account, and
/// «Запомнить» is a step of its own.
@MainActor
final class CardActionsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-cards-\(UUID().uuidString)", isDirectory: true)
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

  private func account(_ name: String, kind: PaymentMethodKind = .card) throws -> PaymentMethod {
    let account = PaymentMethod(name: name, kind: kind, currency: .rub)
    try XCTUnwrap(environment.references).save(account)
    return account
  }

  private func category(_ name: String) throws -> CoreKit.Category {
    let category = CoreKit.Category(kind: .expense, name: name)
    try XCTUnwrap(environment.references).save(category)
    return category
  }

  private func percent(_ e4: Int64) -> CashbackPercent { CashbackPercent(e4: e4)! }

  // MARK: Cards

  func testAddingRenamingAndUndoingACardAreOneStepEach() throws {
    let tBank = try account("Т-Банк")
    let black = PaymentCard(accountId: tBank.id, name: " Black ", aliases: ["чёрная", " "])
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    let saved = try XCTUnwrap(actions.cards.first)
    XCTAssertEqual(saved.name, "Black")
    XCTAssertEqual(saved.aliases, ["чёрная"], "other names are tidied")

    var renamed = saved
    renamed.name = "Black Metal"
    XCTAssertEqual(actions.save(renamed, previous: saved), .done)
    XCTAssertEqual(actions.cards.map(\.name), ["Black Metal"])
    store.undo()
    XCTAssertEqual(actions.cards.map(\.name), ["Black"], "a rename is one step")
    store.undo()
    XCTAssertTrue(actions.cards.isEmpty, "adding is one step")
  }

  func testANameAnotherAccountOrLiveCardHoldsIsRefused() throws {
    let tBank = try account("Т-Банк")
    let sber = try account("Сбер")
    XCTAssertEqual(
      actions.save(PaymentCard(accountId: tBank.id, name: "сбер"), previous: nil),
      .refused(.card(.nameTaken(owner: .account(sber.id)))))
    XCTAssertEqual(
      actions.save(PaymentCard(accountId: tBank.id, name: "Т-Банк"), previous: nil), .done,
      "a card may carry its own account's name")
    let virtual = PaymentCard(accountId: tBank.id, name: "Virtual")
    XCTAssertEqual(actions.save(virtual, previous: nil), .done)
    XCTAssertEqual(
      actions.save(PaymentCard(accountId: tBank.id, name: "VIRTUAL"), previous: nil),
      .refused(.card(.nameTaken(owner: .card(virtual.id)))))
    XCTAssertEqual(actions.cards.count, 2, "nothing was written by a refusal")
  }

  func testArchiveAndRestoreRefusedWhileTheNameIsTaken() throws {
    let tBank = try account("Т-Банк")
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    XCTAssertEqual(actions.archive(black.id), .done)
    XCTAssertEqual(actions.cards.first?.archived, true)
    let second = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(actions.save(second, previous: nil), .done, "an archived card holds no name")
    XCTAssertEqual(
      actions.restore(black.id), .refused(.card(.nameTaken(owner: .card(second.id)))))
    store.undo()
    XCTAssertEqual(actions.restore(black.id), .done)
    XCTAssertEqual(actions.cards.first { $0.id == black.id }?.archived, false)
  }

  func testOnlyAnUnusedCardIsDeletedAndUndoBringsItsRules() throws {
    let tBank = try account("Т-Банк")
    let groceries = try category("Продукты")
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    let used = PaymentCard(accountId: tBank.id, name: "Used")
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    XCTAssertEqual(actions.save(used, previous: nil), .done)
    let rule = CashbackRule(
      accountId: tBank.id, cardId: black.id, categoryId: groceries.id, percent: percent(30_000))
    XCTAssertEqual(actions.saveRules(of: [.card(black.id)], [rule]), .done)
    let purchase = TransactionDraft(
      amount: AmountE4(whole: 100), paymentMethodId: tBank.id,
      parts: [PartDraft(amount: AmountE4(whole: 100))], cardId: used.id)
    XCTAssertTrue(store.save(try purchase.materialize()))

    guard case .refused(.inUse(let usage)) = actions.delete(used.id) else {
      return XCTFail("a used card is not deleted")
    }
    XCTAssertEqual(usage.operations, 1)
    XCTAssertEqual(actions.delete(black.id), .done)
    XCTAssertTrue(actions.rules.isEmpty, "its rules went with it")
    store.undo()
    XCTAssertEqual(actions.rules, [rule], "⌘Z brings the card and its rules back")
    XCTAssertTrue(actions.cards.contains { $0.id == black.id })
  }

  /// «Объединить с…»: one write and one step of ⌘Z. The merged card's operations, scheduled
  /// payments and rules go to the kept card — a rule of a month and category the kept card
  /// already has gives way to it —, the kept card is known by the merged card's names, the entry
  /// line learns that at once, and ⌘Z brings everything back as it was.
  func testMergingACardIntoAnotherCardOfItsAccountIsOneStep() throws {
    let tBank = try account("Т-Банк")
    let cafe = try category("Кафе")
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    let virtual = PaymentCard(accountId: tBank.id, name: "Virtual", aliases: ["virt"])
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    XCTAssertEqual(actions.save(virtual, previous: nil), .done)
    let blackCafe = CashbackRule(
      accountId: tBank.id, cardId: black.id, categoryId: cafe.id, percent: percent(50_000))
    let virtualCafe = CashbackRule(
      accountId: tBank.id, cardId: virtual.id, categoryId: cafe.id, percent: percent(100_000))
    let virtualRest = CashbackRule(
      accountId: tBank.id, cardId: virtual.id, percent: percent(20_000))
    XCTAssertEqual(
      actions.saveRules(
        of: [.card(black.id), .card(virtual.id)], [blackCafe, virtualCafe, virtualRest]),
      .done)
    let purchase = try TransactionDraft(
      amount: AmountE4(whole: 100), paymentMethodId: tBank.id,
      parts: [PartDraft(amount: AmountE4(whole: 100))], cardId: virtual.id
    ).materialize()
    XCTAssertTrue(store.save(purchase))
    let payment = ScheduledPayment(
      name: "Телефон", amountE4: AmountE4(whole: 500), paymentMethodId: tBank.id,
      cardId: virtual.id)
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(scheduled: [payment]))))
    let cardsBefore = actions.cards
    let rulesBefore = actions.rules

    let plan = try actions.mergePlan(virtual.id, into: black.id).get()
    XCTAssertEqual(plan.droppedRules, [virtualCafe], "the kept card's own rule wins")
    XCTAssertEqual(actions.merge(virtual.id, into: black.id), .done)

    XCTAssertEqual(actions.cards.map(\.id), [black.id], "the merged card is gone")
    XCTAssertEqual(actions.cards.first?.aliases, ["Virtual", "virt"])
    XCTAssertEqual(
      Set(actions.rules.map(\.id)), [blackCafe.id, virtualRest.id])
    XCTAssertEqual(actions.rules.first { $0.id == virtualRest.id }?.cardId, black.id)
    let transactions = try XCTUnwrap(environment.transactions)
    XCTAssertEqual(try transactions.entry(id: purchase.id)?.transaction.cardId, black.id)
    XCTAssertEqual(
      try XCTUnwrap(environment.planning).scheduled().first { $0.id == payment.id }?.cardId,
      black.id)
    XCTAssertTrue(
      environment.vocabulary.cards.contains {
        $0.entry.id == black.id && $0.entry.aliases.contains("virt")
      }, "the entry line reads the merged card's names as the kept card")

    store.undo()
    XCTAssertEqual(Set(actions.cards), Set(cardsBefore), "one ⌘Z brings the card back")
    XCTAssertEqual(Set(actions.rules), Set(rulesBefore))
    XCTAssertEqual(try transactions.entry(id: purchase.id)?.transaction.cardId, virtual.id)
    XCTAssertEqual(
      try XCTUnwrap(environment.planning).scheduled().first { $0.id == payment.id }?.cardId,
      virtual.id)
  }

  /// Only a live card of the same account is merged into; nothing is written otherwise.
  func testACardOfAnotherAccountIsNotMergedInto() throws {
    let tBank = try account("Т-Банк")
    let sber = try account("Сбер")
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    let sberCard = PaymentCard(accountId: sber.id, name: "Сбер Visa")
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    XCTAssertEqual(actions.save(sberCard, previous: nil), .done)
    XCTAssertEqual(actions.merge(black.id, into: sberCard.id), .refused(.merge(.otherAccount)))
    XCTAssertEqual(actions.merge(black.id, into: black.id), .refused(.merge(.sameCard)))
    XCTAssertEqual(actions.cards.count, 2)
    XCTAssertFalse(CardMerge.offered(for: black, cards: actions.cards))
  }

  /// What the lists lay over their data after a merge and after its ⌘Z: the live operation that
  /// moved, read again.
  func testTheListsLearnTheOperationsAMergeMoved() {
    let moved = MovedCardReference(rowId: UUID(), from: UUID(), into: UUID())
    let undo = PlanningUndo(movedCards: [moved])
    XCTAssertEqual(TransactionsStore.broughtBack(by: undo), [moved.rowId])
  }

  /// Cash had rules of its own; its first card changes nothing about them: the card follows
  /// them, and ⌘Z takes the card away alone.
  func testTheFirstCardLeavesTheAccountsRules() throws {
    let cash = try account("Кошелёк", kind: .other)
    let own = CashbackRule(accountId: cash.id, percent: percent(10_000))
    XCTAssertEqual(actions.saveRules(of: [.account(cash.id)], [own]), .done)
    let card = PaymentCard(accountId: cash.id, name: "Карта кошелька")
    XCTAssertEqual(actions.save(card, previous: nil), .done)
    XCTAssertEqual(actions.rules.map(\.cardId), [nil])
    XCTAssertEqual(actions.rules.map(\.id), [own.id])
    store.undo()
    XCTAssertEqual(actions.rules.map(\.cardId), [nil])
    XCTAssertTrue(actions.cards.isEmpty)
  }

  /// A card in the archive comes back with the rules of its own it kept, and the account's rules
  /// stay the account's: one ⌘Z puts the card back in the archive and touches nothing else.
  func testRestoringACardLeavesTheRulesAlone() throws {
    let tBank = try account("Т-Банк")
    let cafes = try category("Кафе")
    let groceries = try category("Продукты")
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    let cardCafes = CashbackRule(
      accountId: tBank.id, cardId: black.id, categoryId: cafes.id, percent: percent(50_000))
    XCTAssertEqual(actions.saveRules(of: [.card(black.id)], [cardCafes]), .done)
    XCTAssertEqual(actions.archive(black.id), .done)
    XCTAssertEqual(
      CashbackHolders.editableHolders(of: tBank.id, cards: actions.cards), [.account(tBank.id)])
    let ownCafes = CashbackRule(
      accountId: tBank.id, categoryId: cafes.id, percent: percent(70_000))
    let ownGroceries = CashbackRule(
      accountId: tBank.id, categoryId: groceries.id, percent: percent(30_000))
    XCTAssertEqual(actions.saveRules(of: [.account(tBank.id)], [ownCafes, ownGroceries]), .done)
    let before = Set(actions.rules)

    XCTAssertEqual(actions.restore(black.id), .done)
    XCTAssertEqual(Set(actions.rules), before, "no rule moved")
    XCTAssertEqual(actions.rules.filter { $0.cardId == black.id }, [cardCafes])
    XCTAssertEqual(
      CashbackHolders.editableHolders(of: tBank.id, cards: actions.cards),
      [.account(tBank.id), .card(black.id)])
    store.undo()
    XCTAssertEqual(Set(actions.rules), before)
    XCTAssertEqual(actions.cards.first?.archived, true, "one step: the card alone")
  }

  // MARK: Rules

  /// Two rows of the sheet swap their categories and a percent changes: saved by key, in one
  /// step, and ⌘Z gives the old rules back.
  func testTheRulesSheetSavesASwapInOneStep() throws {
    let tBank = try account("Т-Банк")
    let cafes = try category("Кафе")
    let groceries = try category("Продукты")
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    let first = CashbackRule(
      accountId: tBank.id, cardId: black.id, categoryId: cafes.id, percent: percent(50_000))
    let second = CashbackRule(
      accountId: tBank.id, cardId: black.id, categoryId: groceries.id, percent: percent(30_000))
    XCTAssertEqual(actions.saveRules(of: [.card(black.id)], [first, second]), .done)
    var swappedFirst = first
    swappedFirst.categoryId = groceries.id
    swappedFirst.percent = percent(70_000)
    var swappedSecond = second
    swappedSecond.categoryId = cafes.id
    swappedSecond.percent = percent(50_000)
    XCTAssertEqual(actions.saveRules(of: [.card(black.id)], [swappedFirst, swappedSecond]), .done)
    XCTAssertEqual(
      Set(actions.rules.map { "\($0.categoryId!) \($0.percent.e4)" }),
      ["\(cafes.id) 50000", "\(groceries.id) 70000"])
    store.undo()
    XCTAssertEqual(Set(actions.rules), [first, second])
    // A duplicate never reaches the database.
    XCTAssertEqual(
      actions.saveRules(of: [.card(black.id)], [first, first.with(id: UUID())]),
      .refused(.rules(.duplicate(first.key))))
  }

  // MARK: Settings of the account

  /// The rules and the settings of the account's cashback — rounding, payout, points — are saved
  /// in one step, and ⌘Z gives both back.
  func testTheSheetSavesTheSettingsWithTheRulesInOneStep() throws {
    let tBank = try account("Т-Банк")
    let bonus = try account("Бонусы", kind: .other)
    let cafes = try category("Кафе")
    let own = CashbackRule(
      accountId: tBank.id, categoryId: cafes.id, percent: percent(50_000))
    var edited = tBank
    edited.cashbackRounding = CashbackRounding(precision: .cents, direction: .down)
    edited.cashbackPayout = CashbackPayout.later(day: 10)
    edited.cashbackPointsAccountId = bonus.id
    XCTAssertEqual(actions.saveRules(of: [.account(tBank.id)], [own], account: edited), .done)
    let stored = try XCTUnwrap(actions.accounts.first { $0.id == tBank.id })
    XCTAssertEqual(stored.cashbackRounding, edited.cashbackRounding)
    XCTAssertEqual(stored.cashbackPayout, CashbackPayout.later(day: 10))
    XCTAssertEqual(stored.cashbackPointsAccountId, bonus.id)
    XCTAssertEqual(actions.rules, [own])

    store.undo()
    let reverted = try XCTUnwrap(actions.accounts.first { $0.id == tBank.id })
    XCTAssertEqual(reverted.cashbackRounding, .standard)
    XCTAssertNil(reverted.cashbackPayout)
    XCTAssertNil(reverted.cashbackPointsAccountId)
    XCTAssertTrue(actions.rules.isEmpty, "one step: the rules and the settings")
    XCTAssertFalse(store.canUndo)
  }

  /// Settings alone are a save too; a save that changes nothing writes nothing.
  func testTheSettingsAloneAreSavedAndNothingChangedWritesNothing() throws {
    let tBank = try account("Т-Банк")
    XCTAssertEqual(actions.saveRules(of: [.account(tBank.id)], [], account: tBank), .done)
    XCTAssertFalse(store.canUndo, "nothing changed, nothing written")
    var edited = tBank
    edited.cashbackPayout = .immediately
    XCTAssertEqual(actions.saveRules(of: [.account(tBank.id)], [], account: edited), .done)
    XCTAssertEqual(
      actions.accounts.first { $0.id == tBank.id }?.cashbackPayout, .immediately)
    XCTAssertTrue(store.canUndo)
    // Nothing else of the account was touched.
    XCTAssertEqual(actions.accounts.first { $0.id == tBank.id }?.name, "Т-Банк")
  }

  /// An account cannot take its own points, nor an account that is not there or is in the
  /// archive; nothing is written.
  func testThePointsAccountIsCheckedInWords() throws {
    let tBank = try account("Т-Банк")
    let old = try account("Старые бонусы", kind: .other)
    var archived = old
    archived.archived = true
    try XCTUnwrap(environment.references).save(archived)
    func points(_ id: UUID?) -> CardActionOutcome {
      var edited = tBank
      edited.cashbackPointsAccountId = id
      return actions.saveRules(of: [.account(tBank.id)], [], account: edited)
    }
    XCTAssertEqual(points(tBank.id), .refused(.points(.isItself)))
    XCTAssertEqual(points(UUID()), .refused(.points(.notFound)))
    XCTAssertEqual(points(old.id), .refused(.points(.archived)))
    XCTAssertNil(actions.accounts.first { $0.id == tBank.id }?.cashbackPointsAccountId)
    XCTAssertFalse(store.canUndo)
    for refusal in [CardRefusal.points(.isItself), .points(.notFound), .points(.archived)] {
      let text = CardText.message(
        refusal, cards: [], accounts: [], categories: [:], environment)
      XCTAssertFalse(text.contains("cashback.refusal"), text)
    }
  }

  /// A rule on «Кредиты» is refused in words: a payment on a debt earns nothing.
  func testARuleOnLoansIsRefused() throws {
    let tBank = try account("Т-Банк")
    let loans: CoreKit.Category
    if let seeded = actions.categories.first(where: { $0.systemRole == .loans }) {
      loans = seeded
    } else {
      loans = CoreKit.Category(kind: .expense, name: "Кредиты", systemRole: .loans)
      try XCTUnwrap(environment.references).save(loans)
    }
    let rule = CashbackRule(
      accountId: tBank.id, categoryId: loans.id, percent: percent(0))
    XCTAssertEqual(
      actions.saveRules(of: [.account(tBank.id)], [rule]),
      .refused(.rules(.categoryIsLoan(loans.id))))
    XCTAssertEqual(actions.remember(rule), .refused(.rules(.categoryIsLoan(loans.id))))
    XCTAssertTrue(actions.rules.isEmpty)
    let text = CardText.message(
      .rules(.categoryIsLoan(loans.id)), cards: [], accounts: [], categories: [:], environment)
    XCTAssertFalse(text.contains("cashback.refusal"), text)
  }

  /// «Запомнить»: a typed 7 % becomes a rule of the card at once, one step of its own; a second
  /// «Запомнить» of the same key takes the same row.
  func testRememberIsItsOwnStepAndReusesTheKey() throws {
    let tBank = try account("Т-Банк")
    let pharmacy = try category("Аптеки")
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    let september = MonthKey(year: 2026, month: 9)
    let typed = CashbackRule(
      accountId: tBank.id, cardId: black.id, categoryId: pharmacy.id, month: september,
      percent: percent(70_000))
    XCTAssertEqual(actions.remember(typed), .done)
    XCTAssertEqual(actions.rules, [typed])
    var again = typed
    again.id = UUID()
    again.percent = percent(80_000)
    XCTAssertEqual(actions.remember(again), .done)
    XCTAssertEqual(actions.rules.map(\.id), [typed.id])
    XCTAssertEqual(actions.rules.first?.percent, percent(80_000))
    store.undo()
    XCTAssertEqual(actions.rules, [typed])
    store.undo()
    XCTAssertTrue(actions.rules.isEmpty)
    XCTAssertEqual(actions.cards.count, 1, "the card was a step before")
  }

  func testTheWordsOfARefusalNameWhoHoldsTheName() throws {
    let sber = try account("Сбер")
    let text = CardText.message(
      .card(.nameTaken(owner: .account(sber.id))), cards: [], accounts: [sber], categories: [:],
      environment)
    XCTAssertTrue(text.contains("Сбер"), text)
    XCTAssertFalse(text.contains("card.refusal"), text)
  }

  func testTheMonthInItsPrepositionalCase() throws {
    let september = MonthKey(year: 2026, month: 9)
    let words = environment.language(DateFormatting.monthInKey(september))
    XCTAssertFalse(words.hasPrefix("month.in"), "the key is in Common")
    XCTAssertEqual(
      environment.dates.monthIn(september, thisYear: 2026, words: words), words)
    XCTAssertEqual(
      environment.dates.monthIn(september, thisYear: 2025, words: words), words + " 2026")
  }
}

extension CashbackRule {
  fileprivate func with(id: UUID) -> CashbackRule {
    var copy = self
    copy.id = id
    return copy
  }
}
