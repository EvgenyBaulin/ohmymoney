import CoreAccounting
import CoreKit
import Foundation

extension SampleDataSet {
  /// The references a set with accounts adds:
  ///
  /// * a holiday fair that is over: a place in the archive with one purchase in cash ten days
  ///   before the last day — gone from the pickers, still in Analytics, Reports and the list;
  /// * a concert, an event of one day twelve days before the last day, with a budget and the
  ///   tickets bought with the travel card on that day.
  ///
  /// Both purchases come after the accounts' own count two weeks before the last day, so that
  /// count still finds what it found; each is at most a few thousand, well inside what the
  /// accounts keep above zero.
  func withReferencesLayer(
    seed: UInt64, calendar: CalendarContext, language: String, now: Date?
  ) -> SampleDataSet {
    let layer = SampleLayer(
      tag: 0x0012_2EF5_0000_0012, seed: seed, set: self, calendar: calendar, language: language,
      now: now)
    var set = self

    if let day = layer.daysBeforeEnd(10), let gifts = starter("Gifts"),
      let cash = paymentMethods.first(where: { $0.kind == .cash && !$0.isDefault && !$0.archived })
    {
      var rng = layer.stream("holiday fair", on: day)
      let fair = Place(
        id: rng.nextUUID(), name: layer.word("Holiday Fair", "Праздничная ярмарка"), archived: true)
      set.places.append(fair)
      set.add(
        layer.purchase(
          AmountE4(whole: Int64(rng.int(in: 9...15)) * 100), of: gifts.category,
          parent: gifts.parent, at: layer.moment(on: day, rng: &rng), account: cash.id,
          note: layer.word("Handmade candles", "Свечи ручной работы"), placeId: fair.id,
          rng: &rng),
        calendar: calendar)
    }

    if let day = layer.daysBeforeEnd(12), let fun = starter("Entertainment"),
      let travel = paymentMethods.first(where: { account in
        account.kind == .card && !account.isDefault && !account.archived && account.holds(.rub)
      })
    {
      var rng = layer.stream("concert", on: day)
      let concert = Event(
        id: rng.nextUUID(), name: layer.word("Concert", "Концерт"), kind: .other, startDate: day,
        endDate: day, budgetE4: AmountE4(whole: 5_000))
      set.events.append(concert)
      set.events.sort { left, right in
        left.startDate != right.startDate
          ? left.startDate < right.startDate : left.id.uuidString < right.id.uuidString
      }
      set.add(
        layer.purchase(
          AmountE4(whole: Int64(rng.int(in: 25...40)) * 100), of: fun.category, parent: fun.parent,
          at: layer.moment(on: day, rng: &rng), account: travel.id,
          note: layer.word("Concert tickets", "Билеты на концерт"), eventId: concert.id,
          rng: &rng),
        calendar: calendar)
    }
    return set
  }
}
