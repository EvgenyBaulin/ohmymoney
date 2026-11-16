import AppCore
import Foundation

/// The switch makes a separate debit account only after its sheet is confirmed. Past
/// operations stay by default; the owner may instead move all or those from a chosen day.
struct CardOwnBalanceDraft: Equatable {
  var past: CardToCreditCardDraft.Past = .none
  var fromDate: Date
  var name = ""
  var asksForName = false
  var refusal: CardOwnBalanceIssue?

  init(today: Date) { fromDate = today }

  func pastOperations(calendar: CalendarContext) -> CardPastOperations {
    switch past {
    case .all: .all
    case .none: .none
    case .fromDate: .onAndAfter(calendar.day(of: fromDate))
    }
  }

  mutating func attempt(
    separating card: PaymentCard, cards: [PaymentCard], accounts: [PaymentMethod],
    calendar: CalendarContext
  ) -> CreditCardConversionPlan? {
    let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch CardOwnBalance.plan(
      separating: card.id, past: pastOperations(calendar: calendar),
      name: typed.isEmpty ? nil : typed, cards: cards, accounts: accounts)
    {
    case .success(let plan):
      refusal = nil
      return plan
    case .failure(let issue):
      refusal = issue
      if case .conversion(.name) = issue { asksForName = true }
      return nil
    }
  }
}
