import AppCore
import CoreKit
import Foundation
import GRDB

/// The dictionaries of Settings → Справочники whose rows can be deleted, archived and brought
/// back by these rules. Accounts have rules of their own (`AccountRepository`).
public enum ReferenceBook: String, Sendable, CaseIterable {
  case people, places, events
}

/// What still points at a person, a place or an event.
public struct ReferenceUsage: Hashable, Sendable {
  /// Operations that name it, the deleted ones in the bin included: undoing their deletion
  /// would bring them back naming a row that is not there.
  public var operations: Int
  /// Debts, scheduled payments, expected income and import rules that name it.
  public var planning: Int

  public init(operations: Int = 0, planning: Int = 0) {
    self.operations = operations
    self.planning = planning
  }

  public var isUsed: Bool { operations + planning > 0 }
}

/// What a deletion of several rows did: the rows nothing pointed at are gone, the rest stayed
/// with what points at them — something may have come to point at a row since it was asked.
public struct ReferenceDeletion: Hashable, Sendable {
  public var deleted: [UUID]
  public var kept: [UUID: ReferenceUsage]

  public init(deleted: [UUID] = [], kept: [UUID: ReferenceUsage] = [:]) {
    self.deleted = deleted
    self.kept = kept
  }
}

/// Why a row of a dictionary was not put in the archive or brought back from it.
public enum ReferenceWriteError: Error, Equatable, Sendable {
  /// A live row of the same dictionary already has its name: the entry line could not tell
  /// the two apart.
  case nameTaken
  /// There is no such row: another window deleted it.
  case notFound
}

/// Categories, people, places, payment methods, events, templates and goals.
public struct ReferenceRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  // MARK: Categories

  /// Writes the starter categories on first launch. Existing rows are left untouched.
  public func seedCategoriesIfEmpty(_ categories: [CoreKit.Category]) throws {
    try writer.write { db in
      let existing = try CoreKit.Category.fetchCount(db)
      guard existing == 0 else { return }
      // Parents first: the table references itself.
      for category in categories.filter({ $0.parentId == nil }) {
        try category.insert(db)
      }
      for category in categories.filter({ $0.parentId != nil }) {
        try category.insert(db)
      }
    }
  }

  public func categories(includeArchived: Bool = false) throws -> [CoreKit.Category] {
    try writer.read { db in
      var request = CoreKit.Category.all()
      if !includeArchived {
        request = request.filter(Column("archived") == false)
      }
      return try request.order(Column("sort"), Column("name")).fetchAll(db)
    }
  }

  public func category(systemRole: SystemRole, kind: CategoryKind) throws -> CoreKit.Category? {
    try writer.read { db in
      try CoreKit.Category
        .filter(Column("system_role") == systemRole.rawValue)
        .filter(Column("kind") == kind.rawValue)
        .fetchOne(db)
    }
  }

  public func save(_ category: CoreKit.Category) throws {
    try writer.write { db in try category.save(db) }
  }

  /// «Добавить» with the name of a category in the archive brings that one back instead of a
  /// second of the same name: only its flag is written, so it comes back with its quality, its
  /// place and what is filed under it. Throws `notFound` when there is no such category.
  public func restoreCategory(_ id: UUID) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE categories SET archived = 0 WHERE id = ?", arguments: [id.uuidString])
      guard db.changesCount > 0 else { throw ReferenceWriteError.notFound }
    }
  }

  // MARK: Simple dictionaries

  public func people(includeArchived: Bool = false) throws -> [Person] {
    try fetchAll(Person.self, includeArchived: includeArchived)
  }

  public func places(includeArchived: Bool = false) throws -> [Place] {
    try fetchAll(Place.self, includeArchived: includeArchived)
  }

  public func paymentMethods(includeArchived: Bool = false) throws -> [PaymentMethod] {
    try fetchAll(PaymentMethod.self, includeArchived: includeArchived)
  }

  public func events(includeArchived: Bool = false) throws -> [Event] {
    try fetchAll(Event.self, includeArchived: includeArchived)
  }

  /// The banks the accounts are filed under, in the owner's order, then by name.
  public func banks(includeArchived: Bool = false) throws -> [Bank] {
    try writer.read { db in
      var request = Bank.all()
      if !includeArchived { request = request.filter(Column("archived") == false) }
      return try request.order(Column("sort"), Column("name"), Column.rowID).fetchAll(db)
    }
  }

  /// In the owner's order, then by name: 0 everywhere means alphabetical.
  public func goals(includeArchived: Bool = false) throws -> [Goal] {
    try writer.read { db in
      var request = Goal.all()
      if !includeArchived { request = request.filter(Column("archived") == false) }
      return try request.order(Column("sort"), Column("name")).fetchAll(db)
    }
  }

  /// The templates, pinned first, then the most used. A template in the archive is put away,
  /// not forgotten: it is listed with the others — it travels in the archive of the data and its
  /// words still count on it —, and the chips ask for the live ones only.
  public func templates(includeArchived: Bool = true) throws -> [Template] {
    try writer.read { db in
      var request = Template.all()
      if !includeArchived {
        request = request.filter(Column("archived") == false)
      }
      return try request.order(Column("pinned").desc, Column("use_count").desc).fetchAll(db)
    }
  }

  /// The debts by name: the open ones, the closed ones with `includeClosed`. A debt the owner
  /// deleted is left out unless `includeDeleted` asks for it, so it leaves every picker and the
  /// vocabulary of the entry line.
  public func debts(includeClosed: Bool = false, includeDeleted: Bool = false) throws -> [Debt] {
    try writer.read { db in
      var request = Debt.all()
      if !includeClosed {
        request = request.filter(Column("closed") == false)
      }
      if !includeDeleted {
        request = request.filter(Column("deleted_at") == nil)
      }
      return try request.order(Column("name")).fetchAll(db)
    }
  }

  public func save(_ person: Person) throws { try writer.write { db in try person.save(db) } }
  public func save(_ place: Place) throws { try writer.write { db in try place.save(db) } }
  /// Saves an account. Saved as the main one, it takes the flag from every other account in
  /// the same write: there is never a moment with two main accounts, nor one with none.
  public func save(_ method: PaymentMethod) throws {
    try writer.write { db in try Self.save(method, db: db) }
  }

  /// Saves a new account together with the card it starts with (`CardRules.startingCard`), in
  /// one write: both land, or neither. `nil`: the account alone, as `save(_:)`.
  ///
  /// `bank` is a bank made for the account (`BankRules.bank(forNewAccountNamed:)`): written
  /// first, in the same write, since the account stands under it. An account whose bank is an
  /// existing one needs no bank here.
  public func save(
    _ method: PaymentMethod, startingCard: PaymentCard?, bank: Bank? = nil
  ) throws {
    try writer.write { db in
      try bank?.save(db)
      try Self.save(method, db: db)
      if var card = startingCard {
        card.accountId = method.id
        try card.save(db)
      }
    }
  }

  static func save(_ method: PaymentMethod, db: Database) throws {
    try method.save(db)
    guard method.isDefault else { return }
    try db.execute(
      sql: "UPDATE payment_methods SET is_default = 0 WHERE is_default = 1 AND id <> ?",
      arguments: [method.id.uuidString])
  }
  public func save(_ event: Event) throws { try writer.write { db in try event.save(db) } }
  public func save(_ goal: Goal) throws { try writer.write { db in try goal.save(db) } }
  public func save(_ template: Template) throws { try writer.write { db in try template.save(db) } }
  public func save(_ debt: Debt) throws { try writer.write { db in try debt.save(db) } }

  /// One debt's journal in the order the planning book reads it (`PlanningRepository`): by
  /// day, undated lines first, lines of one day in the order they were written. The ties of
  /// a day are not left to the query plan.
  public func debtEntries(debtId: UUID) throws -> [DebtEntry] {
    try writer.read { db in
      try DebtEntry
        .filter(Column("debt_id") == debtId.uuidString)
        .order(Column("date"), Column.rowID)
        .fetchAll(db)
    }
  }

  public func save(_ entry: DebtEntry) throws {
    try writer.write { db in try entry.save(db) }
  }

  /// Puts a template in the archive — out of the chips, still counted on by the words it
  /// holds — or brings it back with «Вернуть», pin and count as they were. Only the flag is
  /// written: what the row on screen holds besides it may be older than the database.
  public func setTemplate(_ id: UUID, archived: Bool) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE templates SET archived = ? WHERE id = ?", arguments: [archived, id.uuidString])
      guard db.changesCount > 0 else { throw ReferenceWriteError.notFound }
    }
  }

  /// A chip picked counts one more use. Only the count is written, by the database itself: the
  /// copy the chip was made from may be older than the row — put in the archive, pinned,
  /// renamed since — and writing it back would undo that. A template deleted meanwhile stays
  /// deleted.
  public func countTemplateUse(_ id: UUID) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE templates SET use_count = use_count + 1 WHERE id = ?",
        arguments: [id.uuidString])
    }
  }

  /// Pins a template or takes its pin off, and nothing else. Throws `notFound` when there is no
  /// such template: another window deleted it.
  public func setTemplate(_ id: UUID, pinned: Bool) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE templates SET pinned = ? WHERE id = ?", arguments: [pinned, id.uuidString])
      guard db.changesCount > 0 else { throw ReferenceWriteError.notFound }
    }
  }

  /// Gives a template new words, without the spaces around them, and nothing else. Throws
  /// `notFound` when there is no such template.
  public func renameTemplate(_ id: UUID, to text: String) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE templates SET text = ? WHERE id = ?",
        arguments: [text.trimmingCharacters(in: .whitespacesAndNewlines), id.uuidString])
      guard db.changesCount > 0 else { throw ReferenceWriteError.notFound }
    }
  }

  /// Templates are only shortcuts for the entry line: deleting one loses no money data.
  public func deleteTemplate(id: UUID) throws {
    _ = try writer.write { db in
      try db.execute(sql: "DELETE FROM templates WHERE id = ?", arguments: [id.uuidString])
    }
  }

  // MARK: Merging duplicates

  /// Every column that points at a row of a dictionary that can be merged, by the table it
  /// points at. Operations are not the only thing that does: a scheduled payment names the
  /// person it is for and the account it is paid from, and the charge it writes next month
  /// takes them from there — a merge that left it behind would undo itself one payment at a
  /// time. `MergeTests` holds this list, with `keptOnMerge`, against the foreign keys of the
  /// schema, so a column a later migration adds cannot be forgotten here.
  ///
  /// The columns move in the order given. The cards of an account move first: a row that names
  /// a card must name the card's own account (the schema's `card_of_account_*` triggers), so the
  /// card is on the target before any operation or payment naming it is. The cashback rules
  /// and the accounts expected income is to come to move too, and so do the goals kept on an
  /// account and the rules of allocation that send money to it. An event a scheduled payment
  /// belongs to is used by it: it is archived or merged, not deleted, in the reference books.
  static let mergedColumns: [String: [(table: String, column: String)]] = [
    "people": [
      ("transaction_parts", "for_person_id"), ("transaction_parts", "debtor_person_id"),
      ("debts", "person_id"), ("scheduled_payments", "for_person_id"),
      ("scheduled_payments", "debtor_person_id"), ("expected_income", "person_id"),
      ("import_mappings", "target_for_person_id"), ("subscription_users", "person_id"),
    ],
    "places": [("transactions", "place_id")],
    "payment_methods": [
      ("cards", "payment_method_id"),
      ("transactions", "payment_method_id"), ("scheduled_payments", "payment_method_id"),
      ("transfers", "from_payment_method_id"), ("transfers", "to_payment_method_id"),
      ("debt_entries", "payment_method_id"), ("cashback_rules", "payment_method_id"),
      ("expected_income", "payment_method_id"), ("payment_methods", "cashback_points_account_id"),
      ("payment_methods", "interest_account_id"), ("goals", "account_id"),
      ("allocation_rules", "payment_method_id"), ("import_batches", "payment_method_id"),
    ],
    "events": [
      ("transaction_parts", "event_id"), ("import_mappings", "target_event_id"),
      ("scheduled_payments", "event_id"), ("event_budget_items", "event_id"),
    ],
  ]

  /// Columns that point at a row being merged and are left where they are, as its history:
  /// the balances counted on an account are what that account held at the time, and they stay
  /// with the account merged away.
  static let keptOnMerge = ["reconciliation_balances.payment_method_id"]

  /// Moves everything that points at one row of a dictionary — operations, debts, the
  /// planning book — to another and archives the one that was merged away. Nothing is
  /// deleted: whatever pointed at the old row points at a row that exists.
  public func mergePerson(_ source: UUID, into target: UUID) throws {
    guard source != target else { return }
    try writer.write { db in
      try Self.repoint("people", from: source, to: target, db: db)
      try Self.mergeAliases(Person.self, source: source, into: target, db: db)
      try db.execute(
        sql: "UPDATE people SET archived = 1 WHERE id = ?", arguments: [source.uuidString])
    }
  }

  public func mergePlace(_ source: UUID, into target: UUID) throws {
    guard source != target else { return }
    try writer.write { db in
      try Self.repoint("places", from: source, to: target, db: db)
      try Self.mergeAliases(Place.self, source: source, into: target, db: db)
      try db.execute(
        sql: "UPDATE places SET archived = 1 WHERE id = ?", arguments: [source.uuidString])
    }
  }

  /// The merge of one account into another as the settings have made it so far: what points
  /// at the source moves to the target, the name becomes an alias, the source goes to the
  /// archive — and when it was the main account, the target becomes the only main one, so the
  /// archive never holds the only main account. Only two accounts of one bank merge
  /// (`AccountWriteError.otherBank`). It works out no balances; a transfer between
  /// the two in one currency would become one from an account to itself, and the schema
  /// refuses the whole merge then.
  public func mergePaymentMethod(_ source: UUID, into target: UUID) throws {
    guard source != target else { return }
    try writer.write { db in
      try AccountRepository.refuseOtherBanks(source, target, db: db)
      try AccountRepository.dropCollidingRules(of: source, into: target, db: db)
      try AccountRepository.dropPayoutToItself(of: source, into: target, db: db)
      try Self.repoint("payment_methods", from: source, to: target, db: db)
      try Self.mergeAliases(PaymentMethod.self, source: source, into: target, db: db)
      let wasMain =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS (
              SELECT 1 FROM payment_methods WHERE id = ? AND is_default = 1 AND archived = 0)
            """,
          arguments: [source.uuidString]) ?? false
      try db.execute(
        sql: "UPDATE payment_methods SET archived = 1, is_default = 0 WHERE id = ?",
        arguments: [source.uuidString])
      if wasMain {
        try db.execute(
          sql: "UPDATE payment_methods SET is_default = 0 WHERE is_default = 1 AND id <> ?",
          arguments: [target.uuidString])
        try db.execute(
          sql: "UPDATE payment_methods SET is_default = 1 WHERE id = ?",
          arguments: [target.uuidString])
      }
    }
  }

  public func mergeEvent(_ source: UUID, into target: UUID) throws {
    guard source != target else { return }
    try writer.write { db in
      try Self.repoint("events", from: source, to: target, db: db)
      try db.execute(
        sql: "UPDATE events SET archived = 1 WHERE id = ?", arguments: [source.uuidString])
    }
  }

  /// Moves every column of `mergedColumns[dictionary]` from `source` to `target`.
  static func repoint(
    _ dictionary: String, from source: UUID, to target: UUID, db: Database
  ) throws {
    for (table, column) in mergedColumns[dictionary] ?? [] {
      try db.execute(
        sql: "UPDATE \(table) SET \(column) = ? WHERE \(column) = ?",
        arguments: [target.uuidString, source.uuidString])
    }
  }

  // MARK: Usage, deleting and the archive

  /// The rows of `book` something points at, with what points at them. A row that is not
  /// here is used by nothing and can be deleted. Every column that points at the dictionary
  /// counts (`mergedColumns`), and so do the operations in the bin.
  public func usage(in book: ReferenceBook) throws -> [UUID: ReferenceUsage] {
    try writer.read { db in try Self.usage(in: book, only: nil, db: db) }
  }

  public func usage(of id: UUID, in book: ReferenceBook) throws -> ReferenceUsage {
    try writer.read { db in try Self.usage(in: book, only: id, db: db)[id] ?? ReferenceUsage() }
  }

  static func usage(
    in book: ReferenceBook, only id: UUID?, db: Database
  ) throws -> [UUID: ReferenceUsage] {
    var operations: [String] = []
    var planning: [String] = []
    for (table, column) in mergedColumns[book.rawValue] ?? [] {
      switch table {
      case "transaction_parts":
        operations.append(
          "SELECT \(column) AS ref, transaction_id AS op FROM transaction_parts"
            + " WHERE \(column) IS NOT NULL")
      case "transactions":
        operations.append(
          "SELECT \(column) AS ref, id AS op FROM transactions WHERE \(column) IS NOT NULL")
      default:
        planning.append("SELECT \(column) AS ref FROM \(table) WHERE \(column) IS NOT NULL")
      }
    }
    var arguments = StatementArguments()
    var only = ""
    if let id {
      only = " WHERE ref = :id"
      arguments = ["id": id.uuidString]
    }
    var usage: [UUID: ReferenceUsage] = [:]
    // An operation that names a person twice — for whom and who gives back — is one operation.
    if !operations.isEmpty {
      let sql = """
        SELECT ref, COUNT(DISTINCT op) AS n
        FROM (\(operations.joined(separator: " UNION ALL ")))\(only) GROUP BY ref
        """
      for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
        guard let text: String = row["ref"], let key = UUID(uuidString: text) else { continue }
        usage[key, default: ReferenceUsage()].operations = row["n"]
      }
    }
    if !planning.isEmpty {
      let sql = """
        SELECT ref, COUNT(*) AS n
        FROM (\(planning.joined(separator: " UNION ALL ")))\(only) GROUP BY ref
        """
      for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
        guard let text: String = row["ref"], let key = UUID(uuidString: text) else { continue }
        usage[key, default: ReferenceUsage()].planning = row["n"]
      }
    }
    return usage
  }

  /// Deletes, for good and in one write, the rows of `ids` nothing points at; a row something
  /// points at stays and is named in `kept` with what points at it. The columns pointing at
  /// these tables would be emptied by the schema, not refused, so the check is made here,
  /// inside the write. No step of ⌘Z.
  public func delete(_ ids: [UUID], from book: ReferenceBook) throws -> ReferenceDeletion {
    try writer.write { db in
      var result = ReferenceDeletion()
      for id in ids {
        let usage = try Self.usage(in: book, only: id, db: db)[id] ?? ReferenceUsage()
        guard !usage.isUsed else {
          result.kept[id] = usage
          continue
        }
        try db.execute(
          sql: "DELETE FROM \(book.rawValue) WHERE id = ?", arguments: [id.uuidString])
        if db.changesCount > 0 { result.deleted.append(id) }
      }
      return result
    }
  }

  /// «Добавить» with a name the archive holds brings that row back instead of making a second
  /// one of the same name, and returns its id. Nil when no archived row answers to the name,
  /// and when a live row already does: then there is nothing to bring back.
  ///
  /// A person or a place answers to its name and to its other names, compared as the entry
  /// line compares them (`nameKey`), its name first. An event answers to its name only, and —
  /// a yearly event is made again every year under the same name — only when its days meet
  /// `days`. A row whose own name a live row has taken meanwhile stays in the archive; its other
  /// names a live row has taken are dropped from it as it comes back.
  public func revive(
    named name: String, in book: ReferenceBook, days: ClosedRange<DateOnly>? = nil
  ) throws -> UUID? {
    let key = Self.nameKey(name)
    guard !key.isEmpty else { return nil }
    return try writer.write { db in
      let rows = try Self.spelled(book, db: db)
      let taken = Self.liveKeys(rows, except: nil)
      guard book == .events || !taken.contains(key) else { return nil }
      let archived = rows.filter { row in
        guard row.archived else { return false }
        guard book == .events, let days else { return true }
        return row.meets(days)
      }
      let byName = archived.filter { Self.nameKey($0.name) == key }
      let byOtherName = archived.filter { $0.aliases.contains { Self.nameKey($0) == key } }
      guard
        let row = (byName + byOtherName).first(where: {
          book == .events || !taken.contains(Self.nameKey($0.name))
        })
      else { return nil }
      try Self.bringBack(row, book: book, taken: taken, db: db)
      return row.id
    }
  }

  /// «В архив»: the row leaves every menu and the vocabulary of the entry line, and keeps
  /// everything else — what points at it still does. Only the flag is written, so an edit of
  /// the row the owner has not saved does not slip in with it. Throws `notFound` when there is
  /// no such row.
  public func archive(_ id: UUID, in book: ReferenceBook) throws {
    try writer.write { db in
      try db.execute(
        sql: "UPDATE \(book.rawValue) SET archived = 1 WHERE id = ?", arguments: [id.uuidString])
      guard db.changesCount > 0 else { throw ReferenceWriteError.notFound }
    }
  }

  /// «Вернуть»: the row is live again. Its other names a live row has taken meanwhile are
  /// dropped, so one name is never on two live rows. Throws `nameTaken` when a live row has its
  /// name — an event is the exception, as events may share a name — and `notFound` when there
  /// is no such row.
  public func restore(_ id: UUID, in book: ReferenceBook) throws {
    try writer.write { db in
      let rows = try Self.spelled(book, db: db)
      guard let row = rows.first(where: { $0.id == id }) else {
        throw ReferenceWriteError.notFound
      }
      guard row.archived else { return }
      let taken = Self.liveKeys(rows, except: id)
      if book != .events, taken.contains(Self.nameKey(row.name)) {
        throw ReferenceWriteError.nameTaken
      }
      try Self.bringBack(row, book: book, taken: taken, db: db)
    }
  }

  /// A name as the entry line compares names: the case, «ё» against «е» and the spaces around
  /// it do not count.
  public static func nameKey(_ name: String) -> String {
    NameKey.fold(name)
  }

  /// A row of a dictionary as far as its names and its days go.
  private struct Spelled {
    let id: UUID
    let name: String
    let aliases: [String]
    let archived: Bool
    let start: String?
    let end: String?

    func meets(_ days: ClosedRange<DateOnly>) -> Bool {
      guard let start, let end else { return true }
      return start <= days.upperBound.iso && end >= days.lowerBound.iso
    }
  }

  private static func spelled(_ book: ReferenceBook, db: Database) throws -> [Spelled] {
    let columns =
      book == .events
      ? "id, name, '' AS aliases, archived, start_date, end_date"
      : "id, name, aliases, archived, NULL AS start_date, NULL AS end_date"
    return try Row.fetchAll(
      db, sql: "SELECT \(columns) FROM \(book.rawValue) ORDER BY name, id"
    ).compactMap { row in
      guard let text: String = row["id"], let id = UUID(uuidString: text) else { return nil }
      return Spelled(
        id: id, name: row["name"] ?? "", aliases: RowMapping.split(row["aliases"] ?? ""),
        archived: row["archived"] ?? false, start: row["start_date"], end: row["end_date"])
    }
  }

  /// Every name and other name of the live rows but `except`.
  private static func liveKeys(_ rows: [Spelled], except: UUID?) -> Set<String> {
    Set(
      rows.filter { !$0.archived && $0.id != except }
        .flatMap { [$0.name] + $0.aliases }
        .map(nameKey))
  }

  private static func bringBack(
    _ row: Spelled, book: ReferenceBook, taken: Set<String>, db: Database
  ) throws {
    guard book != .events else {
      try db.execute(
        sql: "UPDATE events SET archived = 0 WHERE id = ?", arguments: [row.id.uuidString])
      return
    }
    let kept = row.aliases.filter { !taken.contains(nameKey($0)) }
    try db.execute(
      sql: "UPDATE \(book.rawValue) SET archived = 0, aliases = ? WHERE id = ?",
      arguments: [RowMapping.join(kept), row.id.uuidString])
  }

  /// The name of the row that disappears, and its other names, become other names of the row
  /// that stays, so the entry line still recognises what I used to type. A name is compared as
  /// the entry line compares names (`nameKey`): one the row that stays answers to already is
  /// not added twice, and one another live row answers to is left out — two live rows with one
  /// name are two rows the entry line cannot tell apart. The row merged away may come from the
  /// archive, whose names are free for any live row to take.
  private static func mergeAliases<T: FetchableRecord & TableRecord>(
    _ type: T.Type, source: UUID, into target: UUID, db: Database
  ) throws {
    let table = T.databaseTableName
    let rows = try Row.fetchAll(db, sql: "SELECT id, name, aliases, archived FROM \(table)")
    func names(_ row: Row) -> [String] {
      [row["name"] ?? ""] + RowMapping.split(row["aliases"] ?? "")
    }
    func id(_ row: Row) -> String { row["id"] ?? "" }
    guard let sourceRow = rows.first(where: { id($0) == source.uuidString }),
      let targetRow = rows.first(where: { id($0) == target.uuidString })
    else { return }
    let others = Set(
      rows.filter { row in
        let rowId = id(row)
        let archived: Bool = row["archived"] ?? false
        return !archived && rowId != source.uuidString && rowId != target.uuidString
      }
      .flatMap(names).map(nameKey))
    var merged = RowMapping.split(targetRow["aliases"] ?? "")
    var known = Set(names(targetRow).map(nameKey))
    for alias in names(sourceRow) {
      let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = nameKey(trimmed)
      guard !key.isEmpty, !others.contains(key), known.insert(key).inserted else { continue }
      merged.append(trimmed)
    }
    try db.execute(
      sql: "UPDATE \(table) SET aliases = ? WHERE id = ?",
      arguments: [RowMapping.join(merged), target.uuidString])
  }

  /// Everything the entry-line parser needs to recognise names and aliases — the cards too,
  /// each with the account it puts the operation on.
  public func vocabulary(enabledCurrencies: [CurrencyCode]) throws -> ParserVocabulary {
    let accounts = try paymentMethods()
    let cards = try liveCards()
    // The name of a bank is another name of its first account, unless the word is taken.
    let bankNames = BankVocabulary.spellings(
      banks: try banks(), accounts: accounts, cards: cards)
    return ParserVocabulary(
      people: try people().map {
        ParserVocabulary.Entry(id: $0.id, name: $0.name, aliases: $0.aliases)
      },
      places: try places().map {
        ParserVocabulary.Entry(id: $0.id, name: $0.name, aliases: $0.aliases)
      },
      paymentMethods: accounts.map {
        ParserVocabulary.Entry(
          id: $0.id, name: $0.name, aliases: $0.aliases + (bankNames[$0.id].map { [$0] } ?? []))
      },
      events: try events().map { ParserVocabulary.Entry(id: $0.id, name: $0.name) },
      goals: try goals().map { ParserVocabulary.Entry(id: $0.id, name: $0.name) },
      debts: try debts().map { ParserVocabulary.Entry(id: $0.id, name: $0.name) },
      enabledCurrencies: enabledCurrencies,
      cards: cards.map {
        ParserVocabulary.CardEntry(
          entry: ParserVocabulary.Entry(id: $0.id, name: $0.name, aliases: $0.aliases),
          accountId: $0.accountId)
      })
  }

  /// The live cards of live accounts, in the owner's order: the cards the entry line reads. A
  /// card in the archive, or of an account in the archive, is read by nobody.
  private func liveCards() throws -> [PaymentCard] {
    try writer.read { db in
      try PaymentCard.fetchAll(
        db,
        sql: """
          SELECT cards.* FROM cards
          JOIN payment_methods ON payment_methods.id = cards.payment_method_id
          WHERE cards.archived = 0 AND payment_methods.archived = 0
          ORDER BY cards.sort, cards.name, cards.rowid
          """)
    }
  }

  private func fetchAll<T: FetchableRecord & TableRecord>(
    _ type: T.Type, includeArchived: Bool
  ) throws -> [T] {
    try writer.read { db in
      var request = T.all()
      if !includeArchived {
        request = request.filter(Column("archived") == false)
      }
      return try request.order(Column("name")).fetchAll(db)
    }
  }
}
