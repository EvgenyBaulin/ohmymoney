import AppCore
import XCTest

@testable import OhMyMoney

/// The strip of a trip, its words in both languages and the fields of the cards abroad: what the
/// views lay out, read without a window.
@MainActor
final class TravelAppTests: XCTestCase {
  private func amount(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  private func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }

  private func event(
    from: String = "2026-10-05", to: String = "2026-10-15", budget: Int64? = 100_000
  ) -> Event {
    Event(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Бали", kind: .trip,
      startDate: day(from), endDate: day(to), budgetE4: budget.map(amount),
      tripCurrency: CurrencyCode("IDR"))
  }

  private func spending(_ iso: String, _ whole: Int64, event: Event) -> TransactionEntry {
    let id = UUID()
    let when = CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
    return TransactionEntry(
      transaction: CoreKit.Transaction(
        id: id, kind: .expense, occurredAt: when, amountE4: amount(whole), createdAt: when,
        updatedAt: when),
      parts: [
        TransactionPart(
          transactionId: id, amountE4: amount(whole), amountRubE4: amount(whole),
          eventId: event.id)
      ])
  }

  private func model(
    settings: TripSettings, event: Event, spent: [(String, Int64)], today: String
  ) -> TripBannerModel {
    let dataset = Dataset(
      entries: spent.map { spending($0.0, $0.1, event: event) }, events: [event],
      tripSettings: settings)
    return TripBannerModel.make(
      dataset: dataset, ledger: Ledger(dataset: dataset, calendar: .utc), rates: .empty,
      today: day(today))
  }

  // MARK: The strip

  func testNoTripNoStrip() {
    let trip = event()
    XCTAssertTrue(
      model(settings: .off, event: trip, spent: [("2026-10-06", 500)], today: "2026-10-10").isEmpty)
  }

  func testATripThatIsOnShowsItsLineAndTheAllowanceOfTheDay() throws {
    let trip = event()
    let banner = model(
      settings: TripSettings(activeEventId: trip.id), event: trip,
      spent: [("2026-07-01", 40_000), ("2026-10-10", 5_000)], today: "2026-10-10")
    let mode = try XCTUnwrap(banner.mode)
    XCTAssertNil(banner.welcome)
    XCTAssertEqual(mode.spentRub, amount(45_000))
    XCTAssertEqual(mode.budgetRub, amount(100_000))
    let allowance = try XCTUnwrap(mode.allowance)
    XCTAssertEqual(allowance.perDay, amount(10_000))
    XCTAssertEqual(allowance.leftToday, amount(5_000))
  }

  func testATripWithoutABudgetHasNoAllowance() throws {
    let trip = event(budget: nil)
    let banner = model(
      settings: TripSettings(activeEventId: trip.id), event: trip, spent: [], today: "2026-10-10")
    XCTAssertNotNil(banner.mode)
    XCTAssertNil(banner.mode?.allowance)
  }

  func testTheMorningAfterTheLastDayTheStripIsTheCardAndTheModeIsOffEvenBeforeItIsWrittenDown()
    throws
  {
    let trip = event()
    // The settings still name the trip: the day changed while the app was closed.
    let banner = model(
      settings: TripSettings(activeEventId: trip.id), event: trip,
      spent: [("2026-07-01", 42_000), ("2026-10-08", 9_000)], today: "2026-10-16")
    XCTAssertNil(banner.mode)
    let welcome = try XCTUnwrap(banner.welcome)
    XCTAssertEqual(welcome.event.id, trip.id)
    XCTAssertEqual(welcome.totalRub, amount(51_000))
  }

  func testTheCardStaysUntilItIsClosed() {
    let trip = event()
    let waiting = TripSettings(returnCardEventId: trip.id)
    XCTAssertNotNil(model(settings: waiting, event: trip, spent: [], today: "2026-11-20").welcome)
    XCTAssertTrue(
      model(
        settings: TripMode.dismissingCard(settings: waiting), event: trip, spent: [],
        today: "2026-11-20"
      )
      .isEmpty)
  }

  // MARK: The words

  func testTheLineOfTheTripInBothLanguages() throws {
    let trip = event()
    let banner = model(
      settings: TripSettings(activeEventId: trip.id), event: trip, spent: [], today: "2026-10-10")
    let mode = try XCTUnwrap(banner.mode)
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let russian = TravelText.modeLine(mode, environment)
    XCTAssertTrue(russian.hasPrefix("Поездка: Бали до "), russian)
    XCTAssertTrue(russian.contains("валюта IDR"), russian)
    XCTAssertTrue(russian.contains("бюджет \(environment.money.rounded(amount(100_000)))"), russian)
    environment.language.choice = .english
    let english = TravelText.modeLine(mode, environment)
    XCTAssertTrue(english.hasPrefix("Trip: Бали until "), english)
    XCTAssertTrue(english.contains("currency IDR"), english)
    XCTAssertTrue(english.contains("budget "), english)
  }

  func testTheDayLineSaysOverAndExhaustedInWords() throws {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let left = try XCTUnwrap(
      TripAllowance.make(
        budget: amount(100_000), spentBeforeToday: amount(40_000), spentToday: amount(5_000),
        endDate: day("2026-10-15"), today: day("2026-10-10")))
    XCTAssertTrue(TravelText.dayLine(left, environment).contains("осталось на день"))
    let over = try XCTUnwrap(
      TripAllowance.make(
        budget: amount(100_000), spentBeforeToday: amount(40_000), spentToday: amount(12_000),
        endDate: day("2026-10-15"), today: day("2026-10-10")))
    XCTAssertTrue(TravelText.dayLine(over, environment).contains("сверх доли дня"))
    let gone = try XCTUnwrap(
      TripAllowance.make(
        budget: amount(100_000), spentBeforeToday: amount(100_000), spentToday: amount(1_000),
        endDate: day("2026-10-15"), today: day("2026-10-10")))
    XCTAssertTrue(TravelText.dayLine(gone, environment).contains("Бюджет поездки потрачен"))
    environment.language.choice = .english
    XCTAssertTrue(TravelText.dayLine(gone, environment).contains("The trip budget is spent"))
    XCTAssertTrue(TravelText.dayLine(left, environment).contains("left for the day"))
  }

  func testEveryKeyOfTheTableIsThereInBothLanguages() throws {
    let keys = [
      "travel.mode.title", "travel.mode.currency", "travel.mode.budget", "travel.mode.off",
      "travel.day.left", "travel.day.over", "travel.day.exhausted", "travel.welcome.title",
      "travel.welcome.body", "travel.welcome.summary", "travel.welcome.extend",
      "travel.welcome.close", "travel.extend.title", "travel.extend.until",
      "travel.extend.confirm", "travel.summary.title", "travel.summary.missing",
      "travel.summary.total", "travel.summary.byDay", "travel.summary.byCategory",
      "travel.summary.byCurrency", "travel.summary.noCategory", "travel.summary.settlement",
      "travel.summary.settlement.none", "travel.summary.settlement.note",
      "travel.summary.budget.none", "travel.summary.budget.over", "travel.summary.budget.left",
      "travel.cards.button", "travel.cards.title", "travel.cards.best", "travel.cards.noBest",
      "travel.cards.loss", "travel.cards.notTyped", "travel.cards.fx", "travel.cards.atmPercent",
      "travel.cards.atmFixed", "travel.cards.atmCurrency", "travel.cards.badPercent",
      "travel.cards.badFixed", "travel.gain.title", "travel.gain.period", "travel.gain.month",
      "travel.gain.year", "travel.gain.note",
    ]
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for key in keys {
        XCTAssertNotEqual(
          TravelText.t(key, environment), key, "\(key) is missing in \(choice.rawValue)")
      }
    }
    environment.language.choice = .russian
    XCTAssertNotEqual(
      environment.format("travel.gain.uncounted", table: TravelText.table, counts: 2),
      "travel.gain.uncounted")
    XCTAssertTrue(
      environment.format("travel.gain.uncounted", table: TravelText.table, counts: 2)
        .contains("2 пары"))
    XCTAssertTrue(
      environment.format("travel.gain.unpriced", table: TravelText.table, counts: 5)
        .contains("5 пар"))
    environment.language.choice = .english
    XCTAssertTrue(
      environment.format("travel.gain.unpriced", table: TravelText.table, counts: 1)
        .contains("1 pair has no rate"))
  }

  // MARK: The cards abroad

  func testTheFieldsOfACardReadIntoItsTerms() {
    var draft = CardForeignDraft()
    XCTAssertEqual(
      draft.reading, .terms(CardForeignTerms()), "nothing typed is a card without terms")
    draft.conversionFee = "1.5"
    draft.atmFeePercent = "2"
    draft.atmFeeFixed = "3"
    draft.atmFeeFixedCurrency = "usd"
    guard case .terms(let terms) = draft.reading else { return XCTFail("not read") }
    XCTAssertEqual(terms.conversionFee?.e4, 15_000)
    XCTAssertEqual(terms.atmFeePercent?.e4, 20_000)
    XCTAssertEqual(terms.atmFeeFixed, Money(amount: amount(3), currency: .usd))
    XCTAssertEqual(
      CardForeignDraft(terms),
      {
        var again = draft
        again.atmFeeFixedCurrency = "USD"
        return again
      }())
  }

  func testAFeeOfNothingIsAFeeAndAnEmptyFieldIsNot() {
    var draft = CardForeignDraft()
    draft.conversionFee = "0"
    guard case .terms(let terms) = draft.reading else { return XCTFail("not read") }
    XCTAssertEqual(terms.conversionFee?.e4, 0)
    XCTAssertNil(terms.atmFeePercent)
    XCTAssertFalse(terms.isEmpty)
  }

  func testAnUnreadableFieldIsRefusedAndNothingIsGuessed() {
    var draft = CardForeignDraft()
    draft.conversionFee = "101"
    XCTAssertEqual(draft.reading, .badPercent)
    draft.conversionFee = "1.00001"
    XCTAssertEqual(draft.reading, .badPercent, "more than four places")
    draft.conversionFee = "abc"
    XCTAssertEqual(draft.reading, .badPercent)
    draft.conversionFee = ""
    draft.atmFeeFixed = "3"
    XCTAssertEqual(draft.reading, .badFixed, "a fixed fee needs its currency")
    draft.atmFeeFixedCurrency = "US"
    XCTAssertEqual(draft.reading, .badFixed)
    draft.atmFeeFixed = ""
    draft.atmFeeFixedCurrency = "USD"
    XCTAssertEqual(draft.reading, .badFixed, "a currency needs its sum")
    draft.atmFeeFixed = "-1"
    XCTAssertEqual(draft.reading, .badFixed)
  }

  func testTheGainPeriodsStartAtTheFirstDayOfTheMonthAndOfTheYear() {
    XCTAssertEqual(CurrencyGainPeriod.month.start(today: day("2026-10-20")), day("2026-10-01"))
    XCTAssertEqual(CurrencyGainPeriod.year.start(today: day("2026-10-20")), day("2026-01-01"))
    XCTAssertEqual(CurrencyGainSection.symbol(of: amount(5)), "arrow.up.right")
    XCTAssertEqual(CurrencyGainSection.symbol(of: amount(-5)), "arrow.down.right")
    XCTAssertEqual(CurrencyGainSection.symbol(of: .zero), "arrow.right")
  }
}
