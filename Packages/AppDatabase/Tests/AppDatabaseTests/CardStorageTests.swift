import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The cards and the cashback rules as the app writes and reads them: a card with its rules and
/// an operation's own cashback come back as written, the rules sheet saves by key in one step, a
/// used card stays, and the repository of the cards reads what the screens ask for.
@Suite("Cards and cashback rules in the database")
struct CardStorageTests {
  let at = Date(timeIntervalSince1970: 1_789_900_000)

  func tables(_ stack: DatabaseStack) throws -> [String: ExactTable] {
    try stack.writer.read { db in try ExactTables.read(db) }
  }

  func rule(
    _ account: UUID, card: UUID?, category: UUID? = nil, month: MonthKey? = nil,
    _ percentE4: Int64
  ) -> CashbackRule {
    CashbackRule(
      accountId: account, cardId: card, categoryId: category, month: month,
      percent: CashbackPercent(e4: percentE4) ?? .zero)
  }

  func purchase(on account: UUID, card: UUID?, cashback: Money? = nil) -> TransactionEntry {
    let transaction = CoreKit.Transaction(
      kind: .expense, occurredAt: at, amountE4: AmountE4(whole: 350), paymentMethodId: account,
      createdAt: at, updatedAt: at, cardId: card, cashback: cashback)
    return TransactionEntry(
      transaction: transaction,
      parts: [TransactionPart(transactionId: transaction.id, amountE4: AmountE4(whole: 350))])
  }

  @Test func roundTripCardsRulesAndOverride() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let account = references.paymentMethod.id
    let planning = PlanningRepository(writer: stack.writer)
    let black = PaymentCard(accountId: account, name: "Black", aliases: ["чёрная", "black card"])
    let rules = [
      rule(account, card: black.id, category: references.category.id, 50_000),
      rule(
        account, card: black.id, category: references.category.id,
        month: MonthKey(year: 2026, month: 9), 333_333),
      rule(account, card: black.id, 15_000),
    ]
    _ = try planning.apply(
      PlanningChange(upsert: PlanningRows(cards: [black], cashbackRules: rules)))
    let coffee = purchase(
      on: account, card: black.id, cashback: Money(amount: AmountE4(raw: 350_000), currency: .rub))
    try TransactionRepository(writer: stack.writer).save(coffee)

    let cards = CardRepository(writer: stack.writer)
    #expect(try cards.cards() == [black])
    #expect(try cards.rules() == rules)
    #expect(try cards.rules(of: .card(black.id)) == rules)
    #expect(try cards.rules(of: .account(account)).isEmpty)
    let dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 1) }
    #expect(dataset.cards == [black])
    #expect(dataset.cashbackRules == rules)
    let stored = try #require(dataset.entries.first { $0.id == coffee.id })
    #expect(stored.transaction.cardId == black.id)
    #expect(stored.transaction.cashback == Money(amount: AmountE4(raw: 350_000), currency: .rub))
  }

  @Test func usedCardCannotBeDeleted() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let account = references.paymentMethod.id
    let planning = PlanningRepository(writer: stack.writer)
    let black = PaymentCard(accountId: account, name: "Black")
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(cards: [black])))
    try TransactionRepository(writer: stack.writer).save(purchase(on: account, card: black.id))
    let cards = CardRepository(writer: stack.writer)
    #expect(try cards.usage(of: black.id) == CardUsage(operations: 1, scheduled: 0))
    #expect(try cards.usage(of: black.id).isUsed)
    #expect(throws: PlanningWriteError.referencedByOperations(black.id)) {
      try planning.apply(PlanningChange(delete: PlanningRowIDs(cards: [black.id])))
    }
    // The archive is always open to it.
    var archived = black
    archived.archived = true
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(cards: [archived])))
    #expect(try cards.cards().isEmpty)
    #expect(try cards.cards(includeArchived: true) == [archived])
    #expect(try cards.cards(of: account) == [archived])
  }

  @Test func deletingACardAndUndoBringsItsRules() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let account = references.paymentMethod.id
    let planning = PlanningRepository(writer: stack.writer)
    let virtual = PaymentCard(accountId: account, name: "Virtual")
    let rules = [rule(account, card: virtual.id, 30_000)]
    _ = try planning.apply(
      PlanningChange(upsert: PlanningRows(cards: [virtual], cashbackRules: rules)))
    let before = try tables(stack)
    let undo = try planning.apply(PlanningChange(delete: PlanningRowIDs(cards: [virtual.id])))
    let cards = CardRepository(writer: stack.writer)
    #expect(try cards.cards(includeArchived: true).isEmpty)
    #expect(try cards.rules().isEmpty)
    try planning.revert(undo)
    #expect(try tables(stack) == before)
    #expect(try cards.rules() == rules)
  }

  /// The sheet swaps the categories of two rows of Black and saves: the keyed diff keeps each
  /// key on its row, the write is one step and never meets the one-rule-per-key index halfway.
  @Test func aSwapOfTwoRulesLandsInOneStep() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let account = references.paymentMethod.id
    let other = CoreKit.Category(kind: .expense, name: "Cafes")
    try ReferenceRepository(writer: stack.writer).save(other)
    let planning = PlanningRepository(writer: stack.writer)
    let black = PaymentCard(accountId: account, name: "Black")
    let groceries = rule(account, card: black.id, category: references.category.id, 50_000)
    let cafes = rule(account, card: black.id, category: other.id, 30_000)
    _ = try planning.apply(
      PlanningChange(upsert: PlanningRows(cards: [black], cashbackRules: [groceries, cafes])))
    let before = try tables(stack)

    // The rows as the sheet holds them after the swap: each row keeps its id, the categories
    // and the percents trade places, and the second changes to 7 %.
    var first = groceries
    first.categoryId = other.id
    first.percent = CashbackPercent(e4: 70_000)!
    var second = cafes
    second.categoryId = references.category.id
    second.percent = CashbackPercent(e4: 50_000)!
    let diff = CashbackRules.diff(old: [groceries, cafes], new: [first, second])
    let undo = try planning.apply(
      PlanningChange(
        upsert: PlanningRows(cashbackRules: diff.upserts),
        delete: PlanningRowIDs(cashbackRules: diff.deletions)))
    let written = try CardRepository(writer: stack.writer).rules()
    #expect(written.count == 2)
    #expect(written.first { $0.categoryId == other.id }?.id == cafes.id)
    #expect(written.first { $0.categoryId == other.id }?.percent.e4 == 70_000)
    #expect(written.first { $0.categoryId == references.category.id }?.id == groceries.id)
    try planning.revert(undo)
    #expect(try tables(stack) == before)

    // An id-based save of the same sheet would have met the index.
    #expect(throws: (any Error).self) {
      try planning.apply(PlanningChange(upsert: PlanningRows(cashbackRules: [first])))
    }
    #expect(try tables(stack) == before)
  }

  /// The sheet changes the category of a row and saves: «Groceries 5 %» becomes «Home 5 %» and
  /// the card keeps one rule, of «Home». A chain — Groceries → Home, Home → Cinema — keeps two.
  /// ⌘Z gives the tables back each time.
  @Test func aRowMovedToANewCategoryIsNotLost() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let account = references.paymentMethod.id
    let home = CoreKit.Category(kind: .expense, name: "Home")
    let cinema = CoreKit.Category(kind: .expense, name: "Cinema")
    try ReferenceRepository(writer: stack.writer).save(home)
    try ReferenceRepository(writer: stack.writer).save(cinema)
    let planning = PlanningRepository(writer: stack.writer)
    let cards = CardRepository(writer: stack.writer)
    let black = PaymentCard(accountId: account, name: "Black")
    let groceries = rule(account, card: black.id, category: references.category.id, 50_000)
    _ = try planning.apply(
      PlanningChange(upsert: PlanningRows(cards: [black], cashbackRules: [groceries])))
    let before = try tables(stack)
    func lines() throws -> Set<String> {
      Set(try cards.rules().map { "\($0.categoryId?.uuidString ?? "-") \($0.percent.e4)" })
    }

    // The row keeps its id as the sheet holds it; only its category changes.
    var moved = groceries
    moved.categoryId = home.id
    let diff = CashbackRules.diff(old: [groceries], new: [moved])
    let undo = try planning.apply(
      PlanningChange(
        upsert: PlanningRows(cashbackRules: diff.upserts),
        delete: PlanningRowIDs(cashbackRules: diff.deletions)))
    #expect(try lines() == ["\(home.id.uuidString) 50000"])
    try planning.revert(undo)
    #expect(try tables(stack) == before)

    let homeRule = rule(account, card: black.id, category: home.id, 30_000)
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(cashbackRules: [homeRule])))
    let beforeChain = try tables(stack)
    var first = groceries
    first.categoryId = home.id
    var second = homeRule
    second.categoryId = cinema.id
    let chain = CashbackRules.diff(old: [groceries, homeRule], new: [first, second])
    let chainUndo = try planning.apply(
      PlanningChange(
        upsert: PlanningRows(cashbackRules: chain.upserts),
        delete: PlanningRowIDs(cashbackRules: chain.deletions)))
    #expect(try lines() == ["\(home.id.uuidString) 50000", "\(cinema.id.uuidString) 30000"])
    try planning.revert(chainUndo)
    #expect(try tables(stack) == beforeChain)
  }

  /// The entry line reads the live cards of live accounts, each with its account; an archived
  /// card, and a card of an archived account, it does not.
  @Test func vocabularyHasLiveCardsOfLiveAccounts() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let tBank = PaymentMethod(name: "T-Bank", kind: .card)
    let old = PaymentMethod(name: "Old bank", kind: .card, archived: true)
    try references.save(tBank)
    try references.save(old)
    let black = PaymentCard(accountId: tBank.id, name: "Black", aliases: ["чёрная"])
    let gone = PaymentCard(accountId: tBank.id, name: "Gone", archived: true)
    let oldCard = PaymentCard(accountId: old.id, name: "Old card")
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(cards: [black, gone, oldCard])))
    let vocabulary = try references.vocabulary(enabledCurrencies: [.rub])
    #expect(vocabulary.cards.map(\.entry.id) == [black.id])
    #expect(vocabulary.cards.first?.accountId == tBank.id)
    #expect(vocabulary.cards.first?.entry.aliases == ["чёрная"])
  }

  /// «Добавить…» of a new account of the kind «card» writes the account and its card in one
  /// write; a card that cannot be written leaves no account behind.
  @Test func aNewAccountAndItsStartingCardAreOneWrite() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let sber = PaymentMethod(name: "Sber", kind: .card)
    let card = try #require(CardRules.startingCard(for: sber))
    try references.save(sber, startingCard: card)
    let cards = CardRepository(writer: stack.writer)
    #expect(try cards.cards(of: sber.id).map(\.name) == ["Sber"])
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    try references.save(cash, startingCard: nil)
    #expect(try cards.cards(of: cash.id).isEmpty)

    // A card whose name the table refuses: nothing of the write lands.
    let broken = PaymentMethod(name: "Broken", kind: .card)
    #expect(throws: (any Error).self) {
      try references.save(broken, startingCard: PaymentCard(accountId: broken.id, name: " "))
    }
    let accounts = try references.paymentMethods(includeArchived: true)
    #expect(!accounts.contains { $0.id == broken.id })
  }

  @Test func sameRuleKeyTwiceIsRefusedByTheIndex() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let account = references.paymentMethod.id
    let planning = PlanningRepository(writer: stack.writer)
    // An account without cards holds its own rules; «everything else, always» twice is one key.
    #expect(throws: (any Error).self) {
      try planning.apply(
        PlanningChange(
          upsert: PlanningRows(
            cashbackRules: [rule(account, card: nil, 10_000), rule(account, card: nil, 20_000)])))
    }
    #expect(try CardRepository(writer: stack.writer).rules().isEmpty)
    // «Запомнить» on a key already kept takes that row.
    let kept = rule(account, card: nil, 10_000)
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(cashbackRules: [kept])))
    let remembered = CashbackRules.upserting(rule(account, card: nil, 20_000), into: [kept])
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(cashbackRules: [remembered])))
    #expect(try CardRepository(writer: stack.writer).rules() == [remembered])
    #expect(remembered.id == kept.id)
  }
}
