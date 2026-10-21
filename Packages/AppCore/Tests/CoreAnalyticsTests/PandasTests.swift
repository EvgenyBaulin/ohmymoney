import CoreCSV
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// Every Reports table of the golden set, written as the app writes it and read back by
/// pandas with `read_csv(path)` and no parameters — the promise of the format.
/// Every kind × every grouping, for July, August and the year.
///
/// pandas is a declared tool, not part of the core: `make pyenv` puts it in a venv outside
/// iCloud and git, and `make test-core` hands that Python over through `OHMYMONEY_PYTHON`.
/// Without it the suite is skipped and says why, and `make verify` prints «pandas: NOT
/// checked». The structure of the CSV is checked in Swift either way (`RuleTests`).
@Suite(
  "pandas reads every Reports table",
  .enabled(
    if: Pandas.python != nil,
    "OHMYMONEY_PYTHON is not set: run `make pyenv`, then `make test-core` to read the CSV with pandas"
  ))
struct PandasTests {
  /// What pandas saw in one file. Amounts come back as text, so nothing is compared as a
  /// floating-point number.
  struct Reading: Decodable {
    let rows: Int
    let columns: [String]
    /// The dtype of every `*_rub` column: whole rubles are `int64` unless a dash (a month
    /// still to come) makes the column `float64`.
    let dtypes: [String: String]
    /// The `*_rub` values of the Total line.
    let total: [String: String]
    /// Σ of every `*_rub_exact` column over the item rows, four decimals.
    let itemSums: [String: String]
    /// Σ of `share` over the item rows, four decimals; `nil` without that column.
    let itemShares: String?
    /// `str()` of the first name: `nan` when pandas took it for a missing value.
    let firstName: String
    /// How many names pandas read back as missing values.
    let missingNames: Int
  }

  /// One Python for all the files: importing pandas once takes most of the time.
  static let script = """
    import json, sys, pandas
    result = {}
    for path in sys.argv[2:]:
        frame = pandas.read_csv(path)
        rub = [c for c in frame.columns if c.endswith("_rub")]
        exact = [c for c in frame.columns if c.endswith("_rub_exact")]
        items = frame[frame["row_type"] == "item"]
        total = frame[frame["row_type"] == "total"].iloc[0]
        reading = {
            "rows": int(len(frame)),
            "columns": [str(c) for c in frame.columns],
            "dtypes": {c: str(frame[c].dtype) for c in rub},
            "total": {c: "%d" % total[c] for c in rub},
            "itemSums": {c: "%.4f" % items[c].sum() for c in exact},
            "firstName": str(frame["name"].iloc[0]),
            "missingNames": int(frame["name"].isna().sum()),
        }
        if "share" in frame.columns:
            reading["itemShares"] = "%.4f" % items["share"].sum()
        result[path] = reading
    with open(sys.argv[1], "w", encoding="utf-8") as output:
        json.dump(result, output)
    """

  /// A name the owner may well give — a card called «N/A» — that is one of pandas' default
  /// missing-value words ('NA', 'N/A', 'None', 'null', 'NaN'…). `read_csv` with no
  /// parameters reads it back as NaN, quoted or not; only `keep_default_na=False` keeps it.
  /// The file cannot prevent that without changing the owner's name, so the limit is
  /// written down and recorded here rather than found by surprise.
  static let missingValueName = "N/A"
  static let missingValueKey = ReportKey.paymentMethod(id(61))

  /// The names as the app would give them, and harder: Russian words, a comma and quotes
  /// of both kinds inside a name must neither split its column nor come back changed. One
  /// payment method is called «N/A», which comes back as a missing value.
  static func label(_ golden: Golden) -> (ReportKey) -> String {
    { key in
      if key == PandasTests.missingValueKey { return PandasTests.missingValueName }
      return switch key {
      case .uncategorized: "Без категории"
      case .noSubcategory: "(без подкатегории)"
      default: "«\(golden.label(key))», \"\(fixtureKey(key))\""
      }
    }
  }

  /// The lines in the order `ReportCSV` writes them: each parent before its children, then
  /// the average, then the total.
  static func written(_ table: ReportTable) -> [ReportRow] {
    func flat(_ row: ReportRow) -> [ReportRow] { [row] + row.children.flatMap(flat) }
    return table.rows.flatMap(flat) + [table.average].compactMap { $0 } + [table.total]
  }

  @Test func everyTableReadsBackWithNoParameters() throws {
    let python = try #require(Pandas.python)
    let golden = try Golden.load()
    let builder = ReportBuilder(ledger: golden.ledger(), today: golden.todayDay)
    let label = Self.label(golden)
    let periods: [(String, Period)] = [
      ("2026-07", .month(MonthKey(year: 2026, month: 7))),
      ("2026-08", .month(MonthKey(year: 2026, month: 8))),
      ("2026", .year(2026)),
    ]

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-pandas-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    var tables: [String: ReportTable] = [:]
    for kind in ReportTable.Kind.allCases {
      for grouping in ReportGrouping.allCases {
        for (name, period) in periods {
          let table = builder.table(kind, period: period, grouping: grouping)
          let url = folder.appendingPathComponent(
            "\(kind.rawValue)-\(grouping.rawValue)-\(name).csv")
          try ReportCSV.data(table, label: label).write(to: url)
          tables[url.path] = table
        }
      }
    }
    #expect(tables.count == 75)

    let output = folder.appendingPathComponent("readings.json")
    let run = try Pandas.run(
      python, script: Self.script, arguments: [output.path] + tables.keys.sorted())
    try #require(run.status == 0, "pandas failed: \(run.output)")
    let readings = try JSONDecoder().decode(
      [String: Reading].self, from: Data(contentsOf: output))
    #expect(readings.count == tables.count)
    // The tables by payment method name the card «N/A», and pandas loses that name.
    #expect(readings.values.contains { $0.missingNames > 0 })

    for (path, table) in tables.sorted(by: { $0.key < $1.key }) {
      let file = URL(fileURLWithPath: path).lastPathComponent
      let reading = try #require(readings[path], "pandas did not read \(file)")
      let lines = Self.written(table)
      #expect(reading.rows == lines.count, "\(file)")
      #expect(reading.columns == ReportCSV.columns(for: table), "\(file)")
      let names = lines.map { ReportCSV.name(of: $0, label: label) }
      let missing = names.filter { $0 == Self.missingValueName }.count
      #expect(reading.missingNames == missing, "\(file)")
      #expect(
        reading.firstName == (names[0] == Self.missingValueName ? "nan" : names[0]), "\(file)")

      for (index, measure) in table.measures.enumerated() {
        let stem = measure == .amount ? "amount" : measure.rawValue
        let values = lines.map { $0.values[index] }
        let hasDash = values.contains { $0 == nil }
        #expect(reading.dtypes["\(stem)_rub"] == (hasDash ? "float64" : "int64"), "\(file)")

        let total = try #require(table.total.values[index], "\(file): the total has a dash")
        #expect(reading.total["\(stem)_rub"] == String(total.wholeRubles), "\(file)")

        let items = zip(lines, values).filter { $0.0.type == .item }.compactMap(\.1)
        #expect(
          reading.itemSums["\(stem)_rub_exact"] == ReportCSV.exact(AmountE4.sum(items)),
          "\(file)")
        // Summing the items gives the total: subtotals and the average are never counted
        // twice. The period total alone is a difference of its two lines.
        if table.kind != .periodTotal {
          #expect(reading.itemSums["\(stem)_rub_exact"] == ReportCSV.exact(total), "\(file)")
        }
      }

      if table.hasShares {
        let shares = lines.filter { $0.type == .item }.compactMap(\.share).reduce(0, +)
        #expect(reading.itemShares == ReportCSV.share(shares), "\(file)")
      } else {
        #expect(reading.itemShares == nil, "\(file)")
      }
    }
  }
}

/// The Python of the pandas check, and a way to run it.
enum Pandas {
  /// `OHMYMONEY_PYTHON`, set by `make test-core` once `make pyenv` has made the venv.
  static var python: String? {
    guard let path = ProcessInfo.processInfo.environment["OHMYMONEY_PYTHON"], !path.isEmpty else {
      return nil
    }
    return path
  }

  /// Runs `python -c script arguments…` and waits for it; standard output and errors come
  /// back together, for the message of a failure.
  static func run(
    _ python: String, script: String, arguments: [String]
  ) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = ["-c", script] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    // Read to the end before waiting: a full pipe would otherwise hold Python forever.
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
  }
}
