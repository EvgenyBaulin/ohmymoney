import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Books of 1.2 drawn at random with what a hand edit or an older build can leave — ids in
/// lower case, one UUID in two spellings, names alike by the rule of the entry line, blank
/// names, archived accounts and cards, cards holding the same rules or different ones, rules of
/// the account beside rules of its cards, rules on «Кредиты» and under it — go through the update
/// to 1.3 and every open after it:
///
/// - the update and the opens after it never fail, and an open after the update changes nothing;
/// - every account that can be named — the spelling the filing writes to — is under a bank that
///   exists, and no two live banks are called alike;
/// - no rule is left on «Кредиты»; every rule left is a row of 1.2 with its month, category and
///   percent, on its own account, its card kept or let go of;
/// - every other value of 1.2 is where it was.
@Suite("Odd books of 1.2 go through the update to 1.3")
struct Migration0006OddBooksPropertyTests {
  private static let context = MigrationContext.tests

  private struct Drawn {
    var url: URL
    /// The spelling of each account id the filing writes to: the first of its UUID.
    var firstSpellings: Set<String>
    var loans: Set<String>
  }

  private static func spelled(_ id: UUID, lower: Bool) -> String {
    lower ? id.uuidString.lowercased() : id.uuidString
  }

  private static func draw(seed: UInt64) throws -> Drawn {
    var random = SeededRandom(seed: seed)
    let url = OnePointOneBook.freshURL(named: "odd-\(seed)")
    let old = try DatabaseStack(
      url: url, schema: FilteredSchemaSource(upTo: "0005_cards"), context: context)
    var firstSpellings: Set<String> = []
    var loans: Set<String> = []
    try old.writer.write { db in
      // The categories: two of mine, «Кредиты» and a subcategory under it.
      var categories: [String] = []
      for name in ["Food", "Fun"] {
        let id = UUID().uuidString
        try db.execute(
          sql: "INSERT INTO categories (id, kind, name) VALUES (?, 'expense', ?)",
          arguments: [id, name])
        categories.append(id)
      }
      let loanRoot = UUID().uuidString
      try db.execute(
        sql: """
          INSERT INTO categories (id, kind, name, system_role) VALUES (?, 'expense', 'Loans', 'loans')
          """, arguments: [loanRoot])
      let loanSub = UUID().uuidString
      try db.execute(
        sql: "INSERT INTO categories (id, parent_id, kind, name) VALUES (?, ?, 'expense', 'Bank')",
        arguments: [loanSub, loanRoot])
      loans = [loanRoot, loanSub]
      let ruleCategories: [String?] = [nil, categories[0], categories[1], loanRoot, loanSub]

      let names = [
        "Сбер", "сбер", " СБЕР ", "Ёлка", "елка", "  ", "Наличные", "Visa", "visa", "Т-Банк",
      ]
      var accounts: [String] = []
      for _ in 0..<random.int(in: 1...8) {
        let id = UUID()
        let text = spelled(id, lower: random.chance(1, outOf: 3))
        try db.execute(
          sql: "INSERT INTO payment_methods (id, name, kind, archived) VALUES (?, ?, ?, ?)",
          arguments: [
            text, names[random.int(in: 0..<names.count)],
            ["card", "cash", "account", "other"][random.int(in: 0...3)],
            random.chance(1, outOf: 4) ? 1 : 0,
          ])
        firstSpellings.insert(text)
        accounts.append(text)
        if random.chance(1, outOf: 5) {
          // The same UUID in the other spelling: another row, with a name of its own.
          let other = text == id.uuidString ? id.uuidString.lowercased() : id.uuidString
          try db.execute(
            sql: "INSERT INTO payment_methods (id, name, kind, archived) VALUES (?, ?, 'card', ?)",
            arguments: [
              other, names[random.int(in: 0..<names.count)], random.chance(1, outOf: 3) ? 1 : 0,
            ])
          accounts.append(other)
        }
      }

      var used: Set<String> = []
      func rule(account: String, card: String?) throws {
        let category = ruleCategories[random.int(in: 0..<ruleCategories.count)]
        let month: String? = random.chance(1, outOf: 3) ? "2026-05" : nil
        let key = [account, card ?? "", month ?? "", category ?? ""].joined(separator: "|")
        guard used.insert(key).inserted else { return }
        try db.execute(
          sql: """
            INSERT INTO cashback_rules (id, payment_method_id, card_id, category_id, month,
              percent_e4)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            spelled(UUID(), lower: random.chance(1, outOf: 4)), account, card, category, month,
            [0, 10_000, 30_000, 50_000][random.int(in: 0...3)],
          ])
      }
      for account in accounts {
        // Two cards that hold the same rules now and then, as 1.2 could leave them.
        let shared = random.chance(1, outOf: 3)
        var sharedRules: [(String?, String?)] = []
        for index in 0..<random.int(in: 0...3) {
          let card = spelled(UUID(), lower: random.chance(1, outOf: 4))
          try db.execute(
            sql: """
              INSERT INTO cards (id, payment_method_id, name, archived) VALUES (?, ?, ?, ?)
              """,
            arguments: [card, account, "Card \(index)", random.chance(1, outOf: 4) ? 1 : 0])
          if shared {
            if sharedRules.isEmpty {
              for _ in 0..<random.int(in: 1...3) {
                sharedRules.append(
                  (
                    ruleCategories[random.int(in: 0..<ruleCategories.count)],
                    random.chance(1, outOf: 3) ? "2026-05" : nil
                  ))
              }
            }
            for (category, month) in sharedRules {
              let key = [account, card, month ?? "", category ?? ""].joined(separator: "|")
              guard used.insert(key).inserted else { continue }
              try db.execute(
                sql: """
                  INSERT INTO cashback_rules (id, payment_method_id, card_id, category_id,
                    month, percent_e4)
                  VALUES (?, ?, ?, ?, ?, 20000)
                  """, arguments: [UUID().uuidString, account, card, category, month])
            }
          } else {
            for _ in 0..<random.int(in: 0...3) { try rule(account: account, card: card) }
          }
        }
        if random.chance(1, outOf: 4) { try rule(account: account, card: nil) }
      }
    }
    try old.close()
    return Drawn(url: url, firstSpellings: firstSpellings, loans: loans)
  }

  private static func read<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
    let queue = try DatabaseQueue(path: url.path)
    defer { try? queue.close() }
    return try queue.read(body)
  }

  @Test(arguments: Array(UInt64(1)...UInt64(120)))
  func anOddBookGoesThroughTheUpdate(seed: UInt64) throws {
    let drawn = try Self.draw(seed: seed)
    defer { try? FileManager.default.removeItem(at: drawn.url.deletingLastPathComponent()) }
    let before = try Self.read(drawn.url) { db in try TestSupport.contents(db) }
    let rulesBefore = try Self.read(drawn.url) { db in
      Dictionary(
        uniqueKeysWithValues: try Row.fetchAll(
          db,
          sql: """
            SELECT id, payment_method_id, card_id, category_id, month, percent_e4
            FROM cashback_rules
            """
        ).map { row -> (String, [String?]) in
          (
            row["id"],
            [
              row["payment_method_id"], row["card_id"], row["category_id"], row["month"],
              (row["percent_e4"] as Int64?).map(String.init),
            ]
          )
        })
    }

    let stack = try DatabaseStack(
      url: drawn.url, schema: TestSupport.schemaSource, context: Self.context)
    #expect(try AccountRepository(writer: stack.writer).ensureBanks() == nil, "seed \(seed)")
    try stack.close()
    let afterUpdate = try Self.read(drawn.url) { db in try TestSupport.contents(db) }
    let again = try DatabaseStack(
      url: drawn.url, schema: TestSupport.schemaSource, context: Self.context)
    #expect(try AccountRepository(writer: again.writer).ensureBanks() == nil, "seed \(seed)")
    try again.close()
    #expect(
      try Self.read(drawn.url) { db in try TestSupport.contents(db) } == afterUpdate,
      "seed \(seed): an open after the update changed something")

    try Self.read(drawn.url) { db in
      // Every account that can be named is under a bank that exists.
      for row in try Row.fetchAll(db, sql: "SELECT id, name, bank_id FROM payment_methods") {
        let id: String = row["id"]
        let name: String = row["name"]
        guard drawn.firstSpellings.contains(id), !NameKey.fold(name).isEmpty else { continue }
        let bank: String? = row["bank_id"]
        #expect(bank != nil, "seed \(seed): \(name) has no bank")
        if let bank {
          let exists = try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM banks WHERE id = ?)", arguments: [bank])
          #expect(exists == true, "seed \(seed): the bank of \(name) is not there")
        }
      }
      // No two live banks called alike.
      let live = try String.fetchAll(db, sql: "SELECT name FROM banks WHERE archived = 0")
      #expect(Set(live.map(NameKey.fold)).count == live.count, "seed \(seed): \(live)")

      // The rules: rows of 1.2, nothing on loans, nothing but the card changed.
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT id, payment_method_id, card_id, category_id, month, percent_e4
          FROM cashback_rules
          """)
      {
        let id: String = row["id"]
        guard let old = rulesBefore[id] else {
          Issue.record("seed \(seed): a rule that 1.2 did not have")
          continue
        }
        let category: String? = row["category_id"]
        #expect(!(category.map(drawn.loans.contains) ?? false), "seed \(seed): a rule on loans")
        #expect(row["payment_method_id"] == old[0])
        let card: String? = row["card_id"]
        #expect(card == nil || card == old[1])
        #expect(category == old[2])
        #expect(row["month"] == old[3])
        #expect((row["percent_e4"] as Int64?).map(String.init) == old[4])
      }
    }

    // Every other value of 1.2 is where it was; the accounts, the categories, the debts, the
    // journal, the goals and the transfers in the columns 1.2 had (the later updates add columns
    // to them).
    for (table, contents) in before
    where ![
      "banks", "cashback_rules", "payment_methods", "debt_entries", "debts", "categories",
      "goals", "transfers", "transactions", "events", "cards", "import_batches",
      "expected_income", "custom_currencies",
    ].contains(table) {
      #expect(afterUpdate[table] == contents, "seed \(seed): \(table) changed")
    }
    let oldColumns = try Self.read(drawn.url) { db in
      try TestSupport.contents(
        db,
        columns: [
          "payment_methods": before["payment_methods"]?.columns ?? [],
          "debt_entries": before["debt_entries"]?.columns ?? [],
          "debts": before["debts"]?.columns ?? [],
          "categories": before["categories"]?.columns ?? [],
          "goals": before["goals"]?.columns ?? [],
          "transfers": before["transfers"]?.columns ?? [],
          "transactions": before["transactions"]?.columns ?? [],
          "events": before["events"]?.columns ?? [],
          "cards": before["cards"]?.columns ?? [],
        ])
    }
    #expect(oldColumns["payment_methods"] == before["payment_methods"], "seed \(seed)")
    #expect(oldColumns["debt_entries"] == before["debt_entries"], "seed \(seed)")
    #expect(oldColumns["debts"] == before["debts"], "seed \(seed)")
    #expect(oldColumns["categories"] == before["categories"], "seed \(seed)")
    #expect(oldColumns["goals"] == before["goals"], "seed \(seed)")
    #expect(oldColumns["transfers"] == before["transfers"], "seed \(seed)")
    #expect(oldColumns["transactions"] == before["transactions"], "seed \(seed)")
    #expect(oldColumns["events"] == before["events"], "seed \(seed)")
    #expect(oldColumns["cards"] == before["cards"], "seed \(seed)")
  }
}
