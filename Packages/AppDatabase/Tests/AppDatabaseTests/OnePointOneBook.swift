import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A database as 1.1.2 leaves it — the migrations up to `0004_accounts` — on disk: half a year of
/// synthetic history with its accounts, groups, transfers and counts, written row by row the
/// way that build wrote it (`LegacyWriter` keeps only the columns the file has), and the rows
/// only an older build or a person could leave:
///
/// * accounts of every kind — a live card «Visa» in two currencies, a live card named with
///   spaces only, an archived card, cash, a bank account, another kind, and a live card whose id
///   is stored in lower case, with an operation of its own;
/// * four sheets of counts that compared, one per case of the mode of a count (R1–R4), after a
///   sheet of first counts; a compared opening of the setup made after «Позже»;
/// * a count of one total from 1.0.0 with its operation;
/// * goals with a monthly plan, archived too, and one without;
/// * anomalies waved away, the owner's choices of a category, currencies, rates, an import and
///   the model's row, so that no table compares empty with empty.
struct OnePointOneBook {
  let url: URL
  /// The history with its accounts, as generated.
  let set: SampleDataSet

  let visa: PaymentMethod
  let blank: PaymentMethod
  let archivedCard: PaymentMethod
  let cash: PaymentMethod
  let deposit: PaymentMethod
  let other: PaymentMethod
  /// A live card whose id the file holds in lower case.
  let lowerCase: PaymentMethod
  var lowerCaseText: String { lowerCase.id.uuidString.lowercased() }

  /// The sheet of first counts, the compared opening, the four sheets and the total, oldest
  /// first, and the counts of the first six in the order they are written.
  let reconciliations: [Reconciliation]
  let balances: [ReconciledBalance]
  /// The rows of the four sheets by their letter: R1 A B C, R2 D E, R3 F G, R4 H I.
  let rows: [String: ReconciledBalance]
  /// The operations the book adds: the differences of the sheets and of the total, and the
  /// purchase on the lower-case card.
  let entries: [TransactionEntry]
  /// A goal with a plan, an archived one with a plan and one without.
  let goals: [Goal]

  /// The mode every compared count of a sheet should get: the four sheets by the table of the
  /// rule, and the sample's own sheet, which recorded (its short row has its operation).
  let expectedModes: [UUID: Bool]

  static func freshURL(named name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-one-one-\(name)-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("finance.sqlite")
  }

  init(named name: String) throws {
    url = Self.freshURL(named: name)
    let calendar = TestSupport.sampleCalendar
    set = TestSupport.sample().withAccounts(
      seed: 20_260_918, calendar: calendar, language: "en")

    visa = PaymentMethod(name: "Visa", kind: .card, currency: .rub, otherCurrencies: [.usd])
    blank = PaymentMethod(name: "  ", kind: .card, currency: .rub)
    archivedCard = PaymentMethod(name: "Old Visa", kind: .card, currency: .rub, archived: true)
    cash = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub)
    deposit = PaymentMethod(name: "Вклад", kind: .account, currency: .rub)
    other = PaymentMethod(name: "Другое", kind: .other, currency: .rub)
    lowerCase = PaymentMethod(name: " Сбер ", kind: .card, currency: .rub)

    func at(_ day: Int, hour: Int = 12) -> Date {
      calendar.startOfDay(DateOnly(year: 2026, month: 8, day: day))
        .addingTimeInterval(TimeInterval(hour * 3_600))
    }
    let reconcileExpense = try #require(
      set.settings[PlanningSettings.reconcileExpenseCategoryKey].flatMap(UUID.init(uuidString:)))
    let reconcileIncome = try #require(
      set.settings[PlanningSettings.reconcileIncomeCategoryKey].flatMap(UUID.init(uuidString:)))
    let spending = try #require(
      set.categories.first { $0.kind == .expense && $0.parentId != nil && !$0.isSystem })

    // The first counts, all starting points.
    let first = Reconciliation(
      date: DateOnly(year: 2026, month: 8, day: 1), reconciledAt: at(1),
      actualTotalRubE4: .zero, kind: .accounts)
    var balances: [ReconciledBalance] = []
    var actual: [BalanceKey: AmountE4] = [:]
    for (account, currency, amount) in [
      (visa, CurrencyCode.rub, Int64(20_000)), (visa, .usd, 300), (cash, .rub, 5_000),
      (deposit, .rub, 100_000), (other, .rub, 1_000),
    ] {
      let row = ReconciledBalance(
        reconciliationId: first.id, accountId: account.id, currency: currency,
        actualE4: AmountE4(whole: amount))
      balances.append(row)
      actual[row.key] = row.actualE4
    }
    // The setup made after «Позже»: an opening of a key already counted, which compares.
    let opening = Reconciliation(
      date: DateOnly(year: 2026, month: 8, day: 2), reconciledAt: at(2),
      actualTotalRubE4: .zero, kind: .opening)
    let otherRubles = BalanceKey(accountId: other.id, currency: .rub)
    balances.append(
      ReconciledBalance(
        reconciliationId: opening.id, accountId: other.id, currency: .rub,
        actualE4: actual[otherRubles] ?? .zero, expectedE4: actual[otherRubles] ?? .zero,
        differenceE4: .zero))

    // The four sheets. A row that differs by `difference` whole units, with its operation as
    // the sheet wrote it: alive, in the bin, or none.
    var entries: [TransactionEntry] = []
    var rows: [String: ReconciledBalance] = [:]
    func count(
      _ letter: String, _ sheet: Reconciliation, _ account: PaymentMethod,
      _ currency: CurrencyCode, difference: Int64, operation: MigratingCount.Operation
    ) {
      let key = BalanceKey(accountId: account.id, currency: currency)
      let expected = actual[key] ?? .zero
      let counted = expected + AmountE4(whole: difference)
      var row = ReconciledBalance(
        reconciliationId: sheet.id, accountId: account.id, currency: currency,
        actualE4: counted, expectedE4: expected, differenceE4: AmountE4(whole: difference))
      if operation != .none, let moment = sheet.reconciledAt {
        let income = difference > 0
        let amount = AmountE4(whole: abs(difference))
        let transaction = Transaction(
          kind: income ? .income : .expense, occurredAt: moment, currency: currency,
          amountE4: amount, paymentMethodId: account.id,
          externalId: OperationLink.reconciledBalance(reconciliation: sheet.id, balance: row.id)
            .externalId,
          createdAt: moment, updatedAt: moment,
          deletedAt: operation == .binned ? moment.addingTimeInterval(600) : nil)
        let part = TransactionPart(
          transactionId: transaction.id,
          categoryId: income ? reconcileIncome : reconcileExpense, categorySource: .system,
          quality: income ? nil : .neutral, qualitySource: income ? nil : .category,
          amountE4: amount)
        entries.append(TransactionEntry(transaction: transaction, parts: [part]))
        row.transactionId = transaction.id
      }
      rows[letter] = row
      balances.append(row)
      actual[key] = counted
    }
    func sheet(_ day: Int) -> Reconciliation {
      Reconciliation(
        date: DateOnly(year: 2026, month: 8, day: day), reconciledAt: at(day, hour: 21),
        actualTotalRubE4: .zero, kind: .accounts)
    }
    let r1 = sheet(10)
    count("A", r1, visa, .rub, difference: -500, operation: .live)
    count("B", r1, cash, .rub, difference: 0, operation: .none)
    count("C", r1, deposit, .rub, difference: 300, operation: .binned)
    let r2 = sheet(12)
    count("D", r2, visa, .rub, difference: 0, operation: .none)
    count("E", r2, cash, .rub, difference: 0, operation: .none)
    let r3 = sheet(14)
    count("F", r3, deposit, .rub, difference: -200, operation: .none)
    count("G", r3, other, .rub, difference: 0, operation: .none)
    let r4 = sheet(16)
    count("H", r4, visa, .usd, difference: 10, operation: .none)
    count("I", r4, cash, .rub, difference: -1_000, operation: .live)

    // A count of one total from 1.0.0, with the operation of its difference.
    let totalId = UUID()
    let totalOperation = Transaction(
      kind: .expense, occurredAt: at(20), amountE4: AmountE4(whole: 1_200),
      paymentMethodId: set.paymentMethods.first { $0.isDefault }?.id,
      externalId: OperationLink.reconciliation(totalId).externalId, createdAt: at(20),
      updatedAt: at(20))
    entries.append(
      TransactionEntry(
        transaction: totalOperation,
        parts: [
          TransactionPart(
            transactionId: totalOperation.id, categoryId: spending.id,
            amountE4: AmountE4(whole: 1_200))
        ]))
    let total = Reconciliation(
      id: totalId, date: DateOnly(year: 2026, month: 8, day: 20), reconciledAt: at(20),
      actualTotalRubE4: AmountE4(whole: 100_000), expectedTotalRubE4: AmountE4(whole: 101_200),
      differenceE4: AmountE4(whole: -1_200), transactionId: totalOperation.id,
      breakdown: [
        ReconciliationAmount(
          currency: .usd, amountE4: AmountE4(whole: 100), rubPerUnit: Decimal(string: "81.43"),
          rubE4: AmountE4(whole: 8_143))
      ])

    // A purchase on the card whose id is in lower case.
    let purchase = Transaction(
      kind: .expense, occurredAt: at(18), amountE4: AmountE4(whole: 640), note: "odd card",
      paymentMethodId: lowerCase.id, createdAt: at(18), updatedAt: at(18))
    entries.append(
      TransactionEntry(
        transaction: purchase,
        parts: [
          TransactionPart(
            transactionId: purchase.id, categoryId: spending.id, amountE4: AmountE4(whole: 640))
        ]))

    goals = [
      Goal(
        name: "Planned", targetE4: AmountE4(whole: 500_000), monthlyPlanE4: AmountE4(whole: 10_000)),
      Goal(
        name: "Planned, archived", targetE4: AmountE4(whole: 50_000),
        monthlyPlanE4: AmountE4(whole: 2_000), archived: true),
      Goal(name: "Unplanned", targetE4: AmountE4(whole: 70_000)),
    ]
    reconciliations = [first, opening, r1, r2, r3, r4, total]
    self.balances = balances
    self.rows = rows
    self.entries = entries

    var modes: [UUID: Bool] = [:]
    for (letter, records) in [
      ("A", true), ("B", true), ("C", false), ("D", true), ("E", true), ("F", false),
      ("G", false), ("H", true), ("I", true),
    ] {
      if let row = rows[letter] { modes[row.id] = records }
    }
    let sampleSheets = Set(set.reconciliations.filter { $0.kind == .accounts }.map(\.id))
    for row in set.reconciledBalances
    where sampleSheets.contains(row.reconciliationId) && row.expectedE4 != nil {
      modes[row.id] = true
    }
    expectedModes = modes

    let old = try DatabaseStack(url: url, schema: FilteredSchemaSource(upTo: "0004_accounts"))
    try old.writer.write { db in try write(into: db) }
    try old.close()
  }

  // MARK: What the update gives

  /// The accounts as the step reads them, in the order they were written.
  var migratingAccounts: [MigratingCardAccount] {
    (set.paymentMethods + [visa, blank, archivedCard, cash, deposit, other, lowerCase]).map {
      MigratingCardAccount(id: $0.id, name: $0.name, kind: $0.kind, archived: $0.archived)
    }
  }

  /// The counts the step of the cards gives this book.
  var cardsStep: [String: Int] {
    let plan = CardsMigration.plan(accounts: migratingAccounts)
    return TestSupport.cardsStep(
      cardsCreated: plan.cards.count, cardsSkipped: plan.skipped,
      countsRecorded: expectedModes.values.filter { $0 }.count,
      countsKept: expectedModes.values.filter { !$0 }.count,
      goalPlansStarted: (set.goals + goals).filter { ($0.monthlyPlanE4?.raw ?? 0) > 0 }.count)
  }

  /// The history as the core has it, before the update.
  var dataset: Dataset {
    var dataset = TestSupport.dataset(set)
    dataset.entries += entries.filter { !$0.transaction.isDeleted }
    dataset.paymentMethods += [visa, blank, archivedCard, cash, deposit, other, lowerCase]
    dataset.goals += goals
    dataset.transfers = set.transfers
    dataset.accountGroups = set.accountGroups
    var book = set.planningBook
    book.reconciliations += reconciliations
    book.reconciledBalances += balances
    dataset.planning = book
    return dataset
  }

  // MARK: Writing

  private func write(into db: Database) throws {
    let planning = set.planning
    for group in set.accountGroups { try LegacyWriter.insert(group, db: db) }
    for category in set.categories where category.parentId == nil {
      try LegacyWriter.insert(category, db: db)
    }
    for category in set.categories where category.parentId != nil {
      try LegacyWriter.insert(category, db: db)
    }
    for person in set.people { try LegacyWriter.insert(person, db: db) }
    for place in set.places { try LegacyWriter.insert(place, db: db) }
    for account in set.paymentMethods + [visa, blank, archivedCard, cash, deposit, other] {
      try LegacyWriter.insert(account, db: db)
    }
    try db.execute(
      sql: """
        INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived)
        VALUES (?, ?, 'card', 'RUB', '', 0, 0)
        """,
      arguments: [lowerCaseText, lowerCase.name])
    for event in set.events { try LegacyWriter.insert(event, db: db) }
    for template in set.templates { try LegacyWriter.insert(template, db: db) }
    for goal in set.goals + goals { try LegacyWriter.insert(goal, db: db) }
    for debt in set.debts { try LegacyWriter.insert(debt, db: db) }
    for payment in planning.scheduled { try LegacyWriter.insert(payment, db: db) }
    for price in planning.prices { try LegacyWriter.insert(price, db: db) }
    for income in planning.expected { try LegacyWriter.insert(income, db: db) }
    for budget in planning.budgets { try LegacyWriter.insert(budget, db: db) }
    for entry in set.entries + entries {
      var transaction = entry.transaction
      let onTheOddCard = transaction.paymentMethodId == lowerCase.id
      if onTheOddCard { transaction.paymentMethodId = nil }
      try LegacyWriter.insert(transaction, db: db)
      if onTheOddCard {
        try db.execute(
          sql: "UPDATE transactions SET payment_method_id = ? WHERE id = ?",
          arguments: [lowerCaseText, transaction.id.uuidString])
      }
      for part in entry.parts { try LegacyWriter.insert(part, db: db) }
    }
    for line in set.debtEntries { try LegacyWriter.insert(line, db: db) }
    for link in set.links { try LegacyWriter.insert(link, db: db) }
    for link in planning.expectedLinks { try LegacyWriter.insert(link, db: db) }
    for transfer in set.transfers { try LegacyWriter.insert(transfer, db: db) }
    for reconciliation in set.reconciliations + reconciliations {
      try LegacyWriter.insert(reconciliation, db: db)
    }
    for balance in set.reconciledBalances + balances { try LegacyWriter.insert(balance, db: db) }
    var settings = set.settings
    settings[AnalyticsSettings.cashbackCategoryKey] = set.cashbackCategoryId.uuidString
    settings["planning.reconcileEveryDays"] = "21"
    for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
      try db.execute(
        sql: "INSERT INTO settings (key, value) VALUES (?, ?)", arguments: [key, value])
    }

    let operation = set.entries[0]
    let category = try #require(operation.parts[0].categoryId)
    try db.execute(
      sql: """
        INSERT INTO anomaly_dismissals (id, rule, transaction_id, at, subject)
          VALUES (?, 'largePayment', ?, '2026-09-01 10:00:00.000', NULL),
                 (?, 'priceRise', NULL, '2026-09-02 10:00:00.000', 'sched:x');
        INSERT INTO category_feedback (id, text, predicted_category_id, chosen_category_id, at,
          part_id, confidence_bp)
          VALUES (?, 'coffee', ?, ?, '2026-09-01 10:00:00.000', ?, 8100);
        INSERT INTO currencies (code, enabled, sort) VALUES ('RUB', 1, 0), ('USD', 1, 1);
        INSERT INTO rates (date, currency, rub_per_unit, nominal, source, fetched_at)
          VALUES ('2026-09-01', 'KZT', '15.6321', 100, 'cbr', '2026-09-01 12:00:00.000');
        INSERT INTO import_batches (id, source_file_name, imported_at, rows_total, rows_imported,
          rows_skipped) VALUES (?, 'old.numbers', '2026-01-10 10:00:00.000', 10, 9, 1);
        INSERT INTO import_mappings (id, source_kind, source_category, source_subcategory,
          target_category_id, target_for_whom, subcategory_is_place, target_quality)
          VALUES (?, 'expense', 'Food', NULL, ?, 'me', 0, 'good');
        INSERT INTO ml_models (id, kind, version, trained_at, metrics_json, file, checksum)
          VALUES (?, 'category', 1, '2026-09-01 10:00:00.000',
                  '{"fingerprint":"f","summary":"s"}', 'models/category-model-v1.json', 'abc');
        """,
      arguments: [
        UUID().uuidString, operation.id.uuidString, UUID().uuidString,
        UUID().uuidString, category.uuidString, category.uuidString,
        operation.parts[0].id.uuidString, UUID().uuidString, UUID().uuidString,
        category.uuidString, UUID().uuidString,
      ])
    try expectEveryCaseIsThere(db)
  }

  /// The file really holds every case the update must carry.
  private func expectEveryCaseIsThere(_ db: Database) throws {
    func count(_ sql: String, _ arguments: StatementArguments = []) throws -> Int {
      try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
    }
    #expect(try count("SELECT COUNT(*) FROM grdb_migrations") == 4)
    for kind in PaymentMethodKind.allCases {
      #expect(
        try count("SELECT COUNT(*) FROM payment_methods WHERE kind = ?", [kind.rawValue]) > 0,
        "no account of the kind \(kind)")
    }
    #expect(try count("SELECT COUNT(*) FROM payment_methods WHERE id <> upper(id)") == 1)
    #expect(
      try count(
        "SELECT COUNT(*) FROM transactions WHERE payment_method_id <> upper(payment_method_id)")
        == 1)
    #expect(try count("SELECT COUNT(*) FROM reconciliations WHERE kind = 'total'") > 0)
    #expect(try count("SELECT COUNT(*) FROM reconciliations WHERE kind = 'opening'") > 0)
    #expect(
      try count(
        """
        SELECT COUNT(*) FROM reconciliation_balances b JOIN transactions t ON t.id = b.transaction_id
        WHERE t.deleted_at IS NOT NULL
        """) == 1)
    #expect(try count("SELECT COUNT(*) FROM reconciliation_balances WHERE expected_e4 IS NULL") > 0)
    #expect(try count("SELECT COUNT(*) FROM goals WHERE monthly_plan_e4 > 0") >= 2)
    #expect(try count("SELECT COUNT(*) FROM goals WHERE monthly_plan_e4 IS NULL") >= 1)
    #expect(try count("SELECT COUNT(*) FROM scheduled_payments") > 0)
    #expect(try count("SELECT COUNT(*) FROM expected_income") > 0)
    #expect(try count("SELECT COUNT(*) FROM debt_entries") > 0)
    #expect(try count("SELECT COUNT(*) FROM transfers") > 0)
    // The sample's own sheet has the operation of its short row: it recorded.
    #expect(
      set.reconciledBalances.contains { $0.transactionId != nil },
      "the sample's sheet wrote no difference")
  }

  func read<T>(_ body: (Database) throws -> T) throws -> T {
    let queue = try DatabaseQueue(path: url.path)
    defer { try? queue.close() }
    return try queue.read(body)
  }

  /// A copy of the file as it is now, beside it.
  func keep(as name: String) throws -> URL {
    let copy = url.deletingLastPathComponent().appendingPathComponent(name)
    try DatabaseStack.backup(fileAt: url, to: copy)
    return copy
  }

  func remove() {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }
}

extension TestSupport {
  /// The counts of the step of the accounts (`0004_accounts`).
  static let accountsStepKeys: Set<String> = [
    "mainKept", "mainChosen", "mainCreated", "defaultsCleared", "assigned",
  ]

  /// The counts of the step of the cards (`0005_cards`).
  static let cardsStepKeys: Set<String> = [
    "cardsCreated", "cardsSkipped", "countsRecorded", "countsKept", "goalPlansStarted",
  ]

  /// The counts of the step of the banks and of the cashback rules (`0006_banks`).
  static let banksStepKeys: Set<String> = [
    "banksCreated", "banksSkipped", "accountsFiled", "cashbackRulesMoved",
    "cashbackRulesDropped", "cashbackRulesVoided",
  ]

  /// What the step of the banks does to the accounts of a file as it is: the plan worked out
  /// from every account in it. A file of 1.1 holds no cashback rules, so the step moves and
  /// drops none.
  static func banksStep(_ db: Database) throws -> [String: Int] {
    var accounts: [MigratingBankAccount] = []
    for row in try Row.fetchAll(
      db, sql: "SELECT id, name, archived FROM payment_methods ORDER BY rowid")
    {
      guard let text: String = row["id"], let id = UUID(uuidString: text) else { continue }
      let archived: Int64? = row["archived"]
      accounts.append(
        MigratingBankAccount(
          id: id, name: row["name"] ?? "", archived: (archived ?? 0) != 0, hasBank: false))
    }
    let plan = BanksMigration.plan(accounts: accounts)
    return [
      "banksCreated": plan.banks.count, "banksSkipped": plan.skipped,
      "accountsFiled": plan.assignments.count, "cashbackRulesMoved": 0,
      "cashbackRulesDropped": 0, "cashbackRulesVoided": 0,
    ]
  }

  /// What the step of the banks did, of all the steps of one open.
  static func banksStep(_ steps: [String: Int]) -> [String: Int] {
    steps.filter { banksStepKeys.contains($0.key) }
  }

  /// What the step of the accounts did, of all the steps of one open.
  static func accountsStep(_ steps: [String: Int]) -> [String: Int] {
    steps.filter { accountsStepKeys.contains($0.key) }
  }

  /// What the step of the cards did, of all the steps of one open.
  static func cardsStep(_ steps: [String: Int]) -> [String: Int] {
    steps.filter { cardsStepKeys.contains($0.key) }
  }

  /// The counts of the step of the cards, zero but those given.
  static func cardsStep(
    cardsCreated: Int = 0, cardsSkipped: Int = 0, countsRecorded: Int = 0, countsKept: Int = 0,
    goalPlansStarted: Int = 0
  ) -> [String: Int] {
    [
      "cardsCreated": cardsCreated, "cardsSkipped": cardsSkipped,
      "countsRecorded": countsRecorded, "countsKept": countsKept,
      "goalPlansStarted": goalPlansStarted,
    ]
  }
}
