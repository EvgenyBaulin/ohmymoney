import AppCore
import CoreKit
import Foundation
import GRDB

@testable import AppDatabase

/// A database of the older schema — the migrations up to `0003_model` — drawn at random from a
/// seed and written with plain SQL, the way no repository of today would write it: every table
/// filled, and the odd values an older build or a hand edit could leave — a currency that is
/// NULL, empty, blank or in lower case, two main accounts or none, an archived main one,
/// operations without an account in the bin and out of it, zero amounts, reconciliations
/// without their moment, names with quotes, commas, line breaks and emoji.
///
/// The same seed always writes the same file, so a failure names the seed that reproduces it.
struct RandomLegacyDatabase {
  /// How the flags of the main account are drawn: every rule of the choice of the main account
  /// gets seeds of its own.
  enum Flags: Int, CaseIterable {
    case none, oneLive, twoLive, onlyArchived, all, random
  }

  struct Account {
    var id: String
    var rowid: Int64
    var archived: Bool
    var isDefault: Bool
  }

  let url: URL
  let seed: UInt64
  /// Every account as written, in the order it was written.
  private(set) var accounts: [Account] = []
  /// Every operation's id and account as written; `nil` — none.
  private(set) var operationAccounts: [(id: String, account: String?, live: Bool)] = []
  /// A word every name the database holds carries, so an output can be searched for any of
  /// them.
  let marker: String

  /// - Parameters:
  ///   - operations: how many operations, at most.
  ///   - brokenLinks: also write rows whose foreign keys point nowhere, as a file edited by
  ///     hand, or written with the keys off, can hold.
  init(
    seed: UInt64, operations: Int = 60, accounts accountCount: ClosedRange<Int> = 0...6,
    flags: Flags? = nil, unassigned: Bool? = nil, brokenLinks: Bool = false
  ) throws {
    self.seed = seed
    marker = "Zq\(seed)"
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "ohmymoney-random-legacy-\(seed)-\(UUID().uuidString)", isDirectory: true
      )
      .appendingPathComponent("finance.sqlite")
    // The seed is mixed once first: SplitMix64 steps its state by a fixed constant, so the
    // streams of neighbouring seeds would otherwise be one stream shifted by a step.
    var mixer = SeededRandom(seed: seed)
    let random = SeededRandom(seed: mixer.next())
    let flags = flags ?? Flags(rawValue: Int(seed % UInt64(Flags.allCases.count)))!
    let unassigned = unassigned ?? (seed % 3 != 0)
    let old = try DatabaseStack(url: url, schema: FilteredSchemaSource(upTo: "0003_model"))
    var writer = Writer(random: random, marker: marker)
    try old.writer.write { db in
      try writer.write(
        db, operations: operations, accountCount: accountCount, flags: flags,
        unassigned: unassigned)
    }
    if brokenLinks {
      try old.writer.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA foreign_keys = OFF")
        try writer.writeBrokenLinks(db)
        try db.execute(sql: "PRAGMA foreign_keys = ON")
      }
    }
    try old.close()
    accounts = writer.accounts
    operationAccounts = writer.operationAccounts
  }

  func read<T>(_ body: (Database) throws -> T) throws -> T {
    let queue = try DatabaseQueue(path: url.path)
    defer { try? queue.close() }
    return try queue.read(body)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  // MARK: Writing

  /// The drawing itself. A struct of its own so the random source and what was written travel
  /// together through the closures of GRDB.
  private struct Writer {
    var random: SeededRandom
    let marker: String
    var accounts: [Account] = []
    var operationAccounts: [(id: String, account: String?, live: Bool)] = []

    var expenseCategories: [String] = []
    var incomeCategories: [String] = []
    var people: [String] = []
    var places: [String] = []
    var events: [String] = []
    var goals: [String] = []
    var debts: [String] = []
    var batches: [String] = []
    var operations: [(id: String, kind: String)] = []
    var parts: [(id: String, operation: String, reimbursable: Bool)] = []
    var nameCount = 0

    init(random: SeededRandom, marker: String) {
      self.random = random
      self.marker = marker
    }

    mutating func id() -> String {
      let high = random.next()
      let low = random.next()
      let hex = String(format: "%016llX%016llX", high, low)
      let characters = Array(hex)
      let text =
        String(characters[0..<8]) + "-" + String(characters[8..<12]) + "-"
        + String(characters[12..<16]) + "-" + String(characters[16..<20]) + "-"
        + String(characters[20..<32])
      return UUID(uuidString: text)!.uuidString
    }

    mutating func chance(_ numerator: Int, _ denominator: Int) -> Bool {
      random.chance(numerator, outOf: denominator)
    }

    mutating func pick<T>(_ values: [T]) -> T {
      values[random.int(in: 0..<values.count)]
    }

    mutating func maybe<T>(_ values: [T], _ numerator: Int = 1, _ denominator: Int = 2) -> T? {
      guard !values.isEmpty, chance(numerator, denominator) else { return nil }
      return pick(values)
    }

    /// A name that carries the marker, and now and then what a name should never break: a
    /// quote, a comma, a line break, an emoji, spaces around it.
    mutating func name(_ word: String) -> String {
      nameCount += 1
      let odd = pick(["", " \"quoted\"", ", with a comma", "\nsecond line", " 🎂", "  "])
      return "\(marker) \(word) \(nameCount)\(odd)"
    }

    /// An instant of 2026 in the format GRDB writes, `YYYY-MM-DD HH:MM:SS.SSS`.
    mutating func instant() -> String {
      let day = random.int(in: 0..<260)
      let date = Date(timeIntervalSince1970: 1_767_225_600 + Double(day) * 86_400)
      var utc = Calendar(identifier: .gregorian)
      utc.timeZone = TimeZone(secondsFromGMT: 0)!
      let parts = utc.dateComponents([.year, .month, .day], from: date)
      return String(
        format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", parts.year!, parts.month!, parts.day!,
        random.int(in: 0...23), random.int(in: 0...59), random.int(in: 0...59),
        random.int(in: 0...999))
    }

    mutating func day() -> String { String(instant().prefix(10)) }

    mutating func amount() -> Int64 {
      if chance(1, 20) { return 0 }
      return Int64(random.int(in: 1...5_000)) * Int64(pick([100, 10_000, 1, 2_500]))
    }

    mutating func write(
      _ db: Database, operations operationCount: Int, accountCount: ClosedRange<Int>,
      flags: Flags, unassigned: Bool
    ) throws {
      try categories(db)
      for _ in 0..<random.int(in: 0...3) {
        let id = id()
        people.append(id)
        try db.execute(
          sql: "INSERT INTO people (id, name, relation, aliases, archived) VALUES (?, ?, ?, ?, ?)",
          arguments: [
            id, name("person"), pick(["family", "partner", "friend", "other"]),
            pick(["", "Al", "Al\nAlex"]), chance(1, 5) ? 1 : 0,
          ])
      }
      for _ in 0..<random.int(in: 0...3) {
        let id = id()
        places.append(id)
        try db.execute(
          sql: "INSERT INTO places (id, name, aliases, archived) VALUES (?, ?, ?, ?)",
          arguments: [id, name("place"), pick(["", "market"]), chance(1, 5) ? 1 : 0])
      }
      try paymentMethods(db, count: random.int(in: accountCount), flags: flags)
      for _ in 0..<random.int(in: 0...2) {
        let id = id()
        events.append(id)
        let start = day()
        try db.execute(
          sql: """
            INSERT INTO events (id, name, kind, start_date, end_date, budget_e4,
              recurring_yearly, series_id, archived)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id, name("event"), pick(["birthday", "new_year", "trip", "holiday", "other"]), start,
            start, chance(1, 2) ? amount() : nil, chance(1, 3) ? 1 : 0,
            chance(1, 3) ? self.id() : nil, chance(1, 5) ? 1 : 0,
          ])
      }
      for _ in 0..<random.int(in: 0...2) {
        let id = id()
        goals.append(id)
        try db.execute(
          sql: """
            INSERT INTO goals (id, name, target_e4, target_date, monthly_plan_e4,
              subcategory_id, archived)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id, name("goal"), amount(), chance(1, 2) ? day() : nil,
            chance(1, 2) ? amount() : nil, maybe(expenseCategories), chance(1, 4) ? 1 : 0,
          ])
      }
      for _ in 0..<random.int(in: 0...3) {
        let id = id()
        debts.append(id)
        try db.execute(
          sql: """
            INSERT INTO debts (id, direction, type, name, person_id, currency, interest_rate,
              monthly_payment_e4, payment_day, remind_days_before, payments_are_expenses,
              origin, note, closed, loans_subcategory_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id, pick(["i_owe", "owed_to_me"]),
            pick(["loan", "credit_card", "installment", "personal"]), name("debt"),
            maybe(people), pick(["RUB", "USD", "usd"]), chance(1, 2) ? "12.5" : nil,
            chance(1, 2) ? amount() : nil, chance(1, 2) ? random.int(in: 1...31) : nil,
            chance(1, 3) ? 2 : nil, chance(1, 2) ? 1 : 0, pick(["existing", "purchase"]),
            chance(1, 2) ? name("note") : nil, chance(1, 5) ? 1 : 0, maybe(expenseCategories),
          ])
      }
      if chance(1, 2) {
        let id = id()
        batches.append(id)
        try db.execute(
          sql: """
            INSERT INTO import_batches (id, source_file_name, imported_at, rows_total,
              rows_imported, rows_skipped) VALUES (?, ?, ?, 3, 2, 1)
            """,
          arguments: [id, name("file"), instant()])
      }
      for _ in 0..<random.int(in: 0...max(0, operationCount)) {
        try operation(db, unassigned: unassigned)
      }
      try links(db)
      try debtLines(db)
      try planning(db)
      try rest(db)
    }

    mutating func categories(_ db: Database) throws {
      func insert(
        _ id: String, parent: String?, kind: String, quality: String?, role: String?,
        archived: Bool
      ) throws {
        try db.execute(
          sql: """
            INSERT INTO categories (id, parent_id, kind, name, sort, archived, quality,
              system_role)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id, parent, kind, name("category"), random.int(in: 0...9), archived ? 1 : 0,
            quality, role,
          ])
      }
      let food = id()
      let unknown = id()
      let goalsParent = id()
      let salary = id()
      try insert(food, parent: nil, kind: "expense", quality: "neutral", role: nil, archived: false)
      try insert(
        unknown, parent: nil, kind: "expense", quality: nil, role: "unknown", archived: false)
      try insert(
        goalsParent, parent: nil, kind: "expense", quality: "good", role: "goals", archived: false)
      try insert(salary, parent: nil, kind: "income", quality: nil, role: nil, archived: false)
      expenseCategories = [food, unknown]
      incomeCategories = [salary]
      for parent in [food, food, goalsParent] {
        let child = id()
        try insert(
          child, parent: parent, kind: "expense", quality: maybe(["good", "bad", "neutral"]),
          role: nil, archived: chance(1, 6))
        expenseCategories.append(child)
      }
      let bonus = id()
      try insert(bonus, parent: salary, kind: "income", quality: nil, role: nil, archived: false)
      incomeCategories.append(bonus)
    }

    mutating func paymentMethods(_ db: Database, count: Int, flags: Flags) throws {
      for index in 0..<count {
        let archived: Bool
        let isDefault: Bool
        switch flags {
        case .none:
          archived = chance(1, 4)
          isDefault = false
        case .oneLive:
          archived = index == 0 ? false : chance(1, 4)
          isDefault = index == 0
        case .twoLive:
          archived = index < 2 ? false : chance(1, 4)
          isDefault = index < 2
        case .onlyArchived:
          archived = index == 0 ? true : chance(1, 4)
          isDefault = archived
        case .all:
          archived = chance(1, 4)
          isDefault = true
        case .random:
          archived = chance(1, 4)
          isDefault = chance(1, 3)
        }
        let id = id()
        try db.execute(
          sql: """
            INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id, name("account"), pick(["card", "cash", "account", "other"]),
            pick([nil, "", "   ", "RUB", "rub", "USD", "usd", "KZT"] as [String?]),
            pick(["", "tbank", "sber\nsberbank"]), isDefault ? 1 : 0, archived ? 1 : 0,
          ])
        accounts.append(
          Account(id: id, rowid: db.lastInsertedRowID, archived: archived, isDefault: isDefault))
      }
    }

    mutating func operation(_ db: Database, unassigned: Bool) throws {
      let id = id()
      let kind = pick([
        "expense", "expense", "expense", "expense", "income", "refund", "reimbursement",
      ])
      let currency = pick(["RUB", "RUB", "RUB", "USD", "usd", "EUR"])
      let amount = amount()
      let foreign = currency != "RUB"
      let rubles = foreign ? amount * Int64(random.int(in: 80...100)) : amount
      let account: String?
      if accounts.isEmpty || (unassigned && chance(1, 3)) {
        account = nil
      } else {
        account = pick(accounts).id
      }
      let deleted = chance(1, 7)
      let created = instant()
      try db.execute(
        sql: """
          INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_expr, rate,
            rate_date, rate_source, rate_provisional, amount_rub_e4, note, place_id,
            payment_method_id, period_month, debt_id, credit_debt_id, import_batch_id,
            external_id, created_at, updated_at, deleted_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          id, kind, instant(), currency, amount, chance(1, 6) ? "(100+50)/2" : nil,
          foreign ? pick(["90.1234", "81", "0.5"]) : nil, foreign ? day() : nil,
          foreign ? pick(["cbr", "cbr_mirror", "manual", "import"]) : nil,
          foreign && chance(1, 4) ? 1 : 0, rubles, chance(2, 3) ? name("note") : nil,
          maybe(places), account, kind == "income" ? String(day().prefix(7)) : nil,
          kind == "expense" ? maybe(debts, 1, 5) : nil, maybe(debts, 1, 8), maybe(batches, 1, 4),
          chance(1, 8) ? "legacy:\(self.id())" : nil, created, chance(1, 2) ? instant() : created,
          deleted ? instant() : nil,
        ])
      operations.append((id, kind))
      operationAccounts.append((id, account, !deleted))
      // Parts that add up to the operation, one to three of them.
      let count = amount == 0 ? 1 : random.int(in: 1...3)
      var left = amount
      var leftRub = rubles
      for index in 0..<count {
        let last = index == count - 1
        let share = last ? left : left / 2
        let shareRub = last ? leftRub : leftRub / 2
        left -= share
        leftRub -= shareRub
        let partId = self.id()
        let reimbursable = kind == "expense" && !people.isEmpty && chance(1, 5)
        let category: String?
        switch kind {
        case "income": category = pick(incomeCategories)
        case "reimbursement": category = nil
        default: category = chance(1, 12) ? nil : pick(expenseCategories)
        }
        try db.execute(
          sql: """
            INSERT INTO transaction_parts (id, transaction_id, category_id, category_source,
              quality, quality_source, amount_e4, amount_rub_e4, for_whom, for_person_id,
              reimbursable, debtor_person_id, reimbursement_status, event_id, goal_id, note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            partId, id, category,
            pick(["manual", "history", "model", "template", "import", "system"]),
            kind == "income" ? nil : maybe(["good", "neutral", "bad"]),
            kind == "income" ? nil : maybe(["system", "history", "category", "manual"]), share,
            shareRub, pick(["me", "me", "partner", "friends", "family", "other"]),
            maybe(people, 1, 3), reimbursable ? 1 : 0, reimbursable ? pick(people) : nil,
            reimbursable ? pick(["expected", "returned", "written_off"]) : nil,
            maybe(events, 1, 4), kind == "expense" ? maybe(goals, 1, 6) : nil,
            chance(1, 4) ? name("part") : nil,
          ])
        parts.append((partId, id, reimbursable))
      }
    }

    mutating func links(_ db: Database) throws {
      let owed = parts.filter(\.reimbursable)
      for back in operations where back.kind == "reimbursement" && !owed.isEmpty {
        for _ in 0..<random.int(in: 0...2) {
          try db.execute(
            sql: """
              INSERT INTO reimbursement_links (id, reimbursement_tx_id, part_id, amount_e4)
              VALUES (?, ?, ?, ?)
              """,
            arguments: [id(), back.id, pick(owed).id, amount()])
        }
      }
    }

    mutating func debtLines(_ db: Database) throws {
      let kinds = ["borrowed", "offset", "payment", "transfer_in", "transfer_out", "adjustment"]
      for debt in debts {
        for _ in 0..<random.int(in: 0...4) {
          let full = chance(1, 3)
          try db.execute(
            sql: """
              INSERT INTO debt_entries (id, debt_id, group_name, date, description,
                full_amount_e4, share, amount_e4, kind, transaction_id, note)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              """,
            arguments: [
              id(), debt, chance(1, 3) ? name("group") : nil, chance(3, 4) ? day() : nil,
              chance(1, 2) ? name("line") : nil, full ? amount() : nil, full ? "0.5" : nil,
              (chance(1, 2) ? -1 : 1) * amount(), pick(kinds),
              maybe(operations.map(\.id), 1, 4), chance(1, 4) ? name("note") : nil,
            ])
        }
      }
    }

    mutating func planning(_ db: Database) throws {
      var subscriptions: [String] = []
      for _ in 0..<random.int(in: 0...3) {
        let id = id()
        let kind = pick(["bill", "subscription"])
        if kind == "subscription" { subscriptions.append(id) }
        let reimbursable = !people.isEmpty && chance(1, 4)
        try db.execute(
          sql: """
            INSERT INTO scheduled_payments (id, name, kind, amount_e4, currency, category_id,
              payment_method_id, for_whom, for_person_id, reimbursable, debtor_person_id,
              reimbursement_amount_e4, reimbursement_currency, freq, interval, day, month,
              next_date, end_date, trial_end, cancel_url, remind_days_before, active)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id, name("payment"), kind, amount(), pick(["RUB", "USD", "usd"]),
            maybe(expenseCategories), maybe(accounts.map(\.id)),
            pick(["me", "partner", "friends", "family", "other"]), maybe(people, 1, 3),
            reimbursable ? 1 : 0, reimbursable ? pick(people) : nil,
            reimbursable ? amount() : nil, reimbursable ? pick(["RUB", "usd", ""]) : nil,
            pick(["weekly", "monthly", "yearly"]), random.int(in: 1...3),
            chance(3, 4) ? random.int(in: 1...31) : nil,
            chance(1, 3) ? random.int(in: 1...12) : nil,
            chance(3, 4) ? day() : nil, chance(1, 4) ? day() : nil, chance(1, 5) ? day() : nil,
            chance(1, 5) ? "https://example.com/\(marker)" : nil, chance(1, 2) ? 3 : nil,
            chance(4, 5) ? 1 : 0,
          ])
      }
      for payment in subscriptions {
        for _ in 0..<random.int(in: 0...2) {
          try db.execute(
            sql: """
              INSERT INTO subscription_prices (id, payment_id, date, amount_e4)
              VALUES (?, ?, ?, ?)
              """,
            arguments: [id(), payment, day(), amount()])
        }
      }
      let incomes = operations.filter { $0.kind == "income" }.map(\.id)
      for _ in 0..<random.int(in: 0...2) {
        let id = id()
        let recurring = chance(1, 2)
        try db.execute(
          sql: """
            INSERT INTO expected_income (id, name, category_id, person_id, kind, total_e4,
              currency, due_date, freq, day, parts_expected, closed)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id, name("expected"), maybe(incomeCategories), maybe(people),
            recurring ? "recurring" : "one_off", amount(), pick(["RUB", "usd"]),
            chance(3, 4) ? day() : nil, recurring ? pick(["weekly", "monthly", "yearly"]) : nil,
            chance(1, 2) ? random.int(in: 1...28) : nil, random.int(in: 1...3),
            chance(1, 5) ? 1 : 0,
          ])
        var linked: Set<String> = []
        for _ in 0..<random.int(in: 0...2) where !incomes.isEmpty {
          let income = pick(incomes)
          guard linked.insert(income).inserted else { continue }
          try db.execute(
            sql: """
              INSERT INTO expected_income_links (id, expected_income_id, transaction_id)
              VALUES (?, ?, ?)
              """,
            arguments: [self.id(), id, income])
        }
      }
      var limited: Set<String> = []
      for _ in 0..<random.int(in: 0...3) {
        let category = pick(expenseCategories)
        guard limited.insert(category).inserted else { continue }
        try db.execute(
          sql: """
            INSERT INTO budgets (id, scope, category_id, for_whom, amount_e4, rollover, start_month)
            VALUES (?, 'category', ?, NULL, ?, ?, ?)
            """,
          arguments: [
            id(), category, amount(), chance(1, 2) ? 1 : 0,
            chance(1, 2) ? String(day().prefix(7)) : nil,
          ])
      }
      if chance(1, 2) {
        try db.execute(
          sql: """
            INSERT INTO budgets (id, scope, category_id, for_whom, amount_e4, rollover)
            VALUES (?, 'bad_total', NULL, NULL, ?, 0)
            """,
          arguments: [id(), amount()])
      }
      for _ in 0..<random.int(in: 0...3) {
        let withMoment = chance(1, 2)
        let difference = chance(1, 2)
        try db.execute(
          sql: """
            INSERT INTO reconciliations (id, date, actual_total_rub_e4, expected_total_rub_e4,
              difference_e4, transaction_id, reconciled_at, breakdown)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id(), day(), amount(), difference ? amount() : nil,
            difference ? (chance(1, 2) ? -1 : 1) * amount() : nil,
            difference ? maybe(operations.map(\.id)) : nil, withMoment ? instant() : nil,
            chance(1, 3)
              ? #"[{"amount_e4":1000000,"currency":"USD","rub_e4":81430000,"rub_per_unit":"81.43"}]"#
              : nil,
          ])
      }
    }

    mutating func rest(_ db: Database) throws {
      for _ in 0..<random.int(in: 0...3) {
        try db.execute(
          sql: """
            INSERT INTO templates (id, text, category_id, amount_e4, currency, pinned, use_count)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id(), name("template"), maybe(expenseCategories), chance(1, 2) ? amount() : nil,
            pick([nil, "", "rub", "USD"] as [String?]), chance(1, 3) ? 1 : 0,
            random.int(in: 0...40),
          ])
      }
      try db.execute(
        sql: """
          INSERT INTO currencies (code, enabled, sort) VALUES ('RUB', 1, 0), ('USD', 1, 1),
            ('EUR', ?, 2)
          """,
        arguments: [chance(1, 2) ? 1 : 0])
      for _ in 0..<random.int(in: 0...4) {
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO rates (date, currency, rub_per_unit, nominal, source, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            day(), pick(["USD", "EUR", "KZT"]), pick(["90.1234", "15.6321", "0.1"]),
            pick([1, 100]), pick(["cbr", "cbr_mirror", "manual", "import"]),
            chance(1, 2) ? instant() : nil,
          ])
      }
      if chance(1, 2) {
        try db.execute(
          sql: """
            INSERT INTO import_mappings (id, source_kind, source_category, source_subcategory,
              target_category_id, target_for_whom, target_for_person_id, subcategory_is_place,
              target_event_id, target_quality, special_rule)
            VALUES (?, 'expense', ?, NULL, ?, 'me', ?, 0, ?, 'good', NULL)
            """,
          arguments: [id(), name("source"), pick(expenseCategories), maybe(people), maybe(events)])
      }
      for _ in 0..<random.int(in: 0...2) {
        try db.execute(
          sql: """
            INSERT INTO category_feedback (id, text, predicted_category_id, chosen_category_id,
              at, part_id, confidence_bp)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id(), name("feedback"), maybe(expenseCategories), pick(expenseCategories), instant(),
            maybe(parts.map(\.id)), chance(1, 2) ? random.int(in: 0...10_000) : nil,
          ])
      }
      if chance(1, 2) {
        try db.execute(
          sql: """
            INSERT INTO ml_models (id, kind, version, trained_at, metrics_json, file, checksum)
            VALUES (?, 'category', 1, ?, '{"fingerprint":"f","summary":"s"}',
              'models/category-model-v1.json', 'abc')
            """,
          arguments: [id(), instant()])
      }
      var dismissed: Set<String> = []
      for _ in 0..<random.int(in: 0...3) {
        let subject = chance(1, 2) ? "sched:\(random.int(in: 0...5))" : nil
        let rule = pick(["largePayment", "duplicate", "priceRise"])
        guard dismissed.insert("\(rule)|\(subject ?? "")").inserted else { continue }
        try db.execute(
          sql: """
            INSERT INTO anomaly_dismissals (id, rule, transaction_id, at, subject)
            VALUES (?, ?, ?, ?, ?)
            """,
          arguments: [id(), rule, maybe(operations.map(\.id)), instant(), subject])
      }
      try db.execute(
        sql: "INSERT INTO settings (key, value) VALUES ('planning.reconcileEveryDays', ?)",
        arguments: [String(random.int(in: 7...40))])
      if chance(1, 2) {
        try db.execute(
          sql: "INSERT INTO settings (key, value) VALUES ('app.odd', ?)",
          arguments: [name("setting")])
      }
    }

    /// Rows whose keys point nowhere: an operation's place, a part's category, a line's
    /// operation, an operation's account.
    mutating func writeBrokenLinks(_ db: Database) throws {
      let lost = id()
      let lostMoment = instant()
      try db.execute(
        sql: """
          INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
            payment_method_id, created_at, updated_at)
          VALUES (?, 'expense', ?, 'RUB', 20000, 20000, ?, ?, ?)
          """,
        arguments: [lost, lostMoment, id(), lostMoment, lostMoment])
      let lostAccount = try String.fetchOne(
        db, sql: "SELECT payment_method_id FROM transactions WHERE id = ?", arguments: [lost])
      operationAccounts.append((lost, lostAccount, true))
      try db.execute(
        sql: """
          INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4)
          VALUES (?, ?, 20000, 20000)
          """,
        arguments: [id(), lost])
      let operation = id()
      let moment = instant()
      try db.execute(
        sql: """
          INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
            place_id, payment_method_id, created_at, updated_at)
          VALUES (?, 'expense', ?, 'RUB', 10000, 10000, ?, NULL, ?, ?)
          """,
        arguments: [operation, moment, id(), moment, moment])
      operationAccounts.append((operation, nil, true))
      try db.execute(
        sql: """
          INSERT INTO transaction_parts (id, transaction_id, category_id, amount_e4, amount_rub_e4)
          VALUES (?, ?, ?, 10000, 10000)
          """,
        arguments: [id(), operation, id()])
      if let debt = debts.first {
        try db.execute(
          sql: """
            INSERT INTO debt_entries (id, debt_id, amount_e4, kind, transaction_id)
            VALUES (?, ?, 100, 'payment', ?)
            """,
          arguments: [id(), debt, id()])
      }
    }
  }
}

// MARK: - The rule of the main account, written once more

/// What the update has to do to the accounts of an older database, worked out apart from the
/// code that does it: the main account is the one live flagged account, or the most used of
/// several (the first written on a tie); with none flagged, the most used live account when
/// every operation has one; otherwise a new account, when there is anything at all.
enum MainAccountModel {
  enum Main: Equatable {
    case existing(String)
    case created
    case none
  }

  static func main(
    accounts: [RandomLegacyDatabase.Account],
    operations: [(id: String, account: String?, live: Bool)]
  ) -> Main {
    var uses: [String: Int] = [:]
    for operation in operations where operation.live {
      if let account = operation.account { uses[account, default: 0] += 1 }
    }
    func busiest(_ candidates: [RandomLegacyDatabase.Account]) -> String? {
      var best: RandomLegacyDatabase.Account?
      for account in candidates.sorted(by: { $0.rowid < $1.rowid }) {
        guard let current = best else {
          best = account
          continue
        }
        if uses[account.id, default: 0] > uses[current.id, default: 0] { best = account }
      }
      return best?.id
    }
    let live = accounts.filter { !$0.archived }
    let unassigned = operations.contains { $0.account == nil }
    if let flagged = busiest(live.filter(\.isDefault)) { return .existing(flagged) }
    if !unassigned, let chosen = busiest(live) { return .existing(chosen) }
    if unassigned || !operations.isEmpty || !accounts.isEmpty { return .created }
    return .none
  }
}

// MARK: - Tables as SQLite holds them

/// A table value for value: each row is its rowid and the `quote()` of every column — the exact
/// literal SQLite has, so an integer and a real, a text and a blob, an empty text and NULL all
/// differ.
struct ExactTable: Equatable {
  var columns: [String]
  var rows: [[String]]

  /// The table without `column`: the rowid stays first.
  func dropping(_ column: String) -> ExactTable {
    guard let index = columns.firstIndex(of: column) else { return self }
    var copy = self
    copy.columns.remove(at: index)
    copy.rows = rows.map { row in
      var row = row
      row.remove(at: index + 1)
      return row
    }
    return copy
  }

  /// The rows without their rowids, in the order of their values: for a table read by its
  /// key, where the rowid a row lands at says nothing.
  var byValue: ExactTable {
    ExactTable(
      columns: columns,
      rows: rows.map { Array($0.dropFirst()) }.sorted { $0.lexicographicallyPrecedes($1) })
  }

  /// The rows without their rowids, grouped by `column` and in rowid order inside each group:
  /// for rows whose order counts only among their own — the parts of one operation, read in
  /// the order of its split.
  func inOrderWithin(_ column: String) -> ExactTable {
    guard let index = columns.firstIndex(of: column) else { return self }
    let grouped = rows.enumerated().sorted { left, right in
      let (a, b) = (left.element[index + 1], right.element[index + 1])
      return a != b ? a < b : left.offset < right.offset
    }
    return ExactTable(columns: columns, rows: grouped.map { Array($0.element.dropFirst()) })
  }

  func values(of column: String) -> [String] {
    guard let index = columns.firstIndex(of: column) else { return [] }
    return rows.map { $0[index + 1] }
  }
}

enum ExactTables {
  /// Every table but SQLite's and GRDB's; `columns` names the columns to read of a table, all
  /// of them otherwise.
  static func read(
    _ db: Database, columns: [String: [String]]? = nil
  ) throws -> [String: ExactTable] {
    let tables = try String.fetchAll(
      db,
      sql: """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
        """)
    var result: [String: ExactTable] = [:]
    for table in tables {
      let names = try columns?[table] ?? db.columns(in: table).map(\.name)
      let list = (["rowid"] + names).map { "quote(\"\($0)\")" }.joined(separator: ", ")
      let rows = try Row.fetchAll(db, sql: "SELECT \(list) FROM \"\(table)\" ORDER BY rowid")
        .map { row in (0..<row.count).map { index -> String in row[index] ?? "?" } }
      result[table] = ExactTable(columns: names, rows: rows)
    }
    return result
  }
}
