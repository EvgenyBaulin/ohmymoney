import AppCore
import CoreKit
import Foundation
import GRDB

/// Moves the cashback rules the cards held up to their account (`CashbackRulesMigration`) and
/// drops the rules on «Кредиты», which earns nothing now: the step of the update to 1.3 that
/// touches the rules.
///
/// Every read and write is raw SQL against the columns of `cards`, `cashback_rules` and
/// `categories` as the schema made them, never through the record types: the step of a
/// migration must do tomorrow exactly what it does today. A rule is written back by the text its
/// id is stored as, so an id a hand edit left in lower case is matched in lower case. A row that
/// does not read is left where it is.
///
/// Done twice it changes nothing: an account that has rules of its own is left alone, and the
/// rules on loans are gone.
enum CashbackRulesFiling {
  /// What filing did, counts only.
  struct Outcome: Hashable {
    /// Rules that lost their card and are the account's now.
    var moved = 0
    /// Rules deleted: the copies of cards that held the same rules, and the rules on loans.
    var dropped = 0
    /// How many of those were rules on «Кредиты».
    var onLoans = 0
  }

  static func file(db: Database) throws -> Outcome {
    var cards: [PaymentCard] = []
    for row in try Row.fetchAll(
      db, sql: "SELECT id, payment_method_id, archived FROM cards ORDER BY rowid")
    {
      guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
        let account = (row["payment_method_id"] as String?).flatMap(UUID.init(uuidString:))
      else { continue }
      // A card whose archive flag does not read is taken for archived: its rules stay on it.
      let archived = (try? RowMapping.flag(row, "archived", fallback: false)) ?? true
      cards.append(PaymentCard(id: id, accountId: account, name: "", archived: archived))
    }

    var ruleTexts: [UUID: String] = [:]
    var rules: [CashbackRule] = []
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT id, payment_method_id, card_id, category_id, month, percent_e4
        FROM cashback_rules ORDER BY rowid
        """)
    {
      guard let text: String = row["id"], let id = UUID(uuidString: text),
        let account = (row["payment_method_id"] as String?).flatMap(UUID.init(uuidString:))
      else { continue }
      if ruleTexts[id] == nil { ruleTexts[id] = text }
      let stored = (try? RowMapping.optionalInteger(row, "percent_e4")) ?? nil
      rules.append(
        CashbackRule(
          id: id, accountId: account, cardId: RowMapping.optionalUUID(row, "card_id"),
          categoryId: RowMapping.optionalUUID(row, "category_id"),
          month: RowMapping.month(row, "month"),
          percent: stored.flatMap { CashbackPercent(e4: Int64($0)) } ?? .zero))
    }

    // «Кредиты» and what is under it.
    var loans: Set<UUID> = []
    for row in try Row.fetchAll(
      db, sql: "SELECT id FROM categories WHERE system_role = 'loans'")
    {
      if let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)) { loans.insert(id) }
    }
    for row in try Row.fetchAll(
      db, sql: "SELECT id, parent_id FROM categories WHERE parent_id IS NOT NULL")
    {
      if let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
        let parent = (row["parent_id"] as String?).flatMap(UUID.init(uuidString:)),
        loans.contains(parent)
      {
        loans.insert(id)
      }
    }

    let plan = CashbackRulesMigration.plan(rules: rules, cards: cards, loanCategoryIds: loans)
    var outcome = Outcome()
    for id in plan.dropped {
      guard let text = ruleTexts[id] else { continue }
      try db.execute(sql: "DELETE FROM cashback_rules WHERE id = ?", arguments: [text])
      outcome.dropped += db.changesCount
    }
    outcome.onLoans = plan.droppedOnLoans
    for id in plan.movedUp {
      guard let text = ruleTexts[id] else { continue }
      try db.execute(
        sql: "UPDATE cashback_rules SET card_id = NULL WHERE id = ? AND card_id IS NOT NULL",
        arguments: [text])
      outcome.moved += db.changesCount
    }
    return outcome
  }
}
