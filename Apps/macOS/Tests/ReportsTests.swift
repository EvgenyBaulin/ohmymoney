import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The golden set of the core, from this test bundle — never from the repository.
private func loadGolden() throws -> Golden {
  let url = try XCTUnwrap(
    Bundle(for: ReportsSelectionTests.self).url(
      forResource: "golden-small", withExtension: "json"),
    "golden-small.json is missing from the test bundle")
  return try Golden.decode(Data(contentsOf: url))
}

/// What the window shows and keeps: the table, the period — a month or a year,
/// never after today — and the grouping, which only the spending tables take.
final class ReportsSelectionTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private let september = MonthKey(year: 2026, month: 9)

  func testTheStoredTextsComeBackAsTheSameSelection() {
    let stored = ReportsSelection(
      table: "expensesByCategory", period: "year:2025-12", grouping: "place", today: today)
    XCTAssertEqual(stored.kind, .expensesByCategory)
    XCTAssertEqual(
      stored.period, AnalyticsPeriod(kind: .year, month: MonthKey(year: 2025, month: 12)))
    XCTAssertEqual(stored.grouping, .place)
    XCTAssertEqual(
      ReportsSelection(
        table: stored.kind.rawValue, period: stored.period.storage,
        grouping: stored.grouping.rawValue, today: today),
      stored)

    // Nothing stored yet, or a text that no longer reads: spending by category and
    // subcategory for the current month, by category.
    let fresh = ReportsSelection(table: "", period: "", grouping: "", today: today)
    XCTAssertEqual(fresh.kind, .expensesByCategoryAndSubcategory)
    XCTAssertEqual(fresh.period, .current(today: today))
    XCTAssertEqual(fresh.grouping, .category)
    XCTAssertEqual(
      ReportsSelection(table: "pie", period: "week:2026-09", grouping: "colour", today: today),
      fresh)
  }

  /// A month after today, a year stepped past this one, a text stored by hand: every one
  /// opens no later than the month of today, and nothing steps past it.
  func testThePeriodNeverGoesIntoTheFuture() {
    XCTAssertEqual(ReportsSelection.period(from: "month:2026-12", today: today).month, september)
    XCTAssertEqual(ReportsSelection.period(from: "month:2031-01", today: today).month, september)
    let year = ReportsSelection.period(from: "year:2027-03", today: today)
    XCTAssertEqual(year.kind, .year)
    XCTAssertEqual(year.month, september)
    XCTAssertEqual(year.period, .year(2026))

    // Reports know months and years only.
    let twelve = ReportsSelection.period(from: "twelveMonths:2026-05", today: today)
    XCTAssertEqual(twelve.kind, .month)
    XCTAssertEqual(twelve.period, .month(MonthKey(year: 2026, month: 5)))

    for kind in [AnalyticsPeriod.Kind.month, .year] {
      let current = AnalyticsPeriod.current(kind, today: today)
      XCTAssertFalse(current.canStepForward(today: today), "\(kind)")
      XCTAssertTrue(current.stepped(by: -1).canStepForward(today: today), "\(kind)")
      // A step forward from the current period, if it were taken, comes back to it.
      XCTAssertEqual(
        ReportsSelection.period(from: current.stepped(by: 1).storage, today: today), current)
    }
    // A past year steps forward to this one, anchored on the month of today.
    let lastYear = AnalyticsPeriod.year(2025, today: today)
    XCTAssertTrue(lastYear.canStepForward(today: today))
    XCTAssertEqual(
      ReportsSelection.period(from: lastYear.stepped(by: 1).storage, today: today),
      AnalyticsPeriod(kind: .year, month: september))
  }

  /// «Group by» belongs to the spending tables. Another table is by category whatever was
  /// chosen, and the choice comes back with a spending table.
  func testTheGroupingAppliesToTheSpendingTablesOnly() {
    var selection = ReportsSelection(
      kind: .expensesByCategoryAndSubcategory, period: .current(today: today), grouping: .place)
    XCTAssertTrue(selection.isGroupable)
    XCTAssertEqual(selection.request(today: today).grouping, .place)

    for kind in [ReportTable.Kind.incomeByCategory, .monthly, .periodTotal] {
      selection.kind = kind
      XCTAssertFalse(selection.isGroupable, "\(kind)")
      XCTAssertEqual(selection.effectiveGrouping, .category, "\(kind)")
      XCTAssertEqual(selection.request(today: today).grouping, .category, "\(kind)")
      XCTAssertEqual(selection.grouping, .place, "the choice is kept")
    }
    selection.kind = .expensesByCategory
    XCTAssertEqual(selection.request(today: today).grouping, .place)
    selection.grouping = .event
    XCTAssertEqual(selection.request(today: today).grouping, .event)
  }

  /// The monthly table is a year: the year of the chosen month when a month is chosen.
  func testTheMonthlyTableIsAlwaysAYear() {
    let august = AnalyticsPeriod(kind: .month, month: MonthKey(year: 2025, month: 8))
    let selection = ReportsSelection(kind: .monthly, period: august, grouping: .place)
    XCTAssertEqual(selection.request(today: today).period, .year(2025))
    var other = selection
    other.kind = .periodTotal
    XCTAssertEqual(other.request(today: today).period, .month(MonthKey(year: 2025, month: 8)))
  }
}

/// What the table shows while the data is not there, and whose table it shows.
final class ReportsStoreTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 8, day: 20)
  private let at = Date(timeIntervalSince1970: 0)

  private func request(
    _ kind: ReportTable.Kind = .expensesByCategoryAndSubcategory,
    _ grouping: ReportGrouping = .category,
    _ period: Period = .month(MonthKey(year: 2026, month: 8))
  ) -> ReportsRequest {
    ReportsRequest(kind: kind, period: period, grouping: grouping, today: today)
  }

  func testTheTableShowsTheStateOfTheDataFirst() throws {
    let ledger = try loadGolden().ledger()
    let wanted = request()
    let model = ReportsBuilder.model(wanted, ledger: ledger)
    XCTAssertEqual(
      ReportsStore.state(
        for: wanted, data: BlockState<Int>.calculating, model: model, at: at
      ).phase, .calculating)
    XCTAssertEqual(
      ReportsStore.state(
        for: wanted, data: BlockState<Int>.failed(messageKey: "compute.failed.data"),
        model: model, at: at
      ).phase, .failed)
    XCTAssertEqual(
      ReportsStore.state(for: wanted, data: BlockState<Int>.ready(1, at: at), model: model, at: at)
        .phase, .ready)
  }

  /// A switch of the grouping, the table or the period never shows the table of the old
  /// choice under the new one: «Считается» until its own table is there.
  func testASwitchNeverShowsTheTableOfTheOldChoice() throws {
    let ledger = try loadGolden().ledger()
    let ready = BlockState<Int>.ready(1, at: at)
    let shown = ReportsBuilder.model(request(), ledger: ledger)
    for other in [
      request(.expensesByCategoryAndSubcategory, .place), request(.expensesByCategory),
      request(.expensesByCategoryAndSubcategory, .category, .month(MonthKey(year: 2026, month: 7))),
    ] {
      XCTAssertEqual(
        ReportsStore.state(for: other, data: ready, model: shown, at: at).phase, .calculating,
        "\(other)")
    }
    XCTAssertEqual(
      ReportsStore.state(for: request(), data: ready, model: nil, at: nil).phase, .calculating)
  }

  /// A table with no lines is «Мало данных», not an empty table.
  func testATableWithNoLinesHasNotEnoughData() throws {
    let ledger = try loadGolden().ledger()
    let empty = request(.expensesByCategory, .category, .month(MonthKey(year: 2026, month: 3)))
    let model = ReportsBuilder.model(empty, ledger: ledger)
    XCTAssertFalse(model.table.hasData)
    XCTAssertEqual(
      ReportsStore.state(for: empty, data: BlockState<Int>.ready(1, at: at), model: model, at: at)
        .phase, .notEnoughData)
  }
}

/// The name a CSV is offered under: ASCII, the table, the period, the grouping when it is
/// not by category.
final class ReportFileNameTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  private func name(
    _ kind: ReportTable.Kind, _ period: AnalyticsPeriod, _ grouping: ReportGrouping = .category
  ) -> String {
    ReportFileName.make(
      for: ReportsSelection(kind: kind, period: period, grouping: grouping).request(today: today))
  }

  func testTheDefaultNames() {
    let september = AnalyticsPeriod(kind: .month, month: MonthKey(year: 2026, month: 9))
    let year = september.with(kind: .year)
    XCTAssertEqual(
      name(.expensesByCategory, september), "ohmymoney-expenses-by-category-2026-09.csv")
    XCTAssertEqual(
      name(.expensesByCategoryAndSubcategory, year, .place),
      "ohmymoney-expenses-by-category-and-subcategory-2026-by-place.csv")
    XCTAssertEqual(
      name(.expensesByCategory, september, .forWhom),
      "ohmymoney-expenses-by-category-2026-09-by-for-whom.csv")
    XCTAssertEqual(
      name(.expensesByCategory, september, .paymentMethod),
      "ohmymoney-expenses-by-category-2026-09-by-account.csv")
    // Tables without grouping never name one, whatever was chosen.
    XCTAssertEqual(
      name(.incomeByCategory, september, .event), "ohmymoney-income-by-category-2026-09.csv")
    XCTAssertEqual(name(.monthly, september, .place), "ohmymoney-monthly-2026.csv")
    XCTAssertEqual(name(.periodTotal, year), "ohmymoney-period-total-2026.csv")
  }

  func testEveryNameIsPlainASCII() {
    let september = AnalyticsPeriod(kind: .month, month: MonthKey(year: 2026, month: 9))
    var names: Set<String> = []
    for kind in ReportTable.Kind.allCases {
      for grouping in ReportGrouping.allCases {
        for period in [september, september.with(kind: .year)] {
          let file = name(kind, period, grouping)
          XCTAssertTrue(
            file.unicodeScalars.allSatisfy {
              $0.isASCII && ($0 == "-" || $0 == "." || CharacterSet.alphanumerics.contains($0))
            }, file)
          XCTAssertTrue(file.hasPrefix("ohmymoney-") && file.hasSuffix(".csv"), file)
          names.insert(file)
        }
      }
    }
    // Two spending tables × five groupings × two periods, and three tables × two periods —
    // the monthly one is the same year either way.
    XCTAssertEqual(names.count, 2 * 5 * 2 + 2 * 2 + 1)
  }
}

/// The table on screen and its CSV: the same lines, the same whole rubles, the
/// same shares and the same names — in the language of the moment, with the captions the
/// owner set for «для кого».
@MainActor
final class ReportsExportTests: XCTestCase {
  private var environment: AppEnvironment!
  private var golden: Golden!

  override func setUp() async throws {
    environment = AppEnvironment()
    golden = try loadGolden()
  }

  private func model(
    _ kind: ReportTable.Kind, _ grouping: ReportGrouping = .category,
    _ period: Period = .month(MonthKey(year: 2026, month: 8)), dataset: Dataset? = nil
  ) -> ReportsModel {
    let ledger = Ledger(dataset: dataset ?? golden.dataset(), calendar: .utc)
    return ReportsBuilder.model(
      ReportsRequest(kind: kind, period: period, grouping: grouping, today: golden.todayDay),
      ledger: ledger)
  }

  private func csv(_ model: ReportsModel) throws -> [[String]] {
    try CSVReader.rows(
      from: ReportExport.data(model.table, names: ReportsText.csvNames(for: model, environment)))
  }

  /// Every table, every grouping, a month and the year, in both languages: row by row the
  /// CSV holds exactly the lines of the table — its kind, the name the table shows, the
  /// whole rubles and the share — and nothing else.
  func testTheCSVHoldsExactlyTheLinesAndRoundedNumbersOfTheTable() throws {
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for kind in ReportTable.Kind.allCases {
        for grouping in ReportGrouping.allCases {
          for period in [Period.month(MonthKey(year: 2026, month: 7)), .year(2026)] {
            let model = model(kind, grouping, period)
            let label = "\(choice) \(kind) \(grouping) \(period)"
            let rows = try csv(model)
            let header = try XCTUnwrap(rows.first, label)
            XCTAssertEqual(header, ReportCSV.columns(for: model.table), label)
            let lines = model.flattened
            XCTAssertEqual(rows.count - 1, lines.count, label)
            for (row, line) in zip(rows.dropFirst(), lines) {
              XCTAssertEqual(row[0], line.type.rawValue, label)
              switch line.type {
              case .item, .subtotal:
                XCTAssertEqual(row[1], ReportsText.name(of: line, in: model, environment), label)
              case .total: XCTAssertEqual(row[1], "Total", label)
              case .average: XCTAssertEqual(row[1], "Average", label)
              }
              for index in model.table.measures.indices {
                XCTAssertEqual(row[2 + 2 * index], line.values[index].map(String.init) ?? "", label)
              }
              if model.table.hasShares {
                XCTAssertEqual(row.last, ReportCSV.share(line.share), label)
              }
            }
          }
        }
      }
    }
  }

  /// The words of the lines follow the language, the captions of «для кого» those set in
  /// the Settings, and an archived category keeps its name with «(архив)».
  func testNamesAreResolvedInTheLanguageOfTheApp() throws {
    let year = Period.year(2026)
    func names(_ model: ReportsModel) throws -> [String] {
      try csv(model).dropFirst().map { $0[1] }
    }

    environment.language.choice = .russian
    let forWhom = try names(model(.expensesByCategory, .forWhom, year))
    XCTAssertTrue(forWhom.contains("Партнёр"), "\(forWhom)")
    XCTAssertTrue(forWhom.contains("Я"), "\(forWhom)")
    let people = try names(model(.expensesByCategoryAndSubcategory, .forWhom, year))
    XCTAssertTrue(people.contains("Anna"), "\(people)")
    // Money that names no person is the value's own — for «Я», simply mine: never a line
    // «Без человека», but the value itself again, last under it, so the lines still add up.
    XCTAssertFalse(people.contains("Без человека"), "\(people)")
    XCTAssertEqual(people.filter { $0 == "Друзья" }.count, 2, "\(people)")
    let friends = try XCTUnwrap(
      model(.expensesByCategoryAndSubcategory, .forWhom, year).lines.first {
        $0.key == .forWhom(.friends)
      })
    XCTAssertEqual(friends.children.last?.key, .forWhom(.friends))
    XCTAssertEqual(
      friends.children.map(\.values[0]).reduce(0) { $0 + ($1 ?? 0) }, friends.values[0])
    let categories = try names(model(.expensesByCategoryAndSubcategory, .category, year))
    XCTAssertTrue(categories.contains("Без категории"), "\(categories)")
    XCTAssertTrue(categories.contains("(без подкатегории)"), "\(categories)")
    XCTAssertTrue(categories.contains("Hobby (архив)"), "\(categories)")
    XCTAssertEqual(
      try names(model(.periodTotal, .category, year)), ["Доходы", "Расходы", "Total"])
    let months = try names(model(.monthly, .category, year))
    XCTAssertEqual(months.first, "Январь 2026")
    XCTAssertEqual(months.suffix(2), ["Average", "Total"])

    environment.language.choice = .english
    let english = try names(model(.expensesByCategoryAndSubcategory, .category, year))
    XCTAssertTrue(english.contains("Uncategorized"), "\(english)")
    XCTAssertTrue(english.contains("(no subcategory)"), "\(english)")
    XCTAssertTrue(english.contains("Hobby (archived)"), "\(english)")
    XCTAssertEqual(try names(model(.monthly, .category, year)).first, "January 2026")
    XCTAssertTrue(try names(model(.expensesByCategory, .forWhom, year)).contains("Partner"))

    // The owner calls «Партнёр» «Девушка»: the table and its file say so.
    environment.forWhomLabels = [.partner: "Девушка"]
    let custom = try names(model(.expensesByCategory, .forWhom, year))
    XCTAssertTrue(custom.contains("Девушка"), "\(custom)")
    XCTAssertFalse(custom.contains("Partner"), "\(custom)")
  }

  /// The lines of the table on screen: the average names its months, the total of the
  /// period total is «Итог периода», the current month is marked.
  func testTheServiceLinesOfTheTable() throws {
    environment.language.choice = .russian
    let monthly = model(.monthly, .category, .year(2026))
    let average = try XCTUnwrap(monthly.lines.first { $0.type == .average })
    // Today is 20 August in the golden set: the average is July alone.
    XCTAssertEqual(ReportsText.name(of: average, in: monthly, environment), "Среднее (июль)")
    let august = try XCTUnwrap(
      monthly.lines.first { $0.key == .month(MonthKey(year: 2026, month: 8)) })
    XCTAssertTrue(august.isIncomplete)
    XCTAssertEqual(monthly.lines.filter(\.isIncomplete).count, 1)
    XCTAssertEqual(
      monthly.lines.first { $0.key == .month(MonthKey(year: 2026, month: 9)) }?.values,
      [nil, nil, nil])

    let total = model(.periodTotal, .category, .year(2026))
    let net = try XCTUnwrap(total.lines.last)
    XCTAssertEqual(ReportsText.name(of: net, in: total, environment), "Итог периода")
    let spending = model(.expensesByCategory)
    XCTAssertEqual(
      ReportsText.name(of: try XCTUnwrap(spending.lines.last), in: spending, environment), "Итого")
    XCTAssertEqual(ReportsText.share(2573, environment), "25.73\u{00A0}%")
    XCTAssertEqual(ReportsText.amount(nil, environment), "—")

    environment.language.choice = .english
    XCTAssertEqual(ReportsText.name(of: average, in: monthly, environment), "Average (Jul)")
    XCTAssertEqual(ReportsText.share(2573, environment), "25.73%")
  }

  /// The line under the title: the period, «неполный» while the period holds today — its
  /// last day included, as the core counts it — and the grouping of a spending table. It
  /// names no «по <сегодня>»: the tables take the whole period, operations entered ahead
  /// included, and in the golden set August holds the salary of the 25th.
  func testTheSubtitleSaysWhatThePeriodIs() {
    environment.language.choice = .russian
    let august = Period.month(MonthKey(year: 2026, month: 8))
    func subtitle(_ today: String, _ kind: ReportTable.Kind = .expensesByCategory) -> String {
      ReportsText.subtitle(
        ReportsRequest(kind: kind, period: august, grouping: .place, today: day(today)),
        environment)
    }
    XCTAssertEqual(subtitle("2026-08-20"), "Август 2026 · неполный · по месту")
    XCTAssertEqual(subtitle("2026-08-31"), "Август 2026 · неполный · по месту")
    XCTAssertEqual(subtitle("2026-09-01"), "Август 2026 · по месту")
    XCTAssertEqual(subtitle("2026-09-01", .incomeByCategory), "Август 2026")
    XCTAssertEqual(subtitle("2026-08-20", .incomeByCategory), "Август 2026 · неполный")

    environment.language.choice = .english
    XCTAssertEqual(subtitle("2026-08-20"), "August 2026 · incomplete · by place")
  }

  /// A year with no completed month yet — the owner's first month — has no average to take.
  /// The table says so on the line of the average, «Среднее — мало данных», instead of
  /// dropping the line; the file has no such row, so the CSV is still exactly the other lines
  /// of the table.
  func testAYearWithNoCompletedMonthSaysTheAverageLacksData() throws {
    environment.language.choice = .russian
    let july = ReportsBuilder.model(
      ReportsRequest(
        kind: .monthly, period: .year(2026), grouping: .category, today: day("2026-07-20")),
      ledger: golden.ledger())
    XCTAssertNil(july.table.average)
    XCTAssertTrue(july.table.hasData)
    let average = try XCTUnwrap(july.lines.first { $0.type == .average })
    XCTAssertTrue(average.lacksData)
    XCTAssertEqual(july.lines.suffix(2).map(\.type), [.average, .total])
    XCTAssertEqual(ReportsText.name(of: average, in: july, environment), "Среднее")
    for index in july.table.measures.indices {
      XCTAssertEqual(ReportsText.value(of: average, at: index, environment), "мало данных")
    }
    // A month with figures and a month to come keep theirs.
    let first = try XCTUnwrap(july.lines.first)
    XCTAssertEqual(
      ReportsText.value(of: first, at: 0, environment), ReportsText.amount(0, environment))

    let rows = try csv(july)
    XCTAssertFalse(rows.contains { $0[0] == "average" }, "\(rows)")
    XCTAssertEqual(rows.count - 1, july.flattened.count)
    XCTAssertFalse(july.flattened.contains(where: \.lacksData))

    environment.language.choice = .english
    XCTAssertEqual(ReportsText.name(of: average, in: july, environment), "Average")
    XCTAssertEqual(ReportsText.value(of: average, at: 0, environment), "not enough data")

    // With a completed month there is a real average, and no such line.
    let august = model(.monthly, .category, .year(2026))
    XCTAssertEqual(august.lines.filter { $0.type == .average }.count, 1)
    XCTAssertFalse(august.lines.contains(where: \.lacksData))
  }

  /// A month after the current one with something booked for it shows its figures, with
  /// «ещё не начался» by its name; the current month says «неполный».
  func testAMonthBookedAheadIsMarkedAsNotStarted() throws {
    environment.language.choice = .russian
    // On 20 July the salary of 25 August and the rest of August are booked ahead.
    let july = ReportsBuilder.model(
      ReportsRequest(
        kind: .monthly, period: .year(2026), grouping: .category, today: day("2026-07-20")),
      ledger: golden.ledger())
    let current = try XCTUnwrap(
      july.lines.first { $0.key == .month(MonthKey(year: 2026, month: 7)) })
    let ahead = try XCTUnwrap(july.lines.first { $0.key == .month(MonthKey(year: 2026, month: 8)) })
    let later = try XCTUnwrap(july.lines.first { $0.key == .month(MonthKey(year: 2026, month: 9)) })
    XCTAssertEqual(ReportsText.mark(of: current, in: july, environment)?.text, "неполный")
    XCTAssertEqual(ReportsText.mark(of: ahead, in: july, environment)?.text, "ещё не начался")
    XCTAssertNotEqual(ahead.values, [nil, nil, nil])
    XCTAssertNil(ReportsText.mark(of: later, in: july, environment))
    XCTAssertEqual(later.values, [nil, nil, nil])
    XCTAssertNil(ReportsText.mark(of: try XCTUnwrap(july.lines.first), in: july, environment))

    environment.language.choice = .english
    XCTAssertEqual(ReportsText.mark(of: ahead, in: july, environment)?.text, "not started yet")
  }

  /// The file is written whole where the owner said; a write that cannot happen is an
  /// error the owner is told about, never swallowed.
  func testTheFileIsWrittenOrTheFailureIsThrown() throws {
    environment.language.choice = .russian
    let model = model(.expensesByCategoryAndSubcategory)
    let names = ReportsText.csvNames(for: model, environment)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-reports-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let url = folder.appendingPathComponent(ReportFileName.make(for: model.request))
    try ReportExport.write(model.table, names: names, to: url)
    XCTAssertEqual(try Data(contentsOf: url), ReportExport.data(model.table, names: names))

    let nowhere = folder.appendingPathComponent("missing/folder/report.csv")
    XCTAssertThrowsError(try ReportExport.write(model.table, names: names, to: nowhere)) { error in
      XCTAssertEqual(error as? ReportExport.Failure, .other)
    }
  }

  /// A write the system refuses is told in words of the interface language. The alert used to
  /// carry the system's own description: in the language of the Mac, not of the app, and
  /// naming the file. The reason is read from the codes of the error instead.
  func testAFailedWriteIsToldInTheWordsOfTheInterface() throws {
    let model = model(.expensesByCategoryAndSubcategory)
    let names = ReportsText.csvNames(for: model, environment)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-reports-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
      try? FileManager.default.removeItem(at: folder)
    }
    // A folder the app may not write into.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

    let url = folder.appendingPathComponent("report.csv")
    XCTAssertThrowsError(try ReportExport.write(model.table, names: names, to: url)) { error in
      XCTAssertEqual(error as? ReportExport.Failure, .noPermission, "\(error)")
    }

    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for failure in ReportExport.Failure.allCases {
        let words = ReportsText.t(failure.messageKey, environment)
        XCTAssertNotEqual(words, failure.messageKey, "\(failure) in \(choice.rawValue)")
      }
    }
    environment.language.choice = .russian
    XCTAssertEqual(
      ReportsText.t(ReportExport.Failure.noPermission.messageKey, environment),
      "Приложению нельзя сохранять в эту папку. Выберите другую.")
  }

  /// The reason is the system's code, whichever layer carries it: Foundation's own, the POSIX
  /// one, or a POSIX code wrapped in a Foundation error.
  func testTheReasonOfAFailedWriteIsReadFromTheCodesOfTheError() {
    let wrapped = { (code: POSIXErrorCode) in
      NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
        userInfo: [NSUnderlyingErrorKey: POSIXError(code)])
    }
    let cases: [(Error, ReportExport.Failure)] = [
      (CocoaError(.fileWriteNoPermission), .noPermission),
      (POSIXError(.EACCES), .noPermission),
      (POSIXError(.EPERM), .noPermission),
      (CocoaError(.fileWriteOutOfSpace), .diskFull),
      (wrapped(.ENOSPC), .diskFull),
      (POSIXError(.EDQUOT), .diskFull),
      (CocoaError(.fileWriteVolumeReadOnly), .readOnly),
      (wrapped(.EROFS), .readOnly),
      (CocoaError(.fileNoSuchFile), .other),
      (wrapped(.EIO), .other),
      (CancellationError(), .other),
    ]
    for (error, reason) in cases {
      XCTAssertEqual(ReportExport.Failure(of: error), reason, "\(error)")
    }
  }

  /// «Бэкапы, экспорт, архив, сверка: начало, результат, размер файла, число записей»: a table
  /// saved from Reports is in the journal too — the reason and the error's type and code when
  /// it fails, never a path or the system's words.
  func testSavingATableIsInTheJournalWithoutItsPath() async throws {
    let model = model(.expensesByCategoryAndSubcategory)
    let names = ReportsText.csvNames(for: model, environment)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-reports-\(UUID().uuidString)", isDirectory: true)
    let logs = folder.appendingPathComponent("Logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }

    try ReportExport.write(model.table, names: names, to: folder.appendingPathComponent("a.csv"))
    XCTAssertThrowsError(
      try ReportExport.write(
        model.table, names: names, to: folder.appendingPathComponent("missing/b.csv")))

    var lines: [String] = []
    for _ in 0..<50 {
      lines = Logbook.shared.lines()
      if lines.contains(where: { $0.contains("reports.export.failed") }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let done = try XCTUnwrap(lines.first { $0.contains("reports.export.done") }, "\(lines)")
    XCTAssertTrue(done.contains("rows=") && done.contains("bytes="), done)
    let failed = try XCTUnwrap(lines.first { $0.contains("reports.export.failed") }, "\(lines)")
    for pair in ["reason=other", "error=", "code=4"] {
      XCTAssertTrue(failed.contains(pair), "\(pair) in \(failed)")
    }
    XCTAssertFalse(lines.contains { $0.contains(folder.path) }, "a path reached the journal")
    XCTAssertFalse(lines.contains { $0.contains("b.csv") }, "a file name reached the journal")
  }

  /// One source for three windows. The month of the Reports year and its column in Analytics
  /// take the whole month; Overview «с начала месяца» takes it through today. So the current
  /// month is one number in the three windows when nothing of it is dated after today — how
  /// the owner checks it by hand — and otherwise Reports and Analytics are larger by exactly
  /// what is dated after today. The golden set on its real today, 20 August, holds such a
  /// thing: the salary of 25 August. July is checked the same way on its last day, with the
  /// cashback for July that arrived on 1 August.
  func testTheCurrentMonthIsOverviewsMonthToDateAndTheAnalyticsColumn() throws {
    let today = golden.todayDay
    let asIs = golden.dataset()
    let ahead = asIs.entries.filter {
      CalendarContext.utc.day(of: $0.transaction.occurredAt) > today
    }
    XCTAssertEqual(ahead.map(\.transaction.note), ["salary"])
    let cut = asIs.removing(ahead.map(\.id))

    struct Figures {
      var report: [Int64?]
      var analytics: IncomeExpenseMonth
      var overview: OverviewSummary
      /// Mine expenses and income of the month dated after the day of Overview.
      var later: (expenses: AmountE4, income: AmountE4)
    }
    func figures(_ dataset: Dataset, _ month: MonthKey, on day: DateOnly) throws -> Figures {
      let ledger = Ledger(dataset: dataset, calendar: .utc)
      let report = ReportsBuilder.model(
        ReportsRequest(kind: .monthly, period: .year(2026), grouping: .category, today: today),
        ledger: ledger)
      let line = try XCTUnwrap(report.lines.first { $0.key == .month(month) })
      let analytics = AnalyticsBuilder.model(
        AnalyticsRequest(section: .overview, period: .year(2026), today: today, forecast: nil),
        ledger: ledger)
      let column = try XCTUnwrap(
        analytics.overview?.incomeVsExpenses.content?.first { $0.month == month })
      let overview = DataSnapshot.build(
        dataset: dataset, calendar: .utc, today: day, context: SnapshotContext(),
        version: DataVersion(load: 0)
      ).summary
      let later = ledger.rows(attributedTo: [month]).filter { $0.day > day }
      return Figures(
        report: line.values, analytics: column, overview: overview,
        later: (
          AmountE4.sum(later.map(\.contribution)),
          AmountE4.sum(later.filter { $0.kind == .income }.map(\.amountRubE4))
        ))
    }

    let august = today.monthKey
    let july = MonthKey(year: 2026, month: 7)
    for (dataset, label) in [(asIs, "as is"), (cut, "nothing after today")] {
      for (month, day) in [(august, today), (july, july.lastDay)] {
        let it = try figures(dataset, month, on: day)
        let what = "\(label), \(month.iso)"
        // Reports and Analytics: the whole month, always one number.
        XCTAssertEqual(it.report[0], it.analytics.expenses, what)
        XCTAssertEqual(it.report[1], it.analytics.income, what)
        // Overview: through its day; the rest is what is dated after it.
        XCTAssertEqual(
          it.report[0], (it.overview.expenses.current + it.later.expenses).wholeRubles, what)
        XCTAssertEqual(
          it.report[1], (it.overview.income.current + it.later.income).wholeRubles, what)
      }
    }

    // Check 5 as the owner makes it: nothing is dated after today, three windows, one number.
    let checked = try figures(cut, august, on: today)
    XCTAssertEqual(checked.report, [19_200, 50_700, 31_500])
    XCTAssertEqual(checked.overview.expenses.current.wholeRubles, 19_200)
    XCTAssertEqual(checked.overview.income.current.wholeRubles, 50_700)
    XCTAssertEqual(checked.analytics.income, 50_700)
    // The golden set as it is: the salary of 25 August is in Reports and Analytics only.
    let golden = try figures(asIs, august, on: today)
    XCTAssertEqual(golden.overview.income.current.wholeRubles, 50_700)
    XCTAssertEqual(golden.report[1], 150_700)
    XCTAssertEqual(golden.analytics.income, 150_700)
    XCTAssertEqual(golden.later.income.wholeRubles, 100_000)
  }
}

/// Every table drawn off screen, as the window draws it: a `Table` with a column per
/// measure, its parents under disclosure triangles and the lines of the total and the
/// average. SwiftUI takes every column and row, in both languages.
@MainActor
final class ReportsRenderingTests: XCTestCase {
  /// Every kind with two groupings on the golden set's today, and the year seen on 20 July:
  /// its average reads «мало данных» and August, booked ahead, «ещё не начался».
  func testEveryTableDraws() throws {
    let golden = try loadGolden()
    let ledger = golden.ledger()
    let environment = AppEnvironment()
    var requests = ReportTable.Kind.allCases.flatMap { kind in
      [ReportGrouping.category, .forWhom].map { grouping in
        ReportsRequest(kind: kind, period: .year(2026), grouping: grouping, today: golden.todayDay)
      }
    }
    requests.append(
      ReportsRequest(
        kind: .monthly, period: .year(2026), grouping: .category, today: day("2026-07-20")))
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for request in requests {
        let model = ReportsBuilder.model(request, ledger: ledger)
        let host = NSHostingView(
          rootView: ReportTableView(model: model, collapsed: .constant([]))
            .appDependencies(.forTests(environment))
            .frame(width: 900, height: 600))
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
          backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertGreaterThan(
          host.fittingSize.width, 0,
          "\(choice) \(request.kind) \(request.grouping) \(request.today.iso)")
        window.contentView = nil
      }
    }
  }
}
