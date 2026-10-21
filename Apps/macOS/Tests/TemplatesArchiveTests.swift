import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Templates in the archive: a chip put away leaves the strip and stays in Settings → Шаблоны,
/// where «Вернуть» brings it back as it was; its words go on counting on it instead of making a
/// second chip. And the line of a chip names its currency whenever it is not the default one.
@MainActor
final class TemplatesArchiveTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
  private let kzt = CurrencyCode("KZT")

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    try references.save(groceries)
  }

  private func draft(
    _ note: String, _ amount: Int64, _ currency: CurrencyCode = .rub
  )
    -> TransactionDraft
  {
    var draft = TransactionDraft(
      kind: .expense, currency: currency, amount: AmountE4(whole: amount), note: note)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = groceries.id
    return draft
  }

  private func model() -> TemplatesModel {
    let model = TemplatesModel()
    model.attach(references)
    return model
  }

  /// «В архив» on a chip takes it off the strip; the template stays, pin and count included.
  func testAnArchivedChipLeavesTheStripAndStays() throws {
    let coffee = Template(text: "кофе", amountE4: AmountE4(whole: 250), pinned: true, useCount: 7)
    let taxi = Template(text: "такси", useCount: 3)
    try references.save(coffee)
    try references.save(taxi)
    let strip = model()
    XCTAssertEqual(strip.templates.map(\.id), [coffee.id, taxi.id])

    XCTAssertTrue(strip.archive(coffee))
    XCTAssertEqual(strip.templates.map(\.id), [taxi.id], "the chip is still on the strip")
    let kept = try XCTUnwrap(
      try references.templates().first { $0.id == coffee.id })
    XCTAssertTrue(kept.archived)
    XCTAssertTrue(kept.pinned)
    XCTAssertEqual(kept.useCount, 7)
  }

  /// «Вернуть» brings it back to the strip as it was.
  func testBringingATemplateBackPutsItOnTheStripAgain() throws {
    let coffee = Template(text: "кофе", pinned: true, useCount: 7, archived: true)
    try references.save(coffee)
    let strip = model()
    XCTAssertTrue(strip.templates.isEmpty)

    try references.setTemplate(coffee.id, archived: false)
    strip.reload()
    XCTAssertEqual(strip.templates.map(\.id), [coffee.id])
    XCTAssertEqual(strip.templates.first?.useCount, 7)
    XCTAssertEqual(strip.templates.first?.pinned, true)
  }

  /// The archive flag is written alone: a chip picked on the strip counted one more use after
  /// the row on screen was read, and putting that stale row away keeps the count.
  func testArchivingKeepsWhatWasWrittenSinceTheRowWasRead() throws {
    let coffee = Template(text: "кофе", useCount: 1)
    try references.save(coffee)
    let strip = model()
    let shown = try XCTUnwrap(strip.templates.first)
    strip.use(shown)

    XCTAssertTrue(strip.archive(shown))
    XCTAssertEqual(try references.templates(includeArchived: true).first?.useCount, 2)
    XCTAssertThrowsError(try references.setTemplate(UUID(), archived: true))
  }

  /// A chip still on the strip after its template went to the archive elsewhere — Settings →
  /// Шаблоны, another window — is a copy older than the row. Picking or pinning it writes the
  /// count or the pin alone: the template stays in the archive.
  func testAStaleChipLeavesItsTemplateInTheArchive() throws {
    let coffee = Template(text: "кофе", useCount: 1)
    try references.save(coffee)
    let strip = model()
    let stale = try XCTUnwrap(strip.templates.first)
    try references.setTemplate(coffee.id, archived: true)

    strip.use(stale)
    XCTAssertTrue(strip.togglePin(stale))
    let kept = try XCTUnwrap(try references.templates().first)
    XCTAssertTrue(kept.archived, "a stale chip brought its template back from the archive")
    XCTAssertEqual(kept.useCount, 2)
    XCTAssertTrue(kept.pinned)
    XCTAssertTrue(strip.templates.isEmpty)
  }

  /// A chip of a template deleted meanwhile writes nothing back.
  func testAStaleChipOfADeletedTemplateWritesNothingBack() throws {
    let coffee = Template(text: "кофе", useCount: 1)
    try references.save(coffee)
    let strip = model()
    let stale = try XCTUnwrap(strip.templates.first)
    try references.deleteTemplate(id: coffee.id)

    strip.use(stale)
    XCTAssertTrue(try references.templates().isEmpty, "the deleted template is back")
    XCTAssertTrue(strip.templates.isEmpty)
  }

  /// The chips are read again as soon as Settings → Шаблоны writes: a template put away there
  /// leaves the strip at once, rather than waiting for the next change of the operations.
  func testTheChipsAreReadAgainWhenTheTemplatesChangeElsewhere() throws {
    let coffee = Template(text: "кофе", useCount: 1)
    try references.save(coffee)
    let strip = model()
    XCTAssertEqual(strip.templates.count, 1)

    try references.setTemplate(coffee.id, archived: true)
    NotificationCenter.default.post(name: .templatesChanged, object: nil)
    XCTAssertTrue(strip.templates.isEmpty, "the strip still shows a chip put away in Settings")
  }

  /// A chip shows its amount in the currency Enter will save it in: a template that names no
  /// currency is entered as the entry line reads an amount without a code — in rubles —, so it
  /// is shown in rubles too, whatever the default currency.
  func testAChipShowsTheCurrencyItIsEnteredIn() {
    let plain = Template(text: "кофе", amountE4: AmountE4(whole: 250))
    let tenge = Template(text: "такси", amountE4: AmountE4(whole: 900), currency: kzt)
    XCTAssertEqual(Templates.line(for: plain, categories: []), "кофе 250")
    XCTAssertEqual(Templates.currency(of: plain), .rub, "the chip names a currency Enter ignores")
    XCTAssertEqual(Templates.currency(of: tenge), kzt)
    XCTAssertEqual(Templates.currency(of: plain, lineDefault: kzt), kzt)
  }

  /// The words of an archived template count on it and it stays in the archive: a second chip
  /// of the same words would bring back what the owner took off the strip.
  func testTheWordsOfAnArchivedTemplateMakeNoSecondChip() throws {
    let strip = model()
    strip.remember(draft("кофе", 250), categories: [groceries])
    let coffee = try XCTUnwrap(strip.templates.first)
    XCTAssertTrue(strip.archive(coffee))

    strip.remember(draft("Кофе", 300), categories: [groceries])
    let all = try references.templates(includeArchived: true)
    XCTAssertEqual(all.count, 1, "a second chip of the same words")
    XCTAssertEqual(all.first?.useCount, 2)
    XCTAssertEqual(all.first?.amountE4, AmountE4(whole: 300))
    XCTAssertEqual(all.first?.archived, true)
    XCTAssertTrue(strip.templates.isEmpty)
  }

  /// The line of a chip names the currency whenever it is not the default one — the currency
  /// the line reads an amount in when it names none — so a ruble chip says «RUB» once the
  /// default is the tenge, and a tenge chip says nothing then.
  func testTheLineOfAChipNamesAnyCurrencyButTheDefault() {
    let rubles = Template(text: "кофе", amountE4: AmountE4(whole: 250), currency: .rub)
    let tenge = Template(text: "такси", amountE4: AmountE4(whole: 900), currency: kzt)
    XCTAssertEqual(Templates.line(for: rubles, categories: []), "кофе 250")
    XCTAssertEqual(Templates.line(for: tenge, categories: []), "такси 900 KZT")
    XCTAssertEqual(
      Templates.line(for: rubles, categories: [], defaultCurrency: kzt), "кофе 250 RUB")
    XCTAssertEqual(Templates.line(for: tenge, categories: [], defaultCurrency: kzt), "такси 900")
  }

  /// Settings → Шаблоны shows a template's amount in the currency its chip enters it in: its
  /// own, or — a template that names none — the default currency, which the entry line reads
  /// an amount without a code in. A chip of «такси 900» saves tenge once the default is the
  /// tenge, so the row says tenge too.
  func testTheSettingsRowShowsTheCurrencyTheChipEntersTheAmountIn() {
    let unnamed = Template(text: "такси", amountE4: AmountE4(whole: 900))
    let rubles = Template(text: "кофе", amountE4: AmountE4(whole: 250), currency: .rub)
    XCTAssertEqual(
      TemplatesSettingsView.amountCurrency(of: unnamed, defaultCurrency: kzt), kzt,
      "the row said rubles for a chip that saves tenge")
    XCTAssertEqual(TemplatesSettingsView.amountCurrency(of: unnamed, defaultCurrency: .rub), .rub)
    XCTAssertEqual(TemplatesSettingsView.amountCurrency(of: rubles, defaultCurrency: kzt), .rub)
  }

  /// The chips of the app follow «Валюта по умолчанию»: with the tenge as the default, a ruble
  /// chip puts «RUB» into the line, so Enter saves rubles, and a template that names no
  /// currency is shown in the tenge Enter will save it in — not in rubles.
  func testTheChipsOfTheAppFollowTheDefaultCurrency() throws {
    let environment = AppEnvironment()
    let before = environment.defaultCurrency
    defer { environment.defaultCurrency = before }
    environment.defaultCurrency = kzt
    let rubles = Template(text: "кофе", amountE4: AmountE4(whole: 250), currency: .rub)
    let plain = Template(text: "такси", amountE4: AmountE4(whole: 900))

    let line = Templates.line(for: rubles, categories: [], in: environment)
    XCTAssertEqual(line, "кофе 250 RUB")
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc)
      .parse(line, today: DateOnly(year: 2026, month: 9, day: 18))
    XCTAssertEqual(parsed.currency, .rub, "a ruble chip would save tenge")
    XCTAssertEqual(Templates.currency(of: rubles, in: environment), .rub)

    XCTAssertEqual(Templates.line(for: plain, categories: [], in: environment), "такси 900")
    XCTAssertEqual(Templates.currency(of: plain, in: environment), kzt)
  }

  /// A new template is in the currency of the operation it was remembered from — which the
  /// entry line takes from the default currency when nothing else names one.
  func testANewTemplateIsInTheCurrencyOfItsOperation() throws {
    let strip = model()
    strip.remember(draft("плов", 2_000, kzt), categories: [groceries])
    XCTAssertEqual(strip.templates.first?.currency, kzt)
  }
}
