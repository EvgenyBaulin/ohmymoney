import CoreKit
import Foundation

/// A line of «Стоит посмотреть» about the purchases.
public enum PurchaseNote: Hashable, Sendable, Identifiable {
  /// «На «Наушники» накоплено достаточно»: the price of a wish is within what is free now.
  case wishReady(wishId: UUID, name: String, priceRubE4: AmountE4)
  /// «Возврат ждёт зачисления N дней»: the expected day came and the money did not.
  case refundWaiting(
    transactionId: UUID, note: String?, amountRubE4: AmountE4, expectedBy: DateOnly,
    daysWaiting: Int, daysLate: Int)
  /// «День рождения у Ани через неделю»: `daysLeft` is 0 on the day itself.
  case birthday(GiftDay)
  /// The question «Не пожалели?» itself, as a card.
  case regret(RegretQuestion)

  /// The key «Готово» puts away: one per subject and its day.
  public var id: String {
    switch self {
    case .wishReady(let id, _, _): "purchase.wish:\(id.uuidString)"
    case .refundWaiting(let id, _, _, let until, _, _):
      "purchase.refund:\(id.uuidString):\(until.iso)"
    case .birthday(let day): "purchase.birthday:\(day.id)"
    case .regret(let question): "purchase.regret:\(question.transactionId.uuidString)"
    }
  }
}

public enum PurchaseNotes {
  /// At most this many wishes speak at once; the most wanted first.
  public static let maxWishNotes = 3

  /// The lines for `today`, `dismissed` holding the `id`s put away with «Готово»:
  /// wishes whose price is within `freeRubE4` (priority first, then the dearer), refunds past
  /// their expected day, birthdays a week away or nearer, the questions «Не пожалели?» (at most
  /// `RegretSchedule.maxQuestionsAtOnce`). Wishes already bought or archived, and without a price,
  /// are left out. `rates` turns a price in another currency into rubles; a currency without a
  /// rate is skipped.
  public static func list(
    wishes: [Wish], rates: [CurrencyCode: Decimal] = [:], freeRubE4: AmountE4?,
    waiting: WaitingRefunds, gifts: [GiftDay], regret: [RegretQuestion], today: DateOnly,
    dismissed: Set<String> = []
  ) -> [PurchaseNote] {
    var notes: [PurchaseNote] = []
    if let free = freeRubE4, free.raw > 0 {
      var ready: [(wish: Wish, price: AmountE4)] = []
      for wish in wishes where !wish.isBought && !wish.archived {
        guard let price = wish.priceE4, price.raw > 0 else { continue }
        let rub: AmountE4
        if wish.currency == .rub {
          rub = price
        } else if let rate = rates[wish.currency] {
          rub = PurchaseMath.converted(price, rate: rate)
        } else {
          continue
        }
        if rub <= free { ready.append((wish, rub)) }
      }
      ready.sort { left, right in
        let a = left.wish.priority == 0 ? Int.max : left.wish.priority
        let b = right.wish.priority == 0 ? Int.max : right.wish.priority
        if a != b { return a < b }
        if left.price != right.price { return left.price > right.price }
        return left.wish.id.uuidString < right.wish.id.uuidString
      }
      notes += ready.prefix(maxWishNotes).map {
        .wishReady(wishId: $0.wish.id, name: $0.wish.name, priceRubE4: $0.price)
      }
    }
    for item in waiting.items where today >= item.expectedBy {
      notes.append(
        .refundWaiting(
          transactionId: item.transactionId, note: item.note, amountRubE4: item.amountRubE4,
          expectedBy: item.expectedBy, daysWaiting: item.daysWaiting(today: today),
          daysLate: max(0, item.expectedBy.days(to: today))))
    }
    notes += gifts.filter(\.reminderDue).map(PurchaseNote.birthday)
    notes += regret.prefix(RegretSchedule.maxQuestionsAtOnce).map(PurchaseNote.regret)
    return notes.filter { !dismissed.contains($0.id) }
  }
}
