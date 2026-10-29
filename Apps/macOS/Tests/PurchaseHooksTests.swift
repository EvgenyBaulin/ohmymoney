import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The purchase hooks of the entry line, the editor, «Стоит посмотреть», the people and the
/// calendar of gifts: the line puts the discount into the draft, the questions «Подождать?» and
/// «Сколько проехали с прошлой заправки?» are asked in their order, the fields keep what the
/// owner set, and every word reads in both languages.
@MainActor
final class PurchaseHooksTests: XCTestCase {
  private var book: CardEntryBook!

  override func setUp() async throws {
    book = try await CardEntryBook()
  }

  override func tearDown() async throws {
    await book?.close()
    book = nil
  }

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func reading(_ line: String, kind: TransactionKind? = nil) -> InputLineReading {
    CoreLineInterpreter(
      vocabulary: book.environment.vocabulary, calendar: book.environment.calendar,
      catalog: book.environment.currencyCatalog
    ).read(line, today: book.today, kind: kind)
  }

  private func enter(_ line: String, into model: EntryDraftModel) throws {
    let read = reading(line, kind: model.draft.kind)
    let amount = try read.parsed.amount.map { try AmountE4(decimal: $0) } ?? model.draft.amount
    model.apply(read, amount: amount, today: book.today, text: line)
  }

  private func asked(
    _ model: EntryDraftModel, _ money: EntrySaveQuestions.Money
  ) -> [EntrySaveQuestions.Kind] {
    var kinds: [EntrySaveQuestions.Kind] = []
    while let question = EntrySaveQuestions.next(
      for: model, environment: book.environment, money: money, now: Date()), kinds.count < 8
    {
      kinds.append(question.kind)
      switch question.kind {
      case .ahead: model.aheadAnswered = true
      case .overLimit: model.overLimitAnswered = true
      case .minBalance: model.minBalanceAnswered = true
      case .repeated: model.repeatConfirmed = true
      case .pause: model.pauseAnswered = true
      case .mileage: model.mileageAnswered = true
      }
    }
    return kinds
  }

  private func money(
    pause: Bool = true, free: Int64? = 100_000, asksMileage: Bool = true, lastFill: FuelFill? = nil
  ) -> EntrySaveQuestions.Money {
    var money = EntrySaveQuestions.Money()
    money.purchase = PurchaseSettings(pauseEnabled: pause, fuelAskMileage: asksMileage)
    money.freeRubE4 = free.map { AmountE4(whole: $0) }
    money.lastFill = lastFill
    return money
  }

  // MARK: The discount in the line

  func testTheLineFillsTheDiscountAndTheSavedOperationKeepsIt() throws {
    let model = book.model()
    try enter("наушники 5000 скидка 300", into: model)
    XCTAssertEqual(model.draft.discountE4, AmountE4(whole: 300))
    let saved = try book.save(model)
    let stored = try XCTUnwrap(try book.stored(saved.id)).transaction
    XCTAssertEqual(stored.discountE4, AmountE4(whole: 300))
  }

  func testTheEnglishWordGivesTheDiscountToo() throws {
    let model = book.model()
    try enter("headphones 5000 discount 300", into: model)
    XCTAssertEqual(model.draft.discountE4, AmountE4(whole: 300))
  }

  func testADiscountPickedInThePanelIsNotOverwrittenByTheLine() throws {
    let model = book.model()
    model.draft.discountE4 = AmountE4(whole: 111)
    try enter("наушники 5000 скидка 300", into: model)
    XCTAssertEqual(model.draft.discountE4, AmountE4(whole: 111))
  }

  func testALineThatStopsNamingTheDiscountTakesItBack() throws {
    let model = book.model()
    try enter("наушники 5000 скидка 300", into: model)
    XCTAssertNotNil(model.draft.discountE4)
    try enter("наушники 5000", into: model)
    XCTAssertNil(model.draft.discountE4)
  }

  func testAnIncomeHasNoDiscount() throws {
    let model = book.model()
    try enter("+5000 зарплата скидка 300", into: model)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertNil(model.draft.discountE4)
  }

  func testEditingSomethingElseKeepsTheFieldsOfThePurchase() throws {
    let model = book.model()
    try enter("наушники 5000 скидка 300", into: model)
    model.draft.odometerKm = 120_500
    model.draft.regret = .yes
    model.draft.regretAskedOn = book.today
    let saved = try book.save(model)
    let stored = try XCTUnwrap(try book.stored(saved.id))
    var draft = TransactionDraft(entry: stored)
    draft.note = "наушники белые"
    let edited = try draft.materialize(updating: stored).transaction
    XCTAssertEqual(edited.discountE4, AmountE4(whole: 300))
    XCTAssertEqual(edited.odometerKm, 120_500)
    XCTAssertEqual(edited.regret, .yes)
    XCTAssertEqual(edited.regretAskedOn, book.today)
  }

  func testTheWaitForARefundSurvivesAnEdit() throws {
    let day = DateOnly(year: 2026, month: 11, day: 20)
    var draft = TransactionDraft(kind: .expense, amount: AmountE4(whole: 900))
    draft.refundWaitingUntil = day
    XCTAssertEqual(TransactionDraft(entry: try materialized(draft)).refundWaitingUntil, day)
  }

  private func materialized(_ draft: TransactionDraft) throws -> TransactionEntry {
    var draft = draft
    if draft.parts.isEmpty { draft.parts = [PartDraft(amount: draft.amount)] }
    return try draft.materialize(rublesConverter: { $0 })
  }

  // MARK: The questions

  func testThePauseIsOffByDefaultAndAsksAboveTheShare() throws {
    let model = book.model()
    try enter("ноутбук 50000", into: model)
    XCTAssertEqual(asked(model, money(pause: false)), [])
    let again = book.model()
    try enter("ноутбук 50000", into: again)
    XCTAssertEqual(asked(again, money()), [.pause])
  }

  func testAPurchaseWithinTheShareAsksNothing() throws {
    let model = book.model()
    try enter("кофе 250", into: model)
    XCTAssertEqual(asked(model, money()), [])
  }

  func testNoFreeSumAsksNothingAndAZeroOneAsksWithoutAShare() throws {
    let model = book.model()
    try enter("ноутбук 50000", into: model)
    XCTAssertEqual(asked(model, money(free: nil)), [])
    let question = model.pauseQuestion(money: money(free: 0))
    XCTAssertNotNil(question)
    XCTAssertNil(question?.sharePercent)
  }

  func testAPurchaseInAnotherCurrencyIsCountedInRubles() throws {
    let model = book.model()
    model.draft.currency = .usd
    model.draft.amount = AmountE4(whole: 500)
    model.draft.parts = [PartDraft(amount: AmountE4(whole: 500))]
    var withRate = money()
    withRate.rubPerUnit = [.usd: 90]
    XCTAssertEqual(model.pauseQuestion(money: withRate)?.amountRubE4, AmountE4(whole: 45_000))
    XCTAssertNil(model.pauseQuestion(money: money()))
  }

  func testAFillUpAsksForTheMileageAndOnlyOnce() throws {
    let model = book.model()
    try enter("заправка 3000 45 л", into: model)
    XCTAssertEqual(asked(model, money(pause: false)), [.mileage])
    let off = book.model()
    try enter("заправка 3000 45 л", into: off)
    XCTAssertEqual(asked(off, money(pause: false, asksMileage: false)), [])
    let known = book.model()
    try enter("заправка 3000 45 л", into: known)
    known.draft.odometerKm = 100_000
    XCTAssertEqual(asked(known, money(pause: false)), [])
  }

  func testThePauseIsAskedBeforeTheMileage() throws {
    let model = book.model()
    try enter("заправка 40000 45 л", into: model)
    XCTAssertEqual(asked(model, money()), [.pause, .mileage])
  }

  func testTheKilometresDrivenMakeTheMileageFromTheLastFillUp() throws {
    let last = FuelFill(
      transactionId: UUID(), day: book.today, odometerKm: 120_000, liters: 40,
      costRubE4: AmountE4(whole: 2_000))
    let model = book.model()
    model.answerMileage(550, previous: last)
    XCTAssertEqual(model.draft.odometerKm, 120_550)
    XCTAssertTrue(model.mileageAnswered)
    let first = book.model()
    first.answerMileage(88_000, previous: nil)
    XCTAssertEqual(first.draft.odometerKm, 88_000)
    let unknown = book.model()
    unknown.answerMileage(nil, previous: last)
    XCTAssertNil(unknown.draft.odometerKm)
    XCTAssertTrue(unknown.mileageAnswered)
  }

  // MARK: The rules of the fields

  func testFuelCategoriesAreToldByTheirNames() {
    for name in ["Топливо", "Бензин", "АЗС: заправка", "Fuel", "Petrol"] {
      XCTAssertTrue(PurchaseFieldRules.isFuelName(name), name)
    }
    XCTAssertFalse(PurchaseFieldRules.isFuelName("Кафе и рестораны"))
  }

  func testTheMileageTextReadsWholeKilometres() {
    XCTAssertEqual(PurchaseFieldRules.mileage(from: "120 500"), 120_500)
    XCTAssertEqual(PurchaseFieldRules.mileage(from: "120,500"), 120_500)
    XCTAssertNil(PurchaseFieldRules.mileage(from: ""))
    XCTAssertNil(PurchaseFieldRules.mileage(from: "0"))
    XCTAssertEqual(PurchaseFieldRules.mileageText(nil), "")
    XCTAssertEqual(PurchaseFieldRules.mileageText(7), "7")
  }

  func testTheAnswerOnADraftIsTheOneTheCoreWritesOnAnOperation() {
    let today = DateOnly(year: 2026, month: 10, day: 29)
    var draft = TransactionDraft(kind: .expense, amount: AmountE4(whole: 100))
    PurchaseFieldRules.answer(.yes, on: &draft, today: today)
    let operation = RegretSchedule.recording(
      .yes, on: Transaction(kind: .expense, occurredAt: Date(), amountE4: AmountE4(whole: 100)),
      today: today)
    XCTAssertEqual(draft.regret, operation.regret)
    XCTAssertEqual(draft.regretAskedOn, operation.regretAskedOn)
  }

  func testTheRowsShowForTheKindsThatHaveThem() {
    var draft = TransactionDraft(kind: .expense, amount: AmountE4(whole: 100))
    XCTAssertTrue(PurchaseFieldRules.showsDiscount(draft))
    XCTAssertTrue(PurchaseFieldRules.showsRegret(draft, editsSaved: true))
    XCTAssertFalse(PurchaseFieldRules.showsRegret(draft, editsSaved: false))
    XCTAssertFalse(PurchaseFieldRules.showsWaitingRefund(draft))
    draft.kind = .refund
    XCTAssertTrue(PurchaseFieldRules.showsWaitingRefund(draft))
    XCTAssertFalse(PurchaseFieldRules.showsDiscount(draft))
    draft.kind = .income
    XCTAssertFalse(PurchaseFieldRules.showsDiscount(draft))
  }

  // MARK: Words

  func testEveryKeyHasWordsInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for key in PurchaseHookText.keys {
        let value = environment.language(key, table: PurchaseHookText.table)
        XCTAssertNotEqual(value, key, "\(choice) \(key)")
        XCTAssertFalse(value.isEmpty, key)
      }
      for action in WorthALookNoteText.Action.allCases where action.isPurchase {
        XCTAssertNotEqual(environment.language(action.key, table: action.table), action.key)
      }
    }
  }

  func testTheLinesOfThePurchaseNotesNameWhatTheyAreAbout() {
    let russian = environment(.russian)
    let english = environment(.english)
    let wish = PurchaseNote.wishReady(
      wishId: UUID(), name: "Наушники", priceRubE4: AmountE4(whole: 32_000))
    XCTAssertTrue(PurchaseHookText.note(wish, russian).contains("Наушники"))
    XCTAssertTrue(PurchaseHookText.note(wish, russian).contains("накоплено"))
    let late = PurchaseNote.refundWaiting(
      transactionId: UUID(), note: "Куртка", amountRubE4: AmountE4(whole: 4_000),
      expectedBy: book.today, daysWaiting: 20, daysLate: 3)
    XCTAssertTrue(PurchaseHookText.note(late, russian).contains("просрочен"))
    XCTAssertTrue(PurchaseHookText.note(late, russian).contains("3 дня"))
    XCTAssertTrue(PurchaseHookText.note(late, english).contains("late"))
    XCTAssertTrue(PurchaseHookText.note(late, english).contains("3 days"))
    XCTAssertTrue(PurchaseHookText.isAlarm(late))
    XCTAssertEqual(PurchaseHookText.symbol(late), "exclamationmark.circle")
    let waiting = PurchaseNote.refundWaiting(
      transactionId: UUID(), note: nil, amountRubE4: AmountE4(whole: 4_000),
      expectedBy: book.today, daysWaiting: 5, daysLate: 0)
    XCTAssertFalse(PurchaseHookText.isAlarm(waiting))
    XCTAssertTrue(PurchaseHookText.note(waiting, russian).contains("5 дней"))
  }

  func testTheBirthdayLinesNameThePersonTheDayAndTheBudget() {
    let russian = environment(.russian)
    let day = GiftDay(
      personId: UUID(), name: "Маша", date: DateOnly(year: 2027, month: 3, day: 14), daysLeft: 7,
      turnsAge: 30, budgetE4: AmountE4(whole: 5_000), reminderDue: true)
    let line = PurchaseHookText.birthday(day, russian)
    XCTAssertTrue(line.contains("Маша") && line.contains("14 марта") && line.contains("бюджет"))
    var without = day
    without.budgetE4 = nil
    XCTAssertFalse(PurchaseHookText.birthday(without, russian).contains("бюджет"))
    var today = day
    today.daysLeft = 0
    XCTAssertTrue(PurchaseHookText.birthday(today, russian).contains("Сегодня"))
    XCTAssertTrue(PurchaseHookText.calendarLine(day, russian).contains("исполняется 30"))
    XCTAssertEqual(PurchaseHookText.symbol(.birthday(day)), "gift")
  }

  func testThePurchaseLinesOfTheCardOfferTheirActions() {
    let regret = PurchaseNote.regret(
      RegretQuestion(
        transactionId: UUID(), boughtOn: book.today, categoryId: nil,
        amountRubE4: AmountE4(whole: 9_000), note: "Куртка"))
    XCTAssertEqual(
      WorthALookNoteText.actions(.purchase(regret)), [.regretNo, .regretYes, .regretSkip])
    let day = GiftDay(
      personId: UUID(), name: "Маша", date: book.today, daysLeft: 3, turnsAge: nil, budgetE4: nil,
      reminderDue: true)
    XCTAssertEqual(WorthALookNoteText.actions(.purchase(.birthday(day))), [.createEvent, .done])
    for note in [regret, .birthday(day)] {
      XCTAssertFalse(
        WorthALookNoteText.text(
          .purchase(note), debts: [:], accounts: [:], environment(.english)
        ).isEmpty)
    }
  }

  // MARK: People and the calendar of gifts

  func testTheYearOfBirthReadsOnlyWhenItIsAYear() {
    XCTAssertEqual(PersonGiftFields.year(from: "1990"), 1990)
    XCTAssertNil(PersonGiftFields.year(from: "199"))
    XCTAssertNil(PersonGiftFields.year(from: "1800"))
    XCTAssertNil(PersonGiftFields.year(from: "19900"))
  }

  func testAPersonKeepsTheBirthdayAndTheBudgetInTheDatabase() throws {
    let references = try XCTUnwrap(book.environment.references)
    var person = Person(name: "Маша")
    person.birthday = Birthday(month: 3, day: 14)
    person.giftBudgetE4 = AmountE4(whole: 5_000)
    try references.save(person)
    let loaded = try XCTUnwrap(
      try references.people(includeArchived: true).first { $0.id == person.id })
    XCTAssertEqual(loaded.birthday, Birthday(month: 3, day: 14))
    XCTAssertEqual(loaded.giftBudgetE4, AmountE4(whole: 5_000))
  }

  func testTheCalendarMarksTheDaysOfBirthdays() {
    let masha = Person(
      name: "Маша", birthday: Birthday(month: 2, day: 29, year: 1996),
      giftBudgetE4: AmountE4(whole: 5_000))
    let petya = Person(name: "Петя", birthday: Birthday(month: 2, day: 27))
    let gone = Person(name: "Старый", archived: true, birthday: Birthday(month: 2, day: 27))
    let nobody = Person(name: "Без даты")
    let days = (20...28).map { DateOnly(year: 2027, month: 2, day: $0) }
    let found = CalendarBirthdays.gifts(
      people: [masha, petya, gone, nobody], on: days, today: DateOnly(year: 2027, month: 2, day: 21)
    )
    XCTAssertEqual(found[DateOnly(year: 2027, month: 2, day: 28)]?.map(\.name), ["Маша"])
    XCTAssertEqual(found[DateOnly(year: 2027, month: 2, day: 28)]?.first?.turnsAge, 31)
    XCTAssertEqual(found[DateOnly(year: 2027, month: 2, day: 27)]?.map(\.name), ["Петя"])
    XCTAssertEqual(found.count, 2)
  }

  func testTheEventOfABirthdayIsOfferedUntilItExists() {
    let environment = environment(.russian)
    let day = GiftDay(
      personId: UUID(), name: "Маша", date: DateOnly(year: 2027, month: 3, day: 14), daysLeft: 5,
      turnsAge: nil, budgetE4: AmountE4(whole: 5_000), reminderDue: true)
    XCTAssertTrue(CalendarBirthdays.offersEvent(for: day, events: [], environment))
    let event = GiftCalendar.event(
      for: day, name: PurchaseHookActions.eventName(for: day, environment))
    XCTAssertEqual(event.budgetE4, AmountE4(whole: 5_000))
    XCTAssertFalse(CalendarBirthdays.offersEvent(for: day, events: [event], environment))
    var past = day
    past.daysLeft = -1
    XCTAssertFalse(CalendarBirthdays.offersEvent(for: past, events: [], environment))
  }

  func testPlanningShowsAtMostThreeBirthdaysOfTheNextMonth() {
    let today = DateOnly(year: 2026, month: 10, day: 29)
    let people =
      (1...5).map { number in
        Person(name: "P\(number)", birthday: Birthday(month: 11, day: number))
      } + [Person(name: "Far", birthday: Birthday(month: 6, day: 1))]
    let upcoming = PlanningBirthdays.upcoming(people: people, today: today)
    XCTAssertEqual(upcoming.map(\.name), ["P1", "P2", "P3"])
  }
}
