import CoreCSV
import CoreKit
import CoreSample
import Foundation
import Testing

/// Every file of Export, written from a six-month sample with its accounts — so the groups,
/// the transfers and the counted balances have rows too — read back by pandas with
/// `read_csv(path)` and no parameters: the promise of the format. pandas sees as many rows as
/// were written and the columns under the names the export declares, in its order.
///
/// Gated like the Reports check (`PandasTests`): without `make pyenv` it is skipped and says
/// why, and `make verify` prints «pandas: NOT checked».
@Suite(
  "pandas reads every file of Export",
  .enabled(
    if: Pandas.python != nil,
    "OHMYMONEY_PYTHON is not set: run `make pyenv`, then `make test-core` to read the CSV with pandas"
  ))
struct ExportPandasTests {
  struct Reading: Decodable {
    let rows: Int
    let columns: [String]
  }

  static let script = """
    import json, sys, pandas
    result = {}
    for path in sys.argv[2:]:
        frame = pandas.read_csv(path)
        result[path] = {"rows": int(len(frame)), "columns": [str(c) for c in frame.columns]}
    with open(sys.argv[1], "w", encoding="utf-8") as output:
        json.dump(result, output)
    """

  /// The rows of each file, as the export writes them from a database holding the sample.
  static func rows(of given: SampleDataSet) -> [ExportTable: [[String]]] {
    // The banks the accounts sit under, as the update of an older book leaves them.
    let set = given.assigningBanks()
    let planning = set.planning
    var rows: [ExportTable: [[String]]] = [:]
    rows[ExportTables.transactions] = set.entries.map { ExportTables.row($0.transaction) }
    rows[ExportTables.transactionParts] = set.entries.flatMap(\.parts).map(ExportTables.row)
    rows[ExportTables.reimbursementLinks] = set.links.map(ExportTables.row)
    rows[ExportTables.people] = set.people.map(ExportTables.row)
    rows[ExportTables.paymentMethods] = set.paymentMethods.map(ExportTables.row)
    rows[ExportTables.places] = set.places.map(ExportTables.row)
    rows[ExportTables.events] = set.events.map(ExportTables.row)
    rows[ExportTables.categories] = set.categories.map(ExportTables.row)
    rows[ExportTables.templates] = set.templates.map(ExportTables.row)
    rows[ExportTables.scheduledPayments] = planning.scheduled.map(ExportTables.row)
    rows[ExportTables.subscriptionPrices] = planning.prices.map(ExportTables.row)
    rows[ExportTables.expectedIncome] = planning.expected.map(ExportTables.row)
    rows[ExportTables.budgets] = planning.budgets.map(ExportTables.row)
    rows[ExportTables.goals] = set.goals.map(ExportTables.row)
    rows[ExportTables.debts] = set.debts.map(ExportTables.row)
    rows[ExportTables.debtEntries] = set.debtEntries.map(ExportTables.row)
    rows[ExportTables.reconciliations] = set.reconciliations.map(ExportTables.row)
    // The sample fetches no rates: the file is its header alone.
    rows[ExportTables.rates] = []
    rows[ExportTables.accountGroups] = set.accountGroups.map(ExportTables.row)
    rows[ExportTables.transfers] = set.transfers.map(ExportTables.row)
    rows[ExportTables.reconciliationBalances] = set.reconciledBalances.map(ExportTables.row)
    let (cards, rules) = Self.cardsAndRules(of: set)
    rows[ExportTables.cards] = cards.map(ExportTables.row)
    rows[ExportTables.cashbackRules] = rules.map(ExportTables.row)
    rows[ExportTables.banks] = set.banks.map(ExportTables.row)
    let (assets, valuations) = Self.assetsAndValuations()
    rows[ExportTables.assets] = assets.map(ExportTables.row)
    rows[ExportTables.assetValuations] = valuations.map(ExportTables.row)
    // The tables of loans, allocation and own currencies the sample does not fill yet: headers alone.
    for table in [
      ExportTables.debtInstalments, ExportTables.debtCosts, ExportTables.allocationRules,
      ExportTables.customCurrencies, ExportTables.settings,
    ] where rows[table] == nil {
      rows[table] = []
    }
    return rows
  }

  /// Two assets and their valuations, whatever the sample holds: a car in euros sold on a day,
  /// with a valuation of kopecks and one without a note, and a flat kept, with no note at all.
  static func assetsAndValuations() -> ([Asset], [AssetValuation]) {
    let car = Asset(
      id: UUID(uuidString: "0A0A0A0A-0000-4000-8000-000000000001")!, name: "Машина",
      kind: .vehicle, currency: .eur, note: "куплена в кредит",
      disposedOn: DateOnly(year: 2026, month: 9, day: 1), sort: 1)
    let flat = Asset(
      id: UUID(uuidString: "0A0A0A0A-0000-4000-8000-000000000002")!, name: "Квартира",
      kind: .realty)
    let valuations = [
      AssetValuation(
        id: UUID(uuidString: "0A0A0A0A-0000-4000-8000-000000000003")!, assetId: car.id,
        day: DateOnly(year: 2026, month: 3, day: 31), valueE4: AmountE4(raw: 150_000_005_000),
        note: "оценка дилера"),
      AssetValuation(
        id: UUID(uuidString: "0A0A0A0A-0000-4000-8000-000000000004")!, assetId: car.id,
        day: DateOnly(year: 2026, month: 6, day: 30), valueE4: AmountE4(whole: 14_000)),
      AssetValuation(
        id: UUID(uuidString: "0A0A0A0A-0000-4000-8000-000000000005")!, assetId: flat.id,
        day: DateOnly(year: 2026, month: 1, day: 15), valueE4: AmountE4(whole: 9_000_000)),
    ]
    return ([car, flat], valuations)
  }

  /// The sample's cards and cashback rules, and one card more whatever the sample holds, so
  /// that pandas reads the cells only these files have: `aliases` over two lines, a card of
  /// its account, a percent of four decimals, and the empty `card_id`, `category_id` and
  /// `month` of an account's own rule for everything else.
  static func cardsAndRules(of set: SampleDataSet) -> ([PaymentCard], [CashbackRule]) {
    let accounts = set.paymentMethods.filter { !$0.archived }
    guard let first = accounts.first, let category = set.categories.first,
      let third = CashbackPercent(decimal: Decimal(string: "33.3333")!),
      let flat = CashbackPercent(decimal: 1)
    else { return (set.cards, set.cashbackRules) }
    let second = accounts.dropFirst().first ?? first
    let card = PaymentCard(
      id: UUID(uuidString: "0C0C0C0C-0000-4000-8000-000000000001")!, accountId: first.id,
      name: "Visa 4242", aliases: ["visa", "четыре двойки"])
    let onTheCard = CashbackRule(
      id: UUID(uuidString: "0C0C0C0C-0000-4000-8000-000000000002")!, accountId: first.id,
      cardId: card.id, categoryId: category.id, month: MonthKey(year: 2026, month: 9),
      percent: third)
    let ofTheAccount = CashbackRule(
      id: UUID(uuidString: "0C0C0C0C-0000-4000-8000-000000000003")!, accountId: second.id,
      percent: flat)
    return (set.cards + [card], set.cashbackRules + [onTheCard, ofTheAccount])
  }

  @Test func everyFileReadsBackWithNoParameters() throws {
    let python = try #require(Pandas.python)
    let set = SampleDataGenerator(seed: 20_260_918).generate(
      months: 6, endingOn: Synthetic.endingOn, calendar: Synthetic.calendar, language: "ru"
    ).withAccounts(seed: 20_260_918, calendar: Synthetic.calendar, language: "ru")
    let rows = Self.rows(of: set)
    #expect(ExportTables.all.count == 31)
    #expect(Set(rows.keys) == Set(ExportTables.all), "a file of Export has no rows here")
    for table in [
      ExportTables.accountGroups, ExportTables.transfers, ExportTables.reconciliationBalances,
      ExportTables.cards, ExportTables.cashbackRules, ExportTables.banks, ExportTables.assets,
      ExportTables.assetValuations,
    ] {
      #expect(!(rows[table] ?? []).isEmpty, "\(table.fileName) is empty")
    }

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-export-pandas-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var paths: [String: ExportTable] = [:]
    for table in ExportTables.all {
      var writer = CSVWriter(columns: table.columns)
      for row in rows[table] ?? [] {
        #expect(row.count == table.columns.count, "\(table.fileName): a row of another width")
        writer.append(row)
      }
      let url = folder.appendingPathComponent(table.fileName)
      try writer.data().write(to: url)
      paths[url.path] = table
    }

    let output = folder.appendingPathComponent("readings.json")
    let run = try Pandas.run(
      python, script: Self.script, arguments: [output.path] + paths.keys.sorted())
    try #require(run.status == 0, "pandas failed: \(run.output)")
    let readings = try JSONDecoder().decode(
      [String: Reading].self, from: Data(contentsOf: output))
    #expect(readings.count == 31)
    for (path, table) in paths.sorted(by: { $0.key < $1.key }) {
      let reading = try #require(readings[path], "pandas did not read \(table.fileName)")
      #expect(reading.rows == (rows[table] ?? []).count, "\(table.fileName): rows")
      #expect(reading.columns == table.columns, "\(table.fileName): columns")
    }
  }

  static let cardsScript = """
    import json, sys, pandas
    cards = pandas.read_csv(sys.argv[2])
    rules = pandas.read_csv(sys.argv[3])
    def cell(value):
        return None if pandas.isna(value) else str(value)
    result = {
        "aliases": [cell(v) for v in cards["aliases"]],
        "percent": [repr(float(v)) for v in rules["percent"]],
        "cardId": [cell(v) for v in rules["card_id"]],
        "categoryId": [cell(v) for v in rules["category_id"]],
        "month": [cell(v) for v in rules["month"]],
    }
    with open(sys.argv[1], "w", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False)
    """

  struct CardsReading: Decodable {
    let aliases: [String?]
    let percent: [String]
    let cardId: [String?]
    let categoryId: [String?]
    let month: [String?]
  }

  /// The cells of a card and its rules read by pandas with no parameters as they were
  /// written: two aliases in one quoted cell over two lines, a percent of four decimals as a
  /// number, and the empty card, category and month of an account's own rule as missing.
  @Test func aCardAndItsRulesReadBackAsWritten() throws {
    let python = try #require(Pandas.python)
    let set = SampleDataGenerator(seed: 20_260_918).generate(
      months: 6, endingOn: Synthetic.endingOn, calendar: Synthetic.calendar, language: "ru"
    ).withAccounts(seed: 20_260_918, calendar: Synthetic.calendar, language: "ru")
    let (cards, rules) = Self.cardsAndRules(of: set)
    let card = try #require(cards.last)
    let onTheCard = try #require(rules.dropLast().last)

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-export-cards-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var paths: [String] = []
    for (table, rows) in [
      (ExportTables.cards, cards.map(ExportTables.row)),
      (ExportTables.cashbackRules, rules.map(ExportTables.row)),
    ] {
      var writer = CSVWriter(columns: table.columns)
      for row in rows { writer.append(row) }
      let url = folder.appendingPathComponent(table.fileName)
      try writer.data().write(to: url)
      paths.append(url.path)
    }

    let output = folder.appendingPathComponent("cards.json")
    let run = try Pandas.run(python, script: Self.cardsScript, arguments: [output.path] + paths)
    try #require(run.status == 0, "pandas failed: \(run.output)")
    let reading = try JSONDecoder().decode(CardsReading.self, from: Data(contentsOf: output))
    #expect(reading.aliases.count == cards.count)
    #expect(reading.aliases.last == "visa\nчетыре двойки")
    #expect(reading.percent.count == rules.count)
    #expect(Array(reading.percent.suffix(2)) == ["33.3333", "1.0"])
    #expect(Array(reading.cardId.suffix(2)) == [card.id.uuidString, nil])
    #expect(Array(reading.categoryId.suffix(2)) == [onTheCard.categoryId?.uuidString, nil])
    #expect(Array(reading.month.suffix(2)) == ["2026-09", nil])
  }

  /// What an owner may type into a name or a note, each of it a way to break a hand-made CSV:
  /// a comma, quotes, line breaks of three kinds, a lone quote, emoji of several scalars,
  /// words pandas takes for a missing value, a leading `#`, spaces at the ends, a formula.
  static let awkward = [
    "Кофе, с молоком", "say \"hi\"", "две\nстроки", "crlf\r\nline", "lone\rcr",
    "☕️ 👨‍👩‍👧", "NA", "null", "nan", "#tag", "  spaced  ", "\"", "=1+2", "ё Ё й",
  ]

  /// The words `read_csv` reads as a missing value by default: it keeps the row and the
  /// column and loses only the word, which is its promise, not the export's.
  static let missingToPandas: Set<String> = ["", "NA", "null", "nan"]

  static let textScript = """
    import json, sys, pandas
    result = {}
    for path in sys.argv[2:]:
        frame = pandas.read_csv(path)
        texts = {}
        for column in ("name", "note"):
            if column in frame.columns:
                texts[column] = [None if pandas.isna(v) else str(v) for v in frame[column]]
        result[path] = {"rows": int(len(frame)), "columns": [str(c) for c in frame.columns],
                        "texts": texts}
    with open(sys.argv[1], "w", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False)
    """

  struct TextReading: Decodable {
    let rows: Int
    let columns: [String]
    let texts: [String: [String?]]
  }

  /// The same 26 files with every name and note of every row replaced by an awkward string —
  /// the accounts' groups, transfers and counts among them — read by pandas with no
  /// parameters: no row is lost or split, the columns stay, and every name and note reads
  /// back as written, except the words pandas takes for a missing value.
  @Test func awkwardNamesAndNotesReadBackWithNoParameters() throws {
    let python = try #require(Pandas.python)
    let set = SampleDataGenerator(seed: 20_260_918).generate(
      months: 6, endingOn: Synthetic.endingOn, calendar: Synthetic.calendar, language: "ru"
    ).withAccounts(seed: 20_260_918, calendar: Synthetic.calendar, language: "ru")
    var rows = Self.rows(of: set)
    var written: [ExportTable: [String: [String]]] = [:]
    var replaced = 0
    for table in ExportTables.all {
      for column in ["name", "note"] {
        guard let index = table.columns.firstIndex(of: column) else { continue }
        var values: [String] = []
        for position in (rows[table] ?? []).indices {
          let value = Self.awkward[(position + replaced) % Self.awkward.count]
          rows[table]?[position][index] = value
          values.append(value)
        }
        replaced += values.count
        written[table, default: [:]][column] = values
      }
    }
    #expect(replaced > Self.awkward.count * 4, "too few names and notes to replace")
    #expect(written[ExportTables.transfers]?["note"]?.isEmpty == false)
    #expect(written[ExportTables.accountGroups]?["name"]?.isEmpty == false)

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-export-awkward-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var paths: [String: ExportTable] = [:]
    for table in ExportTables.all {
      var writer = CSVWriter(columns: table.columns)
      for row in rows[table] ?? [] { writer.append(row) }
      let url = folder.appendingPathComponent(table.fileName)
      try writer.data().write(to: url)
      paths[url.path] = table
    }

    let output = folder.appendingPathComponent("readings.json")
    let run = try Pandas.run(
      python, script: Self.textScript, arguments: [output.path] + paths.keys.sorted())
    try #require(run.status == 0, "pandas failed: \(run.output)")
    let readings = try JSONDecoder().decode(
      [String: TextReading].self, from: Data(contentsOf: output))
    #expect(readings.count == 31)
    for (path, table) in paths.sorted(by: { $0.key < $1.key }) {
      let reading = try #require(readings[path], "pandas did not read \(table.fileName)")
      #expect(reading.rows == (rows[table] ?? []).count, "\(table.fileName): rows")
      #expect(reading.columns == table.columns, "\(table.fileName): columns")
      for (column, values) in written[table] ?? [:] {
        let expected: [String?] = values.map { Self.missingToPandas.contains($0) ? nil : $0 }
        #expect(reading.texts[column] == expected, "\(table.fileName): \(column)")
      }
    }
  }
}
