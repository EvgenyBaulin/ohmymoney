import CoreKit
import Foundation
import Testing

@testable import CoreCSV

/// The 49 file names of the export, in their one fixed order: the 18 of the first schema,
/// then the three the accounts brought, then the cards and their cashback rules, then the banks,
/// then the assets and their valuations, then the instalments and costs of the debts, the rules
/// of allocation, the custom currencies and the settings, then the tags, their links, the rules
/// and the notes of days, then the month limits, the articles and templates of events and the
/// extras of subscriptions, then the conditions of bank products and the deposits of the owner, then the attachments, then the wishes, their prices, the shopping list
/// and the things outside the capital.
private let specifiedFileNames = [
  "transactions.csv", "transaction_parts.csv", "reimbursement_links.csv", "people.csv",
  "payment_methods.csv", "places.csv", "events.csv", "categories.csv", "templates.csv",
  "scheduled_payments.csv", "subscription_prices.csv", "expected_income.csv", "budgets.csv",
  "goals.csv", "debts.csv", "debt_entries.csv", "reconciliations.csv", "rates.csv",
  "account_groups.csv", "transfers.csv", "reconciliation_balances.csv", "cards.csv",
  "cashback_rules.csv", "banks.csv", "assets.csv", "asset_valuations.csv",
  "debt_instalments.csv", "debt_costs.csv", "allocation_rules.csv", "custom_currencies.csv",
  "settings.csv", "tags.csv", "part_tags.csv", "rules.csv", "day_notes.csv",
  "budget_month_exceptions.csv", "event_budget_items.csv", "event_templates.csv",
  "subscription_terms.csv", "subscription_usage.csv", "subscription_users.csv",
  "subscription_keep_groups.csv", "bank_conditions.csv", "deposit_offers.csv", "attachments.csv",
  "wishes.csv",
  "wish_prices.csv", "shopping_items.csv", "owned_items.csv",
]

@Suite("ExportTables describes the 49 files of the export")
struct ExportTablesDescriptionTests {
  @Test func theFortyFiveFilesInTheirOrder() {
    #expect(ExportTables.all.count == 49)
    #expect(ExportTables.all.map(\.fileName) == specifiedFileNames)
    #expect(
      ExportTables.all.suffix(28) == [
        ExportTables.cards, ExportTables.cashbackRules, ExportTables.banks, ExportTables.assets,
        ExportTables.assetValuations, ExportTables.debtInstalments, ExportTables.debtCosts,
        ExportTables.allocationRules, ExportTables.customCurrencies, ExportTables.settings,
        ExportTables.tags, ExportTables.partTags, ExportTables.rules, ExportTables.dayNotes,
        ExportTables.budgetMonthExceptions, ExportTables.eventBudgetItems,
        ExportTables.eventTemplates, ExportTables.subscriptionTerms,
        ExportTables.subscriptionUsage, ExportTables.subscriptionUsers,
        ExportTables.subscriptionKeepGroups, ExportTables.bankConditions,
        ExportTables.depositOffers, ExportTables.attachments, ExportTables.wishes,
        ExportTables.wishPrices, ExportTables.shoppingItems, ExportTables.ownedItems,
      ])
  }

  /// The credits and the allocation of income brought five files at the end and their columns
  /// at the end of the accounts, the categories, the goals, the debts, their journal and the
  /// transfers: an older reader still finds its columns where they were.
  @Test func theColumnsOfTheCreditsComeLast() {
    #expect(ExportTables.debtInstalments.columns == ["id", "debt_id", "from_index", "amount"])
    #expect(
      ExportTables.debtCosts.columns == [
        "id", "debt_id", "kind", "name", "amount", "every", "day", "in_loan", "transaction_id",
        "sort",
      ])
    #expect(
      ExportTables.allocationRules.columns == [
        "id", "target", "goal_id", "payment_method_id", "mode", "percent", "amount", "currency",
        "sort", "active",
      ])
    #expect(
      ExportTables.customCurrencies.columns == [
        "code", "name", "symbol", "fraction_digits", "archived", "sort", "rate_source",
        "coin_id",
      ])
    #expect(ExportTables.settings.columns == ["key", "value"])
    #expect(
      Array(ExportTables.paymentMethods.columns.suffix(16)) == [
        "cushion", "credit_limit", "credit_grace", "credit_statement_day", "credit_pay_days",
        "credit_grace_days", "credit_purchase_rate", "credit_cash_rate", "credit_min_percent",
        "credit_min_floor", "credit_cash_fee_percent", "credit_cash_fee_fixed",
        "credit_cash_no_grace", "main_card_id", "accent", "hidden",
      ])
    #expect(
      Array(ExportTables.categories.columns.suffix(4)) == [
        "essential", "tax_rate", "tax_npd", "basket",
      ])
    #expect(
      Array(ExportTables.goals.columns.suffix(4)) == [
        "plan_start_month", "account_id", "transfer_on_contribution", "sort",
      ])
    #expect(
      Array(ExportTables.debts.columns.suffix(14)) == [
        "repay_months", "step_days", "first_due_on", "parts", "markup", "psk", "prepay_any_day",
        "prepay_notice_days", "planned_prepay_on", "planned_prepay", "in_ladder", "pledge",
        "return_by", "terms_reviewed",
      ])
    #expect(Array(ExportTables.debtEntries.columns.suffix(2)) == ["tranche", "prepay"])
    #expect(
      Array(ExportTables.transfers.columns.suffix(3)) == [
        "updated_at", "external_id", "arrived_at",
      ])
  }

  /// The capital brought two files at the end and one column at the end of the accounts and of
  /// the categories.
  @Test func theColumnsOfTheCapitalComeLast() {
    #expect(
      ExportTables.assets.columns == [
        "id", "name", "kind", "currency", "note", "disposed_on", "sort",
      ])
    #expect(
      ExportTables.assetValuations.columns == ["id", "asset_id", "day", "value", "note"])
    #expect(ExportTables.paymentMethods.columns[22] == "cushion")
    #expect(
      Array(ExportTables.categories.columns.prefix(9)) == [
        "id", "parent_id", "kind", "name", "sort", "archived", "quality", "system_role",
        "essential",
      ])
  }

  /// Every column the cards, the cashback, the events of payments, the plans of goals, the
  /// deleted debts, the accounts of expected income and the modes of counts brought goes after
  /// every column an older export had, in the order the schema declares them, so an older
  /// reader still finds its columns where they were.
  @Test func everyNewColumnIsLast() {
    #expect(
      ExportTables.transactions.columns == [
        "id", "kind", "occurred_at", "currency", "amount", "amount_expr", "rate", "rate_date",
        "rate_source", "rate_provisional", "amount_rub", "note", "place_id",
        "payment_method_id", "period_month", "debt_id", "credit_debt_id", "import_batch_id",
        "external_id", "created_at", "updated_at", "deleted_at", "account_currency",
        "account_amount", "card_id", "cashback_currency", "cashback", "time_zone", "one_off",
        "source", "bank_status", "posted_on", "dedup_key", "warranty_until", "warranty_where",
        "return_until", "discount", "regret", "regret_asked_on", "refund_waiting_until",
        "odometer_km",
      ])
    #expect(
      ExportTables.scheduledPayments.columns == [
        "id", "name", "kind", "amount", "currency", "category_id", "payment_method_id",
        "for_whom", "for_person_id", "reimbursable", "debtor_person_id",
        "reimbursement_amount", "reimbursement_currency", "freq", "interval", "day", "month",
        "next_date", "end_date", "trial_end", "cancel_url", "remind_days_before", "active",
        "card_id", "event_id",
      ])
    #expect(
      ExportTables.expectedIncome.columns == [
        "id", "name", "category_id", "person_id", "kind", "total", "currency", "due_date",
        "freq", "day", "parts_expected", "closed", "payment_method_id", "payout_kind", "asset_id",
      ])
    #expect(
      Array(ExportTables.goals.columns.prefix(9)) == [
        "id", "name", "target", "target_date", "monthly_plan", "subcategory_id", "archived",
        "currency", "plan_start_month",
      ])
    #expect(
      Array(ExportTables.debts.columns.prefix(21)) == [
        "id", "direction", "type", "name", "person_id", "currency", "interest_rate",
        "monthly_payment", "payment_day", "remind_days_before", "payments_are_expenses",
        "origin", "note", "closed", "loans_subcategory_id", "deleted_at", "accrues_interest",
        "main_from", "grace_kind", "grace_payment", "repay_months",
      ])
    #expect(
      ExportTables.reconciliations.columns == [
        "id", "date", "actual_total_rub", "expected_total_rub", "difference", "transaction_id",
        "reconciled_at", "breakdown", "kind", "origin",
      ])
    #expect(
      ExportTables.reconciliationBalances.columns == [
        "id", "reconciliation_id", "payment_method_id", "currency", "actual", "expected",
        "difference", "transaction_id", "records_difference",
      ])
    #expect(
      ExportTables.cards.columns == [
        "id", "payment_method_id", "name", "aliases", "sort", "archived", "fx_fee",
        "atm_fee_percent", "atm_fee_fixed", "atm_fee_fixed_currency", "last4", "details",
        "expires_on",
      ])
    #expect(
      ExportTables.cashbackRules.columns == [
        "id", "payment_method_id", "card_id", "category_id", "month", "percent",
      ])
    #expect(ExportTables.banks.columns == ["id", "name", "sort", "archived"])
    // The account of a bank and the settings of its cashback: the columns they brought, after
    // every older one.
    #expect(
      Array(ExportTables.paymentMethods.columns.prefix(23)) == [
        "id", "name", "kind", "currency", "aliases", "is_default", "archived", "group_id", "sort",
        "other_currencies", "bank_id", "cashback_precision", "cashback_direction",
        "cashback_payout", "cashback_payout_day", "cashback_points_account_id", "interest_rate",
        "interest_period", "interest_day", "interest_account_id", "deposit_opened_on",
        "deposit_ends_on", "cushion",
      ])
  }

  /// A column added later goes after every column an older export had, so an older reader
  /// still finds its columns where they were, and a new file goes at the end.
  @Test func theColumnsTheAccountsBroughtComeLast() {
    let added: [(ExportTable, [String])] = [
      (ExportTables.transactions, ["account_currency", "account_amount"]),
      (ExportTables.transactionParts, ["refund_of_part_id"]),
      (ExportTables.paymentMethods, ["group_id", "sort", "other_currencies"]),
      (ExportTables.templates, ["archived"]),
      (ExportTables.goals, ["currency"]),
      (
        ExportTables.debtEntries,
        ["payment_method_id", "occurred_at", "account_currency", "account_amount"]
      ),
      (ExportTables.reconciliations, ["kind"]),
    ]
    // The columns each file had before the cards came: the accounts' ones last among them.
    let before: [String: Int] = [
      "transactions.csv": 24, "transaction_parts.csv": 17, "payment_methods.csv": 10,
      "templates.csv": 8, "goals.csv": 8, "debt_entries.csv": 15, "reconciliations.csv": 9,
    ]
    for (table, columns) in added {
      let older = Array(table.columns.prefix(before[table.fileName] ?? 0))
      #expect(Array(older.suffix(columns.count)) == columns, "\(table.fileName)")
    }
    #expect(ExportTables.transactions.columns.count == 41)
    #expect(ExportTables.transactionParts.columns.count == 17)
    #expect(ExportTables.paymentMethods.columns.count == 38)
    #expect(ExportTables.templates.columns.count == 8)
    #expect(ExportTables.goals.columns.count == 12)
    #expect(ExportTables.debtEntries.columns.count == 18)
    #expect(ExportTables.reconciliations.columns.count == 10)
    #expect(
      ExportTables.accountGroups.columns == ["id", "name", "in_summary", "sort", "archived"])
    #expect(
      Array(ExportTables.transfers.columns.prefix(11)) == [
        "id", "occurred_at", "from_payment_method_id", "from_currency", "from_amount",
        "to_payment_method_id", "to_currency", "to_amount", "note", "created_at", "updated_at",
      ])
    #expect(
      Array(ExportTables.reconciliationBalances.columns.prefix(8)) == [
        "id", "reconciliation_id", "payment_method_id", "currency", "actual", "expected",
        "difference", "transaction_id",
      ])
  }

  @Test func fileNamesMatchTheSpecInOrder() {
    #expect(ExportTables.all.map(\.fileName) == specifiedFileNames)
  }

  @Test func everyTableHasAtLeastOneColumn() {
    for table in ExportTables.all {
      #expect(!table.columns.isEmpty, "\(table.fileName) has no columns")
    }
  }

  @Test func everyTableHasUniqueColumnNames() {
    for table in ExportTables.all {
      let unique = Set(table.columns)
      #expect(unique.count == table.columns.count, "\(table.fileName) repeats a column name")
    }
  }

  @Test func columnNamesAreSnakeCaseWithNoBlanks() {
    for table in ExportTables.all {
      for column in table.columns {
        #expect(!column.isEmpty)
        #expect(column == column.lowercased(), "\(table.fileName).\(column) is not lowercase")
        #expect(!column.contains(" "), "\(table.fileName).\(column) contains a space")
      }
    }
  }

  @Test func fileNamesAreUnique() {
    let names = ExportTables.all.map(\.fileName)
    #expect(Set(names).count == names.count)
  }
}

@Suite("ExportTables row functions round-trip through CSVWriter and CSVReader")
struct ExportTablesRowTests {
  /// Writes one table with a single data row, reads it back, and checks that every field
  /// came back unchanged and that the row has the same column count as the header.
  private func roundTrip(_ table: ExportTable, row: [String]) throws -> [String: String] {
    #expect(row.count == table.columns.count)
    var writer = CSVWriter(columns: table.columns)
    writer.append(row)
    let dictionaries = try CSVReader.dictionaries(from: writer.data())
    #expect(dictionaries.count == 1)
    return dictionaries[0]
  }

  /// Every value of the credits and the allocation reads back as written: amounts as decimal
  /// strings, flags as words, the grace period of a card in its own columns.
  @Test func theRowsOfTheCreditsReadBack() throws {
    let account = PaymentMethod(
      name: "Кредитка, «Т»", kind: .card,
      credit: CreditCardTerms(
        limitE4: AmountE4(whole: 150_000), grace: .statement(day: 5, payDays: 25),
        purchaseRate: Decimal(string: "29.9"), minFloorE4: AmountE4(whole: 600),
        cashWithoutGrace: true),
      mainCardId: UUID())
    let accountRow = try roundTrip(ExportTables.paymentMethods, row: ExportTables.row(account))
    #expect(accountRow["credit_limit"] == "150000")
    #expect(accountRow["credit_grace"] == "statement")
    #expect(accountRow["credit_statement_day"] == "5")
    #expect(accountRow["credit_pay_days"] == "25")
    #expect(accountRow["credit_grace_days"] == "")
    #expect(accountRow["credit_purchase_rate"] == "29.9")
    #expect(accountRow["credit_min_floor"] == "600")
    #expect(accountRow["credit_cash_no_grace"] == "true")
    #expect(accountRow["main_card_id"] == account.mainCardId?.uuidString)
    let plain = try roundTrip(
      ExportTables.paymentMethods, row: ExportTables.row(PaymentMethod(name: "Cash")))
    #expect(plain["credit_limit"] == "" && plain["credit_cash_no_grace"] == "false")

    let debt = Debt(
      direction: .iOwe, type: .installment, name: "Телефон", origin: .purchase,
      steps: DebtSteps(everyDays: 14, firstDue: DateOnly(year: 2026, month: 10, day: 12)),
      parts: 4, markupE4: AmountE4(whole: 600), termsReviewed: true)
    let debtRow = try roundTrip(ExportTables.debts, row: ExportTables.row(debt))
    #expect(debtRow["step_days"] == "14")
    #expect(debtRow["first_due_on"] == "2026-10-12")
    #expect(debtRow["parts"] == "4")
    #expect(debtRow["markup"] == "600")
    #expect(debtRow["prepay_any_day"] == "true")
    #expect(debtRow["in_ladder"] == "")
    #expect(debtRow["pledge"] == "false")
    #expect(debtRow["terms_reviewed"] == "true")

    let rule = AllocationRule(
      target: .cushion(nil), amount: .fixed(AmountE4(whole: 5_000), .usd), sort: 2)
    let ruleRow = try roundTrip(ExportTables.allocationRules, row: ExportTables.row(rule))
    #expect(ruleRow["target"] == "cushion")
    #expect(ruleRow["mode"] == "fixed")
    #expect(ruleRow["percent"] == "")
    #expect(ruleRow["amount"] == "5000")
    #expect(ruleRow["currency"] == "USD")
    let percent = AllocationRule(target: .goal(UUID()), amount: .percent(Decimal(string: "10.5")!))
    let percentRow = try roundTrip(ExportTables.allocationRules, row: ExportTables.row(percent))
    #expect(percentRow["mode"] == "percent" && percentRow["percent"] == "10.5")

    #expect(
      try roundTrip(
        ExportTables.settings,
        row: ExportTables.settingRow(key: "debts.nudgeTemplate", value: "{имя},\n«верни»")
      )["value"] == "{имя},\n«верни»")
  }

  @Test func transactionRoundTrips() throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let occurredAt = utc.date(
      from: DateComponents(year: 2026, month: 9, day: 17, hour: 14, minute: 3, second: 0))!
    let updatedAt = utc.date(
      from: DateComponents(year: 2026, month: 9, day: 17, hour: 14, minute: 3, second: 20))!

    let transaction = Transaction(
      id: UUID(),
      kind: .expense,
      occurredAt: occurredAt,
      currency: .rub,
      amountE4: AmountE4(raw: -12_345_678),
      amountExpr: "1000+600, \"tax\"",
      rate: Decimal(string: "92.3456"),
      rateDate: DateOnly(year: 2026, month: 9, day: 17),
      rateSource: .cbr,
      rateProvisional: true,
      amountRubE4: AmountE4(whole: 1500),
      note: "кофе\nи булочка",
      placeId: UUID(),
      paymentMethodId: UUID(),
      periodMonth: MonthKey(year: 2026, month: 9),
      debtId: nil,
      creditDebtId: nil,
      importBatchId: nil,
      externalId: nil,
      createdAt: occurredAt,
      updatedAt: updatedAt,
      deletedAt: nil)

    let row = ExportTables.row(transaction)
    let read = try roundTrip(ExportTables.transactions, row: row)
    #expect(read["account_currency"] == "")
    #expect(read["account_amount"] == "")

    #expect(read["id"] == transaction.id.uuidString)
    #expect(read["kind"] == "expense")
    #expect(read["occurred_at"] == "2026-09-17T14:03:00Z")
    #expect(read["currency"] == "RUB")
    #expect(read["amount"] == "-1234.5678")
    #expect(read["amount_expr"] == "1000+600, \"tax\"")
    #expect(read["rate"] == "92.3456")
    #expect(read["rate_date"] == "2026-09-17")
    #expect(read["rate_source"] == "cbr")
    #expect(read["rate_provisional"] == "true")
    #expect(read["amount_rub"] == "1500")
    #expect(read["note"] == "кофе\nи булочка")
    #expect(read["period_month"] == "2026-09")
    #expect(read["debt_id"] == "")
    #expect(read["external_id"] == "")
    #expect(read["deleted_at"] == "")
  }

  @Test func transactionPartRoundTrips() throws {
    let part = TransactionPart(
      id: UUID(),
      transactionId: UUID(),
      categoryId: UUID(),
      categorySource: .imported,
      quality: .bad,
      qualitySource: .manual,
      amountE4: AmountE4(raw: 0),
      amountRubE4: AmountE4(raw: 0),
      forWhom: .family,
      forPersonId: nil,
      reimbursable: true,
      debtorPersonId: UUID(),
      reimbursementStatus: .writtenOff,
      eventId: nil,
      goalId: nil,
      note: nil)

    let row = ExportTables.row(part)
    let read = try roundTrip(ExportTables.transactionParts, row: row)

    #expect(read["category_source"] == "import")
    #expect(read["quality"] == "bad")
    #expect(read["amount"] == "0")
    #expect(read["for_whom"] == "family")
    #expect(read["reimbursable"] == "true")
    #expect(read["reimbursement_status"] == "written_off")
    #expect(read["note"] == "")
    #expect(read["refund_of_part_id"] == "")
  }

  /// What moved on an account that does not hold the operation's currency, and the purchase
  /// part a refund takes back from.
  @Test func theLegOfAnOperationAndTheRefundOfAPartRoundTrip() throws {
    let transaction = Transaction(
      kind: .refund, occurredAt: Date(timeIntervalSince1970: 1_789_000_000), currency: .usd,
      amountE4: AmountE4(whole: 50), paymentMethodId: UUID(), accountCurrency: .rub,
      accountAmountE4: AmountE4(raw: 46_123_456))
    let read = try roundTrip(ExportTables.transactions, row: ExportTables.row(transaction))
    #expect(read["account_currency"] == "RUB")
    #expect(read["account_amount"] == "4612.3456")

    let part = TransactionPart(
      transactionId: transaction.id, amountE4: AmountE4(whole: 50), refundOfPartId: UUID())
    let readPart = try roundTrip(ExportTables.transactionParts, row: ExportTables.row(part))
    #expect(readPart["refund_of_part_id"] == part.refundOfPartId?.uuidString)
  }

  @Test func reimbursementLinkRoundTrips() throws {
    let link = ReimbursementLink(
      id: UUID(), reimbursementTxId: UUID(), partId: UUID(), amountE4: AmountE4(whole: 300))
    let row = ExportTables.row(link)
    let read = try roundTrip(ExportTables.reimbursementLinks, row: row)
    #expect(read["amount"] == "300")
  }

  @Test func personRoundTripsAliasesAsNewlines() throws {
    let person = Person(
      id: UUID(), name: "Иван, «Ваня»", relation: .friend,
      aliases: ["Ваня", "Vanya, the neighbor"], archived: false)
    let row = ExportTables.row(person)
    let read = try roundTrip(ExportTables.people, row: row)

    #expect(read["name"] == "Иван, «Ваня»")
    #expect(read["relation"] == "friend")
    #expect(read["aliases"] == "Ваня\nVanya, the neighbor")
    #expect(read["archived"] == "false")
  }

  @Test func paymentMethodRoundTrips() throws {
    let method = PaymentMethod(
      id: UUID(), name: "Card \"Black\"", kind: .card, currency: .usd, aliases: [],
      isDefault: true, archived: false)
    let row = ExportTables.row(method)
    let read = try roundTrip(ExportTables.paymentMethods, row: row)

    #expect(read["name"] == "Card \"Black\"")
    #expect(read["currency"] == "USD")
    #expect(read["is_default"] == "true")
    #expect(read["aliases"] == "")
    #expect(read["group_id"] == "")
    #expect(read["sort"] == "0")
    #expect(read["other_currencies"] == "")
    #expect(read["bank_id"] == "")
    // An account that has said nothing about its cashback starts with whole units and the
    // nearest, and names no payout day and no points account.
    #expect(read["cashback_precision"] == "whole")
    #expect(read["cashback_direction"] == "nearest")
    #expect(read["cashback_payout"] == "")
    #expect(read["cashback_payout_day"] == "")
    #expect(read["cashback_points_account_id"] == "")
  }

  @Test func theCashbackSettingsOfAnAccountTravelWithIt() throws {
    let points = UUID()
    let method = PaymentMethod(
      name: "Black", cashbackRounding: CashbackRounding(precision: .cents, direction: .down),
      cashbackPayout: CashbackPayout.later(day: 10), cashbackPointsAccountId: points)
    let read = try roundTrip(ExportTables.paymentMethods, row: ExportTables.row(method))
    #expect(read["cashback_precision"] == "cents")
    #expect(read["cashback_direction"] == "down")
    #expect(read["cashback_payout"] == "later")
    #expect(read["cashback_payout_day"] == "10")
    #expect(read["cashback_points_account_id"] == points.uuidString)
    let immediate = PaymentMethod(name: "Cash", cashbackPayout: .immediately)
    let second = try roundTrip(ExportTables.paymentMethods, row: ExportTables.row(immediate))
    #expect(second["cashback_payout"] == "immediately")
    #expect(second["cashback_payout_day"] == "")
  }

  @Test func theBankOfAnAccountTravelsWithIt() throws {
    let bank = Bank(name: "Т-Банк")
    let method = PaymentMethod(name: "Black", bankId: bank.id)
    let read = try roundTrip(ExportTables.paymentMethods, row: ExportTables.row(method))
    #expect(read["bank_id"] == bank.id.uuidString)
  }

  @Test func bankRoundTrips() throws {
    let bank = Bank(name: "Банк, «Мой»", sort: 4, archived: true)
    let read = try roundTrip(ExportTables.banks, row: ExportTables.row(bank))
    #expect(read["id"] == bank.id.uuidString)
    #expect(read["name"] == "Банк, «Мой»")
    #expect(read["sort"] == "4")
    #expect(read["archived"] == "true")
  }

  /// The currencies after the main one travel as the database keeps them, joined by commas —
  /// quoted by the writer, read back whole.
  @Test func anAccountOfSeveralCurrenciesRoundTrips() throws {
    let method = PaymentMethod(
      name: "Freedom", kind: .account, currency: .eur, groupId: UUID(), sort: 3,
      otherCurrencies: [.usd, .rub, CurrencyCode("KZT")])
    var writer = CSVWriter(columns: ExportTables.paymentMethods.columns)
    writer.append(ExportTables.row(method))
    #expect(String(decoding: writer.data(), as: UTF8.self).contains("\"USD,RUB,KZT\""))
    let read = try roundTrip(ExportTables.paymentMethods, row: ExportTables.row(method))
    #expect(read["group_id"] == method.groupId?.uuidString)
    #expect(read["sort"] == "3")
    #expect(read["other_currencies"] == "USD,RUB,KZT")
  }

  @Test func placeRoundTrips() throws {
    let place = Place(id: UUID(), name: "Кафе, у дома", aliases: [], archived: true)
    let row = ExportTables.row(place)
    let read = try roundTrip(ExportTables.places, row: row)
    #expect(read["name"] == "Кафе, у дома")
    #expect(read["archived"] == "true")
  }

  @Test func eventRoundTrips() throws {
    let event = Event(
      id: UUID(), name: "Новый год", kind: .newYear,
      startDate: DateOnly(year: 2026, month: 12, day: 31),
      endDate: DateOnly(year: 2027, month: 1, day: 8),
      budgetE4: AmountE4(whole: 20_000), recurringYearly: true, seriesId: UUID(),
      archived: false)
    let row = ExportTables.row(event)
    let read = try roundTrip(ExportTables.events, row: row)
    #expect(read["kind"] == "new_year")
    #expect(read["start_date"] == "2026-12-31")
    #expect(read["end_date"] == "2027-01-08")
    #expect(read["budget"] == "20000")
    #expect(read["recurring_yearly"] == "true")
  }

  @Test func categoryRoundTrips() throws {
    let category = CoreKit.Category(
      id: UUID(), parentId: nil, kind: .expense, name: "Food out / Еда вне дома", sort: 3,
      archived: false, quality: nil, systemRole: nil)
    let row = ExportTables.row(category)
    let read = try roundTrip(ExportTables.categories, row: row)
    #expect(read["name"] == "Food out / Еда вне дома")
    #expect(read["sort"] == "3")
    #expect(read["quality"] == "")
    #expect(read["system_role"] == "")
    #expect(read["essential"] == "")
  }

  /// A category marked essential or not says so; one that follows its parent leaves it empty.
  @Test func theEssentialMarkOfACategoryRoundTrips() throws {
    let yes = CoreKit.Category(kind: .expense, name: "Продукты", essential: true)
    let no = CoreKit.Category(kind: .expense, name: "Кафе", essential: false)
    #expect(
      try roundTrip(ExportTables.categories, row: ExportTables.row(yes))["essential"] == "true")
    #expect(
      try roundTrip(ExportTables.categories, row: ExportTables.row(no))["essential"] == "false")
  }

  @Test func theCushionMarkOfAnAccountRoundTrips() throws {
    let cushion = PaymentMethod(name: "Накопительный", kind: .account, cushion: true)
    #expect(
      try roundTrip(ExportTables.paymentMethods, row: ExportTables.row(cushion))["cushion"]
        == "true")
    #expect(
      try roundTrip(
        ExportTables.paymentMethods, row: ExportTables.row(PaymentMethod(name: "Карта")))[
          "cushion"] == "false")
  }

  @Test func assetRoundTrips() throws {
    let asset = Asset(
      name: "Машина, «Шкода»", kind: .vehicle, currency: .eur, note: "куплена\nв кредит",
      disposedOn: DateOnly(year: 2027, month: 3, day: 1), sort: 2)
    let read = try roundTrip(ExportTables.assets, row: ExportTables.row(asset))
    #expect(read["id"] == asset.id.uuidString)
    #expect(read["name"] == "Машина, «Шкода»")
    #expect(read["kind"] == "vehicle")
    #expect(read["currency"] == "EUR")
    #expect(read["note"] == "куплена\nв кредит")
    #expect(read["disposed_on"] == "2027-03-01")
    #expect(read["sort"] == "2")
    let kept = try roundTrip(ExportTables.assets, row: ExportTables.row(Asset(name: "Ноутбук")))
    #expect(kept["kind"] == "other")
    #expect(kept["currency"] == "RUB")
    #expect(kept["note"] == "")
    #expect(kept["disposed_on"] == "")
  }

  @Test func assetValuationRoundTrips() throws {
    let valuation = AssetValuation(
      assetId: UUID(), day: DateOnly(year: 2026, month: 10, day: 31),
      valueE4: AmountE4(raw: 12_345_678_900), note: "оценка дилера")
    let read = try roundTrip(ExportTables.assetValuations, row: ExportTables.row(valuation))
    #expect(read["id"] == valuation.id.uuidString)
    #expect(read["asset_id"] == valuation.assetId.uuidString)
    #expect(read["day"] == "2026-10-31")
    #expect(read["value"] == "1234567.89")
    #expect(read["note"] == "оценка дилера")
  }

  @Test func systemCategoryRoundTrips() throws {
    let category = CoreKit.Category(
      id: UUID(), kind: .expense, name: "Unknown / Не помню", quality: .neutral,
      systemRole: .unknown)
    let row = ExportTables.row(category)
    let read = try roundTrip(ExportTables.categories, row: row)
    #expect(read["system_role"] == "unknown")
    #expect(read["quality"] == "neutral")
  }

  @Test func templateRoundTrips() throws {
    let template = Template(
      id: UUID(), text: "такси, 300", categoryId: UUID(), amountE4: AmountE4(whole: 300),
      currency: .rub, pinned: true, useCount: 42)
    let row = ExportTables.row(template)
    let read = try roundTrip(ExportTables.templates, row: row)
    #expect(read["text"] == "такси, 300")
    #expect(read["pinned"] == "true")
    #expect(read["use_count"] == "42")
    #expect(read["archived"] == "false")

    var archived = template
    archived.archived = true
    let again = try roundTrip(ExportTables.templates, row: ExportTables.row(archived))
    #expect(again["archived"] == "true")
  }

  @Test func goalRoundTrips() throws {
    let goal = Goal(
      id: UUID(), name: "Отпуск", targetE4: AmountE4(whole: 100_000),
      targetDate: DateOnly(year: 2026, month: 12, day: 1),
      monthlyPlanE4: AmountE4(whole: 10_000), subcategoryId: UUID(), archived: false)
    let row = ExportTables.row(goal)
    let read = try roundTrip(ExportTables.goals, row: row)
    #expect(read["target"] == "100000")
    #expect(read["target_date"] == "2026-12-01")
    #expect(read["monthly_plan"] == "10000")
    #expect(read["currency"] == "RUB")

    let inDollars = Goal(name: "Trip", targetE4: AmountE4(whole: 2_000), currency: .usd)
    let again = try roundTrip(ExportTables.goals, row: ExportTables.row(inDollars))
    #expect(again["currency"] == "USD")
  }

  @Test func debtRoundTrips() throws {
    let debt = Debt(
      id: UUID(), direction: .iOwe, type: .creditCard, name: "Card, \"main\"",
      personId: nil, currency: .rub, interestRate: Decimal(string: "19.9"),
      monthlyPaymentE4: AmountE4(whole: 5_000), paymentDay: 15, remindDaysBefore: 3,
      paymentsAreExpenses: false, origin: .purchase, note: nil, closed: false,
      loansSubcategoryId: UUID())
    let row = ExportTables.row(debt)
    let read = try roundTrip(ExportTables.debts, row: row)
    #expect(read["direction"] == "i_owe")
    #expect(read["type"] == "credit_card")
    #expect(read["interest_rate"] == "19.9")
    #expect(read["payment_day"] == "15")
    #expect(read["payments_are_expenses"] == "false")
    #expect(read["origin"] == "purchase")
    #expect(read["note"] == "")
  }

  @Test func debtEntryRoundTrips() throws {
    let entry = DebtEntry(
      id: UUID(), debtId: UUID(), groupName: "Ремонт, кухня",
      date: DateOnly(year: 2026, month: 1, day: 5), description: "первый взнос",
      fullAmountE4: AmountE4(whole: 200_000), share: Decimal(string: "0.5"),
      amountE4: AmountE4(raw: -1_000_000), kind: .payment, transactionId: UUID(), note: nil)
    let row = ExportTables.row(entry)
    let read = try roundTrip(ExportTables.debtEntries, row: row)
    #expect(read["group_name"] == "Ремонт, кухня")
    #expect(read["full_amount"] == "200000")
    #expect(read["share"] == "0.5")
    #expect(read["amount"] == "-100")
    #expect(read["kind"] == "payment")
    for column in ["payment_method_id", "occurred_at", "account_currency", "account_amount"] {
      #expect(read[column] == "", "\(column) is not empty")
    }
  }

  /// «В этом месяце больше платежей не будет» comes after every column older than it, and only
  /// the tranche and the early repayment after it: an older reader still finds the others where
  /// they were.
  @Test func aPaymentThatClosesItsTermSaysSoInTheLastColumn() throws {
    #expect(
      Array(ExportTables.debtEntries.columns.suffix(3)) == ["closes_term", "tranche", "prepay"])
    let closing = DebtEntry(
      debtId: UUID(), amountE4: AmountE4(whole: -4_000), kind: .payment, closesTerm: true)
    let plain = DebtEntry(debtId: UUID(), amountE4: AmountE4(whole: 1_000), kind: .borrowed)
    #expect(
      try roundTrip(ExportTables.debtEntries, row: ExportTables.row(closing))["closes_term"]
        == "true")
    #expect(
      try roundTrip(ExportTables.debtEntries, row: ExportTables.row(plain))["closes_term"]
        == "false")
  }

  /// Money borrowed through the journal alone: the account it went into, when, and what the
  /// account moved in its own currency.
  @Test func aCashLineOfADebtJournalRoundTripsItsAccount() throws {
    let occurredAt = Self.utc.date(
      from: DateComponents(year: 2026, month: 9, day: 1, hour: 9, minute: 15, second: 0))!
    let entry = DebtEntry(
      debtId: UUID(), date: DateOnly(year: 2026, month: 9, day: 1),
      amountE4: AmountE4(whole: 1_000), kind: .borrowed, paymentMethodId: UUID(),
      occurredAt: occurredAt, accountCurrency: CurrencyCode("KZT"),
      accountAmountE4: AmountE4(whole: 520_000))
    let read = try roundTrip(ExportTables.debtEntries, row: ExportTables.row(entry))
    #expect(read["payment_method_id"] == entry.paymentMethodId?.uuidString)
    #expect(read["occurred_at"] == "2026-09-01T09:15:00Z")
    #expect(read["account_currency"] == "KZT")
    #expect(read["account_amount"] == "520000")
  }

  /// A tranche of a loan says so in the last column of the journal.
  @Test func aTrancheSaysSoInTheLastColumn() throws {
    let tranche = DebtEntry(
      debtId: UUID(), date: DateOnly(year: 2027, month: 2, day: 1),
      amountE4: AmountE4(whole: 150_000), kind: .adjustment, tranche: true)
    let read = try roundTrip(ExportTables.debtEntries, row: ExportTables.row(tranche))
    #expect(read["tranche"] == "true")
    #expect(read["closes_term"] == "false")
    let plain = DebtEntry(debtId: UUID(), amountE4: AmountE4(whole: 1_000), kind: .borrowed)
    #expect(
      try roundTrip(ExportTables.debtEntries, row: ExportTables.row(plain))["tranche"] == "false")
  }

  /// The terms of an education loan: interest day by day, the grace period, the months of the
  /// main schedule; a plain debt leaves them empty and says it charges no interest.
  @Test func theTermsOfALoanRoundTrip() throws {
    let loan = Debt(
      direction: .iOwe, type: .loan, name: "Образовательный", interestRate: 3,
      paymentDay: 5, accruesInterest: true,
      grace: DebtGrace(
        mainFrom: DateOnly(year: 2029, month: 3, day: 1), payment: .fixed(AmountE4(raw: 12_345_678))
      ),
      repayMonths: 120)
    let read = try roundTrip(ExportTables.debts, row: ExportTables.row(loan))
    #expect(read["accrues_interest"] == "true")
    #expect(read["main_from"] == "2029-03-01")
    #expect(read["grace_kind"] == "fixed")
    #expect(read["grace_payment"] == "1234.5678")
    #expect(read["repay_months"] == "120")
    var onInterest = loan
    onInterest.grace = DebtGrace(
      mainFrom: DateOnly(year: 2029, month: 3, day: 1), payment: .interest)
    let interest = try roundTrip(ExportTables.debts, row: ExportTables.row(onInterest))
    #expect(interest["grace_kind"] == "interest")
    #expect(interest["grace_payment"] == "")
    let plain = try roundTrip(
      ExportTables.debts,
      row: ExportTables.row(Debt(direction: .iOwe, type: .personal, name: "Аня")))
    #expect(plain["accrues_interest"] == "false")
    for column in ["main_from", "grace_kind", "grace_payment", "repay_months"] {
      #expect(plain[column] == "", "\(column) is not empty")
    }
  }

  /// The interest of a deposit: the rate as a decimal with a dot, the period, the day, the
  /// account it is paid to and the term; an account without interest leaves them empty.
  @Test func theInterestOfAnAccountRoundTrips() throws {
    let payout = UUID()
    let deposit = PaymentMethod(
      name: "Вклад", kind: .account,
      interest: DepositTerms(
        rate: Decimal(string: "16.5")!, period: .monthly, day: 31, payoutAccountId: payout,
        openedOn: DateOnly(year: 2026, month: 10, day: 1),
        endsOn: DateOnly(year: 2027, month: 4, day: 1)))
    let read = try roundTrip(ExportTables.paymentMethods, row: ExportTables.row(deposit))
    #expect(read["interest_rate"] == "16.5")
    #expect(read["interest_period"] == "monthly")
    #expect(read["interest_day"] == "31")
    #expect(read["interest_account_id"] == payout.uuidString)
    #expect(read["deposit_opened_on"] == "2026-10-01")
    #expect(read["deposit_ends_on"] == "2027-04-01")
    var atEnd = deposit
    atEnd.interest = DepositTerms(
      rate: 18, period: .atEnd, endsOn: DateOnly(year: 2027, month: 4, day: 1))
    #expect(
      try roundTrip(ExportTables.paymentMethods, row: ExportTables.row(atEnd))["interest_period"]
        == "end")
    let plain = try roundTrip(
      ExportTables.paymentMethods, row: ExportTables.row(PaymentMethod(name: "Карта")))
    for column in [
      "interest_rate", "interest_period", "interest_day", "interest_account_id",
      "deposit_opened_on", "deposit_ends_on",
    ] {
      #expect(plain[column] == "", "\(column) is not empty")
    }
  }

  @Test func rateRoundTripsWithoutAnIdColumn() throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let fetchedAt = utc.date(
      from: DateComponents(year: 2026, month: 9, day: 17, hour: 14, minute: 3, second: 0))!

    let rate = Rate(
      date: DateOnly(year: 2026, month: 9, day: 17), currency: .usd,
      rubPerUnit: Decimal(string: "92.3456")!, nominal: 1, source: .cbr, fetchedAt: fetchedAt)
    #expect(!ExportTables.rates.columns.contains("id"))

    let row = ExportTables.row(rate)
    let read = try roundTrip(ExportTables.rates, row: row)
    #expect(read["currency"] == "USD")
    #expect(read["rub_per_unit"] == "92.3456")
    #expect(read["nominal"] == "1")
    #expect(read["source"] == "cbr")
    #expect(read["fetched_at"] == "2026-09-17T14:03:00Z")
  }
}

// MARK: - Planning tables

extension ExportTablesRowTests {
  private static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  @Test func scheduledPaymentRoundTrips() throws {
    let payment = ScheduledPayment(
      name: "Кино, «плюс»", kind: .subscription, amountE4: AmountE4(raw: 4_999_000),
      currency: .usd, categoryId: UUID(), paymentMethodId: UUID(), forWhom: .partner,
      forPersonId: UUID(), reimbursable: true, debtorPersonId: UUID(),
      reimbursementAmountE4: AmountE4(raw: 2_500_000), reimbursementCurrency: .rub,
      freq: .yearly, interval: 2, day: 15, month: 3,
      nextDate: DateOnly(year: 2026, month: 3, day: 15),
      endDate: DateOnly(year: 2030, month: 1, day: 1),
      trialEnd: DateOnly(year: 2026, month: 2, day: 1),
      cancelURL: "https://example.com/cancel?a=1,b=\"2\"", remindDaysBefore: 3, active: false)
    let row = ExportTables.row(payment)
    let read = try roundTrip(ExportTables.scheduledPayments, row: row)

    #expect(read["id"] == payment.id.uuidString)
    #expect(read["name"] == "Кино, «плюс»")
    #expect(read["kind"] == "subscription")
    #expect(read["amount"] == "499.9")
    #expect(read["currency"] == "USD")
    #expect(read["category_id"] == payment.categoryId?.uuidString)
    #expect(read["payment_method_id"] == payment.paymentMethodId?.uuidString)
    #expect(read["for_whom"] == "partner")
    #expect(read["for_person_id"] == payment.forPersonId?.uuidString)
    #expect(read["reimbursable"] == "true")
    #expect(read["debtor_person_id"] == payment.debtorPersonId?.uuidString)
    #expect(read["reimbursement_amount"] == "250")
    #expect(read["reimbursement_currency"] == "RUB")
    #expect(read["freq"] == "yearly")
    #expect(read["interval"] == "2")
    #expect(read["day"] == "15")
    #expect(read["month"] == "3")
    #expect(read["next_date"] == "2026-03-15")
    #expect(read["end_date"] == "2030-01-01")
    #expect(read["trial_end"] == "2026-02-01")
    #expect(read["cancel_url"] == "https://example.com/cancel?a=1,b=\"2\"")
    #expect(read["remind_days_before"] == "3")
    #expect(read["active"] == "false")
  }

  @Test func aBareScheduledPaymentLeavesItsOptionalCellsEmpty() throws {
    let payment = ScheduledPayment(name: "Rent", amountE4: AmountE4(whole: 50_000))
    let read = try roundTrip(ExportTables.scheduledPayments, row: ExportTables.row(payment))
    #expect(read["kind"] == "bill")
    #expect(read["freq"] == "monthly")
    #expect(read["interval"] == "1")
    #expect(read["active"] == "true")
    for column in [
      "category_id", "reimbursement_amount", "reimbursement_currency", "day", "month",
      "next_date", "cancel_url", "remind_days_before",
    ] {
      #expect(read[column] == "", "\(column) is not empty")
    }
  }

  @Test func subscriptionPriceRoundTrips() throws {
    let price = SubscriptionPrice(
      paymentId: UUID(), date: DateOnly(year: 2026, month: 10, day: 1),
      amountE4: AmountE4(raw: 5_990_000))
    let read = try roundTrip(ExportTables.subscriptionPrices, row: ExportTables.row(price))
    #expect(read["id"] == price.id.uuidString)
    #expect(read["payment_id"] == price.paymentId.uuidString)
    #expect(read["date"] == "2026-10-01")
    #expect(read["amount"] == "599")
  }

  @Test func expectedIncomeRoundTrips() throws {
    let income = ExpectedIncome(
      name: "Проект, аванс", categoryId: UUID(), personId: UUID(), kind: .oneOff,
      totalE4: AmountE4(raw: 1_500_005_000), currency: .eur,
      dueDate: DateOnly(year: 2026, month: 11, day: 30), freq: nil, day: nil,
      partsExpected: 2, closed: true)
    let read = try roundTrip(ExportTables.expectedIncome, row: ExportTables.row(income))
    #expect(read["name"] == "Проект, аванс")
    #expect(read["category_id"] == income.categoryId?.uuidString)
    #expect(read["person_id"] == income.personId?.uuidString)
    #expect(read["kind"] == "one_off")
    #expect(read["total"] == "150000.5")
    #expect(read["currency"] == "EUR")
    #expect(read["due_date"] == "2026-11-30")
    #expect(read["freq"] == "")
    #expect(read["day"] == "")
    #expect(read["parts_expected"] == "2")
    #expect(read["closed"] == "true")

    let recurring = ExpectedIncome(
      name: "Help", kind: .recurring, totalE4: AmountE4(whole: 20_000), freq: .monthly, day: 5)
    let again = try roundTrip(ExportTables.expectedIncome, row: ExportTables.row(recurring))
    #expect(again["kind"] == "recurring")
    #expect(again["freq"] == "monthly")
    #expect(again["day"] == "5")
    #expect(again["closed"] == "false")
  }

  @Test func budgetRoundTripsWithItsStartMonthLast() throws {
    #expect(
      ExportTables.budgets.columns == [
        "id", "scope", "category_id", "for_whom", "amount", "rollover", "start_month",
      ])
    let budget = Budget(
      scope: .forWhom, forWhom: .friends, amountE4: AmountE4(raw: 150_000_000),
      rollover: true, startMonth: MonthKey(year: 2026, month: 9))
    let read = try roundTrip(ExportTables.budgets, row: ExportTables.row(budget))
    #expect(read["scope"] == "for_whom")
    #expect(read["category_id"] == "")
    #expect(read["for_whom"] == "friends")
    #expect(read["amount"] == "15000")
    #expect(read["rollover"] == "true")
    #expect(read["start_month"] == "2026-09")

    // A limit made before limits had a start month has none.
    let old = Budget(scope: .badTotal, amountE4: AmountE4(whole: 5_000))
    let again = try roundTrip(ExportTables.budgets, row: ExportTables.row(old))
    #expect(again["scope"] == "bad_total")
    #expect(again["for_whom"] == "")
    #expect(again["rollover"] == "false")
    #expect(again["start_month"] == "")
  }

  @Test func reconciliationRoundTripsWithItsInstantAndBreakdownLast() throws {
    #expect(
      ExportTables.reconciliations.columns == [
        "id", "date", "actual_total_rub", "expected_total_rub", "difference",
        "transaction_id", "reconciled_at", "breakdown", "kind", "origin",
      ])
    let reconciledAt = Self.utc.date(
      from: DateComponents(year: 2026, month: 9, day: 17, hour: 6, minute: 30, second: 5))!
    let reconciliation = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 17), reconciledAt: reconciledAt,
      actualTotalRubE4: AmountE4(raw: 1_234_567_890),
      expectedTotalRubE4: AmountE4(raw: 1_234_580_235),
      differenceE4: AmountE4(raw: -12_345), transactionId: UUID(),
      breakdown: [
        ReconciliationAmount(
          currency: .usd, amountE4: AmountE4(whole: 1_000),
          rubPerUnit: Decimal(string: "81.43")!, rubE4: AmountE4(whole: 81_430)),
        ReconciliationAmount(
          currency: .rub, amountE4: AmountE4(whole: 5_000), rubPerUnit: nil,
          rubE4: AmountE4(whole: 5_000)),
      ])
    let read = try roundTrip(ExportTables.reconciliations, row: ExportTables.row(reconciliation))
    #expect(read["date"] == "2026-09-17")
    #expect(read["actual_total_rub"] == "123456.789")
    #expect(read["expected_total_rub"] == "123458.0235")
    #expect(read["difference"] == "-1.2345")
    #expect(read["transaction_id"] == reconciliation.transactionId?.uuidString)
    #expect(read["reconciled_at"] == "2026-09-17T06:30:05Z")
    #expect(
      read["breakdown"]
        == """
        [{"amount_e4":10000000,"currency":"USD","rub_e4":814300000,"rub_per_unit":"81.43"},\
        {"amount_e4":50000000,"currency":"RUB","rub_e4":50000000,"rub_per_unit":null}]
        """)
    #expect(
      ReconciliationBreakdown.amounts(fromJSON: read["breakdown"]) == reconciliation.breakdown)
    #expect(read["kind"] == "total")
  }

  /// The starting point has nothing to compare with, and one made before a reconciliation
  /// kept its instant has none.
  @Test func theStartingPointLeavesItsOptionalCellsEmpty() throws {
    let start = Reconciliation(
      date: DateOnly(year: 2026, month: 1, day: 1), actualTotalRubE4: AmountE4(whole: 100_000))
    let read = try roundTrip(ExportTables.reconciliations, row: ExportTables.row(start))
    #expect(read["actual_total_rub"] == "100000")
    for column in [
      "expected_total_rub", "difference", "transaction_id", "reconciled_at", "breakdown",
    ] {
      #expect(read[column] == "", "\(column) is not empty")
    }
  }
}

// MARK: - Accounts

extension ExportTablesRowTests {
  @Test func anAccountGroupRoundTrips() throws {
    let group = AccountGroup(name: "Казахстан, «KZ»", inSummary: false, sort: 2, archived: true)
    let read = try roundTrip(ExportTables.accountGroups, row: ExportTables.row(group))
    #expect(read["id"] == group.id.uuidString)
    #expect(read["name"] == "Казахстан, «KZ»")
    #expect(read["in_summary"] == "false")
    #expect(read["sort"] == "2")
    #expect(read["archived"] == "true")
  }

  @Test func aTransferRoundTrips() throws {
    let occurredAt = Self.utc.date(
      from: DateComponents(year: 2026, month: 9, day: 10, hour: 12, minute: 0, second: 0))!
    let transfer = Transfer(
      occurredAt: occurredAt, fromAccountId: UUID(), fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 10_000), toAccountId: UUID(),
      toCurrency: CurrencyCode("KZT"), toAmountE4: AmountE4(raw: 562_345_678),
      note: "обмен, «наличные»", createdAt: occurredAt, updatedAt: occurredAt)
    let read = try roundTrip(ExportTables.transfers, row: ExportTables.row(transfer))
    #expect(read["id"] == transfer.id.uuidString)
    #expect(read["occurred_at"] == "2026-09-10T12:00:00Z")
    #expect(read["from_payment_method_id"] == transfer.fromAccountId.uuidString)
    #expect(read["from_currency"] == "RUB")
    #expect(read["from_amount"] == "10000")
    #expect(read["to_payment_method_id"] == transfer.toAccountId.uuidString)
    #expect(read["to_currency"] == "KZT")
    #expect(read["to_amount"] == "56234.5678")
    #expect(read["note"] == "обмен, «наличные»")
    #expect(read["created_at"] == "2026-09-10T12:00:00Z")
    #expect(read["updated_at"] == "2026-09-10T12:00:00Z")
  }

  /// The first count of an account and currency has nothing to compare with.
  @Test func aReconciledBalanceRoundTrips() throws {
    let start = ReconciledBalance(
      reconciliationId: UUID(), accountId: UUID(), currency: .usd,
      actualE4: AmountE4(raw: 12_345_000))
    let first = try roundTrip(
      ExportTables.reconciliationBalances, row: ExportTables.row(start))
    #expect(first["id"] == start.id.uuidString)
    #expect(first["reconciliation_id"] == start.reconciliationId.uuidString)
    #expect(first["payment_method_id"] == start.accountId.uuidString)
    #expect(first["currency"] == "USD")
    #expect(first["actual"] == "1234.5")
    for column in ["expected", "difference", "transaction_id"] {
      #expect(first[column] == "", "\(column) is not empty")
    }

    let later = ReconciledBalance(
      reconciliationId: UUID(), accountId: UUID(), currency: .rub,
      actualE4: AmountE4(whole: 9_650), expectedE4: AmountE4(whole: 10_000),
      differenceE4: AmountE4(whole: -350), transactionId: UUID())
    let read = try roundTrip(ExportTables.reconciliationBalances, row: ExportTables.row(later))
    #expect(read["expected"] == "10000")
    #expect(read["difference"] == "-350")
    #expect(read["transaction_id"] == later.transactionId?.uuidString)
  }

  @Test func aReconciliationOfAccountsSaysItsKind() throws {
    let sheet = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 20),
      reconciledAt: Date(timeIntervalSince1970: 1_789_900_000), actualTotalRubE4: .zero,
      kind: .accounts)
    let read = try roundTrip(ExportTables.reconciliations, row: ExportTables.row(sheet))
    #expect(read["kind"] == "accounts")
  }
}

// MARK: - Cards, cashback and the columns that came with them

extension ExportTablesRowTests {
  /// A card with other names, and its rules: a percent is a decimal string with a dot, an
  /// empty month is «always», an empty category «everything else».
  @Test func aCardAndARule() throws {
    let account = UUID()
    let card = PaymentCard(
      accountId: account, name: "Visa, «зарплатная»", aliases: ["Зарплатная", "visa 1234"],
      sort: 3, archived: true)
    let read = try roundTrip(ExportTables.cards, row: ExportTables.row(card))
    #expect(read["id"] == card.id.uuidString)
    #expect(read["payment_method_id"] == account.uuidString)
    #expect(read["name"] == "Visa, «зарплатная»")
    #expect(read["aliases"] == "Зарплатная\nvisa 1234")
    #expect(read["sort"] == "3")
    #expect(read["archived"] == "true")

    let always = CashbackRule(
      accountId: account, cardId: card.id, percent: try #require(CashbackPercent(e4: 15_000)))
    let first = try roundTrip(ExportTables.cashbackRules, row: ExportTables.row(always))
    #expect(first["id"] == always.id.uuidString)
    #expect(first["payment_method_id"] == account.uuidString)
    #expect(first["card_id"] == card.id.uuidString)
    #expect(first["category_id"] == "")
    #expect(first["month"] == "")
    #expect(first["percent"] == "1.5")

    let category = UUID()
    let september = CashbackRule(
      accountId: account, categoryId: category, month: MonthKey(year: 2026, month: 9),
      percent: try #require(CashbackPercent(e4: 333_333)))
    let second = try roundTrip(ExportTables.cashbackRules, row: ExportTables.row(september))
    #expect(second["card_id"] == "")
    #expect(second["category_id"] == category.uuidString)
    #expect(second["month"] == "2026-09")
    #expect(second["percent"] == "33.3333")
    let small = CashbackRule(accountId: account, percent: try #require(CashbackPercent(e4: 7_500)))
    #expect(
      try roundTrip(ExportTables.cashbackRules, row: ExportTables.row(small))["percent"] == "0.75")
  }

  /// The card of an operation and the cashback typed for it, in the currency that moved; an
  /// operation without them leaves the three cells empty.
  @Test func theCashbackOfAnOperation() throws {
    let card = UUID()
    let purchase = Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_789_900_000),
      amountE4: AmountE4(whole: 1_500), paymentMethodId: UUID(), cardId: card,
      cashback: Money(amount: AmountE4(whole: 45), currency: .rub))
    let read = try roundTrip(ExportTables.transactions, row: ExportTables.row(purchase))
    #expect(read["card_id"] == card.uuidString)
    #expect(read["cashback_currency"] == "RUB")
    #expect(read["cashback"] == "45")
    let plain = Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_789_900_000),
      amountE4: AmountE4(whole: 10))
    let empty = try roundTrip(ExportTables.transactions, row: ExportTables.row(plain))
    for column in ["card_id", "cashback_currency", "cashback"] {
      #expect(empty[column] == "", "\(column) is not empty")
    }
  }

  /// A later count that records says `true`, one that keeps says `false`, a starting point
  /// says nothing.
  @Test func recordsDifferenceIsTrueFalseOrEmpty() throws {
    func cell(_ mode: Bool?) throws -> String? {
      let count = ReconciledBalance(
        reconciliationId: UUID(), accountId: UUID(), currency: .rub,
        actualE4: AmountE4(whole: 100), expectedE4: mode == nil ? nil : AmountE4(whole: 90),
        differenceE4: mode == nil ? nil : AmountE4(whole: 10), recordsDifference: mode)
      return try roundTrip(ExportTables.reconciliationBalances, row: ExportTables.row(count))[
        "records_difference"]
    }
    #expect(try cell(true) == "true")
    #expect(try cell(false) == "false")
    #expect(try cell(nil) == "")
    #expect(CSVValue.string(bool: Bool?.none) == "")
    #expect(CSVValue.string(bool: Bool?.some(true)) == "true")
  }

  /// Where starting balances came from is the raw value of the origin; a count of a sheet has
  /// none.
  @Test func originIsItsRawValue() throws {
    for origin in ReconciliationOrigin.allCases {
      let opening = Reconciliation(
        date: DateOnly(year: 2026, month: 9, day: 20),
        reconciledAt: Date(timeIntervalSince1970: 1_789_900_000), actualTotalRubE4: .zero,
        kind: .opening, origin: origin)
      let read = try roundTrip(ExportTables.reconciliations, row: ExportTables.row(opening))
      #expect(read["origin"] == origin.rawValue)
    }
    #expect(ReconciliationOrigin.allCases.map(\.rawValue) == ["setup", "account", "merge"])
    let sheet = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 20), actualTotalRubE4: .zero, kind: .accounts)
    #expect(
      try roundTrip(ExportTables.reconciliations, row: ExportTables.row(sheet))["origin"] == "")
  }

  /// A deleted debt says when, as every instant of the export; the event of a payment, the
  /// card, the month a plan starts and the account an income is expected on are ids and months.
  @Test func deletedAtIsAnInstant() throws {
    let deleted = Debt(
      direction: .iOwe, type: .personal, name: "Друг", currency: .rub,
      deletedAt: Self.utc.date(
        from: DateComponents(year: 2026, month: 9, day: 27, hour: 14, minute: 3, second: 0)))
    let read = try roundTrip(ExportTables.debts, row: ExportTables.row(deleted))
    #expect(read["deleted_at"] == "2026-09-27T14:03:00Z")
    let live = Debt(direction: .iOwe, type: .personal, name: "Друг", currency: .rub)
    #expect(try roundTrip(ExportTables.debts, row: ExportTables.row(live))["deleted_at"] == "")

    let goal = Goal(
      name: "Car", targetE4: AmountE4(whole: 100_000), monthlyPlanE4: AmountE4(whole: 10_000),
      planStartMonth: MonthKey(year: 2026, month: 9))
    #expect(
      try roundTrip(ExportTables.goals, row: ExportTables.row(goal))["plan_start_month"]
        == "2026-09")
    let card = UUID()
    let event = UUID()
    let payment = ScheduledPayment(
      name: "Rent", kind: .bill, amountE4: AmountE4(whole: 50_000), currency: .rub,
      freq: .monthly, cardId: card, eventId: event)
    let paid = try roundTrip(ExportTables.scheduledPayments, row: ExportTables.row(payment))
    #expect(paid["card_id"] == card.uuidString)
    #expect(paid["event_id"] == event.uuidString)
    let account = UUID()
    let income = ExpectedIncome(
      name: "Salary", totalE4: AmountE4(whole: 100_000), currency: .rub,
      paymentMethodId: account)
    #expect(
      try roundTrip(ExportTables.expectedIncome, row: ExportTables.row(income))[
        "payment_method_id"] == account.uuidString)
  }
}

@Suite("A reconciliation's breakdown is one JSON text")
struct ReconciliationBreakdownTests {
  @Test func noBreakdownIsNoText() {
    #expect(ReconciliationBreakdown.json([]) == nil)
    #expect(ReconciliationBreakdown.amounts(fromJSON: nil).isEmpty)
    #expect(ReconciliationBreakdown.amounts(fromJSON: "").isEmpty)
  }

  /// Keys sorted, amounts in stored units, the rate a string with a dot: one breakdown, one
  /// text, whatever the machine's language.
  @Test func theTextIsFixed() {
    let amounts = [
      ReconciliationAmount(
        currency: CurrencyCode("thb"), amountE4: AmountE4(raw: 12_345),
        rubPerUnit: Decimal(string: "2.456789")!, rubE4: AmountE4(raw: 3_033))
    ]
    #expect(
      ReconciliationBreakdown.json(amounts)
        == #"[{"amount_e4":12345,"currency":"THB","rub_e4":3033,"rub_per_unit":"2.456789"}]"#)
  }

  @Test func aTextThatIsNotABreakdownReadsAsNone() {
    #expect(ReconciliationBreakdown.amounts(fromJSON: "not json").isEmpty)
    #expect(ReconciliationBreakdown.amounts(fromJSON: #"{"currency":"USD"}"#).isEmpty)
    #expect(ReconciliationBreakdown.amounts(fromJSON: #"[{"currency":"USD"}]"#).isEmpty)
  }

  /// A line written without the rate — by hand, or by another implementation that leaves
  /// `null` out — reads as rubles-style: no rate.
  @Test func aMissingRateReadsAsNoRate() {
    let read = ReconciliationBreakdown.amounts(
      fromJSON: #"[{"amount_e4":10000,"currency":"RUB","rub_e4":10000}]"#)
    #expect(
      read == [
        ReconciliationAmount(
          currency: .rub, amountE4: AmountE4(raw: 10_000), rubPerUnit: nil,
          rubE4: AmountE4(raw: 10_000))
      ])
  }

  @Test func largeAmountsAndLongRatesSurviveExactly() {
    let amounts = [
      ReconciliationAmount(
        currency: .eur, amountE4: AmountE4(raw: 9_007_199_254_740_993),
        rubPerUnit: Decimal(string: "93.123456789012345678")!,
        rubE4: AmountE4(raw: -9_007_199_254_740_993))
    ]
    let text = ReconciliationBreakdown.json(amounts)
    #expect(text?.contains("9007199254740993") == true)
    #expect(ReconciliationBreakdown.amounts(fromJSON: text) == amounts)
  }
}

/// Every custom currency goes out to `custom_currencies.csv` and comes back from it as it was:
/// the code, the name, the symbol or none, the digits, the archive and the order.
@Suite("custom_currencies.csv there and back")
struct CustomCurrenciesCSVTests {
  static func back(_ row: [String: String]) -> CustomCurrency? {
    guard let code = row["code"], let name = row["name"],
      let digits = row["fraction_digits"].flatMap(Int.init),
      let sort = row["sort"].flatMap(Int.init)
    else { return nil }
    let symbol = row["symbol"].flatMap { $0.isEmpty ? nil : $0 }
    return CustomCurrency(
      code: CurrencyCode(code), name: name, symbol: symbol, fractionDigits: digits,
      archived: row["archived"] == "true", sort: sort)
  }

  @Test func theRowsComeBackAsTheyWent() throws {
    let currencies = [
      CustomCurrency(
        code: CurrencyCode("UST"), name: "Tether, \"USDT\"", symbol: "₮", fractionDigits: 4),
      CustomCurrency(
        code: CurrencyCode("PTS"), name: "баллы", fractionDigits: 0, archived: true, sort: 1),
    ]
    var writer = CSVWriter(columns: ExportTables.customCurrencies.columns)
    for currency in currencies { writer.append(ExportTables.row(currency)) }
    let rows = try CSVReader.dictionaries(from: writer.data())
    #expect(rows.map(CustomCurrenciesCSVTests.back) == currencies)
    #expect(rows.first?["archived"] == "false")
    #expect(rows.last?["symbol"] == "")
  }
}
