import CoreKit
import Foundation
import Testing

@testable import CoreSample

/// A sample is the books of the app: every account sits under a bank, as it does after the
/// update. The banks draw nothing from the random sources, so the sequences the other tests pin
/// stay as they are.
@Suite("The banks of the sample")
struct SampleBanksTests {
  @Test func everyAccountOfASampleHasABankOfItsName() {
    let set = SampleAccountsTests.layered().assigningBanks()
    #expect(!set.banks.isEmpty)
    let banks = Dictionary(uniqueKeysWithValues: set.banks.map { ($0.id, $0) })
    for account in set.paymentMethods {
      let bank = account.bankId.flatMap { banks[$0] }
      #expect(bank != nil, "\(account.name) has no bank")
      #expect(bank?.name == account.name)
    }
    #expect(Set(set.banks.map { NameKey.fold($0.name) }).count == set.banks.count)
    #expect(set.banks.allSatisfy { !$0.archived })
  }

  @Test func theHistoryAloneIsFiledToo() {
    let history = SampleAccountsTests.history().assigningAccounts().assigningBanks()
    #expect(history.paymentMethods.allSatisfy { $0.bankId != nil })
    #expect(history.banks.count == history.paymentMethods.count)
  }

  @Test func filingTwiceChangesNothingMore() {
    let once = SampleAccountsTests.layered().assigningBanks()
    #expect(once.assigningBanks().banks == once.banks)
    #expect(once.assigningBanks().paymentMethods == once.paymentMethods)
  }

  /// Nothing the other digests pin moves: banks are derived from the accounts, not drawn.
  @Test func theBanksMoveNoDrawnRow() {
    let before = SampleAccountsTests.layered()
    let after = before.assigningBanks()
    #expect(after.entries == before.entries)
    #expect(after.transfers == before.transfers)
    #expect(after.reconciledBalances == before.reconciledBalances)
    #expect(after.paymentMethods.map(\.id) == before.paymentMethods.map(\.id))
    #expect(after.paymentMethods.map(\.name) == before.paymentMethods.map(\.name))
  }

  @Test func theLayersCarryTheirBanksToo() {
    let set = SampleFeatureLayersTests.layered().assigningBanks()
    #expect(set.paymentMethods.allSatisfy { $0.bankId != nil })
    #expect(
      set.cards.allSatisfy { card in set.paymentMethods.contains { $0.id == card.accountId } })
  }
}
