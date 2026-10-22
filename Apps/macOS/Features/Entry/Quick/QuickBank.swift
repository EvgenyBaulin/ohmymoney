import AppCore
import Foundation

/// What a text of a bank becomes in the entry line, and what is offered beside it. Pure: the
/// cards, the places and the parser are handed in, so a test reads every case without a window.
struct BankOffer: Equatable {
  var message: BankMessage
  /// The line the field is filled with.
  var line: String
  /// The card the digits found, if one.
  var card: CardDigits?
  /// What the digits need: nothing, an answer once, a choice between cards.
  var question: QuickCardQuestion
  /// «Сверить …» is the owner's tick, off unless he sets it (`BankMessage.reconcileOfferedByDefault`).
  var reconcileAfter = BankMessage.reconcileOfferedByDefault
}

enum QuickBank {
  /// The index of the cards that keep their last four digits.
  static func index(of cards: [PaymentCard]) -> CardDigitsIndex {
    CardDigitsIndex(
      cards.filter { !$0.archived }.compactMap { card in
        guard let digits = card.last4, digits.count == 4 else { return nil }
        return CardDigits(cardId: card.id, accountId: card.accountId, last4: digits)
      })
  }

  /// The offer for one text of a bank. The line is the one `BankMessage.suggestedLine` makes
  /// with the place as the owner's list names it, and the name of the card the digits found
  /// when the line reads back to that very card.
  static func offer(
    for message: BankMessage, cards: [PaymentCard], places: [ParserVocabulary.Entry],
    parser: InputLineParser, today: DateOnly
  ) -> BankOffer {
    let lookup = index(of: cards).lookup(message)
    let merchant = message.merchant.flatMap { BankMerchants.resolve($0, places: places) }
    var line = message.suggestedLine(merchantName: merchant?.name)
    var found: CardDigits?
    if case .card(let digits) = lookup {
      found = digits
      if let id = digits.cardId, let card = cards.first(where: { $0.id == id }) {
        let named = line + " " + card.name
        if parser.parse(named, today: today).cardId == id { line = named }
      }
    }
    return BankOffer(
      message: message, line: line, card: found, question: QuickCardQuestion.of(lookup))
  }

  /// A list pasted from the bank's app: the pieces marked with a tick, those the ledger has
  /// already unticked.
  static func candidates(
    _ items: [BankListItem], entries: [TransactionEntry], calendar: CalendarContext, today: DateOnly
  ) -> [BankImportCandidate] {
    let known = entries.compactMap { entry -> KnownOperation? in
      let transaction = entry.transaction
      guard !transaction.isDeleted else { return nil }
      return KnownOperation(
        day: calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId),
        kind: transaction.kind,
        money: Money(amount: transaction.amountE4, currency: transaction.currency))
    }
    return BankImport.candidates(items, known: known, today: today)
  }
}
