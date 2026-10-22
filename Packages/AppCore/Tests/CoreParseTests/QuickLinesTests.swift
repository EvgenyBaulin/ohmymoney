import CoreKit
import Foundation
import Testing

@testable import CoreParse

private func e4(_ text: String) -> AmountE4 {
  try! AmountE4(decimal: dec(text))
}

private let rub = CurrencyCode.rub

@Suite("Places and the usual amount")
struct PlaceSuggestionsTests {
  let shop = UUID()
  let other = UUID()
  let start = Date(timeIntervalSince1970: 1_760_000_000)

  func purchase(
    _ place: UUID, _ amount: String, daysAgo: Int, currency: CurrencyCode = .rub
  )
    -> PlacePurchase
  {
    PlacePurchase(
      placeId: place, money: Money(amount: e4(amount), currency: currency),
      occurredAt: start.addingTimeInterval(-Double(daysAgo) * 86_400))
  }

  @Test func theUsualAmountIsTheMedianOfTheLastFive() {
    let history = [
      purchase(shop, "9000", daysAgo: 60),  // too old to count
      purchase(shop, "1000", daysAgo: 5), purchase(shop, "1500", daysAgo: 4),
      purchase(shop, "900", daysAgo: 3), purchase(shop, "1200", daysAgo: 2),
      purchase(shop, "5000", daysAgo: 1),
    ]
    // 1000, 1500, 900, 1200, 5000 → sorted 900, 1000, 1200, 1500, 5000.
    #expect(PlaceSuggestions.usualAmount(at: shop, in: history)?.amount == e4("1200"))
  }

  @Test func anEvenCountTakesTheMeanOfTheMiddleTwo() {
    let history = [
      purchase(shop, "100", daysAgo: 3), purchase(shop, "300", daysAgo: 2),
      purchase(shop, "200", daysAgo: 1), purchase(shop, "1000", daysAgo: 0),
    ]
    #expect(PlaceSuggestions.usualAmount(at: shop, in: history)?.amount == e4("250"))
  }

  @Test func theMeanRoundsHalfAwayFromZeroToAUnit() {
    let history = [
      purchase(shop, "0.0001", daysAgo: 1), purchase(shop, "0.0002", daysAgo: 0),
    ]
    #expect(PlaceSuggestions.usualAmount(at: shop, in: history)?.amount == AmountE4(raw: 2))
  }

  @Test func onePurchaseIsItsOwnUsual() {
    #expect(
      PlaceSuggestions.usualAmount(at: shop, in: [purchase(shop, "777", daysAgo: 0)])?.amount
        == e4("777"))
  }

  @Test func aPlaceWithoutPurchasesHasNoUsualAmount() {
    #expect(PlaceSuggestions.usualAmount(at: shop, in: [purchase(other, "5", daysAgo: 0)]) == nil)
  }

  @Test func theUsualAmountIsInTheCurrencyOfTheLatestPurchase() {
    let history = [
      purchase(shop, "1000", daysAgo: 3), purchase(shop, "20", daysAgo: 2, currency: .usd),
      purchase(shop, "30", daysAgo: 1, currency: .usd),
    ]
    let usual = PlaceSuggestions.usualAmount(at: shop, in: history)
    #expect(usual?.currency == .usd)
    #expect(usual?.amount == e4("25"))
  }

  @Test func aPrefixFindsThePlaceInEitherAlphabetAndLetterE() {
    let places: [ParserVocabulary.Entry] = [
      .init(id: shop, name: "Пятёрочка", aliases: ["pyaterochka"]),
      .init(id: other, name: "Азбука вкуса"),
    ]
    #expect(
      PlaceSuggestions.suggest(prefix: "пят", places: places, history: []).map(\.placeId) == [shop])
    #expect(
      PlaceSuggestions.suggest(prefix: "ПЯТЕ", places: places, history: []).map(\.placeId) == [shop]
    )
    #expect(
      PlaceSuggestions.suggest(prefix: "pya", places: places, history: []).map(\.placeId) == [shop])
    #expect(
      PlaceSuggestions.suggest(prefix: "вкус", places: places, history: []).map(\.placeId) == [
        other
      ])
    #expect(PlaceSuggestions.suggest(prefix: "", places: places, history: []).isEmpty)
    #expect(PlaceSuggestions.suggest(prefix: "zzz", places: places, history: []).isEmpty)
  }

  @Test func theSuggestionCarriesTheUsualAmountAndTheCount() throws {
    let places: [ParserVocabulary.Entry] = [.init(id: shop, name: "Пятёрочка")]
    let history = [purchase(shop, "1000", daysAgo: 2), purchase(shop, "1400", daysAgo: 1)]
    let found = try #require(
      PlaceSuggestions.suggest(prefix: "пят", places: places, history: history).first)
    #expect(found.usual == Money(amount: e4("1200"), currency: .rub))
    #expect(found.purchases == 2)
  }

  @Test func aNameStartRanksAboveAWordAndMoreVisitsAboveFewer() {
    let first = UUID(), second = UUID(), third = UUID()
    let places: [ParserVocabulary.Entry] = [
      .init(id: first, name: "Кофе у дома"),
      .init(id: second, name: "Вкусный кофе"),
      .init(id: third, name: "Кофемания"),
    ]
    let history = [
      purchase(first, "1", daysAgo: 1), purchase(third, "1", daysAgo: 2),
      purchase(third, "1", daysAgo: 3),
    ]
    let order = PlaceSuggestions.suggest(prefix: "коф", places: places, history: history).map(
      \.placeId)
    #expect(order == [third, first, second])
  }

  @Test func theLimitIsRespected() {
    let places = (0..<10).map { ParserVocabulary.Entry(id: UUID(), name: "Кафе \($0)") }
    #expect(
      PlaceSuggestions.suggest(prefix: "каф", places: places, history: [], limit: 3).count == 3)
  }
}

@Suite("Template with a blank")
struct TemplateBlankTests {
  @Test func theBlankIsFoundAndTheDashDropped() {
    let parts = TemplateBlank.parts(of: "Такси до работы — ? ₽")
    #expect(parts?.before == "Такси до работы")
    #expect(parts?.after == "₽")
  }

  @Test func theLineIsFilledWithTheAmount() {
    #expect(TemplateBlank.filled("Такси до работы — ? ₽", amount: "350") == "Такси до работы 350 ₽")
    #expect(TemplateBlank.filled("Taxi to work - ?", amount: "12 usd") == "Taxi to work 12 usd")
    #expect(TemplateBlank.filled("Кофе ?", amount: "250") == "Кофе 250")
  }

  @Test func aCurrencyGluedToTheBlankStaysGlued() {
    #expect(TemplateBlank.filled("Такси ?₽", amount: "350") == "Такси 350 ₽")
  }

  @Test func aTemplateWithoutABlankIsNotOne() {
    #expect(TemplateBlank.parts(of: "Кофе 250") == nil)
    #expect(TemplateBlank.filled("Кофе 250", amount: "300") == nil)
    #expect(!TemplateBlank.isBlank("Что дальше?"))
    #expect(!TemplateBlank.isBlank("кофе"))
  }

  @Test func anEmptyAmountFillsNothing() {
    #expect(TemplateBlank.filled("Кофе ?", amount: "  ") == nil)
  }

  @Test func theChipPutsTheTextBeforeTheBlankInTheField() {
    #expect(TemplateBlank.prefix(of: "Такси до работы — ? ₽") == "Такси до работы ")
    #expect(TemplateBlank.prefix(of: "? ₽") == "")
    #expect(TemplateBlank.prefix(of: "Кофе") == nil)
  }

  @Test func theTemplateOfTheModelIsRecognised() {
    #expect(TemplateBlank.isBlank(Template(text: "Такси — ?")))
    #expect(!TemplateBlank.isBlank(Template(text: "Такси", amountE4: e4("300"))))
  }

  @Test func theFilledLineIsReadByTheEntryLine() {
    let line = TemplateBlank.filled("Такси до работы — ? ₽", amount: "350") ?? ""
    let parsed = Fixture.parse(line)
    #expect(parsed.amount == 350)
    #expect(parsed.note == "Такси до работы")
  }
}

@Suite("Habits of the moment")
struct HabitOrderingTests {
  let calendar = CalendarContext.utc
  // Friday, 2026-10-16, 08:30 UTC.
  var now: Date { calendar.moment(DateOnly(year: 2026, month: 10, day: 16), hour: 8, minute: 30) }

  func event(_ label: String, day: Int, hour: Int) -> HabitEvent {
    HabitEvent(
      label: label,
      occurredAt: calendar.moment(DateOnly(year: 2026, month: 10, day: day), hour: hour, minute: 5))
  }

  @Test func theLabelStopsAtTheAmountTheBlankOrADash() {
    #expect(HabitOrdering.label(of: "Кофе 250") == "кофе")
    #expect(HabitOrdering.label(of: "Такси до работы — ? ₽") == "такси до работы")
    #expect(HabitOrdering.label(of: "ЁЛКА") == "елка")
    #expect(HabitOrdering.label(of: "250") == "")
  }

  @Test func dayPartsCoverTheClock() {
    #expect(DayPart(hour: 4) == .night)
    #expect(DayPart(hour: 5) == .morning)
    #expect(DayPart(hour: 10) == .morning)
    #expect(DayPart(hour: 11) == .day)
    #expect(DayPart(hour: 16) == .day)
    #expect(DayPart(hour: 17) == .evening)
    #expect(DayPart(hour: 22) == .evening)
    #expect(DayPart(hour: 23) == .night)
    #expect(DayPart(hour: 0) == .night)
  }

  @Test func theMorningHabitComesFirstInTheMorning() {
    let coffee = Template(text: "Кофе")
    let cafe = Template(text: "Кафе")
    // Every day at 08:05 a coffee; Fridays at 20:05 a cafe.
    var history = (1...14).map { event("Кофе 250", day: $0, hour: 8) }
    history += [event("Кафе 1800", day: 2, hour: 20), event("Кафе 2100", day: 9, hour: 20)]
    let ordered = HabitOrdering.ordered(
      [cafe, coffee], history: history, now: now, calendar: calendar)
    #expect(ordered.map(\.text) == ["Кофе", "Кафе"])
  }

  @Test func theFridayEveningHabitComesFirstOnAFridayEvening() {
    let coffee = Template(text: "Кофе")
    let cafe = Template(text: "Кафе")
    var history = (1...14).map { event("Кофе 250", day: $0, hour: 8) }
    history += [event("Кафе 1800", day: 2, hour: 20), event("Кафе 2100", day: 9, hour: 20)]
    let evening = calendar.moment(DateOnly(year: 2026, month: 10, day: 16), hour: 20, minute: 10)
    let ordered = HabitOrdering.ordered(
      [coffee, cafe], history: history, now: evening, calendar: calendar)
    #expect(ordered.map(\.text) == ["Кафе", "Кофе"])
  }

  @Test func pinnedChipsStayFirst() {
    let pinned = Template(text: "Метро", pinned: true)
    let coffee = Template(text: "Кофе")
    let history = (1...10).map { event("Кофе", day: $0, hour: 8) }
    let ordered = HabitOrdering.ordered(
      [coffee, pinned], history: history, now: now, calendar: calendar)
    #expect(ordered.map(\.text) == ["Метро", "Кофе"])
  }

  @Test func withoutHistoryTheOrderIsByUseThenByText() {
    let often = Template(text: "Б", useCount: 5)
    let rare = Template(text: "А", useCount: 1)
    let alsoRare = Template(text: "В", useCount: 1)
    #expect(
      HabitOrdering.ordered([alsoRare, rare, often], history: [], now: now, calendar: calendar)
        .map(\.text) == ["Б", "А", "В"])
  }

  @Test func archivedChipsAreNotShown() {
    let gone = Template(text: "Старый", archived: true)
    #expect(HabitOrdering.ordered([gone], history: [], now: now, calendar: calendar).isEmpty)
  }

  @Test func aHabitOlderThanSixMonthsIsForgotten() {
    let coffee = Template(text: "Кофе")
    let old = HabitEvent(label: "Кофе", occurredAt: now.addingTimeInterval(-200 * 86_400))
    #expect(
      HabitOrdering.scores(for: [coffee], history: [old], now: now, calendar: calendar)[coffee.id]
        == 0)
  }

  @Test func theMemoryEndsAtAWholeDay() {
    let coffee = Template(text: "Кофе")
    let today = calendar.day(of: now)
    let edge = HabitEvent(
      label: "Кофе",
      occurredAt: calendar.moment(
        calendar.adding(days: -HabitOrdering.memoryDays, to: today), hour: 8, minute: 0))
    let before = HabitEvent(
      label: "Кофе",
      occurredAt: calendar.moment(
        calendar.adding(days: -HabitOrdering.memoryDays - 1, to: today), hour: 8, minute: 0))
    #expect(
      HabitOrdering.scores(for: [coffee], history: [edge], now: now, calendar: calendar)[coffee.id]
        ?? 0 > 0)
    #expect(
      HabitOrdering.scores(for: [coffee], history: [before], now: now, calendar: calendar)[
        coffee.id] == 0)
  }

  @Test func theFutureIsNotAHabit() {
    let coffee = Template(text: "Кофе")
    let future = HabitEvent(label: "Кофе", occurredAt: now.addingTimeInterval(3_600))
    #expect(
      HabitOrdering.scores(for: [coffee], history: [future], now: now, calendar: calendar)[
        coffee.id] == 0)
  }
}

@Suite("Several operations in one line")
struct MultiEntryLineTests {
  @Test func theLineSplitsAtSemicolons() {
    #expect(
      MultiEntryLine.split("кофе 250; метро 62; обед 450") == ["кофе 250", "метро 62", "обед 450"])
    #expect(MultiEntryLine.split("кофе 250;") == ["кофе 250"])
    #expect(MultiEntryLine.split(";; кофе 250 ;;  ; метро 62") == ["кофе 250", "метро 62"])
    #expect(MultiEntryLine.split("кофе 250") == ["кофе 250"])
    #expect(MultiEntryLine.split(" ; ").isEmpty)
  }

  @Test func theFullWidthSemicolonSplitsToo() {
    #expect(MultiEntryLine.split("кофе 250；метро 62").count == 2)
    #expect(MultiEntryLine.containsSeparator("а；б"))
    #expect(!MultiEntryLine.containsSeparator("кофе 250"))
  }

  @Test func everyPartIsReadOnItsOwn() {
    let reading = MultiEntryLine.read(
      "вчера кофе 250; метро 62; обед 450", parser: Fixture.parser, today: Fixture.today)
    #expect(reading.isBatch)
    #expect(reading.parts.count == 3)
    #expect(reading.parts.map(\.parsed.amount) == [250, 62, 450])
    // The day written in the first part belongs to the first part alone.
    #expect(reading.parts[0].parsed.date == DateOnly(year: 2026, month: 9, day: 17))
    #expect(reading.parts[1].parsed.date == nil)
    #expect(reading.parts[2].parsed.date == nil)
    #expect(reading.isSaveable)
  }

  @Test func theCardOfOnePartDoesNotReachTheNext() {
    let reading = MultiEntryLine.read(
      "тинькофф кофе 250; метро 62", parser: Fixture.parser, today: Fixture.today)
    #expect(reading.parts[0].parsed.paymentMethodId == Fixture.tinkoff)
    #expect(reading.parts[1].parsed.paymentMethodId == nil)
  }

  @Test func aPartWithoutAnAmountMakesTheBatchUnsaveable() {
    let reading = MultiEntryLine.read(
      "кофе 250; метро; обед 450", parser: Fixture.parser, today: Fixture.today)
    #expect(!reading.isSaveable)
    #expect(reading.firstProblem == 1)
  }

  @Test func oneOperationIsNoBatch() {
    let reading = MultiEntryLine.read("кофе 250", parser: Fixture.parser, today: Fixture.today)
    #expect(!reading.isBatch)
    #expect(reading.isSaveable)
  }

  @Test func aTooLongLineIsNotWritten() {
    let line = (1...(MultiEntryLine.maxParts + 1)).map { "кофе \($0)" }.joined(separator: "; ")
    let reading = MultiEntryLine.read(line, parser: Fixture.parser, today: Fixture.today)
    #expect(reading.truncated)
    #expect(reading.parts.count == MultiEntryLine.maxParts)
    #expect(!reading.isSaveable)
  }

  @Test func anEmptyLineIsNothing() {
    let reading = MultiEntryLine.read(" ; ", parser: Fixture.parser, today: Fixture.today)
    #expect(reading.parts.isEmpty)
    #expect(!reading.isSaveable)
  }
}

@Suite("Oops, 350")
struct CorrectionLineTests {
  func read(_ text: String) -> AmountCorrection? {
    CorrectionLine.read(text, parser: Fixture.parser, today: Fixture.today)
  }

  @Test func theWordOfRegretAndTheAmountAreACorrection() {
    #expect(read("ой 350")?.amount == 350)
    #expect(read("ой, 350")?.amount == 350)
    #expect(read("Ой! 350 р")?.amount == 350)
    #expect(read("исправь на 1 200")?.amount == 1200)
    #expect(read("исправь 1200")?.amount == 1200)
    #expect(read("oops 12.5 usd")?.amount == dec("12.5"))
    #expect(read("oops 12.5 usd")?.currency == .usd)
    #expect(read("fix to 99")?.amount == 99)
  }

  @Test func aFormulaIsKept() {
    let correction = read("ой (1000+600)/2")
    #expect(correction?.amount == 800)
    #expect(correction?.expression == "(1000+600)/2")
  }

  @Test func anythingMoreThanAnAmountIsANewOperation() {
    #expect(read("ой кофе 350") == nil)
    #expect(read("ой 350 вчера") == nil)
    #expect(read("ой 350 в Пятёрочка") == nil)
    #expect(read("ой +350") == nil)
  }

  @Test func withoutTheWordOrTheAmountItIsNothing() {
    #expect(read("кофе 350") == nil)
    #expect(read("350") == nil)
    #expect(read("ой") == nil)
    #expect(read("") == nil)
    #expect(read("ой 3000÷0") == nil)
  }
}

@Suite("A tip written in the line")
struct TipLineTests {
  func read(_ text: String) -> TipReading? {
    TipLine.read(text, parser: Fixture.parser, today: Fixture.today)
  }

  @Test func theTeaOfTheExampleIsATip() {
    let tip = read("кафе 2000 чай 200")
    #expect(tip?.baseLine == "кафе 2000")
    #expect(tip?.amount == .fixed(200))
    #expect(tip?.kind == .tip)
    #expect(tip?.phrase == "чай 200")
  }

  @Test func theWordsOfTipsAndServiceAreRead() {
    #expect(read("ужин 3500 чаевые 350")?.amount == .fixed(350))
    #expect(read("ужин 3500 на чай 300")?.baseLine == "ужин 3500")
    #expect(read("ужин 3500 на чай 300")?.phrase == "на чай 300")
    #expect(read("dinner 80 tip 12")?.amount == .fixed(12))
    #expect(read("ужин 3500 сервисный сбор 350")?.kind == .serviceCharge)
    #expect(read("ужин 3500 service charge 350")?.kind == .serviceCharge)
    #expect(read("ужин 3500 обслуживание 10%")?.kind == .serviceCharge)
  }

  @Test func aTipMayComeFirstOrBeAPercent() {
    #expect(read("чаевые 10% кафе 2000")?.amount == .percent(10))
    #expect(read("чаевые 10% кафе 2000")?.baseLine == "кафе 2000")
    #expect(read("кафе 2000 чаевые 10 %")?.amount == .percent(10))
    #expect(read("кафе 2000 чаевые 10 процентов")?.amount == .percent(10))
    #expect(read("кафе 2000 чаевые 200р")?.amount == .fixed(200))
  }

  @Test func theTipIsAPartOnTopOfTheBill() {
    let reading = read("кафе 2000 чай 200")
    let parts = reading?.parts(base: e4("2000"))
    #expect(parts?.base == e4("2000"))
    #expect(parts?.tip == e4("200"))
  }

  @Test func aPercentIsTakenOfTheBillAndRoundedToAKopek() {
    let reading = read("кафе 1234.5 чаевые 7%")
    #expect(reading?.parts(base: e4("1234.5"))?.tip == e4("86.42"))  // 86.415 → 86.42
    #expect(read("кафе 2000 чаевые 10%")?.parts(base: e4("2000"))?.tip == e4("200"))
  }

  @Test func withoutABillThereIsNoSplit() {
    #expect(read("чай 200") == nil)
    #expect(read("чаевые 200") == nil)
    #expect(read("на чай 200") == nil)
  }

  @Test func ordinaryLinesAreLeftAlone() {
    #expect(read("кафе 2000") == nil)
    #expect(read("чай 200 кофе") == nil)
    #expect(read("кафе 2000 чай") == nil)
    #expect(read("кафе 2000 чай 0") == nil)
  }

  @Test func theWholeSubcategoryHasOneName() {
    #expect(TipReading.subcategoryName == "Чаевые")
  }

  @Test func aZeroOrHugeTipMakesNoParts() {
    let reading = TipReading(baseLine: "x", amount: .fixed(0), kind: .tip, phrase: "")
    #expect(reading.parts(base: e4("100")) == nil)
    let noBase = TipReading(baseLine: "x", amount: .fixed(5), kind: .tip, phrase: "")
    #expect(noBase.parts(base: .zero) == nil)
  }
}
