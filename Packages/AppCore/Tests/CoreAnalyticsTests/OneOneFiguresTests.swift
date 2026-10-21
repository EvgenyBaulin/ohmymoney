import CoreAccounting
import CoreCSV
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// A small book with accounts, linked refunds across months, money back in parts and
/// unlinked refunds — the 1.1 data every Analytics, Reports and Overview figure reads.
fileprivate struct Sheet {
  static let groceries = id(10)
  static let clothes = id(11)
  static let transport = id(12)
  static let bus = id(13)
  static let cashback = id(31)
  static let salary = id(32)
  static let cardA = id(60)
  static let cardB = id(61)
  static let market = id(50)
  static let anna = id(70)
  static let trip = id(80)

  static let abroad = id(90)

  var entries: [TransactionEntry] = []
  var links: [ReimbursementLink] = []
  var events: [Event] = []
  var transfers: [Transfer] = []
  /// Card B in a group left out of the summary: its money apart, its spending not.
  var cardBApart = false

  static func at(_ iso: String, hour: Int = 12) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(TimeInterval(hour * 3600))
  }

  @discardableResult
  mutating func purchase(
    _ number: Int, _ iso: String, _ amount: String, category: UUID = Sheet.groceries,
    account: UUID? = Sheet.cardA, place: UUID? = nil, quality: Quality = .neutral,
    event: UUID? = nil, forAnna: Bool = false, status: ReimbursementStatus? = nil
  ) -> UUID {
    let amountE4 = money(amount)
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(number), kind: .expense, occurredAt: Self.at(iso), amountE4: amountE4,
          placeId: place, paymentMethodId: account),
        parts: [
          TransactionPart(
            id: id(number * 10), transactionId: id(number), categoryId: category,
            quality: quality, qualitySource: .manual, amountE4: amountE4,
            forWhom: forAnna ? .friends : .me, reimbursable: forAnna,
            debtorPersonId: forAnna ? Self.anna : nil,
            reimbursementStatus: forAnna ? (status ?? .expected) : nil, eventId: event)
        ]))
    return id(number * 10)
  }

  /// A refund; `of` links it to a purchase part, `nil` is a refund with no purchase.
  mutating func refund(
    _ number: Int, _ iso: String, _ amount: String, of partId: UUID?,
    category: UUID = Sheet.groceries, account: UUID? = Sheet.cardA, place: UUID? = nil,
    event: UUID? = nil
  ) {
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(number), kind: .refund, occurredAt: Self.at(iso), amountE4: money(amount),
          placeId: place, paymentMethodId: account),
        parts: [
          TransactionPart(
            id: id(number * 10), transactionId: id(number), categoryId: category,
            amountE4: money(amount), eventId: event, refundOfPartId: partId)
        ]))
  }

  mutating func income(
    _ number: Int, _ iso: String, _ amount: String, category: UUID = Sheet.salary,
    account: UUID? = Sheet.cardA, forMonth: MonthKey? = nil
  ) {
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(number), kind: .income, occurredAt: Self.at(iso), amountE4: money(amount),
          paymentMethodId: account, periodMonth: forMonth),
        parts: [
          TransactionPart(
            id: id(number * 10), transactionId: id(number), categoryId: category,
            amountE4: money(amount))
        ]))
  }

  mutating func moneyBack(_ number: Int, _ iso: String, _ amount: String, closing part: UUID) {
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(number), kind: .reimbursement, occurredAt: Self.at(iso), amountE4: money(amount),
          paymentMethodId: Self.cardA),
        parts: [
          TransactionPart(id: id(number * 10), transactionId: id(number), amountE4: money(amount))
        ]))
    links.append(
      ReimbursementLink(reimbursementTxId: id(number), partId: part, amountE4: money(amount)))
  }

  /// «Списать остаток»: the operation the app writes for what is left of a part, and the part
  /// settled.
  mutating func writeOffRest(_ number: Int, _ iso: String, _ amount: String, of part: UUID) {
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(number), kind: .expense, occurredAt: Self.at(iso), amountE4: money(amount),
          paymentMethodId: Self.cardA,
          externalId: MoneyBack.writeOffKey(part: part, operation: id(number))),
        parts: [
          TransactionPart(
            id: id(number * 10), transactionId: id(number), categoryId: Self.groceries,
            quality: .neutral, qualitySource: .manual, amountE4: money(amount),
            forWhom: .friends, forPersonId: Self.anna)
        ]))
    for index in entries.indices {
      for partIndex in entries[index].parts.indices where entries[index].parts[partIndex].id == part
      {
        entries[index].parts[partIndex].reimbursementStatus = .returned
      }
    }
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, links: links,
        categories: [
          CoreKit.Category(
            id: Self.groceries, kind: .expense, name: "Groceries", quality: .neutral),
          CoreKit.Category(id: Self.clothes, kind: .expense, name: "Clothes", quality: .neutral),
          CoreKit.Category(
            id: Self.transport, kind: .expense, name: "Transport", quality: .neutral),
          CoreKit.Category(
            id: Self.bus, parentId: Self.transport, kind: .expense, name: "Bus", quality: .neutral),
          CoreKit.Category(id: Self.cashback, kind: .income, name: "Cashback"),
          CoreKit.Category(id: Self.salary, kind: .income, name: "Salary"),
        ],
        people: [Person(id: Self.anna, name: "Anna")],
        places: [Place(id: Self.market, name: "Market")],
        events: events,
        paymentMethods: [
          PaymentMethod(id: Self.cardA, name: "Card A", isDefault: true),
          PaymentMethod(
            id: Self.cardB, name: "Card B", groupId: cardBApart ? Self.abroad : nil, sort: 1),
        ],
        settings: AnalyticsSettings(cashbackCategoryId: Self.cashback),
        transfers: transfers,
        accountGroups: cardBApart
          ? [AccountGroup(id: Self.abroad, name: "Abroad", inSummary: false)] : []),
      calendar: .utc)
  }
}

fileprivate let january = Period.month(MonthKey(year: 2026, month: 1))
fileprivate let february = Period.month(MonthKey(year: 2026, month: 2))

/// A refund taken back from a purchase makes the purchase cheaper in its own day and month in
/// every analytics figure, while the money moves at the refund's own moment.
@Suite("1.1 figures on Analytics, Reports and Overview")
struct OneOneFiguresTests {
  /// January: 10 000 at the market on card A; 5 February: 4 000 of it back, onto card B.
  fileprivate func crossMonthRefund() -> Sheet {
    var sheet = Sheet()
    let part = sheet.purchase(1, "2026-01-20", "10000", place: Sheet.market)
    sheet.refund(2, "2026-02-05", "4000", of: part, account: Sheet.cardB, place: Sheet.market)
    return sheet
  }

  // MARK: - «Счета»

  /// The account section is the former payment-method section: its turnover is what the bank
  /// pays cashback on, and a refund taken back from a purchase makes the purchase cheaper in
  /// the purchase's month and account — never a negative turnover of another account in the
  /// refund's month.
  @Test func aTakenBackRefundLowersTheTurnoverOfThePurchaseAccountAndMonth() {
    let ledger = crossMonthRefund().ledger

    let inJanuary = PaymentMethodsReport(ledger: ledger, period: january).methods
    #expect(inJanuary.map(\.key) == [.paymentMethod(Sheet.cardA)])
    #expect(inJanuary.first?.mySpending == money("6000"))
    #expect(inJanuary.first?.turnover == money("6000"))

    let inFebruary = PaymentMethodsReport(ledger: ledger, period: february).methods
    #expect(inFebruary.isEmpty, "the refund belongs to January: February has no turnover at all")
  }

  /// Cashback for January that came in February is January's; its share is of the turnover
  /// left after the refund: 60 of 6 000 = 1.00 %.
  @Test func cashbackIsTakenOfWhatIsLeftOfThePurchase() {
    var sheet = crossMonthRefund()
    sheet.income(
      3, "2026-02-03", "60", category: Sheet.cashback,
      forMonth: MonthKey(year: 2026, month: 1))
    let ledger = sheet.ledger

    let card = PaymentMethodsReport(ledger: ledger, period: january).methods.first
    #expect(card?.cashback == money("60"))
    #expect(card?.cashbackShare == 100)
    #expect(PaymentMethodsReport(ledger: ledger, period: february).cashback == .zero)
  }

  /// A refund with no purchase stays on its own day and account and lowers that month's
  /// turnover: it is the only record of the money coming back.
  @Test func aRefundWithNoPurchaseStaysInItsOwnMonthAndAccount() {
    var sheet = Sheet()
    sheet.purchase(1, "2026-02-10", "3000", account: Sheet.cardB)
    sheet.refund(2, "2026-02-12", "500", of: nil, account: Sheet.cardB)
    let methods = PaymentMethodsReport(ledger: sheet.ledger, period: february).methods
    #expect(methods.first?.key == .paymentMethod(Sheet.cardB))
    #expect(methods.first?.mySpending == money("2500"))
    #expect(methods.first?.turnover == money("2500"))
  }

  // MARK: - Transfers and a group apart

  /// January: salary 50 000 and groceries 1 000 on card A, 3 000 spent on card B, 20 000 moved
  /// from A to B with a fee of 150. The transfer is neither income nor spending anywhere; its
  /// fee is spending on card A; and card B's group being left out of the summary changes no
  /// figure of spending or income — it hides the money on B, not what was spent from it.
  @Test(arguments: [false, true])
  func aTransferIsNoFigureItsFeeIsSpentAndAGroupApartStillSpends(_ cardBApart: Bool) {
    var sheet = Sheet()
    sheet.cardBApart = cardBApart
    sheet.income(1, "2026-01-02", "50000")
    sheet.purchase(2, "2026-01-10", "1000")
    sheet.purchase(3, "2026-01-15", "3000", account: Sheet.cardB)
    let transfer = id(4)
    sheet.transfers.append(
      Transfer(
        id: transfer, occurredAt: Sheet.at("2026-01-12"), fromAccountId: Sheet.cardA,
        fromCurrency: .rub, fromAmountE4: money("20000"), toAccountId: Sheet.cardB,
        toCurrency: .rub, toAmountE4: money("20000")))
    sheet.entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(5), kind: .expense, occurredAt: Sheet.at("2026-01-12"), amountE4: money("150"),
          paymentMethodId: Sheet.cardA, externalId: TransferRules.feeKey(of: transfer)),
        parts: [
          TransactionPart(
            id: id(50), transactionId: id(5), categoryId: Sheet.transport, quality: .neutral,
            amountE4: money("150"))
        ]))
    // February: 5 000 back from B to A and nothing else.
    sheet.transfers.append(
      Transfer(
        id: id(6), occurredAt: Sheet.at("2026-02-03"), fromAccountId: Sheet.cardB,
        fromCurrency: .rub, fromAmountE4: money("5000"), toAccountId: Sheet.cardA,
        toCurrency: .rub, toAmountE4: money("5000")))
    let ledger = sheet.ledger

    #expect(ledger.expenses(in: january.range) == money("4150"))
    #expect(ledger.income(in: january) == money("50000"))
    #expect(ledger.expenses(in: february.range) == .zero)
    #expect(ledger.income(in: february) == .zero)

    let accounts = Dictionary(
      uniqueKeysWithValues: PaymentMethodsReport(ledger: ledger, period: january).methods.map {
        ($0.key, [$0.mySpending, $0.turnover])
      })
    #expect(accounts[.paymentMethod(Sheet.cardA)] == [money("1150"), money("1150")])
    #expect(accounts[.paymentMethod(Sheet.cardB)] == [money("3000"), money("3000")])
    #expect(PaymentMethodsReport(ledger: ledger, period: february).methods.isEmpty)

    let builder = ReportBuilder(ledger: ledger, today: day("2026-03-01"))
    let monthly = builder.table(.monthly, period: .year(2026))
    #expect(monthly.rows[0].values == [money("4150"), money("50000"), money("45850")])
    #expect(monthly.rows[1].values == [.zero, .zero, .zero])
    let byCategory = builder.table(.expensesByCategory, period: january)
    #expect(byCategory.total.amount == money("4150"))
    #expect(
      byCategory.rows.first { $0.key == .category(Sheet.transport) }?.amount == money("150"))

    let overview = OverviewSummary(ledger: ledger, today: day("2026-01-31"))
    #expect(overview.expenses.current == money("4150"))
    #expect(overview.income.current == money("50000"))
    #expect(overview.net == money("45850"))
  }

  // MARK: - Places

  /// The refund's month shows no visit to the market: the refund is the purchase's.
  @Test func aTakenBackRefundIsNoVisitInItsOwnMonth() {
    let ledger = crossMonthRefund().ledger
    let january = PlacesReport(ledger: ledger, period: january).places
    #expect(january.map(\.mySpending) == [money("6000")])
    #expect(january.first?.purchases == 1)
    #expect(PlacesReport(ledger: ledger, period: february).places.isEmpty)
  }

  // MARK: - Reports

  /// The monthly table puts the refund in January; the year's total is the sum of its months
  /// and January's row equals January's own tables.
  @Test func theMonthlyTableCountsTheRefundInThePurchaseMonth() {
    var sheet = crossMonthRefund()
    sheet.purchase(3, "2026-02-14", "1000", category: Sheet.bus)
    sheet.income(4, "2026-02-01", "50000", forMonth: MonthKey(year: 2026, month: 1))
    let ledger = sheet.ledger
    let builder = ReportBuilder(ledger: ledger, today: day("2026-03-10"))

    let monthly = builder.table(.monthly, period: .year(2026))
    #expect(monthly.rows[0].values == [money("6000"), money("50000"), money("44000")])
    #expect(monthly.rows[1].values == [money("1000"), .zero, money("-1000")])
    #expect(monthly.total.values == [money("7000"), money("50000"), money("43000")])
    #expect(monthly.average?.values == [money("3500"), money("25000"), money("21500")])

    let byCategory = builder.table(.expensesByCategory, period: january)
    #expect(byCategory.total.amount == monthly.rows[0].values[0])
    let total = builder.table(.periodTotal, period: february)
    #expect(total.rows.map(\.amount) == [.zero, money("1000")])
  }

  /// A refund with no purchase can leave a category below zero: that line gets no share, the
  /// positive lines of every level share exactly 100.00 %, and a sum over the item lines of
  /// the CSV gives its total.
  @Test func theCSVSharesAddUpToAWholeWithANegativeLine() throws {
    var sheet = Sheet()
    sheet.purchase(1, "2026-03-02", "1000")
    sheet.purchase(2, "2026-03-03", "2000", category: Sheet.bus)
    sheet.purchase(3, "2026-03-04", "1000", category: Sheet.transport)
    sheet.refund(4, "2026-03-05", "3000", of: nil, category: Sheet.clothes)
    let builder = ReportBuilder(ledger: sheet.ledger, today: day("2026-04-01"))
    let table = builder.table(
      .expensesByCategoryAndSubcategory, period: .month(MonthKey(year: 2026, month: 3)))

    let clothes = try #require(table.rows.first { $0.key == .category(Sheet.clothes) })
    #expect(clothes.amount == money("-3000"))
    #expect(clothes.share == nil)
    #expect(table.rows.compactMap(\.share).reduce(0, +) == Shares.whole)
    // The lowest level of the whole table — every child, and the top lines with none — is one
    // more whole: a child reads as a part of the same total as its parent.
    let lowest = table.rows.flatMap { $0.children.isEmpty ? [$0] : $0.children }
    #expect(lowest.compactMap(\.share).reduce(0, +) == Shares.whole)
    let transport = try #require(table.rows.first { $0.key == .category(Sheet.transport) })
    #expect(transport.share == 7500)
    #expect(transport.children.compactMap(\.share).reduce(0, +) == 7500)
    #expect(clothes.children.allSatisfy { $0.share == nil })

    let csv = String(decoding: ReportCSV.data(table, label: { $0.description }), as: UTF8.self)
    let lines = csv.split(separator: "\n").map {
      $0.split(separator: ",", omittingEmptySubsequences: false)
    }
    #expect(lines.first == ["row_type", "name", "amount_rub", "amount_rub_exact", "share"])
    let body = lines.dropFirst()
    // Top-level lines are the ones whose key is a category without a parent; a subtotal is
    // followed by its children, so the items of the top level are those that are not children.
    let childNames = Set(table.rows.flatMap(\.children).map { $0.key.description })
    let top = body.filter {
      ($0[0] == "item" || $0[0] == "subtotal") && !childNames.contains(String($0[1]))
    }
    let shares = top.compactMap { Decimal(string: String($0[4])) }
    #expect(shares.reduce(0, +) == 1)
    let exact = top.compactMap { Decimal(string: String($0[3])) }
    let totalLine = try #require(body.first { $0[0] == "total" })
    #expect(exact.reduce(0, +) == Decimal(string: String(totalLine[3])))
    #expect(totalLine[4] == "1.0000")
    #expect(totalLine[3] == "1000.0000")
  }

  // MARK: - Events, for whom, quality

  /// An event is judged as a whole: 5 000 on the trip in January less 2 000 taken back in
  /// February is 3 000, in the purchase's category, and the bad spending of January is 3 000.
  @Test func anEventAndTheQualitiesCountTheRefundInThePurchase() {
    var sheet = Sheet()
    sheet.events = [
      Event(
        id: Sheet.trip, name: "Trip", startDate: day("2026-01-10"), endDate: day("2026-01-25"),
        budgetE4: money("4000"))
    ]
    let part = sheet.purchase(1, "2026-01-15", "5000", quality: .bad, event: Sheet.trip)
    sheet.refund(2, "2026-02-02", "2000", of: part, event: Sheet.trip)
    let ledger = sheet.ledger

    let events = EventsReport(ledger: ledger, period: january).events
    #expect(events.first?.total == money("3000"))
    #expect(events.first?.budgetLeft == money("1000"))
    #expect(events.first?.byCategory.map(\.amount) == [money("3000")])

    let quality = QualityReport(ledger: ledger, period: january, today: day("2026-02-10"))
    #expect(quality.months.first?.qualities.map(\.amount) == [.zero, .zero, money("3000")])
    #expect(quality.badByCategory.map(\.amount) == [money("3000")])
    // The refund carries the trip, as `RefundRules` copies it from the purchase; February
    // still has nothing of the trip to show.
    #expect(EventsReport(ledger: ledger, period: february).events.isEmpty)
    let february = QualityReport(ledger: ledger, period: february, today: day("2026-02-10"))
    #expect(february.months.first?.qualities.map(\.amount) == [.zero, .zero, .zero])
  }

  // MARK: - Money back in parts

  /// 3 000 paid for Anna; 1 000 came back: 2 000 still waits, in «За других» and in «Мне
  /// должны». After «Списать остаток» nothing waits, the 2 000 is written off, and every ruble
  /// paid is accounted for exactly once.
  @Test func moneyBackInPartsKeepsEveryRublePaidAccountedForOnce() {
    var sheet = Sheet()
    let part = sheet.purchase(1, "2026-01-12", "3000", forAnna: true)
    sheet.moneyBack(2, "2026-01-20", "1000", closing: part)
    var ledger = sheet.ledger

    var others = OthersReport(ledger: ledger, period: january)
    #expect(others.totals.paid == money("3000"))
    #expect(others.totals.returned == money("1000"))
    #expect(others.totals.waiting == money("2000"))
    let overview = OverviewSummary(ledger: ledger, today: day("2026-01-31"))
    #expect(overview.owedToMe == money("2000"))
    #expect(overview.owedCount == 1)
    #expect(overview.expenses.current == .zero)
    #expect(overview.income.current == .zero, "money back is not income")

    sheet.writeOffRest(3, "2026-01-28", "2000", of: part)
    ledger = sheet.ledger
    others = OthersReport(ledger: ledger, period: january)
    let totals = others.totals
    #expect(totals.waiting == .zero)
    #expect(totals.writtenOff == money("2000"))
    #expect(totals.returned == money("1000"))
    #expect(totals.paid == totals.returned + totals.writtenOff + totals.waiting + totals.shortfall)
    #expect(OverviewSummary(ledger: ledger, today: day("2026-01-31")).owedToMe == .zero)
    #expect(ledger.expenses(in: january.range) == money("2000"))
  }

  /// A whole period's shares on the Overview cards: the top categories are shares of all my
  /// spending, and the qualities always add up to 100 %.
  @Test func theOverviewQualitiesShareAWholeWithARefund() {
    var sheet = Sheet()
    sheet.purchase(1, "2026-01-03", "3000", quality: .good)
    let part = sheet.purchase(2, "2026-01-04", "2000", category: Sheet.bus, quality: .bad)
    sheet.refund(3, "2026-01-05", "1000", of: part, category: Sheet.bus)
    sheet.purchase(4, "2026-01-06", "1000", category: Sheet.clothes)
    let overview = OverviewSummary(ledger: sheet.ledger, today: day("2026-01-20"))
    #expect(overview.expenses.current == money("5000"))
    #expect(overview.qualities.map(\.amount) == [money("3000"), money("1000"), money("1000")])
    #expect(overview.qualities.compactMap(\.share).reduce(0, +) == Shares.whole)
    #expect(overview.bad.current == money("1000"))
    #expect(overview.topCategories.map(\.amount) == [money("3000"), money("1000"), money("1000")])
  }
}

/// Every Reports table of a 1.1 book — accounts, a refund taken back across a month, a refund
/// of no purchase that leaves a line below zero, money back in parts, cashback — read back
/// by pandas with no parameters: the items add up to the total and their shares to 1.0000.
@Suite(
  "pandas reads the 1.1 Reports tables",
  .enabled(
    if: Pandas.python != nil,
    "OHMYMONEY_PYTHON is not set: run `make pyenv`, then `make test-core` to read the CSV with pandas"
  ))
struct OneOnePandasTests {
  @Test func everyTableOfA1_1BookAddsUpInPandas() throws {
    let python = try #require(Pandas.python)
    var sheet = Sheet()
    let coat = sheet.purchase(1, "2026-01-20", "10000", place: Sheet.market)
    sheet.refund(2, "2026-02-05", "4000", of: coat, account: Sheet.cardB, place: Sheet.market)
    sheet.purchase(3, "2026-02-14", "1000", category: Sheet.bus, account: Sheet.cardB)
    sheet.refund(4, "2026-02-15", "3000", of: nil, category: Sheet.clothes)
    let lent = sheet.purchase(5, "2026-01-12", "3000", forAnna: true)
    sheet.moneyBack(6, "2026-01-20", "1000", closing: lent)
    sheet.income(
      7, "2026-02-03", "60", category: Sheet.cashback, forMonth: MonthKey(year: 2026, month: 1))
    sheet.income(8, "2026-01-25", "50000")
    let builder = ReportBuilder(ledger: sheet.ledger, today: day("2026-03-10"))
    let periods: [(String, Period)] = [
      ("2026-01", january), ("2026-02", february), ("2026", .year(2026)),
    ]

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-pandas-11-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var tables: [String: ReportTable] = [:]
    for kind in ReportTable.Kind.allCases {
      for grouping in ReportGrouping.allCases {
        for (name, period) in periods {
          let table = builder.table(kind, period: period, grouping: grouping)
          let url = folder.appendingPathComponent(
            "\(kind.rawValue)-\(grouping.rawValue)-\(name).csv")
          try ReportCSV.data(table, label: { "«\($0.description)», \"x\"" }).write(to: url)
          tables[url.path] = table
        }
      }
    }

    let output = folder.appendingPathComponent("readings.json")
    let run = try Pandas.run(
      python, script: PandasTests.script, arguments: [output.path] + tables.keys.sorted())
    try #require(run.status == 0, "pandas failed: \(run.output)")
    let readings = try JSONDecoder().decode(
      [String: PandasTests.Reading].self, from: Data(contentsOf: output))
    #expect(readings.count == tables.count)

    for (path, table) in tables.sorted(by: { $0.key < $1.key }) {
      let file = URL(fileURLWithPath: path).lastPathComponent
      let reading = try #require(readings[path], "pandas did not read \(file)")
      #expect(reading.missingNames == 0, "\(file)")
      for (index, measure) in table.measures.enumerated() where table.kind != .periodTotal {
        let stem = measure == .amount ? "amount" : measure.rawValue
        let total = try #require(table.total.values[index], "\(file): the total has a dash")
        #expect(reading.itemSums["\(stem)_rub_exact"] == ReportCSV.exact(total), "\(file)")
        #expect(reading.total["\(stem)_rub"] == String(total.wholeRubles), "\(file)")
      }
      if table.hasShares {
        let anyPositive = PandasTests.written(table).contains {
          $0.type == .item && ($0.amount?.raw ?? 0) > 0
        }
        #expect(reading.itemShares == (anyPositive ? "1.0000" : "0.0000"), "\(file)")
      }
    }
    // January by category: the coat less what came back in February, and nothing of Anna's.
    let januaryByCategory = try #require(
      tables.first { $0.key.hasSuffix("expensesByCategory-category-2026-01.csv") }?.value)
    #expect(januaryByCategory.total.amount == money("6000"))
  }
}
