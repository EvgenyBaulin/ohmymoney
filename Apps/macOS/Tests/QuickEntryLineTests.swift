import AppCore
import XCTest

@testable import OhMyMoney

/// Quick entry, the parts that need no window: what a line is (a correction, several operations,
/// a tip, «повторить вчера»), what a paste is, the offer a text of a bank makes, the places
/// offered while typing, the correction of the last operation, and the words in both languages.
@MainActor
final class QuickEntryLineTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 22)
  private let parser = InputLineParser(vocabulary: .empty, calendar: .utc)

  // MARK: What a line is

  func testALineIsOrdinaryUnlessItSaysMore() {
    XCTAssertEqual(QuickLine.classify("кофе 250", parser: parser, today: today), .ordinary)
    XCTAssertEqual(QuickLine.classify("", parser: parser, today: today), .ordinary)
    // A stray separator at the end is still one operation.
    XCTAssertEqual(QuickLine.classify("кофе 250;", parser: parser, today: today), .ordinary)
  }

  func testAWordOfRegretAndAnAmountIsACorrection() {
    guard
      case .correction(let correction) = QuickLine.classify("ой 350", parser: parser, today: today)
    else { return XCTFail("not a correction") }
    XCTAssertEqual(correction.amount, 350)
    // «ой кофе 350» is a new operation, not a correction.
    XCTAssertEqual(QuickLine.classify("ой кофе 350", parser: parser, today: today), .ordinary)
  }

  func testSeveralOperationsInOneLineAreSplitAtTheSemicolons() {
    let kind = QuickLine.classify(
      "вчера кофе 250; метро 62; обед 450", parser: parser, today: today)
    guard case .several(let parts, let truncated) = kind else { return XCTFail("not several") }
    XCTAssertEqual(parts, ["вчера кофе 250", "метро 62", "обед 450"])
    XCTAssertFalse(truncated)
  }

  func testABillWithATipIsOneLineWithATip() {
    guard case .tip(let tip) = QuickLine.classify("кафе 2000 чай 200", parser: parser, today: today)
    else { return XCTFail("not a tip") }
    XCTAssertEqual(tip.baseLine, "кафе 2000")
    XCTAssertEqual(tip.parts(base: AmountE4(whole: 2000))?.tip, AmountE4(whole: 200))
    // A tea is a tea.
    XCTAssertEqual(QuickLine.classify("чай 200", parser: parser, today: today), .ordinary)
  }

  func testRepeatYesterdayInBothLanguages() {
    for phrase in ["повторить вчера", "Повтори вчера", "repeat yesterday", "как вчера"] {
      XCTAssertEqual(
        QuickLine.classify(phrase, parser: parser, today: today), .repeatYesterday, phrase)
    }
  }

  // MARK: Paste

  func testOnlyABlockInsertedIsAPaste() {
    XCTAssertNil(QuickPaste.inserted(old: "ко", new: "кофе"))
    XCTAssertNil(QuickPaste.inserted(old: "кофе 250", new: "кофе 25"))
    let long = "Покупка, карта *3230. 1 250 ₽. PYATEROCHKA. Доступно 52 340,11 ₽"
    XCTAssertEqual(QuickPaste.inserted(old: "", new: long), long)
    XCTAssertEqual(QuickPaste.inserted(old: "x ", new: "x " + long), long)
    XCTAssertEqual(QuickPaste.inserted(old: "x ", new: long + "x "), long)
    XCTAssertEqual(QuickPaste.inserted(old: "ab", new: "a" + long + "b"), long)
  }

  func testATextOfABankFillsTheLineAndAnythingElseStaysAsPasted() {
    let push = "Покупка, карта *3230. 1 250 ₽. PYATEROCHKA. Доступно 52 340,11 ₽"
    guard case .message(let message) = QuickPaste.decide(chunk: push, today: today)
    else { return XCTFail("not read") }
    XCTAssertEqual(message.money.amount, AmountE4(whole: 1250))
    XCTAssertEqual(message.cardLast4, "3230")
    XCTAssertEqual(message.balance?.amount.decimal, Decimal(string: "52340.11"))
    XCTAssertEqual(
      QuickPaste.decide(chunk: "куплю хлеб, молоко и сыр в магазине рядом", today: today), .plain)
  }

  func testAListOfPushesIsAListWithTicks() {
    let list = """
      MIR-3230 12:45 Покупка 1250р PYATEROCHKA Баланс: 52340.11р
      MIR-3230 13:10 Покупка 300р KOFEINYA Баланс: 52040.11р
      """
    guard case .list(let items) = QuickPaste.decide(chunk: list, today: today)
    else { return XCTFail("not a list") }
    XCTAssertEqual(items.count, 2)
  }

  // MARK: The offer of a text of a bank

  private func card(_ name: String, last4: String?, account: UUID = UUID()) -> PaymentCard {
    PaymentCard(accountId: account, name: name, last4: last4)
  }

  private func message(last4: String? = "3230") -> BankMessage {
    BankMessage(
      bank: .tbank, operation: .purchase,
      money: Money(amount: AmountE4(whole: 1250), currency: .rub), merchant: "PYATEROCHKA",
      cardLast4: last4, balance: Money(amount: AmountE4(whole: 52340), currency: .rub))
  }

  func testTheCardOfTheDigitsIsNamedInTheLine() {
    let platinum = card("Платинум", last4: "3230")
    let offer = QuickBank.offer(
      for: message(), cards: [platinum, card("Другая", last4: "9999")], places: [],
      parser: InputLineParser(
        vocabulary: ParserVocabulary(
          cards: [
            .init(entry: .init(id: platinum.id, name: "Платинум"), accountId: platinum.accountId)
          ]),
        calendar: .utc),
      today: today)
    XCTAssertEqual(offer.card?.cardId, platinum.id)
    XCTAssertEqual(offer.question, QuickCardQuestion.none)
    XCTAssertTrue(offer.line.contains("1250"), offer.line)
    XCTAssertFalse(offer.reconcileAfter, "a count is the owner's tick")
  }

  func testDigitsNoCardHasAreAskedOnceAndTwoCardsAreAsked() {
    let unknown = QuickBank.offer(
      for: message(), cards: [card("Платинум", last4: "1111")], places: [], parser: parser,
      today: today)
    XCTAssertEqual(unknown.question, .unknown(last4: "3230"))
    XCTAssertNil(unknown.card)
    let both = QuickBank.offer(
      for: message(), cards: [card("А", last4: "3230"), card("Б", last4: "3230")], places: [],
      parser: parser, today: today)
    guard case .ambiguous(let candidates) = both.question else { return XCTFail("not ambiguous") }
    XCTAssertEqual(candidates.count, 2)
    // No digits in the text: nothing to ask.
    XCTAssertEqual(
      QuickBank.offer(for: message(last4: nil), cards: [], places: [], parser: parser, today: today)
        .question, QuickCardQuestion.none)
  }

  func testAnArchivedCardIsNotLookedFor() {
    var archived = card("Старая", last4: "3230")
    archived.archived = true
    XCTAssertEqual(
      QuickBank.offer(for: message(), cards: [archived], places: [], parser: parser, today: today)
        .question, .unknown(last4: "3230"))
  }

  func testAListMarksWhatTheLedgerHasAlready() throws {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.moment(today, hour: 12, minute: 0),
      amount: AmountE4(whole: 1250), note: "Пятёрочка")
    draft.normalizeSinglePart()
    let known = try draft.materialize()
    let items = [
      BankListItem(source: "a", message: message()),
      BankListItem(
        source: "b",
        message: BankMessage(
          operation: .purchase, money: Money(amount: AmountE4(whole: 300), currency: .rub),
          merchant: "KOFEINYA")),
    ]
    let candidates = QuickBank.candidates(
      items, entries: [known], calendar: .utc, today: today)
    XCTAssertEqual(candidates.map(\.isDuplicate), [true, false])
    XCTAssertEqual(candidates.map(\.isSelected), [false, true])
  }

  // MARK: Places while typing

  func testTheWordBeingTypedIsWhatIsCompleted() {
    XCTAssertEqual(QuickSuggest.prefix(of: "кофе пят"), "пят")
    XCTAssertNil(QuickSuggest.prefix(of: "кофе пят "))
    XCTAssertNil(QuickSuggest.prefix(of: "кофе 250"))
    XCTAssertNil(QuickSuggest.prefix(of: "к"))
  }

  func testChoosingAPlaceBringsItsUsualAmountUnlessTheLineHasOne() {
    let placeId = UUID()
    let history = (0..<7).map { index in
      PlacePurchase(
        placeId: placeId, money: Money(amount: AmountE4(whole: 1200), currency: .rub),
        occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400))
    }
    let place = PlaceSuggestions.suggest(
      prefix: "пят", places: [.init(id: placeId, name: "Пятёрочка")], history: history
    ).first!
    XCTAssertEqual(place.usual?.amount, AmountE4(whole: 1200))
    XCTAssertEqual(
      QuickSuggest.line(afterChoosing: place, in: "пят", prefix: "пят"), "Пятёрочка 1200")
    XCTAssertEqual(
      QuickSuggest.line(afterChoosing: place, in: "вчера пят", prefix: "пят"),
      "вчера Пятёрочка 1200")
    XCTAssertEqual(
      QuickSuggest.line(afterChoosing: place, in: "900 пят", prefix: "пят"), "900 Пятёрочка")
  }

  func testAChipWithABlankPutsItsWordsAndWaitsForTheSum() {
    let blank = Template(text: "Такси до работы — ? ₽")
    XCTAssertEqual(QuickSuggest.lineForBlank(blank), "Такси до работы ")
    XCTAssertNil(QuickSuggest.lineForBlank(Template(text: "Кофе")))
  }

  func testTheChipsFollowTheHourAndTheWeekday() throws {
    let calendar = CalendarContext.utc
    let monday = calendar.moment(DateOnly(year: 2026, month: 10, day: 19), hour: 8, minute: 0)
    let coffee = Template(text: "Кофе")
    let lunch = Template(text: "Обед")
    var entries: [TransactionEntry] = []
    for offset in 1...4 {
      let day = calendar.adding(days: -7 * offset, to: DateOnly(year: 2026, month: 10, day: 19))
      var draft = TransactionDraft(
        occurredAt: calendar.moment(day, hour: 8, minute: 10), amount: AmountE4(whole: 200),
        note: "Кофе")
      draft.normalizeSinglePart()
      entries.append(try draft.materialize())
    }
    let ordered = HabitOrdering.ordered(
      [lunch, coffee], history: QuickSuggest.habits(of: entries), now: monday, calendar: calendar)
    XCTAssertEqual(ordered.first?.text, "Кофе")
  }

  // MARK: The tip

  func testTheTipGoesToItsSubcategoryUnderTheBillsCategory() {
    let food = CoreKit.Category(kind: .expense, name: "Еда")
    let cafe = CoreKit.Category(parentId: food.id, kind: .expense, name: "Кафе")
    let made = QuickTip.placement(billCategory: cafe.id, in: [food, cafe])
    XCTAssertEqual(made?.isNew, true)
    XCTAssertEqual(made?.category.parentId, food.id)
    XCTAssertEqual(made?.category.name, "Чаевые")
    let tips = CoreKit.Category(parentId: food.id, kind: .expense, name: "чаевые")
    let found = QuickTip.placement(billCategory: cafe.id, in: [food, cafe, tips])
    XCTAssertEqual(found?.category.id, tips.id)
    XCTAssertEqual(found?.isNew, false)
    XCTAssertNil(QuickTip.placement(billCategory: nil, in: [food]))
  }

  // MARK: The correction

  private func correction(_ line: String) throws -> AmountCorrection {
    try XCTUnwrap(CorrectionLine.read(line, parser: parser, today: today))
  }

  private func written(
    _ whole: Int64, note: String, createdHoursAgo: Double, now: Date
  ) throws
    -> TransactionEntry
  {
    var draft = TransactionDraft(
      occurredAt: now.addingTimeInterval(-createdHoursAgo * 3_600), amount: AmountE4(whole: whole),
      note: note)
    draft.normalizeSinglePart()
    var entry = try draft.materialize(now: now.addingTimeInterval(-createdHoursAgo * 3_600))
    entry.transaction.createdAt = now.addingTimeInterval(-createdHoursAgo * 3_600)
    return entry
  }

  func testTheLastOperationIsCorrectedWithTheNewAmountOnItsParts() throws {
    let now = Date()
    let older = try written(100, note: "Хлеб", createdHoursAgo: 5, now: now)
    let last = try written(250, note: "Кофе", createdHoursAgo: 0.1, now: now)
    let dataset = Dataset(entries: [older, last])
    let correction = try correction("ой 350")
    guard case .offer(let offer) = QuickCorrection.outcome(for: correction, in: dataset, now: now)
    else { return XCTFail("no offer") }
    XCTAssertEqual(offer.before.id, last.id)
    XCTAssertFalse(offer.isStale)
    XCTAssertEqual(offer.after.transaction.amountE4, AmountE4(whole: 350))
    XCTAssertEqual(offer.after.parts.map(\.amountE4).reduce(.zero, +), AmountE4(whole: 350))
  }

  func testAnOperationFromHoursAgoIsAskedAboutFirst() throws {
    let now = Date()
    let old = try written(250, note: "Кофе", createdHoursAgo: 26, now: now)
    let outcome = QuickCorrection.outcome(
      for: try correction("ой 350"),
      in: Dataset(entries: [old]), now: now)
    guard case .offer(let offer) = outcome else { return XCTFail("no offer") }
    XCTAssertTrue(offer.isStale)
  }

  func testNothingToCorrectAndWhatCannotBeCorrected() throws {
    let now = Date()
    let none = QuickCorrection.outcome(
      for: try correction("ой 350"), in: Dataset(), now: now)
    XCTAssertEqual(none, .nothingToCorrect)
    let last = try written(250, note: "Кофе", createdHoursAgo: 0.1, now: now)
    let other = QuickCorrection.outcome(
      for: try correction("ой 12 usd"),
      in: Dataset(entries: [last]), now: now)
    XCTAssertEqual(other, .refused(.otherCurrency))
    XCTAssertEqual(
      QuickCorrection.key(of: .otherCurrency), "quick.correction.refused.currency")
  }

  func testAPartAReturnLeansOnCannotBeCorrectedQuietly() throws {
    let now = Date()
    let purchase = try written(250, note: "Наушники", createdHoursAgo: 3, now: now)
    var refundDraft = TransactionDraft(
      kind: .refund, occurredAt: now.addingTimeInterval(-60), amount: AmountE4(whole: 50),
      note: "Возврат")
    refundDraft.normalizeSinglePart()
    refundDraft.parts[0].refundOfPartId = purchase.parts[0].id
    let refund = try refundDraft.materialize(now: now.addingTimeInterval(-60))
    let dataset = Dataset(entries: [purchase, refund])
    XCTAssertTrue(QuickCorrection.leanedParts(in: dataset).contains(purchase.parts[0].id))
  }

  // MARK: Words

  func testEveryWordOfQuickEntryInBothLanguages() {
    for choice in [AppLanguage.Choice.english, .russian] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      for key in QuickText.keys {
        XCTAssertNotEqual(
          environment.language(key, table: QuickText.table), key, "\(key), \(choice)")
      }
    }
    let russian = AppEnvironment()
    russian.language.choice = .russian
    XCTAssertEqual(
      QuickText.counted("quick.drafts.reminder", russian, 3), "3 черновика ждут — дописать?")
    XCTAssertEqual(QuickText.counted("quick.repeat.written", russian, 1), "Записана 1 операция")
    let english = AppEnvironment()
    english.language.choice = .english
    XCTAssertEqual(QuickText.counted("quick.repeat.written", english, 2), "2 operations written")
  }
}
