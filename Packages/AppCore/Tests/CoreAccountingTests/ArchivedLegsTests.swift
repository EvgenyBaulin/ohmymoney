import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The question «Куда перевести остаток «Наличные»?» says every transfer it will write, not only
/// the first: the legs are told from the transfers themselves.
@Suite("The legs a settling of an archived account writes")
struct ArchivedLegsTests {
  let cash = UUID()
  let sber = UUID()
  let now = Date(timeIntervalSince1970: 1_790_000_000)
  var later: Date { now.addingTimeInterval(2 * 86_400) }

  func transfer(
    _ amount: Int64, from: UUID, to: UUID, at moment: Date, currency: CurrencyCode = .rub
  ) -> Transfer {
    Transfer(
      occurredAt: moment, fromAccountId: from, fromCurrency: currency,
      fromAmountE4: AmountE4(whole: amount), toAccountId: to, toCurrency: currency,
      toAmountE4: AmountE4(whole: amount))
  }

  /// 12,000 on «Наличные» now, the rent of 30,000 typed ahead: 12,000 go to «Сбер» now, and
  /// 30,000 come back from «Сбер» with the rent.
  @Test func moneyNowAndMoneyAheadAreTwoLegs() {
    let legs = ArchivedMoney.legs(
      of: [
        transfer(12_000, from: cash, to: sber, at: now),
        transfer(30_000, from: sber, to: cash, at: later),
      ], archived: cash, now: now)
    #expect(legs.count == 2)
    #expect(legs[0].when == .now)
    #expect(legs[0].amount == AmountE4(whole: 12_000))
    #expect(legs[0].from == cash && legs[0].to == sber)
    #expect(!legs[0].returnsToArchived)
    #expect(legs[1].when == .later)
    #expect(legs[1].at == later)
    #expect(legs[1].amount == AmountE4(whole: 30_000))
    #expect(legs[1].from == sber && legs[1].to == cash)
    #expect(legs[1].returnsToArchived)
    #expect(legs.allSatisfy { $0.currency == .rub })
  }

  @Test func oneTransferDatedNowIsOneLegNow() {
    let legs = ArchivedMoney.legs(
      of: [transfer(1_000, from: cash, to: sber, at: now)], archived: cash, now: now)
    #expect(legs.map(\.when) == [.now])
    #expect(legs.map(\.returnsToArchived) == [false])
  }

  /// Nothing to move now and the rent ahead: the only leg is dated with the rent.
  @Test func oneTransferDatedAheadIsOneLegLater() {
    let legs = ArchivedMoney.legs(
      of: [transfer(30_000, from: sber, to: cash, at: later)], archived: cash, now: now)
    #expect(legs.map(\.when) == [.later])
    #expect(legs.map(\.returnsToArchived) == [true])
  }

  /// Money typed ahead as income: the key leaves with more, later.
  @Test func moneyAheadThatLeavesTheArchivedAccountDoesNotReturnToIt() {
    let legs = ArchivedMoney.legs(
      of: [
        transfer(12_000, from: cash, to: sber, at: now),
        transfer(5_000, from: cash, to: sber, at: later),
      ], archived: cash, now: now)
    #expect(legs.map(\.when) == [.now, .later])
    #expect(legs.map(\.returnsToArchived) == [false, false])
  }

  /// What an edit of the archived account's past leaves goes right after its last movement, in
  /// the past: an earlier leg, not one of now.
  @Test func aTransferDatedInThePastIsAnEarlierLeg() {
    let before = now.addingTimeInterval(-3 * 86_400)
    let legs = ArchivedMoney.legs(
      of: [transfer(1_000, from: cash, to: sber, at: before)], archived: cash, now: now)
    #expect(legs.map(\.when) == [.earlier])
    #expect(legs.map(\.at) == [before])
    #expect(legs.map(\.returnsToArchived) == [false])
  }

  @Test func noTransferIsNoLeg() {
    #expect(ArchivedMoney.legs(of: [], archived: cash, now: now).isEmpty)
  }

  /// The legs describe what settling the key writes: the same transfers, in the same order.
  @Test func theLegsFollowSettlingTransfers() {
    let key = BalanceKey(accountId: cash, currency: .rub)
    let leftover = ArchivedLeftover(
      key: key, amount: AmountE4(whole: -18_000), latest: later, heldNow: AmountE4(whole: 12_000))
    let transfers = ArchivedMoney.settlingTransfers(
      leftover, counterpart: sber, counterpartCountedAt: nil, now: now, note: nil)
    let legs = ArchivedMoney.legs(of: transfers, archived: cash, now: now)
    #expect(legs.count == 2)
    #expect(legs.map(\.amount) == [AmountE4(whole: 12_000), AmountE4(whole: 30_000)])
    #expect(legs.map(\.returnsToArchived) == [false, true])
    #expect(legs.map(\.at) == [now, later])
  }
}
