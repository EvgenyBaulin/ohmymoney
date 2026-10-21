import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A fixed id: the same on every run, so that a row can be named in an expectation.
private func id(_ number: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
}

/// The update to 1.3 moves the cashback rules the cards held up to their account, where the
/// cards follow them, and drops what a payment on a debt can no longer earn. It adds the
/// settings of an account's cashback — how it rounds, when it is paid, where the points go —
/// with the values a new account starts with, and changes no other value.
@Suite("The update to 1.3 puts the cashback rules on the account")
struct Migration0006CashbackTests {
  private static let context = MigrationContext.tests

  /// The accounts, cards and rules of a book as 1.2 leaves it, one shape each (see `book`).
  struct Shapes {
    // A: one card holding rules, one of them on «Кредиты».
    let a = id(9_101)
    let aCard = id(9_111)
    let aRules = [id(9_121), id(9_122), id(9_123)]
    // B: two cards holding the same rules.
    let b = id(9_102)
    let bCards = [id(9_112), id(9_113)]
    let bRules = [id(9_131), id(9_132), id(9_133), id(9_134)]
    // C: two cards whose rules differ.
    let c = id(9_103)
    let cCards = [id(9_114), id(9_115)]
    let cRules = [id(9_141), id(9_142)]
    // D: rules of the account itself and a rule of its card.
    let d = id(9_104)
    let dCard = id(9_116)
    let dRules = [id(9_151), id(9_152)]
    // E: a live card without rules and an archived one with a rule.
    let e = id(9_105)
    let eCards = [id(9_117), id(9_118)]
    let eRule = id(9_161)
    var accounts: [UUID] { [a, b, c, d, e] }
  }

  private static func percent(_ e4: Int64) -> CashbackPercent { CashbackPercent(e4: e4)! }

  /// A book as 1.2 leaves it: the rich book of 1.1 updated through `0005_cards`, plus the five
  /// accounts of `Shapes` with their cards and rules.
  static func book(named name: String) throws -> (book: OnePointOneBook, shapes: Shapes) {
    let book = try OnePointOneBook(named: name)
    let stack = try DatabaseStack(
      url: book.url, schema: FilteredSchemaSource(upTo: "0005_cards"), context: context)
    let shapes = Shapes()
    try stack.writer.write { db in
      let categories = try String.fetchAll(
        db,
        sql: """
          SELECT id FROM categories
          WHERE kind = 'expense' AND parent_id IS NULL AND system_role IS NULL
          ORDER BY rowid LIMIT 2
          """
      ).compactMap { UUID(uuidString: $0) }
      let loans = try #require(
        try String.fetchOne(db, sql: "SELECT id FROM categories WHERE system_role = 'loans'")
          .flatMap { UUID(uuidString: $0) })
      let (first, second) = (categories[0], categories[1])
      for (number, account) in shapes.accounts.enumerated() {
        try LegacyWriter.insert(
          PaymentMethod(id: account, name: "Shape \(number)", kind: .card, currency: .rub),
          db: db)
      }
      func card(_ id: UUID, of account: UUID, archived: Bool = false) throws {
        try LegacyWriter.insert(
          PaymentCard(
            id: id, accountId: account, name: "Card \(id.uuidString.prefix(8))", archived: archived),
          db: db)
      }
      func rule(
        _ id: UUID, of account: UUID, card: UUID?, category: UUID?, _ e4: Int64
      ) throws {
        try LegacyWriter.insert(
          CashbackRule(
            id: id, accountId: account, cardId: card, categoryId: category,
            percent: percent(e4)), db: db)
      }
      try card(shapes.aCard, of: shapes.a)
      try rule(shapes.aRules[0], of: shapes.a, card: shapes.aCard, category: first, 50_000)
      try rule(shapes.aRules[1], of: shapes.a, card: shapes.aCard, category: nil, 10_000)
      try rule(shapes.aRules[2], of: shapes.a, card: shapes.aCard, category: loans, 0)

      try card(shapes.bCards[0], of: shapes.b)
      try card(shapes.bCards[1], of: shapes.b)
      try rule(shapes.bRules[0], of: shapes.b, card: shapes.bCards[0], category: first, 30_000)
      try rule(shapes.bRules[1], of: shapes.b, card: shapes.bCards[0], category: nil, 10_000)
      try rule(shapes.bRules[2], of: shapes.b, card: shapes.bCards[1], category: first, 30_000)
      try rule(shapes.bRules[3], of: shapes.b, card: shapes.bCards[1], category: nil, 10_000)

      try card(shapes.cCards[0], of: shapes.c)
      try card(shapes.cCards[1], of: shapes.c)
      try rule(shapes.cRules[0], of: shapes.c, card: shapes.cCards[0], category: first, 30_000)
      try rule(shapes.cRules[1], of: shapes.c, card: shapes.cCards[1], category: first, 40_000)

      try card(shapes.dCard, of: shapes.d)
      try rule(shapes.dRules[0], of: shapes.d, card: nil, category: first, 20_000)
      try rule(shapes.dRules[1], of: shapes.d, card: shapes.dCard, category: second, 10_000)

      try card(shapes.eCards[0], of: shapes.e)
      try card(shapes.eCards[1], of: shapes.e, archived: true)
      try rule(shapes.eRule, of: shapes.e, card: shapes.eCards[1], category: first, 70_000)
    }
    try stack.close()
    return (book, shapes)
  }

  private static func rules(_ db: Database) throws -> [UUID: CashbackRule] {
    Dictionary(
      uniqueKeysWithValues: try CashbackRule.fetchAll(db).map { ($0.id, $0) })
  }

  // MARK: The rules

  @Test func theRulesGoUpWhereEveryCardWouldRepeatThem() throws {
    let (book, shapes) = try Self.book(named: "up")
    defer { book.remove() }
    let before = try book.read { db in try TestSupport.contents(db) }
    let loansRules = shapes.aRules.last!

    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }

    // A: both rules of the card go up as the same rows, the one on «Кредиты» goes.
    // B: the first card's rules go up, the second card's copies go.
    #expect(stack.applied.dataSteps["cashbackRulesMoved"] == 4)
    #expect(stack.applied.dataSteps["cashbackRulesDropped"] == 3)
    #expect(stack.applied.dataSteps["cashbackRulesVoided"] == 1)
    try stack.writer.read { db in
      let rules = try Self.rules(db)
      for number in 0..<2 {
        #expect(rules[shapes.aRules[number]]?.cardId == nil)
        #expect(rules[shapes.aRules[number]]?.accountId == shapes.a)
      }
      #expect(rules[loansRules] == nil)
      #expect(rules[shapes.bRules[0]]?.cardId == nil && rules[shapes.bRules[1]]?.cardId == nil)
      #expect(rules[shapes.bRules[2]] == nil && rules[shapes.bRules[3]] == nil)

      // C keeps a rule on each card, D and E are as they were.
      #expect(rules[shapes.cRules[0]]?.cardId == shapes.cCards[0])
      #expect(rules[shapes.cRules[1]]?.cardId == shapes.cCards[1])
      #expect(rules[shapes.dRules[0]]?.cardId == nil)
      #expect(rules[shapes.dRules[1]]?.cardId == shapes.dCard)
      #expect(rules[shapes.eRule]?.cardId == shapes.eCards[1])

      // Nothing was invented: the rows that are left are rows that were there, with their
      // percents.
      #expect(rules[shapes.aRules[0]]?.percent == Self.percent(50_000))
      #expect(rules[shapes.aRules[1]]?.percent == Self.percent(10_000))
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)

      // The other tables are untouched.
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before where table != "cashback_rules" {
        #expect(after[table] == old, "\(table) changed")
      }
    }
  }

  /// The same account twice over would be the rules twice; running the step again changes
  /// nothing.
  @Test func theStepIsDoneOnce() throws {
    let (book, _) = try Self.book(named: "once")
    defer { book.remove() }
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    let first = try stack.writer.read { db in try Self.rules(db) }
    let again = try stack.writer.write { db in try CashbackRulesFiling.file(db: db) }
    #expect(again == CashbackRulesFiling.Outcome())
    #expect(try stack.writer.read { db in try Self.rules(db) } == first)
  }

  // MARK: The settings

  /// Every account starts with whole units and the nearest, and has said nothing about the
  /// payout or the points.
  @Test func everyAccountStartsWithTheDefaults() throws {
    let (book, shapes) = try Self.book(named: "defaults")
    defer { book.remove() }
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    try stack.writer.read { db in
      let accounts = try PaymentMethod.fetchAll(db)
      #expect(accounts.count > shapes.accounts.count)
      for account in accounts {
        #expect(account.cashbackRounding == .standard, "\(account.name)")
        #expect(account.cashbackPayout == nil, "\(account.name)")
        #expect(account.cashbackPointsAccountId == nil, "\(account.name)")
      }
      // The settings of the cashback come after the bank, ahead of what later updates add.
      let columns = try db.columns(in: "payment_methods").map(\.name)
      let bank = try #require(columns.firstIndex(of: "bank_id"))
      #expect(
        Array(columns[(bank + 1)...].prefix(5)) == [
          "cashback_precision", "cashback_direction", "cashback_payout", "cashback_payout_day",
          "cashback_points_account_id",
        ])
    }
  }
}
