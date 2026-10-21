import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The forecast card of an account screen: the words it shows for each currency of the account
/// in both languages, and the plan the data step builds for it.
@MainActor
final class AccountForecastCardTests: XCTestCase {
  private let main = PaymentMethod(name: "Main", currency: .rub, isDefault: true)
  private let freedom = PaymentMethod(
    name: "Freedom", currency: CurrencyCode("KZT"), otherCurrencies: [.usd])

  private func whole(_ value: Int64) -> AmountE4 { AmountE4(whole: value) }

  private func band(_ low: Int64, _ middle: Int64, _ high: Int64) -> AccountForecast.Band {
    AccountForecast.Band(low: whole(low), middle: whole(middle), high: whole(high))
  }

  /// Main of the worked example: 47,000 now, a transfer of 5,000 written for the 25th, the
  /// salary expected, 1,900 of payments and 60 % of the spending.
  private var mainLine: AccountForecast.Line {
    AccountForecast.Line(
      flows: AccountMonthPlan.Flows(
        key: BalanceKey(accountId: main.id, currency: .rub), account: main, now: whole(47_000),
        writtenAhead: whole(-5_000), income: whole(100_000), scheduled: whole(1_900),
        spendingWeight: whole(36_000)),
      status: .ready, spending: band(4_800, 7_200, 10_800),
      balance: band(129_300, 132_900, 135_300), balanceRub: band(129_300, 132_900, 135_300),
      shareBp: 6_000)
  }

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  /// The figure, its interval and what it is made of, a line of nothing left out; the signs say
  /// which way each line goes, «≈» marks what is estimated.
  func testTheLinesOfAnAccountInBothLanguages() {
    let ru = environment(.russian)
    let pair = AccountForecastText.pair(mainLine, showsCurrency: false, ru)
    XCTAssertNil(pair.header, "one currency: no header")
    XCTAssertEqual(pair.middle, "≈\u{00A0}132,900\u{00A0}₽")
    XCTAssertEqual(pair.range, "от 129,300\u{00A0}₽ до 135,300\u{00A0}₽")
    let percent = ru.money.percent(basisPoints: 6_000, fractionDigits: 0)
    XCTAssertEqual(
      pair.breakdown,
      [
        AccountForecastText.Row(label: "Сейчас", value: "47,000\u{00A0}₽"),
        AccountForecastText.Row(
          label: "Уже записано на следующие дни", value: "−5,000\u{00A0}₽"),
        AccountForecastText.Row(label: "Ожидаемые поступления", value: "+100,000\u{00A0}₽"),
        AccountForecastText.Row(label: "Платежи и подписки", value: "−1,900\u{00A0}₽"),
        AccountForecastText.Row(
          label: "Повседневные траты (\(percent) всех трат)", value: "≈\u{00A0}−7,200\u{00A0}₽"),
      ], "the debts are zero and left out")
    XCTAssertEqual(pair.notes, [])
    XCTAssertEqual(
      pair.spoken, "RUB, примерно 132,900\u{00A0}₽, от 129,300\u{00A0}₽ до 135,300\u{00A0}₽")
    XCTAssertEqual(
      AccountForecastText.title(through: DateOnly(year: 2026, month: 9, day: 30), ru),
      "Прогноз остатка на 30 сентября")

    let en = environment(.english)
    let english = AccountForecastText.pair(mainLine, showsCurrency: true, en)
    XCTAssertEqual(english.header, "RUB")
    XCTAssertEqual(english.range, "from 129,300\u{00A0}₽ to 135,300\u{00A0}₽")
    XCTAssertEqual(english.breakdown.first?.label, "Now")
    XCTAssertEqual(english.breakdown.last?.label, "Day-to-day spending (60% of all spending)")
    XCTAssertEqual(
      AccountForecastText.title(through: DateOnly(year: 2026, month: 9, day: 30), en),
      "Balance forecast for September 30")
    ru.language.choice = .russian
  }

  /// Money that leaves without being my spending — what counts keep finding missing, what is
  /// paid for others less money back — has a line each, estimated, after the debts and before
  /// the day-to-day spending; a line of nothing is left out.
  func testCountLossesAndSpendingForOthersHaveTheirLines() {
    var line = mainLine
    line.flows.debts = whole(3_000)
    line.flows.reconcileLoss = whole(110)
    line.flows.othersSpending = whole(220)
    let ru = environment(.russian)
    let rows = AccountForecastText.pair(line, showsCurrency: false, ru).breakdown
    XCTAssertEqual(
      Array(rows.dropFirst(4).dropLast()),
      [
        AccountForecastText.Row(label: "Платежи по долгам", value: "−3,000\u{00A0}₽"),
        AccountForecastText.Row(
          label: "Потери сверки (по темпу)", value: "≈\u{00A0}−110\u{00A0}₽"),
        AccountForecastText.Row(
          label: "Траты за других минус возвраты (по темпу)", value: "≈\u{00A0}−220\u{00A0}₽"),
      ])
    XCTAssertTrue(rows.last?.label.hasPrefix("Повседневные траты") ?? false)

    let en = environment(.english)
    let english = AccountForecastText.pair(line, showsCurrency: false, en).breakdown.map(\.label)
    XCTAssertTrue(english.contains("Count losses (at the pace)"), "\(english)")
    XCTAssertTrue(
      english.contains("Spending for others less money back (at the pace)"), "\(english)")
    en.language.choice = .russian

    var onlyOne = mainLine
    onlyOne.flows.othersSpending = whole(220)
    let labels = AccountForecastText.pair(onlyOne, showsCurrency: false, ru).breakdown.map(\.label)
    XCTAssertFalse(labels.contains("Потери сверки (по темпу)"), "a loss of nothing is left out")
    XCTAssertTrue(labels.contains("Траты за других минус возвраты (по темпу)"))
  }

  /// Never counted, no rate for the currency, flows left out for want of a rate, a salary that
  /// did not come, a balance that may go below zero, a short history: each is said in words
  /// with a symbol of its own.
  func testWhatTheCardSaysBesideTheFigure() {
    let ru = environment(.russian)
    let usd = BalanceKey(accountId: freedom.id, currency: .usd)
    let never = AccountForecast.Line(
      flows: AccountMonthPlan.Flows(key: usd, account: freedom, now: nil), status: .notCounted)
    let notCounted = AccountForecastText.pair(never, showsCurrency: true, ru)
    XCTAssertNil(notCounted.middle)
    XCTAssertEqual(notCounted.breakdown, [])
    XCTAssertEqual(
      notCounted.notes,
      [AccountForecastText.Note(symbol: "hourglass", text: "Ещё не сверен — прогноза нет")])

    let tenge = BalanceKey(accountId: freedom.id, currency: CurrencyCode("KZT"))
    let noRate = AccountForecast.Line(
      flows: AccountMonthPlan.Flows(key: tenge, account: freedom, now: whole(140_000)),
      status: .noRate(CurrencyCode("KZT")))
    XCTAssertEqual(
      AccountForecastText.pair(noRate, showsCurrency: true, ru).notes,
      [
        AccountForecastText.Note(
          symbol: "exclamationmark.octagon", text: "Нет курса KZT — траты не пересчитать")
      ])

    var troubled = mainLine
    troubled.flows.withoutRate = [.eur]
    troubled.flows.overdueIncome = [
      AccountMonthPlan.OverdueIncome(
        expectationId: UUID(), name: "Salary", due: DateOnly(year: 2026, month: 9, day: 25),
        remaining: whole(100_000), currency: .rub)
    ]
    troubled.balance = band(-6_500, -5_000, -4_000)
    troubled.mayGoNegative = true
    let notes = AccountForecastText.pair(troubled, showsCurrency: false, ru).notes
    XCTAssertEqual(
      notes,
      [
        AccountForecastText.Note(
          symbol: "exclamationmark.circle", text: "Без курса, не учтено: EUR"),
        AccountForecastText.Note(
          symbol: "questionmark.circle", text: "Ожидалось 25 сентября — не пришло?"),
        AccountForecastText.Note(
          symbol: "exclamationmark.triangle", text: "К концу месяца может уйти в минус"),
      ])
    XCTAssertEqual(
      AccountForecastText.lowDataNote(ru),
      AccountForecastText.Note(symbol: "hourglass", text: "Истории пока мало: интервал широкий"))

    let en = environment(.english)
    XCTAssertEqual(
      AccountForecastText.pair(troubled, showsCurrency: false, en).notes.map(\.text),
      [
        "No rate, left out: EUR", "Expected on September 25 — not in yet?",
        "May go below zero by the end of the month",
      ])
    en.language.choice = .russian

    // A salary and a bonus both due on the 25th: the remark names only the day, so the day is
    // asked about once; another day is asked about on its own line.
    var twoOnOneDay = mainLine
    twoOnOneDay.flows.overdueIncome = [
      AccountMonthPlan.OverdueIncome(
        expectationId: UUID(), name: "Salary", due: DateOnly(year: 2026, month: 9, day: 25),
        remaining: whole(100_000), currency: .rub),
      AccountMonthPlan.OverdueIncome(
        expectationId: UUID(), name: "Bonus", due: DateOnly(year: 2026, month: 9, day: 25),
        remaining: whole(20_000), currency: .rub),
      AccountMonthPlan.OverdueIncome(
        expectationId: UUID(), name: "Rent", due: DateOnly(year: 2026, month: 9, day: 26),
        remaining: whole(30_000), currency: .rub),
    ]
    let asked = AccountForecastText.pair(twoOnOneDay, showsCurrency: false, ru).notes
    XCTAssertEqual(
      asked.map(\.text),
      ["Ожидалось 25 сентября — не пришло?", "Ожидалось 26 сентября — не пришло?"])
    XCTAssertEqual(Set(asked).count, asked.count, "no two remarks alike")
  }

  /// A currency the account does not hold is shown only once it was counted; one figure for a
  /// whole range says no interval.
  func testWhichCurrenciesAreShown() {
    let ru = environment(.russian)
    let held = BalanceKey(accountId: freedom.id, currency: CurrencyCode("KZT"))
    let stray = BalanceKey(accountId: freedom.id, currency: .rub)
    var flat = mainLine
    flat.flows.key = held
    flat.flows.account = freedom
    flat.balance = band(151_000, 151_000, 151_000)
    let lines = [
      flat,
      AccountForecast.Line(
        flows: AccountMonthPlan.Flows(key: stray, account: freedom, isHeld: false, now: nil),
        status: .notCounted),
    ]
    let pairs = AccountForecastText.pairs(lines, ru)
    XCTAssertEqual(pairs.count, 1, "a currency not held and never counted is not shown")
    XCTAssertNil(pairs.first?.header)
    XCTAssertNil(pairs.first?.range, "no interval when the three figures are one")
    let figure = ru.money.rounded(whole(151_000), currency: CurrencyCode("KZT"))
    XCTAssertEqual(pairs.first?.spoken, "KZT, примерно \(figure)", "the figure is said once")

    let en = environment(.english)
    XCTAssertEqual(
      AccountForecastText.pairs(lines, en).first?.spoken,
      "KZT, about \(en.money.rounded(whole(151_000), currency: CurrencyCode("KZT")))")
    en.language.choice = .russian
  }

  /// The balances grid of Analytics: VoiceOver hears each account once, as text, with the
  /// whole line — not once per column, and not as an element of no kind. Read from the
  /// accessibility tree the window builds; a runner without an assistive client builds none.
  func testEachAccountOfTheBalancesGridIsHeardOnce() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let environment = AppEnvironment()
    let before = environment.language.choice
    environment.language.choice = .russian
    defer { environment.language.choice = before }
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))

    var tenge = mainLine
    tenge.flows.key = BalanceKey(accountId: freedom.id, currency: CurrencyCode("KZT"))
    tenge.flows.account = freedom
    tenge.balance = band(146_500, 151_000, 154_000)
    tenge.balanceRub = band(29_300, 30_200, 30_800)
    let forecast = AccountForecast(
      through: DateOnly(year: 2026, month: 9, day: 30),
      computedFor: DateOnly(year: 2026, month: 9, day: 19), lowData: false,
      sections: [
        AccountForecast.Section(
          group: nil, inSummary: true, lines: [mainLine, tenge],
          totalRub: band(158_600, 163_100, 166_100), withoutRate: [])
      ],
      inSummaryTotalRub: band(158_600, 163_100, 166_100), unanchored: [])
    let spoken = AccountBalancesForecastText.rows(forecast, environment).compactMap { row in
      if case .line(let line) = row.kind { return line.spoken }
      return nil
    }
    XCTAssertEqual(spoken.count, 2)

    let window = NSWindow(
      contentViewController: NSHostingController(
        rootView: AccountBalancesForecastView(forecast: forecast)
          .padding()
          .frame(width: 640)
          .appDependencies(deps)))
    window.setContentSize(CGSize(width: 640, height: 240))
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    defer { window.close() }

    var heard: [(spoken: String, role: String)] = []
    let deadline = Date().addingTimeInterval(5)
    repeat {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      heard = Self.everything(in: window).map {
        (Self.spoken($0), Self.attribute($0, "accessibilityRole") as? String ?? "")
      }
    } while !spoken.allSatisfy({ line in heard.contains { $0.spoken.contains(line) } })
      && Date() < deadline

    for line in spoken {
      let carriers = heard.filter { $0.spoken.contains(line) }
      XCTAssertEqual(carriers.count, 1, "«\(line)» is heard \(carriers.count) times: \(carriers)")
      XCTAssertEqual(
        carriers.first?.role, NSAccessibility.Role.staticText.rawValue,
        "«\(line)» is heard as \(carriers.map(\.role))")
    }
  }

  /// Every element of the window's accessibility tree, in the order VoiceOver reads them.
  private static func everything(in window: NSWindow) -> [NSObject] {
    var found: [NSObject] = []
    func walk(_ element: Any, depth: Int) {
      guard depth < 60, let object = element as? NSObject else { return }
      found.append(object)
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] {
        walk(child, depth: depth + 1)
      }
    }
    if let root = window.contentView { walk(root, depth: 0) }
    return found
  }

  private static func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  /// What VoiceOver says for an element: its label, its title and its value.
  private static func spoken(_ object: NSObject) -> String {
    ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
      .compactMap { attribute(object, $0) as? String }
      .filter { !$0.isEmpty }
      .joined(separator: " | ")
  }

  /// The data step builds the plan with the snapshot, and the card finds the account's lines
  /// in it; an account never counted has nothing to forecast from.
  func testTheSnapshotCarriesThePlanOfTheAccounts() throws {
    let today = DateOnly(year: 2026, month: 9, day: 19)
    let counted = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 10))
    let reconciliation = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 10), reconciledAt: counted,
      actualTotalRubE4: .zero, kind: .accounts)
    let count = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: main.id, currency: .rub,
      actualE4: whole(50_000))
    let dataset = Dataset(
      paymentMethods: [main, freedom],
      planning: PlanningBook(reconciliations: [reconciliation], reconciledBalances: [count]))
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: .utc, today: today, context: SnapshotContext(),
      version: DataVersion(load: 1), now: CalendarContext.utc.startOfDay(today))
    XCTAssertEqual(snapshot.accountPlan.through, DateOnly(year: 2026, month: 9, day: 30))
    let remainder = MonthForecast.Remainder(
      p10: whole(1_000), middle: whole(2_000), p90: whole(3_000), lowData: true,
      computedFor: today, daysLeft: 11, windowDays: 0)
    let forecast = snapshot.accountPlan.forecast(remainder: remainder)
    let model = AccountForecastModel(forecast: forecast, accountId: main.id)
    XCTAssertTrue(model.hasForecast)
    XCTAssertTrue(model.lowData)
    XCTAssertEqual(model.lines.first?.balance, band(47_000, 48_000, 49_000))
    XCTAssertFalse(AccountForecastModel(forecast: forecast, accountId: freedom.id).hasForecast)
  }
}

/// «На счёт» of an expected income: the choice is kept, and an empty one means «as last time,
/// else the main account».
@MainActor
final class ExpectedIncomeAccountTests: XCTestCase {
  private let main = PaymentMethod(name: "Main", currency: .rub, isDefault: true)
  private let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))

  /// What «Сохранить» writes — the form's income made ready to save, one-off or recurring —
  /// keeps the account picked in «На счёт», and none when the first choice is left.
  func testTheSavedIncomeKeepsTheAccountPicked() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)
    let store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer), references: references, planning: planning)
    for account in [main, kaspi] { try references.save(account) }
    let deps = AppDependencies(
      environment: AppEnvironment(), store: store,
      compute: ComputeStore(calendar: .utc, rebuildsInline: true))
    let actions = PlanningActions(deps)
    let today = DateOnly(year: 2026, month: 9, day: 19)

    // As the form holds them: the picker's choice in `paymentMethodId`, the kind and the dates
    // as picked; the recurring ones on the last day of the month, as the switch leaves them.
    var incomes: [(income: ExpectedIncome, lastDay: Bool)] = []
    for (name, account) in [("Bonus", kaspi.id), ("Gift", nil)] as [(String, UUID?)] {
      var oneOff = ExpectedIncomeForm.newIncome(defaultCurrency: .rub, today: today)
      oneOff.name = name
      oneOff.totalE4 = AmountE4(whole: 5_000)
      oneOff.paymentMethodId = account
      incomes.append((oneOff, false))
    }
    for (name, account) in [("Salary", kaspi.id), ("Rent", nil)] as [(String, UUID?)] {
      var recurring = ExpectedIncomeForm.newIncome(defaultCurrency: .rub, today: today)
      recurring.name = name
      recurring.kind = .recurring
      recurring.totalE4 = AmountE4(whole: 100_000)
      recurring.dueDate = DateOnly(year: 2026, month: 9, day: 30)
      recurring.paymentMethodId = account
      incomes.append((recurring, true))
    }
    for (income, lastDay) in incomes {
      XCTAssertTrue(
        actions.save(income.readyToSave(today: today, lastDay: income.offersLastDay && lastDay)),
        income.name)
    }

    let stored = Dictionary(uniqueKeysWithValues: try planning.expected().map { ($0.name, $0) })
    XCTAssertEqual(stored["Bonus"]?.paymentMethodId, .some(kaspi.id), "one-off, an account")
    XCTAssertEqual(stored["Gift"]?.paymentMethodId, .some(nil), "one-off, as last time")
    XCTAssertEqual(stored["Salary"]?.paymentMethodId, .some(kaspi.id), "recurring, an account")
    XCTAssertEqual(stored["Rent"]?.paymentMethodId, .some(nil), "recurring, as last time")
    XCTAssertEqual(stored["Salary"]?.freq, .monthly, "saved as the form saves it")
    XCTAssertEqual(stored["Salary"]?.day, 31)
    XCTAssertNil(stored["Bonus"]?.freq)
  }

  /// The first choice leaves it open; then the live accounts, the main one first; an account
  /// archived since it was chosen stays in the list.
  func testTheChoicesStartWithAsLastTime() {
    let archived = PaymentMethod(name: "Old", currency: .rub, archived: true)
    let accounts = [kaspi, archived, main]
    let options = ExpectedIncomeAccounts.options(
      accounts, selection: nil, auto: "auto", locale: Locale(identifier: "ru"))
    XCTAssertEqual(options.map(\.id), [nil, main.id, kaspi.id])
    XCTAssertEqual(options.first?.title, "auto")
    let kept = ExpectedIncomeAccounts.options(
      accounts, selection: archived.id, auto: "auto", locale: Locale(identifier: "ru"))
    XCTAssertEqual(kept.map(\.id), [nil, main.id, kaspi.id, archived.id])

    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in ["form.toAccount", "form.toAccount.auto"] {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key, "\(choice) \(key)")
      }
    }
    environment.language.choice = .russian
  }
}
