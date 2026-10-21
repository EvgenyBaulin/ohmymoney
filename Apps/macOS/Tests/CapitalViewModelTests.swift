import AppCore
import XCTest

@testable import OhMyMoney

/// What «Капитал» lays out from a snapshot of the core built by hand: the header's change and
/// the month it counts from, the blocks of the two columns in their order, the share of every
/// row of its column, the warnings, and the credit card kept both as an account below zero and
/// as a debt.
@MainActor
final class CapitalViewModelTests: XCTestCase {
  private let sber = UUID()
  private let deposit = UUID()
  private let dacha = UUID()
  private let dachaGroup = UUID()
  private let car = UUID()
  private let flat = UUID()
  private let laptop = UUID()
  private let anya = UUID()
  private let mortgage = UUID()
  private let card = UUID()
  private let tinkoff = UUID()

  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  private func line(
    _ source: CapitalLine.Source, _ group: CapitalLine.Group, _ name: String, _ whole: Int64?,
    groupId: UUID? = nil, kind: AssetKind? = nil, issue: CapitalLine.Issue? = nil,
    currency: CurrencyCode = .rub
  ) -> CapitalLine {
    CapitalLine(
      source: source, group: group, name: name, currency: currency,
      amount: whole.map { rub($0) }, amountRub: issue == nil ? whole.map { rub($0) } : nil,
      accountGroupId: groupId, assetKind: kind, issue: issue)
  }

  private var snapshot: CapitalSnapshot {
    let have = [
      line(.asset(car), .assets, "Машина", 1_000_000, kind: .vehicle),
      line(.account(sber), .accounts, "Сбер", 300_000),
      line(.account(tinkoff), .accounts, "Тинькофф Platinum", -50_000),
      line(.account(deposit), .deposits, "Вклад", 500_000),
      line(.account(dacha), .outOfSummary, "Касса дачи", 100_000, groupId: dachaGroup),
      line(.asset(flat), .assets, "Квартира", 2_000_000, kind: .realty),
      line(.asset(laptop), .assets, "Ноутбук", nil, kind: .equipment, issue: .unvalued),
      line(.debt(anya), .owedToMe, "Аня", 100_000),
      line(.account(UUID()), .accounts, "Wise", nil, issue: .withoutRate, currency: .usd),
    ]
    let owe = [
      line(.debt(mortgage), .iOwe, "Ипотека", 1_500_000),
      line(.debt(card), .iOwe, "Тинькофф platinum", 50_000),
    ]
    let end = CapitalPoint(day: DateOnly(year: 2026, month: 9, day: 30), isNow: false)
    let now = CapitalPoint(
      day: DateOnly(year: 2026, month: 10, day: 11), isNow: true, accountsRub: rub(250_000),
      depositsRub: rub(500_000), outOfSummaryRub: rub(100_000), assetsRub: rub(3_000_000),
      owedToMeRub: rub(100_000), iOweRub: rub(1_550_000))
    return CapitalSnapshot(
      points: [end, now], now: now, breakdown: CapitalBreakdown(have: have, owe: owe),
      changeThisMonth: rub(85_000))
  }

  private var model: CapitalViewModel {
    CapitalViewModel(
      capital: snapshot,
      accountGroups: [AccountGroup(id: dachaGroup, name: "Дача", inSummary: false)],
      debts: [
        Debt(id: card, direction: .iOwe, type: .creditCard, name: "Тинькофф platinum"),
        Debt(id: mortgage, direction: .iOwe, type: .loan, name: "Ипотека"),
      ])
  }

  func testTheHeader() {
    let model = model
    XCTAssertEqual(model.net, rub(2_400_000))
    XCTAssertEqual(model.have, rub(3_950_000))
    XCTAssertEqual(model.owe, rub(1_550_000))
    XCTAssertEqual(model.change, rub(85_000))
    XCTAssertEqual(model.sinceMonth, MonthKey(year: 2026, month: 9))
    XCTAssertEqual(CapitalText.arrow(of: rub(85_000)), "arrow.up.right")
    XCTAssertEqual(CapitalText.arrow(of: rub(-1)), "arrow.down.right")
    XCTAssertEqual(CapitalText.arrow(of: AmountE4(raw: 4_000)), "arrow.right", "0.40 ₽ is level")

    var unknown = snapshot
    unknown.changeThisMonth = nil
    XCTAssertNil(CapitalViewModel(capital: unknown).sinceMonth, "a month without a change")
  }

  func testTheBlocksInTheirOrder() {
    let groups = model.haveGroups
    XCTAssertEqual(
      groups.map(\.id),
      [
        "accounts", "deposits", "outOfSummary.\(dachaGroup.uuidString)", "assets.vehicle",
        "assets.realty", "assets.equipment", "owedToMe",
      ])
    XCTAssertEqual(groups[0].rows.map(\.line.name), ["Сбер", "Тинькофф Platinum", "Wise"])
    XCTAssertEqual(groups[0].totalRub, rub(250_000), "a row without a rate added to the total")
    XCTAssertEqual(groups[2].accountGroupName, "Дача")
    XCTAssertEqual(model.oweGroups.map(\.kind), [.iOwe])
    XCTAssertEqual(model.oweGroups[0].totalRub, rub(1_550_000))
    XCTAssertFalse(model.isEmpty)
    XCTAssertTrue(CapitalViewModel(capital: .empty).isEmpty)
  }

  /// The shares of a column add up to 100 %; a row that adds nothing or is below zero has none.
  func testTheSharesOfAColumn() {
    let rows = model.haveGroups.flatMap(\.rows)
    XCTAssertEqual(rows.compactMap(\.shareBp).reduce(0, +), Shares.whole)
    XCTAssertNil(rows.first { $0.line.name == "Ноутбук" }?.shareBp)
    XCTAssertNil(rows.first { $0.line.name == "Wise" }?.shareBp)
    XCTAssertNil(rows.first { $0.line.name == "Тинькофф Platinum" }?.shareBp)
    // 2,000,000 of the 4,000,000 that is above zero.
    XCTAssertEqual(rows.first { $0.line.name == "Квартира" }?.shareBp, 5_000)
    XCTAssertEqual(model.oweGroups[0].rows.compactMap(\.shareBp).reduce(0, +), Shares.whole)
  }

  func testTheWarnings() {
    XCTAssertEqual(
      model.warnings,
      [
        CapitalViewModel.Warning(issue: .withoutRate, names: ["Wise"]),
        CapitalViewModel.Warning(issue: .unvalued, names: ["Ноутбук"]),
      ])
  }

  /// A credit card debt named as an account below zero, letter case aside, is a hint; a loan of
  /// such a name is not.
  func testTheCreditCardCountedTwice() {
    XCTAssertEqual(model.countedTwice, ["Тинькофф platinum"])
    let loan = CapitalViewModel(
      capital: snapshot,
      debts: [Debt(id: card, direction: .iOwe, type: .loan, name: "Тинькофф platinum")])
    XCTAssertEqual(loan.countedTwice, [])
  }

  func testTheWordsOfTheHeaderInBothLanguages() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    XCTAssertEqual(
      CapitalText.since(MonthKey(year: 2026, month: 9), environment), "с конца сентября")
    XCTAssertEqual(
      CapitalText.t(CapitalText.kindKey(.vehicle), environment), "Транспорт")
    environment.language.choice = .english
    XCTAssertEqual(
      CapitalText.since(MonthKey(year: 2026, month: 9), environment), "since the end of September")
    for month in 1...12 {
      XCTAssertFalse(
        CapitalText.since(MonthKey(year: 2026, month: month), environment).hasPrefix("capital."),
        "no words for month \(month)")
    }
    for kind in AssetKind.allCases {
      XCTAssertFalse(CapitalText.t(CapitalText.kindKey(kind), environment).hasPrefix("capital."))
    }
  }
}
