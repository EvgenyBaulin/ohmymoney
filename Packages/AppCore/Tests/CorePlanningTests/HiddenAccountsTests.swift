import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Hidden accounts")
struct HiddenAccountsTests {
  let fx = PrivacyFixture()
  var hidden: HiddenAccounts { HiddenAccounts(ids: [fx.hiddenId]) }

  @Test("the total holds all the money and says a part is hidden")
  func totals() {
    let rows = [
      (accountId: fx.visibleId, amountE4: AmountE4(whole: 100)),
      (accountId: fx.hiddenId, amountE4: AmountE4(whole: 40)),
    ]
    let total = hidden.total(rows)
    #expect(total.amountE4 == AmountE4(whole: 140))
    #expect(total.visibleE4 == AmountE4(whole: 100))
    #expect(total.hiddenE4 == AmountE4(whole: 40))
    #expect(total.partHidden)
  }

  @Test("nothing is flagged when no hidden account is in the sum")
  func notFlagged() {
    let total = hidden.total([(accountId: fx.visibleId, amountE4: AmountE4(whole: 100))])
    #expect(!total.partHidden)
    #expect(total.amountE4 == total.visibleE4)
    let none = HiddenAccounts(ids: [UUID]())
    #expect(!none.total([(accountId: fx.hiddenId, amountE4: AmountE4(whole: 1))]).partHidden)
  }

  @Test("an empty hidden account still flags the total")
  func emptyHidden() {
    let total = hidden.total([(accountId: fx.hiddenId, amountE4: .zero)])
    #expect(total.partHidden)
    #expect(total.amountE4 == .zero)
  }

  @Test("a transfer to or from a hidden account is captioned without a name")
  func captions() {
    let byId = Dictionary(uniqueKeysWithValues: fx.dataset.transfers.map { ($0.id, $0) })
    #expect(hidden.caption(for: byId[fx.outTransferId]!) == .toHidden)
    #expect(hidden.caption(for: byId[fx.inTransferId]!) == .fromHidden)
    #expect(hidden.caption(for: byId[fx.bothTransferId]!) == .betweenHidden)
    var plain = byId[fx.outTransferId]!
    plain.toAccountId = fx.visibleId
    #expect(hidden.caption(for: plain) == nil)
    for caption in [HiddenAccounts.TransferCaption.toHidden, .fromHidden, .betweenHidden] {
      #expect(!caption.russian.contains("Secret"))
      #expect(caption.key.hasPrefix("privacy.transfer."))
    }
    #expect(HiddenAccounts.TransferCaption.toHidden.russian == "Перевод на скрытый счёт")
  }

  @Test("the copy without hidden loses the accounts, their cards and operations")
  func excludes() {
    let result = hidden.exclude(from: fx.dataset)
    let d = result.dataset
    #expect(d.paymentMethods.map(\.id) == [fx.visibleId])
    #expect(d.cards.map(\.id) == [fx.visibleCardId])
    #expect(d.banks.map(\.id) == [fx.visibleBankId])
    #expect(!d.entries.contains { $0.id == fx.hiddenOpId })
    #expect(d.entries.contains { $0.id == fx.purchaseId })
    #expect(d.planning.scheduled.count == 1)
    #expect(d.planning.scheduled[0].paymentMethodId == fx.visibleId)
    #expect(d.goals[0].accountId == nil)
    #expect(d.planning.expected[0].paymentMethodId == nil)
    #expect(d.planning.debtEntries[0].paymentMethodId == nil)
    let printed = String(describing: d.paymentMethods) + String(describing: d.cards)
    #expect(!printed.contains("Secret"))
  }

  @Test("a transfer between hidden and visible becomes a nameless one-sided operation")
  func oneSided() {
    let expense = UUID()
    let income = UUID()
    let result = hidden.exclude(from: fx.dataset, reconciliation: (expense, income))
    #expect(Set(result.oneSided) == [fx.outTransferId, fx.inTransferId])
    #expect(result.dataset.transfers.isEmpty)
    let out = result.dataset.entries.first { $0.id == fx.outTransferId }!
    #expect(out.transaction.kind == .expense)
    #expect(out.transaction.paymentMethodId == fx.visibleId)
    #expect(out.transaction.amountE4 == AmountE4(whole: 1000))
    #expect(out.transaction.note == nil)
    #expect(out.parts.count == 1)
    #expect(out.parts[0].categoryId == expense)
    #expect(out.isBalanced)
    let coming = result.dataset.entries.first { $0.id == fx.inTransferId }!
    #expect(coming.transaction.kind == .income)
    #expect(coming.transaction.amountE4 == AmountE4(whole: 400))
    #expect(coming.parts[0].categoryId == income)
    #expect(!String(describing: out).contains("Marina"))
  }

  @Test("the same data gives the same copy")
  func deterministic() {
    let a = hidden.exclude(from: fx.dataset, reconciliation: (nil, nil))
    let b = hidden.exclude(from: fx.dataset, reconciliation: (nil, nil))
    #expect(a.dataset.entries == b.dataset.entries)
  }

  @Test("a foreign one-sided operation without a rate is listed")
  func foreignWithoutRate() {
    var data = fx.dataset
    data.transfers[1].toCurrency = .usd
    let without = hidden.exclude(from: data)
    #expect(without.withoutRate == [fx.inTransferId])
    let with = hidden.exclude(from: data, rubPerUnit: [.usd: 90])
    #expect(with.withoutRate.isEmpty)
    let entry = with.dataset.entries.first { $0.id == fx.inTransferId }!
    #expect(entry.transaction.amountRubE4 == AmountE4(whole: 36_000))
    #expect(!entry.transaction.rateProvisional)
  }

  @Test("nothing hidden leaves the data as it is")
  func nothingHidden() {
    let result = HiddenAccounts(ids: [UUID]()).exclude(from: fx.dataset)
    #expect(result.dataset.entries == fx.dataset.entries)
    #expect(result.oneSided.isEmpty)
  }
}
