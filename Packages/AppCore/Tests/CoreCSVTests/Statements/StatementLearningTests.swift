import CoreKit
import Foundation
import Testing

@testable import CoreCSV

/// A statement learns from what the owner typed by hand: the line that merged with his coffee
/// teaches the pair, the next line of the same text of the same account is filled by it. Every
/// file is synthetic (`StatementFixtures`).
@Suite("A statement learns from the operations typed by hand")
struct StatementLearningTests {
  private let card = UUID()
  private let bank = UUID()
  private let cafe = UUID()
  private let place = UUID()
  private let partner = UUID()
  private let today = DateOnly(year: 2026, month: 9, day: 30)

  private var scope: BankTextMemory.Scope {
    BankTextMemory.Scope(accountId: card, bankId: bank)
  }

  private var categories: [CoreKit.Category] {
    [CoreKit.Category(id: cafe, kind: .expense, name: "Кафе")]
  }

  /// A coffee the owner typed by hand on the card: his place, words, category and «for whom».
  private func handTyped(
    id: UUID = UUID(), _ whole: Int64, day: Int, month: Int = 9, note: String = "Кофе с Машей",
    forWhom: ForWhom = .partner
  ) -> TransactionEntry {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
    let at = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))!
    let transaction = Transaction(
      id: id, kind: .expense, occurredAt: at, currency: .rub, amountE4: AmountE4(whole: whole),
      amountRubE4: AmountE4(whole: whole), note: note, placeId: place, paymentMethodId: card,
      createdAt: at, updatedAt: at)
    let part = TransactionPart(
      transactionId: id, categoryId: cafe, amountE4: AmountE4(whole: whole), forWhom: forWhom)
    return TransactionEntry(transaction: transaction, parts: [part])
  }

  private func manual(_ entry: TransactionEntry, day: Int, month: Int = 9) -> StatementManualEntry {
    StatementManualEntry(
      id: entry.id.uuidString, day: DateOnly(year: 2026, month: month, day: day),
      amount: AmountE4(whole: -(entry.transaction.amountE4.raw / 10_000)))
  }

  private func preview(
    _ parse: StatementParseResult, manual: [StatementManualEntry]
  )
    -> StatementPreview
  {
    StatementPreviewBuilder.build(
      parse: parse, accountKey: card.uuidString, existing: [], manual: manual,
      identity: StatementIdentity(), today: today)
  }

  private func teach(
    _ memory: inout BankTextMemory, _ preview: StatementPreview, entries: [TransactionEntry]
  ) -> Bool {
    StatementLearning.teach(
      &memory, preview: preview, ticks: Set(preview.rows.map(\.index)), picks: [:], scope: scope,
      entry: { id in entries.first { $0.id.uuidString == id } })
  }

  private func parsedCSV(_ data: Data) -> StatementParseResult? {
    if case .parsed(let result) = StatementImporter.parseCSV(data) { return result }
    return nil
  }

  // MARK: Raiffeisen: a CSV that names no bank

  @Test func raiffeisenLineFilledByWhatTheMergedCoffeeTaught() throws {
    let coffee = handTyped(150, day: 14)
    let parse = try #require(parsedCSV(StatementFixtures.raiffeisenCSV()))
    // The file never names its bank: the account the owner chose is the scope.
    #expect(!StatementProfiles.raiffeisenCSV.fileNamesTheBank)
    let first = preview(parse, manual: [manual(coffee, day: 14)])
    let merged = first.rows.filter {
      if case .manualMerge = $0.disposition { true } else { false }
    }
    #expect(merged.count == 1)
    var memory = BankTextMemory()
    let taught1 = teach(&memory, first, entries: [coffee])
    #expect(taught1)

    // The twin line of the same file, and next week's line of the same text, are filled.
    let twin = try #require(
      first.rows.first {
        $0.disposition == .new && $0.operation.description.contains("SAMPLE CAFE")
      }
    )
    let fill = try #require(StatementLearning.fill(memory, line: twin.operation, scope: scope))
    #expect(fill.categoryId == cafe)
    #expect(fill.placeId == place)
    #expect(fill.note == "Кофе с Машей")
    #expect(fill.forWhom == .partner)

    let nextWeek = StatementFixtures.RaiffRow(
      moment: "21.09.2026 10:15", done: "22.09.2026", doc: "DOC0101", income: "",
      expense: "180,00", details: " SAMPLE CAFE", card: "*1111")
    let later = try #require(parsedCSV(StatementFixtures.raiffeisenCSV(rows: [nextWeek])))
    let second = preview(later, manual: [])
    #expect(second.rows.first?.disposition == .new)
    let again = try #require(second.rows.first)
    #expect(StatementLearning.fill(memory, line: again.operation, scope: scope)?.categoryId == cafe)
    // A line of another text is not filled.
    let other = try #require(first.rows.first { $0.operation.description.contains("SAMPLE SHOP") })
    #expect(StatementLearning.fill(memory, line: other.operation, scope: scope) == nil)
  }

  @Test func filledLineIsWrittenWithTheLearnedFields() throws {
    let coffee = handTyped(150, day: 14)
    var memory = BankTextMemory()
    let parse = try #require(parsedCSV(StatementFixtures.raiffeisenCSV()))
    _ = teach(&memory, preview(parse, manual: [manual(coffee, day: 14)]), entries: [coffee])
    let line = try #require(parse.operations.first { $0.description.contains("SAMPLE CAFE") })
    let fill = StatementLearning.checked(
      try #require(StatementLearning.fill(memory, line: line, scope: scope)), kind: .expense,
      categories: categories, places: [place], people: [])
    let choice = StatementLearning.choice(
      over: StatementEntryChoice(categoryID: nil), ruleSetCategory: false, ruleSetPlace: false,
      fill: fill)
    let entry = StatementEntryBuilder.entry(
      for: line, accountID: card, accountKey: card.uuidString, importID: UUID(),
      zoneID: TravelDay.moscowId,
      rubles: StatementRubles(
        amount: line.amount.magnitude, rate: nil, rateDate: nil, source: nil,
        isProvisional: false),
      choice: choice, now: Date(timeIntervalSince1970: 0))
    #expect(entry.transaction.note == "Кофе с Машей")
    #expect(entry.transaction.placeId == place)
    #expect(entry.parts[0].categoryId == cafe)
    #expect(entry.parts[0].categorySource == .imported)
    #expect(entry.parts[0].forWhom == .partner)
  }

  // MARK: VTB

  @Test func vtbPurchaseLearnsByItsCleanedPlace() throws {
    let parse = try #require(parsedCSV(StatementFixtures.vtbCSV()))
    // Line 0: «FUEL 12345_INT», 1 786 ₽ on 14.09; the owner typed 1 790 ₽ (inside 1 %).
    let fuel = handTyped(1_790, day: 14, note: "Бензин", forWhom: .me)
    let first = preview(parse, manual: [manual(fuel, day: 14)])
    var memory = BankTextMemory()
    let taught2 = teach(&memory, first, entries: [fuel])
    #expect(taught2)
    let line = try #require(parse.operations.first { $0.merchant == "FUEL" })
    #expect(StatementLearning.text(of: line) == "FUEL")
    let fill = try #require(StatementLearning.fill(memory, line: line, scope: scope))
    #expect(fill.note == "Бензин")
    // The point number differs at another station of the chain: the cleaned place is the same.
    var other = line
    other.merchant = StatementMerchant.clean("FUEL 99881_INT")
    #expect(StatementLearning.fill(memory, line: other, scope: scope)?.note == "Бензин")
  }

  // MARK: T-Bank: the text layer of a PDF

  @Test func tbankPDFLineLearnsAndFillsTheNextMonth() throws {
    guard case .parsed(let parse) = StatementImporter.parsePDFText(StatementFixtures.tbankLines())
    else {
      Issue.record("not parsed")
      return
    }
    // «Оплата в SAMPLE SHOP MOSCOW RUS», 3 014 ₽ on 15.09.
    let shop = handTyped(3_014, day: 15, note: "Подарок маме", forWhom: .family)
    let first = preview(parse, manual: [manual(shop, day: 15)])
    var memory = BankTextMemory()
    let taught3 = teach(&memory, first, entries: [shop])
    #expect(taught3)
    let line = try #require(parse.operations.first { $0.merchant == "SAMPLE SHOP" })
    var nextMonth = line
    nextMonth.moment = StatementMoment(day: DateOnly(year: 2026, month: 10, day: 15))
    nextMonth.amount = AmountE4(whole: -999)
    let fill = try #require(StatementLearning.fill(memory, line: nextMonth, scope: scope))
    #expect(fill.note == "Подарок маме")
    #expect(fill.forWhom == .family)
  }

  // MARK: Boundaries

  @Test func anotherBankWithTheSameTextIsNotFilled() {
    var memory = BankTextMemory()
    let line = ImportedOperation(
      profileID: "p", sourceIndex: 0, moment: StatementMoment(day: today),
      amount: AmountE4(whole: -150), kind: .purchase, description: "SAMPLE CAFE",
      merchant: "SAMPLE CAFE")
    _ = StatementLearning.learn(&memory, line: line, matched: handTyped(150, day: 14), scope: scope)
    let foreign = BankTextMemory.Scope(accountId: UUID(), bankId: UUID())
    let bankless = BankTextMemory.Scope(accountId: UUID(), bankId: nil)
    #expect(StatementLearning.fill(memory, line: line, scope: foreign) == nil)
    #expect(StatementLearning.fill(memory, line: line, scope: bankless) == nil)
    // Another account of the same bank does use it.
    let sibling = BankTextMemory.Scope(accountId: UUID(), bankId: bank)
    #expect(StatementLearning.fill(memory, line: line, scope: sibling)?.categoryId == cafe)
  }

  @Test func incomeOfTheSameNameIsNotFilledFromAnExpense() {
    var memory = BankTextMemory()
    let out = ImportedOperation(
      profileID: "p", sourceIndex: 0, moment: StatementMoment(day: today),
      amount: AmountE4(whole: -500), kind: .personTransferOut, description: "x",
      counterparty: StatementCounterparty(name: "Иван П."))
    _ = StatementLearning.learn(&memory, line: out, matched: handTyped(500, day: 30), scope: scope)
    var back = out
    back.amount = AmountE4(whole: 500)
    back.kind = .personTransferIn
    #expect(StatementLearning.fill(memory, line: out, scope: scope) != nil)
    #expect(StatementLearning.fill(memory, line: back, scope: scope) == nil)
  }

  @Test func heldReplacementAndUnpickedQuestionTeachNothing() throws {
    let parse = try #require(parsedCSV(StatementFixtures.raiffeisenCSV()))
    // 165 ₽ against the bank's 150 ₽: 10 % apart, asked about, not merged.
    let coffee = handTyped(165, day: 14)
    let asked = preview(parse, manual: [manual(coffee, day: 14)])
    #expect(asked.rows.contains { if case .manualAsk = $0.disposition { true } else { false } })
    var memory = BankTextMemory()
    let taught4 = teach(&memory, asked, entries: [coffee])
    #expect(!taught4)
    // Once the owner picks his coffee, the line teaches.
    let row = try #require(
      asked.rows.first { if case .manualAsk = $0.disposition { true } else { false } })
    let taught5 = StatementLearning.teach(
        &memory, preview: asked, ticks: [row.index], picks: [row.index: coffee.id.uuidString],
        scope: scope, entry: { $0 == coffee.id.uuidString ? coffee : nil })
    #expect(taught5)
    #expect(!memory.isEmpty)
  }

  @Test func ownersEditTeachesThePairAnew() throws {
    let coffee = handTyped(150, day: 14)
    var memory = BankTextMemory()
    let parse = try #require(parsedCSV(StatementFixtures.raiffeisenCSV()))
    _ = teach(&memory, preview(parse, manual: [manual(coffee, day: 14)]), entries: [coffee])
    let line = try #require(parse.operations.first { $0.description.contains("SAMPLE CAFE") })
    // The next line was filled: the operation written from it is remembered.
    let filledID = UUID()
    let taught6 = memory.filled(
        operation: filledID, scope: scope, kind: .expense, text: StatementLearning.text(of: line))
    #expect(taught6)
    #expect(memory.remembers(operation: filledID))
    // The owner corrects it: a lunch for himself, not a coffee for his partner.
    let lunch = UUID()
    let taught7 = memory.relearn(
        operation: filledID,
        fill: BankTextFill(placeId: place, note: "Обед", categoryId: lunch, forWhom: .me))
    #expect(taught7)
    let fill = try #require(StatementLearning.fill(memory, line: line, scope: scope))
    #expect(fill.note == "Обед")
    #expect(fill.categoryId == lunch)
    // The merged hand-typed operation is remembered too.
    #expect(memory.remembers(operation: coffee.id))
    #expect(!memory.remembers(operation: UUID()))
  }

  @Test func checkedDropsWhatNoLongerHolds() {
    let goals = UUID()
    let goalChild = UUID()
    let income = UUID()
    let archived = UUID()
    var archivedCategory = CoreKit.Category(id: archived, kind: .expense, name: "Старое")
    archivedCategory.archived = true
    let list =
      categories + [
        CoreKit.Category(id: goals, kind: .expense, name: "Цели", systemRole: .goals),
        CoreKit.Category(id: goalChild, parentId: goals, kind: .expense, name: "Отпуск"),
        CoreKit.Category(id: income, kind: .income, name: "Зарплата"), archivedCategory,
      ]
    func category(_ id: UUID, _ kind: TransactionKind = .expense) -> UUID? {
      StatementLearning.checked(
        BankTextFill(categoryId: id), kind: kind, categories: list, places: [], people: []
      ).categoryId
    }
    #expect(category(cafe) == cafe)
    #expect(category(goalChild) == nil)
    #expect(category(income) == nil)
    #expect(category(income, .income) == income)
    #expect(category(archived) == nil)
    #expect(category(UUID()) == nil)
    let gone = StatementLearning.checked(
      BankTextFill(placeId: place, forWhom: .other, forPersonId: partner), kind: .expense,
      categories: list, places: [], people: [])
    #expect(gone.placeId == nil && gone.forPersonId == nil && gone.forWhom == nil)
    let income2 = StatementLearning.checked(
      BankTextFill(forWhom: .partner), kind: .income, categories: list, places: [], people: [])
    #expect(income2.forWhom == nil)
  }

  @Test func ruleWinsForItsFieldsAndTheLearnedPairFillsTheRest() {
    let ruleCategory = UUID()
    let fill = BankTextFill(placeId: place, note: "Кофе", categoryId: cafe, forWhom: .partner)
    let choice = StatementLearning.choice(
      over: StatementEntryChoice(categoryID: ruleCategory), ruleSetCategory: true,
      ruleSetPlace: false, fill: fill)
    #expect(choice.categoryID == ruleCategory)
    #expect(choice.placeID == place)
    #expect(choice.note == "Кофе")
    #expect(choice.forWhom == .partner)
  }
}
