import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The summaries of the app: their words in both languages, the promise that hidden amounts
/// stay hidden, what this Mac remembers, the answers to the question of the week and the PDF.
@MainActor
final class SummariesTests: XCTestCase {
  private var environment: AppEnvironment!
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() async throws {
    environment = AppEnvironment()
    suiteName = "ohmymoney-summaries-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() async throws {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }

  // MARK: Data

  private let utc = CalendarContext.utc
  private let food = CoreKit.Category(kind: .expense, name: "Продукты")
  private let cafe = CoreKit.Category(kind: .expense, name: "Кафе")
  private let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  private let cashback = CoreKit.Category(kind: .income, name: "Кэшбэк")
  private let shop = Place(name: "Пятёрочка")

  private func entry(
    _ kind: TransactionKind, _ whole: Int64, _ day: DateOnly, _ category: UUID, place: UUID? = nil
  ) -> TransactionEntry {
    let id = UUID()
    let amount = AmountE4(whole: whole)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: utc.noon(of: day), amountE4: amount, placeId: place),
      parts: [TransactionPart(transactionId: id, categoryId: category, amountE4: amount)])
  }

  /// June to September 2026 with cafés jumping in September.
  private func ledger() -> Ledger {
    var entries: [TransactionEntry] = []
    for month in 6...9 {
      entries.append(entry(.income, 100_000, DateOnly(year: 2026, month: month, day: 5), salary.id))
      entries.append(entry(.income, 7_000, DateOnly(year: 2026, month: month, day: 6), cashback.id))
      for day in [3, 9, 15, 21, 27] {
        let date = DateOnly(year: 2026, month: month, day: day)
        entries.append(entry(.expense, 3_000, date, food.id, place: shop.id))
        entries.append(entry(.expense, month == 9 ? 4_000 : 1_000, date, cafe.id))
      }
    }
    let dataset = Dataset(
      entries: entries, categories: [food, cafe, salary, cashback], places: [shop],
      settings: AnalyticsSettings(cashbackCategoryId: cashback.id))
    return Ledger(dataset: dataset, calendar: utc)
  }

  private let today = DateOnly(year: 2026, month: 10, day: 26)
  private var september: SummaryID { .month(MonthKey(year: 2026, month: 9)) }

  private func text(_ ledger: Ledger, language: AppLanguage.Choice, withAmounts: Bool = true)
    -> SummaryText
  {
    environment.language.choice = language
    let money = MoneyFormatter(locale: environment.language.locale, hidesAmounts: false)
    return SummaryText(
      environment: environment, names: SummaryNames(dataset: ledger.dataset), money: money)
  }

  // MARK: Words

  func testEveryKeyOfEveryCardHasWordsInBothLanguages() throws {
    let ledger = ledger()
    let content = try XCTUnwrap(
      SummaryContent.make(september, ledger: ledger, today: today, moods: []))
    let week = try XCTUnwrap(
      SummaryContent.make(
        .week(WeekKey(containing: DateOnly(year: 2026, month: 9, day: 20))), ledger: ledger,
        today: today, moods: []))
    var keys: Set<String> = []
    for hidden in [true, false] {
      for card in content.cards(hideAmounts: hidden) + week.cards(hideAmounts: hidden) {
        keys.insert(card.title.key)
        for line in card.lines { keys.insert(line.key) }
      }
    }
    keys.formUnion(FactID.allCases.map(\.key))
    XCTAssertGreaterThan(keys.count, 30)
    for language in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = language
      for key in keys {
        let value = environment.language(key, table: "Summaries")
        XCTAssertNotEqual(value, key, "\(key) has no text in \(language)")
        XCTAssertFalse(value.isEmpty, key)
      }
    }
  }

  func testEveryFactSentenceIsFilledAndLeavesNothingBehind() {
    let samples: [FactID: [SummaryArg]] = [
      .weekdayLowest: [.weekday(3), .percent(46)], .weekdayHighest: [.weekday(5), .percent(75)],
      .weekendHeavier: [.percent(30)], .weekendLighter: [.percent(30)],
      .firstHalfHeavier: [.percent(30)], .secondHalfHeavier: [.percent(30)],
      .afterIncomeHeavier: [.percent(30)],
      .timeBiggestChecks: [.timeOfDay(.evening), .percent(40)],
      .timeSmallestChecks: [.timeOfDay(.night), .percent(40)],
      .placeDearest: [.place(shop.id), .percent(40)], .placeCheapest: [.place(shop.id), .percent(40)],
      .placeMostVisited: [.place(shop.id), .count(12)],
      .categoryGrew: [.category(food.id), .percent(40)],
      .categoryShrank: [.category(food.id), .percent(40)],
      .checkGrew: [.percent(25)], .checkShrank: [.percent(25)],
      .purchasesMore: [.percent(25), .count(40)], .purchasesFewer: [.percent(25), .count(40)],
      .repeatedNote: [.name("кофе"), .count(10)],
      .goodShareGrew: [.percent(30), .percent(60)], .badShareGrew: [.percent(30), .percent(60)],
      .savingsGrew: [.percent(30), .percent(60)], .savingsShrank: [.percent(30), .percent(60)],
      .noSpendDaysMore: [.count(8), .count(2)], .noSpendDaysFewer: [.count(2), .count(8)],
    ]
    XCTAssertEqual(Set(samples.keys), Set(FactID.allCases), "a check has no sample")
    let ledger = ledger()
    for language in [AppLanguage.Choice.russian, .english] {
      let words = text(ledger, language: language)
      for (id, args) in samples {
        let sentence = words.text(SummaryLine(id.key, args))
        XCTAssertFalse(sentence.contains("%"), "\(id): \(sentence)")
        XCTAssertFalse(sentence.contains("summaries."), "\(id): \(sentence)")
        XCTAssertGreaterThan(sentence.count, 12, "\(id)")
      }
    }
  }

  func testTheWeekdayOfAFindingReadsAsAPhraseInBothLanguages() {
    let ledger = ledger()
    let line = SummaryLine(FactID.weekdayLowest.key, [.weekday(3), .percent(46)])
    XCTAssertEqual(
      text(ledger, language: .russian).text(line),
      "Ты тратишь меньше всего в среду: на 46\u{00A0}% меньше обычного дня")
    XCTAssertEqual(
      text(ledger, language: .english).text(line),
      "You spend the least on Wednesday: 46% less than on a usual day")
  }

  func testTheMonthOfACardReadsInTheGenitive() throws {
    let content = try XCTUnwrap(
      SummaryContent.make(september, ledger: ledger(), today: today, moods: []))
    let card = try XCTUnwrap(content.cards(hideAmounts: false).first)
    XCTAssertEqual(text(ledger(), language: .russian).title(card), "Итоги сентября 2026")
    XCTAssertEqual(text(ledger(), language: .english).title(card), "Summary of September 2026")
  }

  func testTheAnnouncementNamesTheSummary() {
    environment.language.choice = .russian
    XCTAssertEqual(
      SummaryAnnouncementText.headline(of: september, language: environment.language),
      "Итоги сентября готовы")
    XCTAssertEqual(
      SummaryAnnouncementText.headline(of: .year(2025), language: environment.language),
      "Итоги 2025 года готовы")
    XCTAssertEqual(
      SummaryAnnouncementText.headline(
        of: .week(WeekKey(year: 2026, week: 43)), language: environment.language),
      "Итоги недели готовы")
    environment.language.choice = .english
    XCTAssertEqual(
      SummaryAnnouncementText.headline(of: september, language: environment.language),
      "The summary of September is ready")
  }

  // MARK: Hidden amounts

  func testHiddenAmountsLeaveNoAmountInAnyCardOrPage() throws {
    let ledger = ledger()
    let content = try XCTUnwrap(
      SummaryContent.make(september, ledger: ledger, today: today, moods: []))
    guard case .period(let summary) = content else { return XCTFail("a month is a period") }
    for language in [AppLanguage.Choice.russian, .english] {
      let words = text(ledger, language: language)
      let money = words.money
      let amounts = [summary.income, summary.expenses, summary.net, summary.cashback]
        + summary.topCategories.map(\.amount) + [summary.surprise?.amount, summary.surprise?.usual]
          .compactMap { $0 }
      let written = Set(amounts.filter { !$0.isZero }.map { money.rounded($0) })
      XCTAssertGreaterThan(written.count, 3)

      let shown = content.cards(hideAmounts: false).flatMap { [words.title($0)] + words.lines($0) }
        .joined(separator: "\n")
      for amount in written { XCTAssertTrue(shown.contains(amount), "\(amount) is not shown") }

      let hidden = content.cards(hideAmounts: true).flatMap { [words.title($0)] + words.lines($0) }
        .joined(separator: "\n")
      for amount in written { XCTAssertFalse(hidden.contains(amount), "\(amount) leaked") }
      XCTAssertFalse(hidden.contains("₽"), hidden)
      XCTAssertFalse(hidden.contains(MoneyFormatter.mask), hidden)
      XCTAssertTrue(hidden.contains("%"), "shares stay")
      XCTAssertTrue(hidden.contains("Кафе"), "categories stay")
    }
  }

  func testAWeekHidesAmountsToo() throws {
    let ledger = ledger()
    let id = SummaryID.week(WeekKey(containing: DateOnly(year: 2026, month: 9, day: 15)))
    let content = try XCTUnwrap(SummaryContent.make(id, ledger: ledger, today: today, moods: []))
    let words = text(ledger, language: .russian)
    let hidden = content.cards(hideAmounts: true).flatMap { [words.title($0)] + words.lines($0) }
      .joined(separator: "\n")
    XCTAssertFalse(hidden.contains("₽"), hidden)
    let shown = content.cards(hideAmounts: false).flatMap { [words.title($0)] + words.lines($0) }
      .joined(separator: "\n")
    XCTAssertTrue(shown.contains("₽"), shown)
  }

  // MARK: What this Mac remembers

  func testEveryKindIsOnUntilTurnedOff() {
    let storage = SummaryStorage(defaults: defaults, suffix: "")
    XCTAssertEqual(storage.switches, SummarySwitches(week: true, month: true, year: true))
    storage.setEnabled(false, for: .month)
    XCTAssertEqual(storage.switches, SummarySwitches(week: true, month: false, year: true))
    XCTAssertEqual(defaults.object(forKey: "summaries.month.enabled") as? Bool, false)
  }

  func testShownSummariesAreRememberedPerDataSetAndBounded() {
    let real = SummaryStorage(defaults: defaults, suffix: "")
    let trial = SummaryStorage(defaults: defaults, suffix: ".sample")
    real.markShown(september)
    XCTAssertEqual(real.shown, [september])
    XCTAssertTrue(trial.shown.isEmpty)
    real.markShown(september)
    XCTAssertEqual(real.shown.count, 1)
    for month in 1...12 {
      for year in 2000..<2010 { real.markShown(.month(MonthKey(year: year, month: month))) }
    }
    XCTAssertEqual(real.shown.count, SummaryStorage.rememberedLimit)
    XCTAssertTrue(real.shown.contains(.month(MonthKey(year: 2009, month: 12))))
  }

  // MARK: Answers

  func testAnAnswerIsKeptAndSettlesItsWeek() async {
    let model = SummariesModel(
      store: MemoryWeekAnswers(), storage: SummaryStorage(defaults: defaults, suffix: ""))
    let week = WeekKey(year: 2026, week: 43)
    let moment = Date(timeIntervalSince1970: 1_000)
    let saved = await model.answer(week: week, mood: 4, at: moment)
    XCTAssertTrue(saved)
    XCTAssertEqual(model.moods, [WeekMood(week: week, mood: 4, answeredAt: moment)])
    XCTAssertEqual(model.settledWeeks, [week])
    // A second answer for the same week replaces the first.
    _ = await model.answer(week: week, mood: 2, at: moment)
    XCTAssertEqual(model.moods.map(\.mood), [2])
    // A fresh model reads the same answers back.
    let again = SummariesModel(
      store: MemoryWeekAnswers(model.moods), storage: SummaryStorage(defaults: defaults, suffix: ""))
    await again.load()
    XCTAssertEqual(again.moods.map(\.mood), [2])
  }

  func testWithoutAStoreAnAnswerFailsAndSaysSo() async {
    let model = SummariesModel(store: nil, storage: SummaryStorage(defaults: defaults, suffix: ""))
    let saved = await model.answer(week: WeekKey(year: 2026, week: 43), mood: 3, at: Date())
    XCTAssertFalse(saved)
    XCTAssertTrue(model.answerFailed)
  }

  func testTheCardFollowsTheScheduleAndWhatWasShown() {
    let ledger = ledger()
    let storage = SummaryStorage(defaults: defaults, suffix: "")
    let model = SummariesModel(store: MemoryWeekAnswers(), storage: storage)
    // Monday 26 October: the month of September is ready first.
    XCTAssertEqual(model.announcement(ledger: ledger, today: today), .summary(september))
    model.markShown(september)
    // Then last week (no operations in October yet: the book ends on 27 September).
    XCTAssertNil(model.announcement(ledger: ledger, today: today))
    // On the Sunday of a week with operations, the question is asked.
    let sunday = DateOnly(year: 2026, month: 9, day: 27)
    XCTAssertEqual(
      model.announcement(ledger: ledger, today: sunday),
      .weekQuestion(WeekKey(containing: sunday)))
    storage.setEnabled(false, for: .week)
    XCTAssertNil(model.announcement(ledger: ledger, today: sunday))
  }

  func testTheAnswersLiveInTheDatabase() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let store = DatabaseWeekAnswers(repository: AttachmentRepository(writer: stack.writer))
    let week = WeekKey(year: 2026, week: 43)
    let moment = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.save(WeekMood(week: week, mood: 5, answeredAt: moment))
    try await store.save(WeekMood(week: week, mood: 3, answeredAt: moment))
    let answers = try await store.answers()
    XCTAssertEqual(answers.count, 1)
    XCTAssertEqual(answers.first?.mood, 3)
    XCTAssertEqual(answers.first?.week, week)
  }

  func testTheMoodOfTheMonthIsInItsCards() throws {
    let ledger = ledger()
    let moods = [
      WeekMood(
        week: WeekKey(containing: DateOnly(year: 2026, month: 9, day: 9)), mood: 4,
        answeredAt: Date(timeIntervalSince1970: 0)),
      WeekMood(
        week: WeekKey(containing: DateOnly(year: 2026, month: 9, day: 16)), mood: 3,
        answeredAt: Date(timeIntervalSince1970: 0)),
    ]
    let content = try XCTUnwrap(
      SummaryContent.make(september, ledger: ledger, today: today, moods: moods))
    let words = text(ledger, language: .russian)
    let mood = try XCTUnwrap(content.cards(hideAmounts: true).first { $0.id == "mood" })
    XCTAssertTrue(words.lines(mood).first?.contains("3,5") == true, "\(words.lines(mood))")
  }

  // MARK: Pages

  func testThePdfIsAPdfAndThePictureIsAFile() throws {
    let ledger = ledger()
    let content = try XCTUnwrap(
      SummaryContent.make(september, ledger: ledger, today: today, moods: []))
    let words = text(ledger, language: .russian)
    let page = SummaryPage(
      title: "Итоги",
      cards: content.cards(hideAmounts: false).map { (title: words.title($0), lines: words.lines($0)) })
    let pdf = try XCTUnwrap(SummaryExport.pdf(of: page))
    XCTAssertEqual(String(decoding: pdf.prefix(5), as: UTF8.self), "%PDF-")
    XCTAssertGreaterThan(pdf.count, 1_000)
    let picture = try XCTUnwrap(SummaryExport.pngFile(of: page, name: "test-\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: picture) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: picture.path))
    XCTAssertEqual(picture.pathExtension, "png")
  }
}
