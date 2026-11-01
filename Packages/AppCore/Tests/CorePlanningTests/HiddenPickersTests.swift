import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// What a picker of accounts or cards offers while the hidden accounts are covered: the visible
/// ones, and the one a saved record already names even when it is hidden — so a form never
/// swaps the account of what it edits for another one unseen.
@Suite("Hidden accounts: the pickers keep what a record names")
struct HiddenPickersTests {
  let fx = PrivacyFixture()
  var hidden: HiddenAccounts {
    HiddenAccounts(
      accounts: fx.dataset.paymentMethods.map { account in
        var copy = account
        copy.hidden = account.id == fx.hiddenId
        return copy
      })
  }

  @Test("covered, a hidden account is offered only when the record names it")
  func keepsTheNamedAccount() {
    let accounts = fx.dataset.paymentMethods
    #expect(
      hidden.offered(accounts, visibility: .covered, keeping: nil).map(\.id) == [fx.visibleId])
    #expect(
      hidden.offered(accounts, visibility: .covered, keeping: fx.visibleId).map(\.id)
        == [fx.visibleId])
    #expect(
      Set(hidden.offered(accounts, visibility: .covered, keeping: fx.hiddenId).map(\.id))
        == [fx.visibleId, fx.hiddenId])
  }

  @Test("revealed, every account is offered, in the order given")
  func revealedOffersEverything() {
    let accounts = fx.dataset.paymentMethods
    #expect(
      hidden.offered(accounts, visibility: .revealed, keeping: nil).map(\.id)
        == accounts.map(\.id))
  }

  @Test("covered, the cards of hidden accounts go, the one the record names stays")
  func cards() {
    let cards = fx.dataset.cards
    #expect(
      hidden.offeredCards(cards, visibility: .covered, keeping: []).map(\.id)
        == [fx.visibleCardId])
    #expect(
      Set(hidden.offeredCards(cards, visibility: .covered, keeping: [fx.hiddenCardId]).map(\.id))
        == [fx.visibleCardId, fx.hiddenCardId])
    #expect(hidden.offeredCards(cards, visibility: .revealed, keeping: []).count == cards.count)
  }

  @Test("a record that names a hidden account keeps its cards on offer too")
  func cardsOfAKeptAccount() {
    let cards = fx.dataset.cards
    #expect(
      Set(hidden.offeredCards(cards, visibility: .covered, keeping: [fx.hiddenId]).map(\.id))
        == [fx.visibleCardId, fx.hiddenCardId])
  }
}
