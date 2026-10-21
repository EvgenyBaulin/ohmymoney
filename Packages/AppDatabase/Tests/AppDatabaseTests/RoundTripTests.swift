import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Field-by-field round trips. Every model is written with a distinguishable value in
/// every single field, read back and compared column by column: a field that silently
/// fails to reach SQLite is money lost.
@Suite("Every field of every model survives SQLite")
struct RoundTripTests {

  // MARK: Operations

  @Test func transactionKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let repository = TransactionRepository(writer: stack.writer)

    let original = CoreKit.Transaction(
      kind: .refund,
      occurredAt: Date(timeIntervalSince1970: 1_700_000_001),
      currency: CurrencyCode("USD"),
      amountE4: AmountE4(raw: 1_234_567),
      amountExpr: "(1000+600)/2",
      rate: Decimal(string: "81.4321")!,
      rateDate: DateOnly(year: 2026, month: 9, day: 18),
      rateSource: .cbrMirror,
      rateProvisional: true,
      amountRubE4: AmountE4(raw: 98_765_432),
      note: "чек «кофе» 100%",
      placeId: fixture.place.id,
      paymentMethodId: fixture.paymentMethod.id,
      periodMonth: MonthKey(year: 2026, month: 8),
      debtId: fixture.debt.id,
      creditDebtId: fixture.creditDebt.id,
      importBatchId: fixture.importBatchId,
      externalId: "ext-42",
      createdAt: Date(timeIntervalSince1970: 1_700_000_002),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_003),
      deletedAt: Date(timeIntervalSince1970: 1_700_000_004))
    let part = TransactionPart(
      transactionId: original.id, amountE4: original.amountE4,
      amountRubE4: original.amountRubE4)
    try repository.save(TransactionEntry(transaction: original, parts: [part]))

    let loaded = try #require(try repository.entry(id: original.id)?.transaction)
    #expect(loaded.id == original.id)
    #expect(loaded.kind == original.kind)
    #expect(loaded.occurredAt == original.occurredAt)
    #expect(loaded.currency == original.currency)
    #expect(loaded.amountE4 == original.amountE4)
    #expect(loaded.amountExpr == original.amountExpr)
    #expect(loaded.rate == original.rate)
    #expect(loaded.rateDate == original.rateDate)
    #expect(loaded.rateSource == original.rateSource)
    #expect(loaded.rateProvisional == original.rateProvisional)
    #expect(loaded.amountRubE4 == original.amountRubE4)
    #expect(loaded.note == original.note)
    #expect(loaded.placeId == original.placeId)
    #expect(loaded.paymentMethodId == original.paymentMethodId)
    #expect(loaded.periodMonth == original.periodMonth)
    #expect(loaded.debtId == original.debtId)
    #expect(loaded.creditDebtId == original.creditDebtId)
    #expect(loaded.importBatchId == original.importBatchId)
    #expect(loaded.externalId == original.externalId)
    #expect(loaded.createdAt == original.createdAt)
    #expect(loaded.updatedAt == original.updatedAt)
    #expect(loaded.deletedAt == original.deletedAt)
    #expect(loaded == original)
  }

  @Test func transactionPartKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let repository = TransactionRepository(writer: stack.writer)

    let transaction = CoreKit.Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
      amountE4: AmountE4(raw: 7_654_321))
    let original = TransactionPart(
      transactionId: transaction.id,
      categoryId: fixture.category.id,
      categorySource: .imported,
      quality: .bad,
      qualitySource: .history,
      amountE4: AmountE4(raw: 7_654_321),
      amountRubE4: AmountE4(raw: 7_654_320),
      forWhom: .partner,
      forPersonId: fixture.person.id,
      reimbursable: true,
      debtorPersonId: fixture.person.id,
      reimbursementStatus: .writtenOff,
      eventId: fixture.event.id,
      goalId: fixture.goal.id,
      note: "half of the bill")
    try repository.save(TransactionEntry(transaction: transaction, parts: [original]))

    let loaded = try #require(try repository.entry(id: transaction.id)?.parts.first)
    #expect(loaded.id == original.id)
    #expect(loaded.transactionId == original.transactionId)
    #expect(loaded.categoryId == original.categoryId)
    #expect(loaded.categorySource == original.categorySource)
    #expect(loaded.quality == original.quality)
    #expect(loaded.qualitySource == original.qualitySource)
    #expect(loaded.amountE4 == original.amountE4)
    #expect(loaded.amountRubE4 == original.amountRubE4)
    #expect(loaded.forWhom == original.forWhom)
    #expect(loaded.forPersonId == original.forPersonId)
    #expect(loaded.reimbursable == original.reimbursable)
    #expect(loaded.debtorPersonId == original.debtorPersonId)
    #expect(loaded.reimbursementStatus == original.reimbursementStatus)
    #expect(loaded.eventId == original.eventId)
    #expect(loaded.goalId == original.goalId)
    #expect(loaded.note == original.note)
    #expect(loaded == original)
  }

  @Test func reimbursementLinkKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let entry = try TestSupport.makeEntry()
    try repository.save(entry)

    let original = ReimbursementLink(
      reimbursementTxId: entry.id, partId: entry.parts[0].id,
      amountE4: AmountE4(raw: 12_345))
    try stack.writer.write { db in try original.insert(db) }

    let loaded = try #require(
      try stack.writer.read { db in
        try ReimbursementLink.fetchOne(db, key: original.id.uuidString)
      })
    #expect(loaded.id == original.id)
    #expect(loaded.reimbursementTxId == original.reimbursementTxId)
    #expect(loaded.partId == original.partId)
    #expect(loaded.amountE4 == original.amountE4)
  }

  // MARK: Dictionaries

  @Test func categoryKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let parent = CoreKit.Category(kind: .income, name: "Salary")
    try references.save(parent)

    let original = CoreKit.Category(
      parentId: parent.id, kind: .income, name: "Bonus", sort: 7, archived: true,
      quality: .good, systemRole: .surcharges)
    try references.save(original)

    let loaded = try #require(
      try references.categories(includeArchived: true).first { $0.id == original.id })
    #expect(loaded.id == original.id)
    #expect(loaded.parentId == original.parentId)
    #expect(loaded.kind == original.kind)
    #expect(loaded.name == original.name)
    #expect(loaded.sort == original.sort)
    #expect(loaded.archived == original.archived)
    #expect(loaded.quality == original.quality)
    #expect(loaded.systemRole == original.systemRole)
  }

  @Test func personKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let original = Person(
      name: "Мария", relation: .partner, aliases: ["Маша", "Masha"], archived: true)
    try references.save(original)

    let loaded = try #require(try references.people(includeArchived: true).first)
    #expect(loaded.id == original.id)
    #expect(loaded.name == original.name)
    #expect(loaded.relation == original.relation)
    #expect(loaded.aliases == original.aliases)
    #expect(loaded.archived == original.archived)
  }

  @Test func placeKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let original = Place(name: "Пятёрочка", aliases: ["5ka", "пятёра"], archived: true)
    try references.save(original)

    let loaded = try #require(try references.places(includeArchived: true).first)
    #expect(loaded.id == original.id)
    #expect(loaded.name == original.name)
    #expect(loaded.aliases == original.aliases)
    #expect(loaded.archived == original.archived)
  }

  @Test func paymentMethodKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let original = PaymentMethod(
      name: "Cash USD", kind: .cash, currency: CurrencyCode("USD"),
      aliases: ["нал", "cash"], isDefault: true, archived: true)
    try references.save(original)

    let loaded = try #require(try references.paymentMethods(includeArchived: true).first)
    #expect(loaded.id == original.id)
    #expect(loaded.name == original.name)
    #expect(loaded.kind == original.kind)
    #expect(loaded.currency == original.currency)
    #expect(loaded.aliases == original.aliases)
    #expect(loaded.isDefault == original.isDefault)
    #expect(loaded.archived == original.archived)
  }

  @Test func eventKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let original = Event(
      name: "Новый год", kind: .newYear,
      startDate: DateOnly(year: 2026, month: 12, day: 25),
      endDate: DateOnly(year: 2027, month: 1, day: 8),
      budgetE4: AmountE4(raw: 500_000), recurringYearly: true, seriesId: UUID(),
      archived: true)
    try references.save(original)

    let loaded = try #require(try references.events(includeArchived: true).first)
    #expect(loaded.id == original.id)
    #expect(loaded.name == original.name)
    #expect(loaded.kind == original.kind)
    #expect(loaded.startDate == original.startDate)
    #expect(loaded.endDate == original.endDate)
    #expect(loaded.budgetE4 == original.budgetE4)
    #expect(loaded.recurringYearly == original.recurringYearly)
    #expect(loaded.seriesId == original.seriesId)
    #expect(loaded.archived == original.archived)
  }

  @Test func templateKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let category = CoreKit.Category(kind: .expense, name: "Coffee")
    try references.save(category)

    let original = Template(
      text: "кофе 250", categoryId: category.id, amountE4: AmountE4(raw: 2_500_000),
      currency: CurrencyCode("EUR"), pinned: true, useCount: 17)
    try references.save(original)

    let loaded = try #require(try references.templates().first)
    #expect(loaded.id == original.id)
    #expect(loaded.text == original.text)
    #expect(loaded.categoryId == original.categoryId)
    #expect(loaded.amountE4 == original.amountE4)
    #expect(loaded.currency == original.currency)
    #expect(loaded.pinned == original.pinned)
    #expect(loaded.useCount == original.useCount)
  }

  @Test func goalKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let category = CoreKit.Category(kind: .expense, name: "Goals")
    try references.save(category)

    let original = Goal(
      name: "Велосипед", targetE4: AmountE4(raw: 1_000_000_000),
      targetDate: DateOnly(year: 2027, month: 5, day: 1),
      monthlyPlanE4: AmountE4(raw: 50_000_000), subcategoryId: category.id, archived: true)
    try references.save(original)

    let loaded = try #require(try references.goals(includeArchived: true).first)
    #expect(loaded.id == original.id)
    #expect(loaded.name == original.name)
    #expect(loaded.targetE4 == original.targetE4)
    #expect(loaded.targetDate == original.targetDate)
    #expect(loaded.monthlyPlanE4 == original.monthlyPlanE4)
    #expect(loaded.subcategoryId == original.subcategoryId)
    #expect(loaded.archived == original.archived)
  }

  @Test func debtKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let person = Person(name: "Ivan")
    let category = CoreKit.Category(kind: .expense, name: "Loans")
    try references.save(person)
    try references.save(category)

    let original = Debt(
      direction: .owedToMe, type: .creditCard, name: "Карта", personId: person.id,
      currency: CurrencyCode("KZT"), interestRate: Decimal(string: "12.75")!,
      monthlyPaymentE4: AmountE4(raw: 123_450_000), paymentDay: 25, remindDaysBefore: 3,
      paymentsAreExpenses: false, origin: .purchase, note: "заметка", closed: true,
      loansSubcategoryId: category.id)
    try references.save(original)

    let loaded = try #require(try references.debts(includeClosed: true).first)
    #expect(loaded.id == original.id)
    #expect(loaded.direction == original.direction)
    #expect(loaded.type == original.type)
    #expect(loaded.name == original.name)
    #expect(loaded.personId == original.personId)
    #expect(loaded.currency == original.currency)
    #expect(loaded.interestRate == original.interestRate)
    #expect(loaded.monthlyPaymentE4 == original.monthlyPaymentE4)
    #expect(loaded.paymentDay == original.paymentDay)
    #expect(loaded.remindDaysBefore == original.remindDaysBefore)
    #expect(loaded.paymentsAreExpenses == original.paymentsAreExpenses)
    #expect(loaded.origin == original.origin)
    #expect(loaded.note == original.note)
    #expect(loaded.closed == original.closed)
    #expect(loaded.loansSubcategoryId == original.loansSubcategoryId)
  }

  @Test func debtEntryKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    let debt = Debt(direction: .iOwe, type: .personal, name: "Другу")
    try references.save(debt)
    let entry = try TestSupport.makeEntry()
    try transactions.save(entry)

    let original = DebtEntry(
      debtId: debt.id, groupName: "Квартира", date: DateOnly(year: 2026, month: 3, day: 4),
      description: "первый взнос", fullAmountE4: AmountE4(raw: 10_000_000_000),
      share: Decimal(string: "0.5")!, amountE4: AmountE4(raw: -5_000_000_000),
      kind: .transferOut, transactionId: entry.id, note: "заметка")
    try references.save(original)

    let loaded = try #require(try references.debtEntries(debtId: debt.id).first)
    #expect(loaded.id == original.id)
    #expect(loaded.debtId == original.debtId)
    #expect(loaded.groupName == original.groupName)
    #expect(loaded.date == original.date)
    #expect(loaded.description == original.description)
    #expect(loaded.fullAmountE4 == original.fullAmountE4)
    #expect(loaded.share == original.share)
    #expect(loaded.amountE4 == original.amountE4)
    #expect(loaded.kind == original.kind)
    #expect(loaded.transactionId == original.transactionId)
    #expect(loaded.note == original.note)
  }

  @Test func rateKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let rates = RateRepository(writer: stack.writer)
    let original = Rate(
      date: DateOnly(year: 2026, month: 9, day: 18), currency: CurrencyCode("AMD"),
      rubPerUnit: Decimal(string: "0.2071")!, nominal: 100, source: .imported,
      fetchedAt: Date(timeIntervalSince1970: 1_700_000_005))
    try rates.save([original])

    let loaded = try #require(try rates.allRates().first)
    #expect(loaded.date == original.date)
    #expect(loaded.currency == original.currency)
    #expect(loaded.rubPerUnit == original.rubPerUnit)
    #expect(loaded.nominal == original.nominal)
    #expect(loaded.source == original.source)
    #expect(loaded.fetchedAt == original.fetchedAt)
  }

  // MARK: Storage format

  @Test func identifiersAreTextAndMoneyIsInteger() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(
      amount: AmountE4(whole: 100), rate: Decimal(string: "81.4321")!,
      rateDate: DateOnly(year: 2026, month: 9, day: 18), placeId: fixture.place.id)
    draft.normalizeSinglePart()
    draft.parts[0].eventId = fixture.event.id
    draft.periodMonth = MonthKey(year: 2026, month: 9)
    let entry = try draft.materialize()
    try repository.save(entry)

    let types = try stack.writer.read { db in
      try Row.fetchOne(
        db,
        sql: """
          SELECT typeof(id) AS id, typeof(place_id) AS place, typeof(amount_e4) AS amount,
            typeof(amount_rub_e4) AS rub, typeof(rate) AS rate, typeof(rate_date) AS day,
            typeof(period_month) AS month, typeof(occurred_at) AS instant,
            typeof(rate_provisional) AS flag, rate AS rateText, rate_date AS dayText,
            period_month AS monthText, id AS idText
          FROM transactions
          """)
    }
    let row = try #require(types)
    #expect(row["id"] as String? == "text")
    #expect(row["place"] as String? == "text")
    #expect(row["amount"] as String? == "integer")
    #expect(row["rub"] as String? == "integer")
    #expect(row["rate"] as String? == "text")
    #expect(row["day"] as String? == "text")
    #expect(row["month"] as String? == "text")
    #expect(row["instant"] as String? == "text")
    #expect(row["flag"] as String? == "integer")
    #expect(row["rateText"] as String? == "81.4321")
    #expect(row["dayText"] as String? == "2026-09-18")
    #expect(row["monthText"] as String? == "2026-09")
    #expect(row["idText"] as String? == entry.id.uuidString)

    let partTypes = try #require(
      try stack.writer.read { db in
        try Row.fetchOne(
          db,
          sql: """
            SELECT typeof(id) AS id, typeof(transaction_id) AS tx, typeof(event_id) AS event,
              typeof(amount_e4) AS amount, typeof(reimbursable) AS flag
            FROM transaction_parts
            """)
      })
    #expect(partTypes["id"] as String? == "text")
    #expect(partTypes["tx"] as String? == "text")
    #expect(partTypes["event"] as String? == "text")
    #expect(partTypes["amount"] as String? == "integer")
    #expect(partTypes["flag"] as String? == "integer")
  }

  @Test func instantsAreStoredInUTC() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    // 2026-09-18 12:34:56 UTC.
    let instant = Date(timeIntervalSince1970: 1_789_734_896)
    let entry = try TestSupport.makeEntry(occurredAt: instant)
    try repository.save(entry)

    let text = try stack.writer.read { db in
      try String.fetchOne(db, sql: "SELECT occurred_at FROM transactions")
    }
    #expect(text == "2026-09-18 12:34:56.000")
  }

  @Test func decimalsSurviveExactly() throws {
    let stack = try TestSupport.makeStack()
    let rates = RateRepository(writer: stack.writer)
    let samples = [
      "0.1", "1.005", "81.4321", "0.00001", "-12.345",
      "1234567890.123456789012345678",
      "0.12345678901234567890123456789012345678",
    ]
    let written = samples.enumerated().map { index, text in
      Rate(
        date: DateOnly(year: 2026, month: 1, day: index + 1), currency: CurrencyCode("USD"),
        rubPerUnit: Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!)
    }
    try rates.save(written)

    let loaded = try rates.rates(for: CurrencyCode("USD"))
    #expect(loaded.count == samples.count)
    for rate in written {
      let back = try #require(loaded.first { $0.date == rate.date })
      #expect(back.rubPerUnit == rate.rubPerUnit)
    }

    let stored = try stack.writer.read { db in
      try String.fetchAll(db, sql: "SELECT rub_per_unit FROM rates ORDER BY date")
    }
    #expect(stored == samples)
  }

  /// Money is an `Int64` of 1/10000 units, and SQLite stores the whole range of one.
  @Test func theWholeRangeOfAnAmountSurvives() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let debt = Debt(direction: .iOwe, type: .personal, name: "Extremes")
    try references.save(debt)
    let raws: [Int64] = [Int64.min + 1, -1, 0, 1, Int64.max]
    for raw in raws {
      try references.save(
        DebtEntry(debtId: debt.id, amountE4: AmountE4(raw: raw), kind: .adjustment))
    }

    let loaded = try references.debtEntries(debtId: debt.id)
    #expect(Set(loaded.map(\.amountE4.raw)) == Set(raws))
  }

  @Test func optionalTextReadsBackAsNilAndNotAsAnEmptyString() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let references = ReferenceRepository(writer: stack.writer)
    let entry = try TestSupport.makeEntry(note: nil)
    try repository.save(entry)

    let loaded = try #require(try repository.entry(id: entry.id))
    #expect(loaded.transaction.note == nil)
    #expect(loaded.transaction.amountExpr == nil)
    #expect(loaded.transaction.externalId == nil)
    #expect(loaded.transaction.rate == nil)
    #expect(loaded.transaction.rateDate == nil)
    #expect(loaded.transaction.rateSource == nil)
    #expect(loaded.transaction.periodMonth == nil)
    #expect(loaded.transaction.deletedAt == nil)
    #expect(loaded.parts[0].note == nil)
    #expect(loaded.parts[0].quality == nil)
    #expect(loaded.parts[0].qualitySource == nil)
    #expect(loaded.parts[0].reimbursementStatus == nil)

    let nulls = try stack.writer.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM transactions
          WHERE note IS NULL AND amount_expr IS NULL AND rate IS NULL AND deleted_at IS NULL
          """)
    }
    #expect(nulls == 1)

    let debt = Debt(direction: .iOwe, type: .personal, name: "Bare")
    try references.save(debt)
    let bare = try #require(try references.debts().first)
    #expect(bare.note == nil)
    #expect(bare.interestRate == nil)
    #expect(bare.monthlyPaymentE4 == nil)
    #expect(bare.paymentDay == nil)
    #expect(bare.remindDaysBefore == nil)
    #expect(bare.personId == nil)
    #expect(bare.loansSubcategoryId == nil)

    let method = PaymentMethod(name: "No currency")
    try references.save(method)
    #expect(try references.paymentMethods().first?.currency == nil)
  }

  // MARK: Alias lists

  @Test func aliasListsSurviveTheirEdgeCases() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)

    let empty = Person(name: "No aliases", aliases: [])
    let single = Person(name: "One", aliases: ["один"])
    let spaced = Person(name: "Spaces", aliases: ["две строки", "  ведущие пробелы"])
    try references.save(empty)
    try references.save(single)
    try references.save(spaced)

    let people = try references.people()
    #expect(people.first { $0.id == empty.id }?.aliases == [])
    #expect(people.first { $0.id == single.id }?.aliases == ["один"])
    #expect(
      people.first { $0.id == spaced.id }?.aliases == ["две строки", "  ведущие пробелы"])
  }

  /// A newline inside an alias would silently become two aliases, because the column is
  /// newline separated. The write side has to normalise instead of corrupting.
  @Test func anAliasWithANewlineInsideDoesNotBecomeTwoAliases() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let person = Person(name: "Broken", aliases: ["первая\nвторая", "третья"])
    try references.save(person)

    let loaded = try #require(try references.people().first)
    #expect(loaded.aliases.count == 2)
    #expect(loaded.aliases == ["первая вторая", "третья"])
  }
}

// MARK: - Accounts

extension RoundTripTests {
  @Test func anAccountKeepsItsGroupItsPlaceAndItsCurrencies() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let group = AccountGroup(name: "Казахстан", inSummary: false, sort: 2, archived: true)
    try stack.writer.write { db in try group.insert(db) }
    let original = PaymentMethod(
      name: "Freedom", kind: .account, currency: .eur, aliases: ["фридом"], isDefault: true,
      archived: false, groupId: group.id, sort: 7,
      otherCurrencies: [.usd, .rub, CurrencyCode("KZT")])
    try references.save(original)

    let loaded = try #require(try references.paymentMethods().first)
    #expect(loaded == original)
    #expect(loaded.groupId == group.id)
    #expect(loaded.sort == 7)
    #expect(loaded.otherCurrencies == [.usd, .rub, CurrencyCode("KZT")])
    let row = try stack.writer.read { db in
      try #require(try Row.fetchOne(db, sql: "SELECT * FROM payment_methods"))
    }
    #expect(row["other_currencies"] as String? == "USD,RUB,KZT")
    #expect(row["group_id"] as String? == group.id.uuidString)
    #expect(row["sort"] as Int64? == 7)

    let groups = try stack.writer.read { db in try AccountGroup.fetchAll(db) }
    #expect(groups == [group])
  }

  /// An older build could leave a card with no currency, an empty one or spaces: all of them
  /// read as none — which counts as rubles — and the stored text stays as it was.
  @Test func aBlankCurrencyReadsAsNone() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO payment_methods (id, name, currency, other_currencies)
          VALUES ('00000000-0000-0000-0000-000000000001', 'Null', NULL, ''),
                 ('00000000-0000-0000-0000-000000000002', 'Empty', '', ','),
                 ('00000000-0000-0000-0000-000000000003', 'Spaces', '  ', 'USD,,KZT'),
                 ('00000000-0000-0000-0000-000000000004', 'Lower', 'usd', '')
          """)
    }
    let methods = try ReferenceRepository(writer: stack.writer).paymentMethods()
      .sorted { $0.name < $1.name }
    #expect(methods.map(\.name) == ["Empty", "Lower", "Null", "Spaces"])
    #expect(methods.map(\.currency) == [nil, .usd, nil, nil])
    #expect(methods.map(\.mainCurrency) == [.rub, .usd, .rub, .rub])
    #expect(methods.map(\.otherCurrencies) == [[], [], [], [.usd, CurrencyCode("KZT")]])
    let stored = try stack.writer.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT currency FROM payment_methods WHERE currency IS NOT NULL ORDER BY name")
    }
    #expect(stored == ["", "usd", "  "])
  }

  @Test func anOperationKeepsItsLegAndARefundThePartItTakesBackFrom() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let repository = TransactionRepository(writer: stack.writer)
    // No account and no main one yet: the purchase is saved with no charge apart.
    var draft = TransactionDraft(currency: .usd, amount: AmountE4(whole: 20), rate: 90)
    draft.normalizeSinglePart()
    let purchase = try draft.materialize(rublesConverter: { AmountE4(raw: $0.raw * 90) })
    try repository.save(purchase)

    let refundTransaction = CoreKit.Transaction(
      kind: .refund, occurredAt: Date(timeIntervalSince1970: 1_700_100_000), currency: .usd,
      amountE4: AmountE4(whole: 5), rate: 90, amountRubE4: AmountE4(whole: 450),
      paymentMethodId: fixture.paymentMethod.id, accountCurrency: .rub,
      accountAmountE4: AmountE4(raw: 4_612_345), createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 2))
    let refund = TransactionEntry(
      transaction: refundTransaction,
      parts: [
        TransactionPart(
          transactionId: refundTransaction.id, amountE4: AmountE4(whole: 5),
          amountRubE4: AmountE4(whole: 450), refundOfPartId: purchase.parts[0].id)
      ])
    try repository.save(refund)

    let loaded = try #require(try repository.entry(id: refund.id))
    #expect(loaded == refund)
    #expect(loaded.transaction.accountCurrency == .rub)
    #expect(loaded.transaction.accountAmountE4 == AmountE4(raw: 4_612_345))
    #expect(loaded.parts[0].refundOfPartId == purchase.parts[0].id)
    let row = try stack.writer.read { db in
      try #require(
        try Row.fetchOne(
          db, sql: "SELECT account_currency, account_amount_e4 FROM transactions WHERE id = ?",
          arguments: [refund.id.uuidString]))
    }
    #expect(row["account_currency"] as String? == "RUB")
    #expect(row["account_amount_e4"] as Int64? == 4_612_345)
    #expect(try repository.entry(id: purchase.id)?.transaction.accountCurrency == nil)
  }

  @Test func aTemplateKeepsItsArchiveAndAGoalItsCurrency() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let template = Template(text: "такси 300", archived: true)
    let goal = Goal(name: "Trip", targetE4: AmountE4(whole: 2_000), currency: .usd)
    try references.save(template)
    try references.save(goal)
    #expect(try references.templates() == [template])
    #expect(try references.goals() == [goal])
    let rubles = Goal(name: "Bike", targetE4: AmountE4(whole: 1))
    try references.save(rubles)
    #expect(try references.goals().first { $0.id == rubles.id }?.currency == .rub)
  }

  @Test func aJournalLineKeepsItsAccountItsMomentAndItsLeg() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let references = ReferenceRepository(writer: stack.writer)
    let original = DebtEntry(
      debtId: fixture.debt.id, date: DateOnly(year: 2026, month: 9, day: 1),
      amountE4: AmountE4(whole: 1_000), kind: .borrowed,
      paymentMethodId: fixture.paymentMethod.id,
      occurredAt: Date(timeIntervalSince1970: 1_788_246_900), accountCurrency: .usd,
      accountAmountE4: AmountE4(raw: 110_000))
    try references.save(original)
    #expect(try references.debtEntries(debtId: fixture.debt.id) == [original])
    let row = try stack.writer.read { db in
      try #require(try Row.fetchOne(db, sql: "SELECT * FROM debt_entries"))
    }
    #expect(row["occurred_at"] as String? == "2026-09-01 07:15:00.000")
    #expect(row["account_amount_e4"] as Int64? == 110_000)
  }

  @Test func aTransferAndACountedBalanceKeepEveryField() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    try ReferenceRepository(writer: stack.writer).save(cash)
    let entry = try TestSupport.makeEntry()
    try TransactionRepository(writer: stack.writer).save(entry)

    let transfer = Transfer(
      occurredAt: Date(timeIntervalSince1970: 1_788_000_000),
      fromAccountId: fixture.paymentMethod.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(raw: 50_000_000), toAccountId: cash.id,
      toCurrency: .usd, toAmountE4: AmountE4(raw: 5_555_555), note: "обмен",
      createdAt: Date(timeIntervalSince1970: 1_788_000_001),
      updatedAt: Date(timeIntervalSince1970: 1_788_000_002))
    let reconciliation = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 1),
      reconciledAt: Date(timeIntervalSince1970: 1_788_000_003), actualTotalRubE4: .zero,
      kind: .accounts)
    let balance = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: cash.id, currency: .rub,
      actualE4: AmountE4(whole: 9_650), expectedE4: AmountE4(whole: 10_000),
      differenceE4: AmountE4(whole: -350), transactionId: entry.id)
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(
          reconciliations: [reconciliation], transfers: [transfer],
          reconciledBalances: [balance])))

    try stack.writer.read { db in
      #expect(try Transfer.fetchAll(db) == [transfer])
      #expect(try ReconciledBalance.fetchAll(db) == [balance])
      #expect(try Reconciliation.fetchAll(db) == [reconciliation])
      let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM transfers"))
      #expect(row["from_payment_method_id"] as String? == fixture.paymentMethod.id.uuidString)
      #expect(row["to_amount_e4"] as Int64? == 5_555_555)
      #expect(row["occurred_at"] as String? == "2026-08-29 10:40:00.000")
      let kind = try String.fetchOne(db, sql: "SELECT kind FROM reconciliations")
      #expect(kind == "accounts")
    }
  }
}
