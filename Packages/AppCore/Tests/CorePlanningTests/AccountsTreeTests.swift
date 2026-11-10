import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// «Настройки → Счета» as one tree, built the way the design draws it: «Деньги» with Сбер
/// (Дебетовый and its card), Т-Банк (Дебетовая and two cards) and «Наличные» alone; «Накопления»
/// left out of the summary with Сбер again; «Кредитки»; an account of no group; a hidden one.
@Suite("The tree of the accounts")
struct AccountsTreeTests {
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "7EE00000-0000-0000-0000-%012d", number))!
  }
  static func rub(_ units: Int64) -> AmountE4 { AmountE4(raw: units * 10_000) }

  let money = AccountGroup(id: id(1), name: "Деньги", sort: 1)
  let savings = AccountGroup(id: id(2), name: "Накопления", inSummary: false, sort: 2)
  let credit = AccountGroup(id: id(3), name: "Кредитки", sort: 3)
  let empty = AccountGroup(id: id(4), name: "Пустая", sort: 4)
  let sber = Bank(id: id(11), name: "Сбер")
  let tbank = Bank(id: id(12), name: "Т-Банк")
  let cashBank = Bank(id: id(13), name: "Наличные")
  let idle = Bank(id: id(14), name: "Альфа")

  var accounts: [PaymentMethod] {
    [
      PaymentMethod(
        id: Self.id(21), name: "Дебетовый", isDefault: true, groupId: money.id, sort: 1,
        bankId: sber.id),
      PaymentMethod(
        id: Self.id(22), name: "Дебетовая", groupId: money.id, sort: 2, bankId: tbank.id),
      PaymentMethod(
        id: Self.id(23), name: "Наличные", kind: .cash, groupId: money.id, sort: 3,
        bankId: cashBank.id),
      PaymentMethod(
        id: Self.id(24), name: "Накопительный", kind: .account, groupId: savings.id, sort: 4,
        bankId: sber.id),
      PaymentMethod(
        id: Self.id(25), name: "Кредитка", groupId: credit.id, sort: 5, bankId: tbank.id),
      PaymentMethod(id: Self.id(26), name: "Вклад", kind: .account, sort: 6, bankId: sber.id),
      PaymentMethod(
        id: Self.id(27), name: "Тайный", groupId: money.id, sort: 7, bankId: tbank.id,
        hidden: true),
      PaymentMethod(id: Self.id(28), name: "Старый", archived: true, bankId: sber.id),
    ]
  }

  var cards: [PaymentCard] {
    [
      PaymentCard(id: Self.id(31), accountId: Self.id(21), name: "Карта ··4821"),
      PaymentCard(id: Self.id(32), accountId: Self.id(22), name: "Карта ··7710"),
      PaymentCard(id: Self.id(33), accountId: Self.id(22), name: "Карта папы"),
    ]
  }

  var snapshot: AccountsSnapshot {
    func line(_ number: Int, _ units: Int64) -> AccountsSnapshot.AccountLine {
      let account = accounts.first { $0.id == Self.id(number) }!
      return AccountsSnapshot.AccountLine(
        account: account,
        keys: [
          AccountsSnapshot.KeyLine(
            key: BalanceKey(accountId: account.id, currency: .rub), balance: Self.rub(units),
            rub: Self.rub(units), anchorAt: nil, isHeld: true)
        ], totalRub: Self.rub(units), unknown: 0)
    }
    return AccountsSnapshot(
      sections: [
        .init(
          group: money, accounts: [line(21, 98_200), line(22, 36_200), line(23, 8_000)],
          totalRub: Self.rub(142_400), inSummary: true),
        .init(
          group: nil, accounts: [line(26, 40_000)], totalRub: Self.rub(40_000), inSummary: true),
        .init(
          group: credit, accounts: [line(25, -12_400)], totalRub: Self.rub(-12_400), inSummary: true
        ),
        .init(
          group: savings, accounts: [line(24, 40_000)], totalRub: Self.rub(40_000), inSummary: false
        ),
      ], inSummaryTotalRub: nil, unanchored: [], withoutRate: [], balances: .empty)
  }

  var tree: [AccountsTree.Node] {
    AccountsTree.build(
      accounts: accounts, groups: [money, savings, credit, empty],
      banks: [sber, tbank, cashBank, idle],
      cards: cards, snapshot: snapshot, locale: Locale(identifier: "ru"))
  }

  @Test func theGroupsComeInTheOrderOfTheSidebarThenNoGroupHiddenAndArchive() {
    #expect(
      tree.map(\.id) == [
        "g:\(money.id.uuidString)", "g:\(credit.id.uuidString)", "g:\(empty.id.uuidString)",
        "g:\(savings.id.uuidString)", "g:none", "hidden", "archive",
      ])
  }

  @Test func aGroupHoldsBanksAndAnAccountNamedAsItsBankStandsAlone() throws {
    let group = try #require(tree.first)
    #expect(group.amount == Self.rub(142_400))
    #expect(group.children.map(\.name) == ["Сбер", "Т-Банк", "Наличные"])
    #expect(group.children[2].account?.id == Self.id(23))
    let tBank = group.children[1]
    #expect(tBank.amount == Self.rub(36_200))
    #expect(tBank.children.map(\.name) == ["Дебетовая"])
    #expect(tBank.children[0].amount == Self.rub(36_200))
    #expect(tBank.children[0].currency == .rub)
    #expect(tBank.children[0].children.count == 2)
  }

  @Test func oneBankUnderTwoGroupsHasTwoRowsOfItsOwn() {
    let rows = AccountsTree.rows(tree, collapsed: [])
    let sberRows = rows.filter { $0.node.name == "Сбер" }
    #expect(sberRows.count == 3)
    #expect(Set(rows.map(\.id)).count == rows.count, "no two rows share an id")
  }

  @Test func noGroupHoldsTheLooseAccountsAndTheIdleBanks() throws {
    let none = try #require(tree.first { $0.id == "g:none" })
    #expect(none.children.map(\.name) == ["Сбер", "Альфа"])
    #expect(none.amount == Self.rub(40_000))
    #expect(tree.first { $0.id == "hidden" }?.children.map(\.name) == ["Тайный"])
    #expect(tree.first { $0.id == "archive" }?.children.map(\.name) == ["Старый"])
  }

  @Test func theDepthsFollowTheTreeAndFoldingHidesTheChildren() {
    let rows = AccountsTree.rows(tree, collapsed: AccountsTree.foldedAtFirst)
    let names = rows.prefix(8).map { "\($0.depth) \($0.node.name)" }
    #expect(
      names == [
        "0 Деньги", "1 Сбер", "2 Дебетовый", "3 Карта ··4821", "1 Т-Банк", "2 Дебетовая",
        "3 Карта ··7710", "3 Карта папы",
      ])
    #expect(rows.first { $0.id == "hidden" }?.isFolded == true)
    #expect(!rows.contains { $0.node.name == "Тайный" })
    let folded = AccountsTree.rows(tree, collapsed: ["g:\(money.id.uuidString)"])
    #expect(folded.first?.isFolded == true)
    #expect(folded[1].node.name == "Кредитки")
    let all = AccountsTree.folders(tree)
    #expect(AccountsTree.rows(tree, collapsed: all).allSatisfy { $0.depth == 0 })
  }

  @Test func theSearchKeepsTheMatchAndWhatIsAboveItUnfolded() {
    let rows = AccountsTree.rows(tree, collapsed: AccountsTree.folders(tree), query: "папы")
    #expect(rows.map(\.node.name) == ["Деньги", "Т-Банк", "Дебетовая", "Карта папы"])
    let bank = AccountsTree.rows(tree, collapsed: [], query: "т-банк")
    #expect(bank.contains { $0.node.name == "Карта ··7710" }, "under a match everything shows")
    #expect(AccountsTree.rows(tree, collapsed: [], query: "нет такого").isEmpty)
  }

  @Test func aDropTakesTheGroupOfTheRowAboveAndTheOrderOfTheRows() throws {
    let rows = AccountsTree.rows(tree, collapsed: AccountsTree.foldedAtFirst)
    let source = try #require(rows.firstIndex { $0.node.account?.id == Self.id(26) })
    // Under «Кредитки», right after «Кредитка».
    let credit = try #require(rows.firstIndex { $0.node.account?.id == Self.id(25) })
    let drop = try #require(AccountsTree.drop(rows, from: source, to: credit + 1))
    #expect(drop.accountId == Self.id(26))
    #expect(drop.groupId == self.credit.id)
    let placed = try #require(drop.order.firstIndex(of: Self.id(26)))
    #expect(drop.order[placed - 1] == Self.id(25))
    // Into the hidden ones: not a place for an account.
    let hidden = try #require(rows.firstIndex { $0.id == "hidden" })
    #expect(AccountsTree.drop(rows, from: source, to: hidden + 1) == nil)
    // A card is not dragged.
    let card = try #require(rows.firstIndex { $0.node.name == "Карта папы" })
    #expect(AccountsTree.drop(rows, from: card, to: 0) == nil)
    // To the top: the first group.
    let top = try #require(AccountsTree.drop(rows, from: source, to: 1))
    #expect(top.groupId == money.id)
    #expect(top.order.first == Self.id(26))
  }

  /// While the hidden accounts are covered the tree shows no balance of theirs, and a group
  /// whose total holds their money is marked, so the gap is never read as an amount.
  @Test func aCoveredHiddenAccountShowsNoMoneyAndItsGroupIsMarked() throws {
    var book = snapshot
    let hiddenLine = AccountsSnapshot.AccountLine(
      account: accounts.first { $0.id == Self.id(27) }!,
      keys: [
        AccountsSnapshot.KeyLine(
          key: BalanceKey(accountId: Self.id(27), currency: .rub), balance: Self.rub(5_000),
          rub: Self.rub(5_000), anchorAt: nil, isHeld: true)
      ], totalRub: Self.rub(5_000), unknown: 0)
    book.sections[0].accounts.append(hiddenLine)
    book.sections[0].totalRub = Self.rub(147_400)
    let covered = HiddenAccounts(ids: [Self.id(27)]).cover(book)
    let nodes = AccountsTree.build(
      accounts: accounts, groups: [money, savings, credit, empty],
      banks: [sber, tbank, cashBank, idle], cards: cards, snapshot: covered.snapshot,
      partHidden: covered.sectionsWithHiddenPart, locale: Locale(identifier: "ru"))
    let group = try #require(nodes.first)
    #expect(group.partHidden)
    #expect(!nodes.contains { $0.partHidden && $0.id != group.id })
    let hidden = try #require(nodes.first { $0.id == "hidden" })
    #expect(hidden.children.map(\.name) == ["Тайный"])
    #expect(hidden.children[0].amount == nil, "no balance of a covered account")
  }
}
