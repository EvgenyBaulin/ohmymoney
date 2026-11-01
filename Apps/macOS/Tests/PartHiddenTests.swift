import AppCore
import XCTest

@testable import OhMyMoney

/// «часть скрыта» beside a total that holds money of a hidden account, while the hidden accounts
/// are covered: the screen of «Всего» or of a group, and the money tiles of Overview. The figure
/// keeps all the money and the note never says how much.
@MainActor
final class PartHiddenTests: XCTestCase {
  private let open = PaymentMethod(name: "Sber Main", isDefault: true)
  private let secret: PaymentMethod = {
    var account = PaymentMethod(name: "Vault")
    account.hidden = true
    return account
  }()
  private let group = AccountGroup(name: "Savings")

  private func line(_ account: PaymentMethod, rub: Int64) -> AccountsSnapshot.AccountLine {
    AccountsSnapshot.AccountLine(
      account: account, keys: [], totalRub: AmountE4(whole: rub), unknown: 0)
  }

  /// The accounts of no group (the open one) and a group that holds the hidden one beside it.
  private var accounts: AccountsSnapshot {
    AccountsSnapshot(
      sections: [
        .init(
          group: nil, accounts: [line(open, rub: 100)], totalRub: AmountE4(whole: 100),
          inSummary: true),
        .init(
          group: group, accounts: [line(open, rub: 10), line(secret, rub: 40)],
          totalRub: AmountE4(whole: 50), inSummary: true),
      ],
      inSummaryTotalRub: AmountE4(whole: 150), unanchored: [], withoutRate: [],
      balances: .empty)
  }

  private var covered: CoveredAccounts {
    HiddenAccounts(accounts: [open, secret]).cover(accounts)
  }

  // MARK: The screen of a group

  func testTheScreenOfAllAccountsAndOfTheGroupSayPartHidden() {
    XCTAssertTrue(GroupScope.summary.isPartHidden(covered))
    XCTAssertTrue(GroupScope.group(group.id).isPartHidden(covered))
    XCTAssertFalse(GroupScope.group(UUID()).isPartHidden(covered))
    // The figure keeps all the money.
    let summary = GroupScope.summary.content(in: covered.snapshot)
    XCTAssertEqual(summary?.totalRub, AmountE4(whole: 150))
    let shown = GroupScope.group(group.id).content(in: covered.snapshot)
    XCTAssertEqual(shown?.totalRub, AmountE4(whole: 50))
    XCTAssertEqual(shown?.accounts.map(\.account.id), [open.id])
  }

  func testRevealedNothingIsSaid() {
    XCTAssertFalse(GroupScope.summary.isPartHidden(nil))
    XCTAssertFalse(GroupScope.group(group.id).isPartHidden(nil))
    let nothingHidden = HiddenAccounts(ids: [UUID]()).cover(accounts)
    XCTAssertFalse(GroupScope.summary.isPartHidden(nothingHidden))
  }

  // MARK: Overview

  func testTheMoneyTilesSayPartHiddenWhileCovered() {
    for tile in [OverviewTile.freeMoney, .balanceForecast, .currencyBalances] {
      XCTAssertTrue(OverviewPartHidden.shows(tile, covered: covered), "\(tile)")
      XCTAssertFalse(OverviewPartHidden.shows(tile, covered: nil), "\(tile) revealed")
    }
    XCTAssertFalse(OverviewPartHidden.shows(.monthToDate, covered: covered))
    XCTAssertFalse(OverviewPartHidden.shows(.topCategories, covered: covered))
  }

  func testAHiddenAccountOutOfTheSummaryMarksNoTile() {
    let outside = AccountsSnapshot(
      sections: [
        .init(
          group: nil, accounts: [line(open, rub: 100)], totalRub: AmountE4(whole: 100),
          inSummary: true),
        .init(
          group: group, accounts: [line(secret, rub: 40)], totalRub: AmountE4(whole: 40),
          inSummary: false),
      ],
      inSummaryTotalRub: AmountE4(whole: 100), unanchored: [], withoutRate: [],
      balances: .empty)
    let marks = HiddenAccounts(accounts: [open, secret]).cover(outside)
    XCTAssertFalse(OverviewPartHidden.shows(.freeMoney, covered: marks))
  }

  func testTheHeroSaysItAfterItsLine() {
    XCTAssertEqual(OverviewHero.line("a day", partHidden: "part hidden"), "a day · part hidden")
    XCTAssertEqual(OverviewHero.line(nil, partHidden: "part hidden"), "part hidden")
    XCTAssertEqual(OverviewHero.line("a day", partHidden: nil), "a day")
  }

  func testTheBalanceForecastAddsUpTheHiddenAccountToo() {
    var dataset = Dataset()
    dataset.paymentMethods = [open, secret]
    let whole = DataSnapshot.build(
      dataset: dataset, calendar: .system, today: DateOnly(year: 2026, month: 11, day: 1),
      context: SnapshotContext(), version: DataVersion(load: 0))
    let presented = whole.presented(hiding: HiddenAccounts(accounts: dataset.paymentMethods))
    let english = Locale(identifier: "en_US")
    XCTAssertTrue(
      BalanceForecastCard.summaryAccountIds(of: whole, locale: english).contains(secret.id),
      "the tile reads the whole snapshot")
    XCTAssertFalse(
      BalanceForecastCard.summaryAccountIds(of: presented, locale: english).contains(secret.id),
      "a presented snapshot would leave its money out of the total")
  }

  func testTheLastCountCardLeavesTheCountsOfAHiddenAccountOut() {
    let count = UUID()
    let balances = [
      ReconciledBalance(
        reconciliationId: count, accountId: open.id, currency: .rub,
        actualE4: AmountE4(whole: 100)),
      ReconciledBalance(
        reconciliationId: count, accountId: secret.id, currency: .rub,
        actualE4: AmountE4(whole: 40)),
    ]
    let hiding = HiddenAccounts(accounts: [open, secret])
    XCTAssertEqual(
      ReconciliationCard.visible(balances, hiding: hiding).map(\.accountId), [open.id])
    XCTAssertEqual(
      ReconciliationCard.visible(balances, hiding: HiddenAccounts(ids: [UUID]())).count, 2)
  }

  func testThePartHiddenNoteIsInBothLanguages() {
    for language in ["en", "ru"] {
      let bundle = Bundle.main.path(forResource: language, ofType: "lproj")
        .flatMap(Bundle.init(path:))
      let text = bundle?.localizedString(
        forKey: "privacy.partHidden", value: "\u{0}", table: "PrivacyScreens")
      XCTAssertNotNil(text)
      XCTAssertNotEqual(text, "\u{0}", language)
    }
  }
}
