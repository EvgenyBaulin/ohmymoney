import AppCore
import XCTest

@testable import OhMyMoney

/// The place, person and event filters of the Transactions window: a value in the archive is
/// still in its operations, so the filter offers it — after the live ones — and a filter on a
/// value archived since it was chosen stays, still finding its operations.
final class TransactionFiltersArchiveTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 27)
  private let market = Place(name: "Рынок")
  private let bakery = Place(name: "Булочная")
  private let coffee = Place(name: "Кофемания", archived: true)
  private let bar = Place(name: "Бар", archived: true)

  /// «Булочная», «Рынок», then «Бар» and «Кофемания» of the archive, each part by its name.
  func testAnArchivedPlaceIsOfferedAfterTheLiveOnes() {
    let choices = FilterChoices(Dataset(places: [coffee, market, bar, bakery]))

    XCTAssertEqual(choices.places.map(\.id), [bakery.id, market.id, bar.id, coffee.id])
    XCTAssertEqual(choices.archivedPlaceIds, [bar.id, coffee.id])
  }

  /// «Кофемания» chosen, then archived: the filter keeps it, and it still finds the purchase
  /// made there. A place deleted since is dropped as before.
  func testAFilterOnAPlaceArchivedSinceIsKept() throws {
    var live = coffee
    live.archived = false
    var filters = TransactionFilters(today: today)
    filters.placeId = coffee.id
    filters.keep(within: FilterChoices(Dataset(places: [live, market])))
    XCTAssertEqual(filters.placeId, coffee.id)

    filters.keep(within: FilterChoices(Dataset(places: [coffee, market])))
    XCTAssertEqual(filters.placeId, coffee.id, "a filter on a place put in the archive was dropped")
    let filter = filters.entryFilter(today: today)
    XCTAssertEqual(filter.placeId, coffee.id)

    filters.keep(within: FilterChoices(Dataset(places: [market])))
    XCTAssertNil(filters.placeId, "a filter on a place that is gone stayed")
  }

  /// People and events in the archive are offered as places are: the live ones first, then the
  /// archived ones — people by name, events the latest first — and the picker names them
  /// «(архив)» after a line.
  func testArchivedPeopleAndEventsAreOfferedAfterTheLiveOnes() {
    let anya = Person(name: "Аня")
    let boris = Person(name: "Борис", archived: true)
    let vera = Person(name: "Вера")
    let gleb = Person(name: "Глеб", archived: true)
    func event(_ name: String, day: Int, archived: Bool = false) -> Event {
      Event(
        name: name, startDate: DateOnly(year: 2026, month: 9, day: day),
        endDate: DateOnly(year: 2026, month: 9, day: day), archived: archived)
    }
    let trip = event("Поездка", day: 10)
    let party = event("Праздник", day: 20)
    let wedding = event("Свадьба", day: 5, archived: true)
    let fair = event("Ярмарка", day: 15, archived: true)
    let choices = FilterChoices(
      Dataset(people: [gleb, vera, boris, anya], events: [wedding, trip, fair, party]))

    XCTAssertEqual(choices.people.map(\.id), [anya.id, vera.id, boris.id, gleb.id])
    XCTAssertEqual(choices.archivedPersonIds, [boris.id, gleb.id])
    XCTAssertEqual(choices.events.map(\.id), [party.id, trip.id, fair.id, wedding.id])
    XCTAssertEqual(choices.archivedEventIds, [fair.id, wedding.id])

    let mark: (String) -> String = { "\($0) (архив)" }
    let people = choices.personOptions(archivedName: mark)
    XCTAssertEqual(people.options.map { $0.1 }, ["Аня", "Вера", "Борис (архив)", "Глеб (архив)"])
    XCTAssertEqual(people.dividerBefore, 2)
    let events = choices.eventOptions(archivedName: mark)
    XCTAssertEqual(
      events.options.map { $0.1 }, ["Праздник", "Поездка", "Ярмарка (архив)", "Свадьба (архив)"])
    XCTAssertEqual(events.dividerBefore, 2)
    let places = FilterChoices(Dataset(places: [coffee, market, bar, bakery]))
      .placeOptions(archivedName: mark)
    XCTAssertEqual(
      places.options.map { $0.1 }, ["Булочная", "Рынок", "Бар (архив)", "Кофемания (архив)"])
    XCTAssertEqual(places.dividerBefore, 2)

    // Nothing in the archive: no line.
    XCTAssertNil(
      FilterChoices(Dataset(people: [anya])).personOptions(archivedName: mark).dividerBefore)
  }

  /// A person and an event chosen, then archived: the filter keeps them, as it keeps a place.
  /// Deleted since, they are dropped.
  func testAFilterOnAPersonOrEventArchivedSinceIsKept() {
    let anya = Person(name: "Аня")
    let trip = Event(
      name: "Поездка", startDate: DateOnly(year: 2026, month: 9, day: 1),
      endDate: DateOnly(year: 2026, month: 9, day: 5))
    var filters = TransactionFilters(today: today)
    filters.personId = anya.id
    filters.eventId = trip.id
    var archivedAnya = anya
    archivedAnya.archived = true
    var archivedTrip = trip
    archivedTrip.archived = true

    filters.keep(within: FilterChoices(Dataset(people: [archivedAnya], events: [archivedTrip])))
    XCTAssertEqual(filters.personId, anya.id, "a filter on a person put in the archive was dropped")
    XCTAssertEqual(filters.eventId, trip.id, "a filter on an event put in the archive was dropped")
    let filter = filters.entryFilter(today: today)
    XCTAssertEqual(filter.personId, anya.id)
    XCTAssertEqual(filter.eventId, trip.id)

    filters.keep(within: FilterChoices(Dataset()))
    XCTAssertNil(filters.personId, "a filter on a person that is gone stayed")
    XCTAssertNil(filters.eventId, "a filter on an event that is gone stayed")
  }
}

/// The account filter with cards: each account is offered followed by its live cards when it
/// has two or more, «Т-Банк › Black»; a card brings its account, an account drops the card, and a card archived
/// since it was chosen leaves the account alone chosen.
final class TransactionFiltersCardTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 27)
  private let sber = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
  private let tBank = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub)

  func testTheAccountFilterOffersEachAccountWithItsCards() {
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    let virtual = PaymentCard(accountId: tBank.id, name: "Virtual", sort: 1)
    let old = PaymentCard(accountId: tBank.id, name: "Old", archived: true)
    let sberCard = PaymentCard(accountId: sber.id, name: "Сбер")
    let choices = FilterChoices(
      Dataset(paymentMethods: [tBank, sber], cards: [virtual, old, black, sberCard]),
      locale: Locale(identifier: "ru"))

    XCTAssertEqual(
      choices.accountItems.map(\.name),
      ["Сбер", "Т-Банк", "Т-Банк › Black", "Т-Банк › Virtual"])
    XCTAssertEqual(choices.accountItems.filter(\.isCard).map(\.id), [black.id, virtual.id])
  }

  func testACardBringsItsAccountAndAnAccountDropsTheCard() {
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    var filters = TransactionFilters(today: today)
    filters.setAccountOrCard(black.id, cards: [black])
    XCTAssertEqual(filters.paymentMethodId, tBank.id)
    XCTAssertEqual(filters.cardId, black.id)
    XCTAssertEqual(filters.accountOrCard, black.id)
    let filter = filters.entryFilter(today: today)
    XCTAssertEqual(filter.paymentMethodId, tBank.id)
    XCTAssertEqual(filter.cardId, black.id)
    XCTAssertTrue(filters.canReset)

    filters.setAccountOrCard(sber.id, cards: [black])
    XCTAssertEqual(filters.paymentMethodId, sber.id)
    XCTAssertNil(filters.cardId)
    filters.setAccountOrCard(nil, cards: [black])
    XCTAssertNil(filters.paymentMethodId)
    XCTAssertFalse(filters.canReset)
  }

  func testACardArchivedSinceLeavesItsAccountChosen() {
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    var filters = TransactionFilters(today: today)
    filters.setAccountOrCard(black.id, cards: [black])
    filters.keep(within: FilterChoices(Dataset(paymentMethods: [sber, tBank], cards: [black])))
    XCTAssertEqual(filters.cardId, black.id)

    var archived = black
    archived.archived = true
    filters.keep(within: FilterChoices(Dataset(paymentMethods: [sber, tBank], cards: [archived])))
    XCTAssertNil(filters.cardId, "a card no longer offered went on filtering")
    XCTAssertEqual(filters.paymentMethodId, tBank.id)
  }
}
