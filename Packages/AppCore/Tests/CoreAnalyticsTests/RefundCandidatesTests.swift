import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The purchases a refund is picked from: refundable parts with something left, newest first,
/// the last 90 days unless asked for earlier ones, narrowed by the words, the place and the
/// amount of the line.
@Suite("Возврат покупки: какие покупки предлагаются")
struct RefundCandidatesTests {
  private let calendar = CalendarContext.utc
  private let today = DateOnly(year: 2026, month: 9, day: 26)
  private let shop = UUID()

  private func noon(_ day: DateOnly) -> Date {
    calendar.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  private func purchase(
    _ note: String?, _ whole: Int64, daysAgo: Int, place: UUID? = nil,
    parts: [PartDraft]? = nil, currency: CurrencyCode = .rub, credit: UUID? = nil
  ) -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: noon(calendar.adding(days: -daysAgo, to: today)),
      currency: currency, amount: AmountE4(whole: whole), rate: currency == .rub ? nil : 90,
      note: note, placeId: place, creditDebtId: credit)
    if let parts { draft.parts = parts } else { draft.normalizeSinglePart() }
    let rate = draft.rate
    return try! draft.materialize(rublesConverter: { amount in
      guard let rate else { return amount }
      return try AmountE4(decimal: amount.decimal * rate)
    })
  }

  private func refund(_ amount: Int64, of part: TransactionPart, daysAgo: Int) -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .refund, occurredAt: noon(calendar.adding(days: -daysAgo, to: today)),
      amount: AmountE4(whole: amount))
    draft.parts = [PartDraft(amount: AmountE4(whole: amount), refundOfPartId: part.id)]
    return try! draft.materialize()
  }

  private func list(
    _ entries: [TransactionEntry], since: DateOnly?, query: RefundQuery = RefundQuery(),
    places: [UUID: String] = [:]
  ) -> (candidates: [RefundCandidate], narrowed: Bool) {
    RefundCandidates.list(
      entries: entries, index: RefundIndex(entries: entries, debts: [:]), tree: CategoryTree(),
      since: since, calendar: calendar, query: query, placeNames: places)
  }

  private var window: DateOnly { RefundCandidates.windowStart(today: today, calendar: calendar) }

  @Test("Покупка после дня возврата не предлагается — и без сужения тоже")
  func nothingBoughtAfterTheRefundDay() {
    let before = purchase("кроссовки", 7000, daysAgo: 10)
    let after = purchase("кеды", 5000, daysAgo: 2)
    let day = calendar.adding(days: -5, to: today)
    let found = list([before, after], since: window, query: RefundQuery(latestDay: day))
    #expect(found.candidates.map(\.purchase.id) == [before.id])
    #expect(!found.narrowed)
    let narrowed = list(
      [before, after], since: window, query: RefundQuery(words: "кеды", latestDay: day))
    #expect(narrowed.candidates.map(\.purchase.id) == [before.id])
  }

  @Test("Новые первыми, за 90 дней; «Показать раньше» добавляет старые")
  func newestFirstWithinNinetyDays() {
    let old = purchase("куртка", 9000, daysAgo: 120)
    let edge = purchase("шарф", 900, daysAgo: 89)
    let recent = purchase("кроссовки", 7000, daysAgo: 3)
    let entries = [old, edge, recent]

    let shown = list(entries, since: window).candidates.map(\.purchase.id)
    #expect(shown == [recent.id, edge.id])

    let all = list(entries, since: nil).candidates.map(\.purchase.id)
    #expect(all == [recent.id, edge.id, old.id])
  }

  @Test("Остаток — за вычетом прошлых возвратов; возвращённая целиком не предлагается")
  func remainderAfterRefunds() {
    let shoes = purchase("кроссовки", 7000, daysAgo: 10)
    let hat = purchase("шапка", 1000, daysAgo: 9)
    let partly = refund(2000, of: shoes.parts[0], daysAgo: 5)
    let whole = refund(1000, of: hat.parts[0], daysAgo: 4)
    let found = list([shoes, hat, partly, whole], since: window).candidates
    #expect(found.map(\.part.id) == [shoes.parts[0].id])
    #expect(found.first?.remaining == AmountE4(whole: 5000))
    #expect(found.first?.refunded == AmountE4(whole: 2000))
  }

  @Test("Части «за другого» и покупки в кредит не предлагаются; у сплита — каждая часть")
  func notOfferedParts() {
    let mine = PartDraft(amount: AmountE4(whole: 600), note: "ужин")
    var forAnya = PartDraft(amount: AmountE4(whole: 400), note: "ужин Ани")
    forAnya.reimbursable = true
    forAnya.debtorPersonId = UUID()
    let groceries = PartDraft(amount: AmountE4(whole: 300), note: "продукты")
    let dinner = purchase(
      "ресторан", 1300, daysAgo: 2, parts: [mine, forAnya, groceries])
    let onCredit = purchase("телефон", 90000, daysAgo: 1, credit: UUID())

    let found = list([dinner, onCredit], since: window).candidates
    #expect(found.map(\.part.id) == [dinner.parts[0].id, dinner.parts[2].id])
    #expect(found.filter { !$0.isPartOfASplit }.isEmpty)
  }

  @Test("Строка сужает: слова (с окончаниями), место, сумма не больше остатка")
  func theLineNarrows() {
    let shoes = purchase("кроссовки Nike", 7000, daysAgo: 10, place: shop)
    let coat = purchase("пальто", 15000, daysAgo: 8, place: shop)
    let coffee = purchase("кофе", 300, daysAgo: 1)
    let entries = [shoes, coat, coffee]

    let byWords = list(entries, since: window, query: RefundQuery(words: "кроссовок"))
    #expect(byWords.candidates.map(\.purchase.id) == [shoes.id])
    #expect(byWords.narrowed)

    let byPlace = list(entries, since: window, query: RefundQuery(placeId: shop))
    #expect(byPlace.candidates.map(\.purchase.id) == [coat.id, shoes.id])

    let byPlaceName = list(
      entries, since: window, query: RefundQuery(words: "Спортмастер"),
      places: [shop: "Спортмастер"])
    #expect(byPlaceName.candidates.map(\.purchase.id) == [coat.id, shoes.id])

    let byAmount = list(
      entries, since: window,
      query: RefundQuery(placeId: shop, amount: AmountE4(whole: 8000), currency: .rub))
    #expect(byAmount.candidates.map(\.purchase.id) == [coat.id])
  }

  @Test("Ничего не подошло — предлагается всё за период, без сужения")
  func nothingFitsShowsEverything() {
    let shoes = purchase("кроссовки", 7000, daysAgo: 10)
    let coffee = purchase("кофе", 300, daysAgo: 1)
    let result = list([shoes, coffee], since: window, query: RefundQuery(words: "телевизор"))
    #expect(!result.narrowed)
    #expect(result.candidates.map(\.purchase.id) == [coffee.id, shoes.id])
  }

  @Test("Сумма в другой валюте не отсеивает покупку в долларах")
  func amountOfAnotherCurrencyDoesNotNarrow() {
    let headphones = purchase("наушники", 100, daysAgo: 5, currency: .usd)
    let result = list(
      [headphones], since: window,
      query: RefundQuery(words: "наушники", amount: AmountE4(whole: 9000), currency: .rub))
    #expect(result.candidates.map(\.purchase.id) == [headphones.id])
    #expect(result.narrowed)
  }
}
