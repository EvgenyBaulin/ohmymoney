import CoreKit
import Foundation
import Testing

@testable import CoreCSV

/// Exports of the three trackers, rebuilt from their published descriptions with invented
/// content: invented shops, sums and accounts. Nothing here comes from a real export.
enum MigrationFixtures {
  static let coinKeeper = """
    Данные,Тип,Из,В,Метки,Сумма,Валюта,Сумма в валюте получателя,Валюта получателя,Повторение,Примечание
    05.03.2024,Расход,Наличные,Кафе,,350,RUB,350,RUB,,Латте у дома
    06.03.2024,Доход,Зарплата,Карта Мир,,120000,RUB,120000,RUB,,
    07.03.2024,Перевод,Карта Мир,Наличные,,5000,RUB,5000,RUB,,Снятие
    08.03.2024,Расход,Карта Мир,Еда вне дома,,"1 250,50",RUB,"1 250,50",RUB,,Ужин
    """

  static let zenmoney = """
    date;categoryName;payee;comment;outcomeAccountName;outcome;outcomeCurrencyShortTitle;incomeAccountName;income;incomeCurrencyShortTitle;createdDate;changedDate;qrCode
    2024-03-05;Еда / Кафе;Кофейня;Латте;Карта;350;RUB;Карта;0;RUB;2024-03-05 10:00:00;2024-03-05 10:00:00;
    2024-03-06;Зарплата;;;Карта;0;RUB;Карта;120000;RUB;2024-03-06 10:00:00;2024-03-06 10:00:00;
    2024-03-07;;;;Карта;5000;RUB;Наличные;5000;RUB;2024-03-07 10:00:00;2024-03-07 10:00:00;
    2024-03-08;Путешествия;Hotel;;Карта USD;100;USD;Карта USD;0;USD;2024-03-08 10:00:00;2024-03-08 10:00:00;
    """

  static let moneyManager = """
    Period,Accounts,Category,Subcategory,Note,RUB,Income/Expense,Description,Amount,Currency,Accounts
    03/05/2024 10:15:00,Cash,Food,Eating out,Latte,350,Exp.,near home,350,RUB,350
    03/06/2024 09:00:00,Card,Salary,,March,120000,Income,,120000,RUB,120000
    03/07/2024 12:00:00,Card,Cash,,,5000,Transfer-Out,,5000,RUB,5000
    03/13/2024 18:30:00,Card,Food,Groceries,Market,"1,250.50",Exp.,,"1,250.50",RUB,"1,250.50"
    """

  static let spreadsheet = """
    Дата;Описание;Сумма;Категория;Счёт
    01.02.2024;Кофе;-350,00;Кафе;Т-Банк
    02.02.2024;Аванс;45 000,00;Зарплата;Т-Банк
    03.02.2024;Такси;-0,00;Такси;Т-Банк
    04.02.2024;Продукты;-1 200,00;;Наличные
    """

  static func table(_ text: String) -> MigrationTable {
    guard case .table(let table, _) = MigrationTableReader.read(Data(text.utf8)) else {
      return MigrationTable(header: [], rows: [])
    }
    return table
  }

  static func parse(_ text: String) -> MigrationParse {
    let table = table(text)
    return MigrationRowReader.read(table, mapping: MigrationColumnGuesser.guess(table))
  }
}

@Suite("The columns of other applications are recognised by name and by content")
struct MigrationGuessTests {
  @Test func coinKeeper() {
    let table = MigrationFixtures.table(MigrationFixtures.coinKeeper)
    let mapping = MigrationColumnGuesser.guess(table)
    #expect(mapping.source == .coinKeeper)
    #expect(mapping.column(.date) == 0)
    #expect(mapping.column(.kind) == 1)
    #expect(mapping.column(.from) == 2)
    #expect(mapping.column(.to) == 3)
    #expect(mapping.column(.amount) == 5)
    #expect(mapping.column(.currency) == 6)
    #expect(mapping.column(.comment) == 10)
    #expect(mapping.isComplete)
  }

  @Test func zenmoney() {
    let mapping = MigrationColumnGuesser.guess(MigrationFixtures.table(MigrationFixtures.zenmoney))
    #expect(mapping.source == .zenmoney)
    #expect(mapping.column(.date) == 0)
    #expect(mapping.column(.category) == 1)
    #expect(mapping.column(.payee) == 2)
    #expect(mapping.column(.account) == 4)
    #expect(mapping.column(.expense) == 5)
    #expect(mapping.column(.incomeAccount) == 7)
    #expect(mapping.column(.income) == 8)
    #expect(mapping.column(.incomeCurrency) == 9)
  }

  @Test func moneyManager() {
    let mapping = MigrationColumnGuesser.guess(
      MigrationFixtures.table(MigrationFixtures.moneyManager))
    #expect(mapping.source == .moneyManager)
    #expect(mapping.column(.date) == 0)
    #expect(mapping.column(.account) == 1)
    #expect(mapping.column(.category) == 2)
    #expect(mapping.column(.subcategory) == 3)
    #expect(mapping.column(.description) == 4)
    #expect(mapping.column(.kind) == 6)
    #expect(mapping.column(.amount) == 8)
    #expect(mapping.dateOrder == .monthFirst)
  }

  @Test func columnsWithoutKnownNamesAreFoundByContent() {
    let table = MigrationTable(
      header: ["Когда", "Что", "Сколько"],
      rows: [["01.02.2024", "Кофе", "-350"], ["02.02.2024", "Чай", "-120,50"]])
    let mapping = MigrationColumnGuesser.guess(table)
    #expect(mapping.column(.date) == 0)
    #expect(mapping.column(.amount) == 2)
    #expect(mapping.source == .spreadsheet)
  }

  @Test func assigningARoleTakesItFromTheOtherColumn() {
    var mapping = MigrationMapping(roles: [0: .date, 1: .amount])
    mapping.assign(.amount, to: 2)
    #expect(mapping.column(.amount) == 2)
    #expect(mapping.roles[1] == nil)
    mapping.assign(nil, to: 2)
    #expect(!mapping.isComplete)
  }

  @Test func mappingsSurviveTheSettings() {
    let mapping = MigrationColumnGuesser.guess(MigrationFixtures.table(MigrationFixtures.zenmoney))
    let text = MigrationSettings.text(["h1:x": mapping])
    #expect(MigrationSettings.mappings(from: text)["h1:x"] == mapping)
    #expect(MigrationSettings.mappings(from: "not json").isEmpty)
    let id = UUID()
    #expect(MigrationSettings.ids(from: MigrationSettings.text(["k": id]))["k"] == id)
  }
}

@Suite("Rows become operations; transfers between the other application's accounts do not")
struct MigrationRowTests {
  @Test func coinKeeperFromAndToDependOnTheDirection() {
    let parse = MigrationFixtures.parse(MigrationFixtures.coinKeeper)
    #expect(parse.operations.count == 3)
    #expect(parse.transfers == 1)
    let coffee = parse.operations[0]
    #expect(coffee.operation.amount == AmountE4(whole: -350))
    #expect(coffee.operation.accountRef == "Наличные")
    #expect(coffee.category == MigrationCategoryKey(kind: .expense, parent: "Кафе"))
    #expect(coffee.operation.description == "Латте у дома")
    #expect(coffee.operation.moment.day == DateOnly(year: 2024, month: 3, day: 5))
    let salary = parse.operations[1]
    #expect(salary.operation.amount == AmountE4(whole: 120_000))
    #expect(salary.operation.accountRef == "Карта Мир")
    #expect(salary.category == MigrationCategoryKey(kind: .income, parent: "Зарплата"))
    #expect(parse.operations[2].operation.amount == AmountE4(raw: -12_505_000))
    #expect(parse.operations[0].operation.profileID == "migration.coinKeeper")
  }

  @Test func zenmoneyTwoSidesAndSubcategories() {
    let parse = MigrationFixtures.parse(MigrationFixtures.zenmoney)
    #expect(parse.operations.count == 3)
    #expect(parse.transfers == 1)
    let coffee = parse.operations[0]
    #expect(coffee.category == MigrationCategoryKey(kind: .expense, parent: "Еда", child: "Кафе"))
    #expect(coffee.operation.description == "Кофейня")
    #expect(coffee.operation.comment == "Латте")
    #expect(coffee.operation.merchant == "Кофейня")
    let salary = parse.operations[1]
    #expect(salary.operation.amount == AmountE4(whole: 120_000))
    #expect(salary.category?.kind == .income)
    let hotel = parse.operations[2]
    #expect(hotel.operation.currency == .usd)
    #expect(hotel.operation.accountRef == "Карта USD")
    #expect(parse.accountNames == ["Карта", "Карта USD"])
  }

  @Test func moneyManagerTypeWordsAndMonthFirstDates() {
    let parse = MigrationFixtures.parse(MigrationFixtures.moneyManager)
    #expect(parse.operations.count == 3)
    #expect(parse.transfers == 1)
    let latte = parse.operations[0]
    #expect(latte.operation.amount == AmountE4(whole: -350))
    #expect(
      latte.operation.moment
        == StatementMoment(
          day: DateOnly(year: 2024, month: 3, day: 5), minuteOfDay: 615))
    #expect(
      latte.category == MigrationCategoryKey(kind: .expense, parent: "Food", child: "Eating out"))
    #expect(latte.operation.comment == "near home")
    #expect(parse.operations[2].operation.moment.day == DateOnly(year: 2024, month: 3, day: 13))
    #expect(parse.operations[2].operation.amount == AmountE4(raw: -12_505_000))
  }

  @Test func spreadsheetSignsZerosAndMissingCategory() {
    let parse = MigrationFixtures.parse(MigrationFixtures.spreadsheet)
    #expect(parse.operations.count == 3)
    #expect(parse.zeroLines == 1)
    #expect(parse.operations[1].operation.amount == AmountE4(whole: 45_000))
    #expect(parse.operations[1].category?.kind == .income)
    #expect(parse.operations[2].category == nil)
    #expect(parse.operations[2].operation.accountRef == "Наличные")
    #expect(parse.period?.from == DateOnly(year: 2024, month: 2, day: 1))
    #expect(parse.period?.to == DateOnly(year: 2024, month: 2, day: 4))
    #expect(parse.categories.map(\.title) == ["Кафе", "Зарплата"])
  }

  @Test func badLinesAreCountedNotDropped() {
    let table = MigrationTable(
      header: ["Дата", "Сумма"],
      rows: [["вчера", "-100"], ["01.02.2024", "много"], ["", ""], ["02.02.2024", "-5"]])
    let parse = MigrationRowReader.read(table, mapping: MigrationColumnGuesser.guess(table))
    #expect(parse.operations.count == 1)
    #expect(parse.unparsed.map(\.reason) == [.badDate, .badAmount])
    #expect(parse.unparsed.first?.amount == AmountE4(whole: -100))
  }

  @Test func refundsAreRefunds() {
    let table = MigrationTable(
      header: ["Дата", "Тип", "Сумма", "Категория"],
      rows: [["01.02.2024", "Возврат", "500", "Одежда"]])
    let parse = MigrationRowReader.read(table, mapping: MigrationColumnGuesser.guess(table))
    #expect(parse.operations.first?.operation.kind == .purchaseRefund)
    #expect(parse.operations.first?.category?.kind == .expense)
    #expect(StatementEntryBuilder.kind(of: parse.operations[0].operation) == .refund)
  }
}

@Suite("Categories of the other application are paired with the book's own")
struct MigrationCategoryTests {
  let cafe = CoreKit.Category(kind: .expense, name: "Кафе", sort: 1)
  let food = CoreKit.Category(kind: .expense, name: "Еда", sort: 2)
  let salary = CoreKit.Category(kind: .income, name: "Зарплата", sort: 3)
  var goals: CoreKit.Category {
    var goals = CoreKit.Category(kind: .expense, name: "Цели", sort: 4)
    goals.systemRole = .goals
    return goals
  }

  @Test func byNameBySynonymByMemoryAndNeverASystemCategory() {
    let keys = [
      MigrationCategoryKey(kind: .expense, parent: "кафе "),
      MigrationCategoryKey(kind: .expense, parent: "Еда вне дома"),
      MigrationCategoryKey(kind: .expense, parent: "Еда", child: "Рестораны"),
      MigrationCategoryKey(kind: .income, parent: "Salary"),
      MigrationCategoryKey(kind: .expense, parent: "Цели"),
      MigrationCategoryKey(kind: .expense, parent: "Хобби"),
      MigrationCategoryKey(kind: .income, parent: "Кафе"),
    ]
    let remembered = [keys[5].id: food.id]
    let targets = MigrationCategoryMatcher.suggest(
      keys, categories: [cafe, food, salary, goals], remembered: remembered)
    #expect(targets[keys[0].id] == .existing(cafe.id))
    #expect(targets[keys[1].id] == .existing(cafe.id))
    // The subcategory's meaning comes before the parent's name.
    #expect(targets[keys[2].id] == .existing(cafe.id))
    #expect(targets[keys[3].id] == .existing(salary.id))
    #expect(targets[keys[4].id] == .unsorted)
    #expect(targets[keys[5].id] == .existing(food.id))
    // An income category of the same name as an expense one is not it.
    #expect(targets[keys[6].id] == .unsorted)
  }

  @Test func creatingMakesEachNameOnceAndSubcategoriesUnderTheirParent() {
    let keys = [
      MigrationCategoryKey(kind: .expense, parent: "Хобби", child: "Рыбалка"),
      MigrationCategoryKey(kind: .expense, parent: "хобби", child: "Книги"),
      MigrationCategoryKey(kind: .expense, parent: "Еда", child: "Фрукты"),
      MigrationCategoryKey(kind: .expense, parent: "Кафе"),
      MigrationCategoryKey(kind: .expense, parent: "Прочее"),
    ]
    var targets = Dictionary(
      uniqueKeysWithValues: keys.map { ($0.id, MigrationCategoryTarget.create) })
    targets[keys[4].id] = .unsorted
    let unsorted = UUID()
    let plan = MigrationCategoryPlan.resolve(
      keys, targets: targets, categories: [cafe, food, salary], unsorted: { _ in unsorted })
    // «Хобби» once, two subcategories; «Фрукты» under the existing «Еда»; «Кафе» exists.
    #expect(
      plan.made.map(\.name).sorted()
        == ["Книги", "Рыбалка", "Фрукты", "Хобби"].sorted())
    let hobby = plan.made.first { $0.name == "Хобби" }
    #expect(hobby?.parentId == nil)
    #expect(plan.made.filter { $0.parentId == hobby?.id }.count == 2)
    #expect(plan.made.first { $0.name == "Фрукты" }?.parentId == food.id)
    #expect(plan.ids[keys[3].id] == cafe.id)
    #expect(plan.ids[keys[4].id] == unsorted)
    #expect(plan.made.allSatisfy { $0.sort > 3 })
  }
}

@Suite("The preview counts what will happen and the write is one import per account")
struct MigrationPlanTests {
  let card = UUID()
  let cash = UUID()

  func account(_ name: String) -> UUID? {
    switch NameKey.fold(name) {
    case "т-банк": card
    case "наличные": cash
    default: nil
    }
  }

  @Test func duplicatesLikelyDuplicatesAndLinesWaitingForARate() {
    var parse = MigrationFixtures.parse(MigrationFixtures.spreadsheet)
    // A fourth line in dollars.
    var dollars = parse.operations[0]
    dollars.operation.currency = .usd
    dollars.operation.sourceIndex = 9
    parse.operations.append(dollars)
    let coffee = parse.operations[0].operation
    let stored = StatementExisting(
      id: "x", key: StatementDedupKey(account: card.uuidString, operation: coffee),
      status: .posted, day: coffee.moment.day, amount: coffee.amount, placeKey: coffee.placeKey)
    let typed = StatementManualEntry(
      id: "m", day: DateOnly(year: 2024, month: 2, day: 5), amount: AmountE4(whole: -1_200))
    let preview = MigrationPlanner.preview(
      parse, account: account, existing: { $0 == card ? [stored] : [] },
      manual: { $0 == cash ? [typed] : [] }, hasRate: { $0.currency == .rub })
    #expect(preview.dispositions == [.duplicate, .new, .likelyDuplicate, .waitingForRate])
    #expect(preview.defaultTicks == [1])
    #expect(preview.count(.duplicate) == 1)
  }

  @Test func theWriteFilesEveryLineAsImportedWithoutAnExternalID() throws {
    let parse = MigrationFixtures.parse(MigrationFixtures.spreadsheet)
    let cafe = UUID()
    let unsorted = UUID()
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let write = MigrationPlanner.write(
      parse, ticks: [0, 1, 2], fileName: "export.csv", account: account,
      category: { key, _ in key?.parent == "Кафе" ? cafe : unsorted },
      quality: { $0 == cafe ? .neutral : nil },
      rubles: { RubleProbe.rubles($0) }, zoneID: "Europe/Moscow", now: at)
    #expect(write.entries.count == 3)
    #expect(write.imports.count == 2)
    let coffee = try #require(write.entries.first)
    #expect(coffee.transaction.externalId == nil)
    #expect(coffee.transaction.note == "Кофе")
    #expect(coffee.transaction.kind == .expense)
    #expect(coffee.transaction.paymentMethodId == card)
    #expect(coffee.parts.first?.categoryId == cafe)
    #expect(coffee.parts.first?.categorySource == .imported)
    #expect(coffee.parts.first?.quality == .neutral)
    #expect(coffee.transaction.dedupKey != nil)
    let salary = write.entries[1]
    #expect(salary.transaction.kind == .income)
    #expect(salary.parts.first?.quality == nil)
    let cardImport = try #require(write.imports.first { $0.accountID == card.uuidString })
    #expect(cardImport.newCount == 2)
    #expect(cardImport.profileID == "migration.spreadsheet")
    #expect(cardImport.periodFrom == DateOnly(year: 2024, month: 2, day: 1))
    #expect(coffee.transaction.importBatchId?.uuidString == cardImport.id)
  }

  @Test func unmappedAccountsAndMissingRatesAreLeftOut() {
    let parse = MigrationFixtures.parse(MigrationFixtures.spreadsheet)
    let write = MigrationPlanner.write(
      parse, ticks: [0, 1, 2], fileName: "export.csv",
      account: { NameKey.fold($0) == "наличные" ? self.cash : nil },
      category: { _, _ in nil }, quality: { _ in nil },
      rubles: { RubleProbe.rubles($0) }, zoneID: "Europe/Moscow", now: Date())
    #expect(write.entries.count == 1)
    #expect(write.imports.count == 1)
  }
}

/// Rubles for a ruble line, nothing for others: the rates the tests have on hand.
enum RubleProbe {
  static func rubles(_ operation: ImportedOperation) -> StatementRubles? {
    StatementRubleResolver.resolve(operation) { _, _ in nil }
  }
}
