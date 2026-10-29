import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Hidden accounts: the covered lists")
struct HiddenAccountsCoverTests {
  let fx = PrivacyFixture()
  var hidden: HiddenAccounts {
    HiddenAccounts(
      accounts: fx.dataset.paymentMethods.map { account in
        var copy = account
        copy.hidden = account.id == fx.hiddenId
        return copy
      })
  }

  private func line(_ account: PaymentMethod, rub: Int64) -> AccountsSnapshot.AccountLine {
    AccountsSnapshot.AccountLine(
      account: account, keys: [], totalRub: AmountE4(whole: rub), unknown: 0)
  }

  /// One group of two accounts (one hidden), and the accounts of no group.
  private func snapshot() -> AccountsSnapshot {
    let visible = fx.dataset.paymentMethods.first { $0.id == fx.visibleId }!
    let secret = fx.dataset.paymentMethods.first { $0.id == fx.hiddenId }!
    let group = AccountGroup(name: "Savings")
    let onlyHiddenGroup = AccountGroup(name: "Vault")
    return AccountsSnapshot(
      sections: [
        .init(
          group: nil, accounts: [line(visible, rub: 100)], totalRub: AmountE4(whole: 100),
          inSummary: true),
        .init(
          group: group, accounts: [line(visible, rub: 100), line(secret, rub: 40)],
          totalRub: AmountE4(whole: 140), inSummary: true),
        .init(
          group: onlyHiddenGroup, accounts: [line(secret, rub: 40)],
          totalRub: AmountE4(whole: 40), inSummary: false),
      ],
      inSummaryTotalRub: AmountE4(whole: 240), unanchored: [], withoutRate: [],
      balances: .empty)
  }

  @Test("the hidden lines go, every total keeps all the money")
  func totalsKeepAllTheMoney() {
    let covered = hidden.cover(snapshot())
    #expect(covered.snapshot.inSummaryTotalRub == AmountE4(whole: 240))
    #expect(
      covered.snapshot.sections.flatMap(\.accounts).allSatisfy { $0.account.id != fx.hiddenId })
    let group = covered.snapshot.sections.first { $0.group?.name == "Savings" }
    #expect(group?.totalRub == AmountE4(whole: 140))
    #expect(group?.accounts.count == 1)
  }

  @Test("a section that held only hidden accounts is dropped, its total would give them away")
  func emptySectionIsDropped() {
    let covered = hidden.cover(snapshot())
    #expect(!covered.snapshot.sections.contains { $0.group?.name == "Vault" })
  }

  @Test("«часть скрыта» marks the total and the groups that hold hidden money")
  func marks() {
    let covered = hidden.cover(snapshot())
    #expect(covered.partHidden)
    let savings = covered.snapshot.sections.first { $0.group?.name == "Savings" }!
    #expect(covered.isPartHidden(savings))
    let ungrouped = covered.snapshot.sections.first { $0.group == nil }!
    #expect(!covered.isPartHidden(ungrouped))
  }

  @Test("a hidden account left out of the summary does not mark the total")
  func outOfSummaryDoesNotMarkTheTotal() {
    var only = snapshot()
    only.sections.removeAll { $0.group?.name == "Savings" }
    let covered = hidden.cover(only)
    #expect(!covered.partHidden)
  }

  @Test("nothing hidden: the snapshot is the same and unmarked")
  func nothingHidden() {
    let none = HiddenAccounts(ids: [UUID]())
    let original = snapshot()
    let covered = none.cover(original)
    #expect(covered.snapshot == original)
    #expect(!covered.partHidden)
  }

  @Test("pickers lose the hidden accounts only while covered")
  func pickers() {
    let accounts = fx.dataset.paymentMethods
    #expect(hidden.offered(accounts, visibility: .covered).map(\.id) == [fx.visibleId])
    #expect(hidden.offered(accounts, visibility: .revealed).count == accounts.count)
  }

  @Test("the cards of hidden accounts are found")
  func cards() {
    #expect(hidden.cardIds(in: fx.dataset.cards) == [fx.hiddenCardId])
  }

  @Test("the transfer to a hidden account is told without its name")
  func transferCaption() {
    let toHidden = fx.dataset.transfers.first { $0.id == fx.outTransferId }
    #expect(toHidden.flatMap { hidden.caption(for: $0) } == .toHidden)
    #expect(HiddenAccounts.TransferCaption.toHidden.russian == "Перевод на скрытый счёт")
    for caption in [HiddenAccounts.TransferCaption.toHidden, .fromHidden, .betweenHidden] {
      #expect(!caption.russian.contains("Secret"))
      #expect(!caption.english.contains("Secret"))
    }
  }

  @Test("covered, the operations of hidden accounts and cards are in no list and no search")
  func entryFilterLeavesThemOut() {
    let ledger = Ledger(dataset: fx.dataset, calendar: .system)
    let everything = EntryFilter.none.apply(to: ledger)
    var covered = EntryFilter.none
    covered.hiddenAccountIds = [fx.hiddenId]
    covered.hiddenCardIds = [fx.hiddenCardId]
    let shown = covered.apply(to: ledger)
    #expect(shown.count < everything.count)
    #expect(!shown.contains(fx.hiddenOpId))
    #expect(everything.contains(fx.hiddenOpId))
    // It is not a criterion of the owner's: an empty filter stays empty.
    #expect(covered.isEmpty)
  }
}
