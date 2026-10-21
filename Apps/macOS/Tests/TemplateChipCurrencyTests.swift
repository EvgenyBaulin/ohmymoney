import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// What a chip or the preview above the line says is what Enter saves: on the screen of an
/// account the line reads an amount without a code in that account's currency, so a chip
/// remembered in another currency names its own, a chip in the account's currency stays a
/// plain line, and «1500,5 = 1,500.50 …» is said in the currency the save will give.
@MainActor
final class TemplateChipCurrencyTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  private let kzt = CurrencyCode("KZT")
  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  private lazy var kaspi = PaymentMethod(name: "Kaspi", currency: kzt)
  private let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-chips-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let references = try XCTUnwrap(environment.references)
    // Saved as the main account, the card takes the flag from any account the open made.
    try references.save(card)
    try references.save(kaspi)
    try references.save(groceries)
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// The chip's line entered the way the strip enters it, and what Enter would save.
  private func pick(_ template: Template) throws -> (line: String, saved: TransactionDraft) {
    let line = Templates.line(for: template, categories: [groceries], in: environment)
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc).parse(line, today: today)
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
    model.applyDefaults(today: today)
    return (line, model.draftForSaving)
  }

  private func coffee(_ currency: CurrencyCode?) -> Template {
    Template(
      text: "кофе", categoryId: groceries.id, amountE4: AmountE4(whole: 250), currency: currency)
  }

  /// A ruble chip on the tenge account's screen: it shows 250 ₽, and the line that took no code
  /// saved 250 ₸ — a fifth of the money — on the account whose screen was open.
  func testARubleChipOnATengeScreenSavesRubles() throws {
    environment.focusedAccountId = kaspi.id
    let template = coffee(.rub)
    XCTAssertEqual(Templates.currency(of: template, in: environment), .rub)
    let picked = try pick(template)
    XCTAssertEqual(picked.saved.currency, .rub, picked.line)
    XCTAssertEqual(picked.saved.amount, AmountE4(whole: 250))
  }

  /// A tenge chip on the tenge account's screen needs no code: the line reads tenge there.
  func testAChipInTheCurrencyOfTheScreenStaysAPlainLine() throws {
    environment.focusedAccountId = kaspi.id
    let picked = try pick(coffee(kzt))
    XCTAssertEqual(picked.line, "кофе 250")
    XCTAssertEqual(picked.saved.currency, kzt)
    XCTAssertEqual(picked.saved.paymentMethodId, kaspi.id)
  }

  /// A chip that names no currency shows the one its line is read in, and saves it: the
  /// account's on its screen, the default one elsewhere.
  func testAChipWithoutACurrencyShowsTheOneItsLineIsReadIn() throws {
    let template = coffee(nil)
    XCTAssertEqual(Templates.currency(of: template, in: environment), .rub)
    XCTAssertEqual(try pick(template).saved.currency, .rub)

    environment.focusedAccountId = kaspi.id
    XCTAssertEqual(Templates.currency(of: template, in: environment), kzt)
    XCTAssertEqual(try pick(template).saved.currency, kzt)
  }

  /// The euro account picked in the panel before the chip: the panel's choice lays euros on a
  /// line that names no currency, so a ruble chip names its rubles and saves them.
  func testARubleChipAfterAnAccountWasPickedInThePanelSavesRubles() throws {
    try XCTUnwrap(environment.references).save(freedom)
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.setPaymentMethod(freedom.id)
    XCTAssertEqual(model.draft.currency, .eur)

    let template = coffee(.rub)
    let line = Templates.line(for: template, categories: [groceries], in: environment, model: model)
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc).parse(line, today: today)
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draftForSaving.currency, .rub, line)
    XCTAssertEqual(model.draftForSaving.paymentMethodId, freedom.id)
  }

  // MARK: The preview above the line

  private let freedom = PaymentMethod(name: "Freedom", currency: .eur, otherCurrencies: [.usd])

  private func parse(_ line: String) throws -> ParsedInput {
    try XCTUnwrap(environment.references).save(freedom)
    return InputLineParser(
      vocabulary: ParserVocabulary(paymentMethods: [.init(id: freedom.id, name: freedom.name)]),
      calendar: .utc
    ).parse(line, today: today)
  }

  /// What Enter saves for the line: its currency.
  private func saved(_ parsed: ParsedInput) throws -> CurrencyCode {
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
    model.applyDefaults(today: today)
    return model.draftForSaving.currency
  }

  /// «кофе 1500,5» on the tenge account's screen is saved in tenge, and the preview said rubles.
  func testThePreviewOnATengeScreenIsInTenge() throws {
    environment.focusedAccountId = kaspi.id
    let parsed = try parse("кофе 1500,5")
    XCTAssertNotNil(parsed.amountToPreview)
    XCTAssertEqual(try saved(parsed), kzt)
    XCTAssertEqual(EntryPreview.currency(of: parsed, model: nil, in: environment), kzt)
  }

  /// A line that names an account is previewed in that account's currency, as it is saved.
  func testThePreviewOfALineNamingAnAccountIsInItsCurrency() throws {
    let parsed = try parse("кофе 1500,5 Freedom")
    XCTAssertEqual(parsed.paymentMethodId, freedom.id)
    XCTAssertEqual(try saved(parsed), .eur)
    XCTAssertEqual(EntryPreview.currency(of: parsed, model: nil, in: environment), .eur)
  }

  /// A currency typed in the line beats the screen, in the preview as in the save.
  func testATypedCurrencyIsPreviewedOnAnyScreen() throws {
    environment.focusedAccountId = kaspi.id
    let parsed = try parse("кофе 1500,5 usd")
    XCTAssertEqual(try saved(parsed), .usd)
    XCTAssertEqual(EntryPreview.currency(of: parsed, model: nil, in: environment), .usd)
  }

  /// A model left over from the last save, carrying no choice, does not hold the preview to the
  /// default currency on the tenge account's screen.
  func testAnIdleModelDoesNotHoldThePreviewToTheDefault() throws {
    environment.focusedAccountId = kaspi.id
    let idle = EntryDraftModel(environment: environment)
    idle.reload()
    idle.reset()
    let parsed = try parse("кофе 1500,5")
    XCTAssertEqual(EntryPreview.currency(of: parsed, model: idle, in: environment), kzt)
  }

  /// Off any account screen a ruble chip stays the plain line it always was.
  func testOffAnAccountScreenARubleChipIsAPlainLine() throws {
    let picked = try pick(coffee(.rub))
    XCTAssertEqual(picked.line, "кофе 250")
    XCTAssertEqual(picked.saved.currency, .rub)
    XCTAssertEqual(picked.saved.paymentMethodId, card.id)
  }

  // MARK: One panel across screens and choices

  /// The entry line is one for the whole main window: its panel lives on while the owner moves
  /// from screen to screen, and what the chips and the preview say is read from that same
  /// panel at that moment.
  private func linesParser() -> InputLineParser {
    InputLineParser(
      vocabulary: ParserVocabulary(paymentMethods: [
        .init(id: freedom.id, name: freedom.name), .init(id: kaspi.id, name: kaspi.name),
      ]),
      calendar: .utc)
  }

  private var freedomSaved = false

  private func panel() throws -> EntryDraftModel {
    if !freedomSaved {
      try XCTUnwrap(environment.references).save(freedom)
      freedomSaved = true
    }
    let model = EntryDraftModel(environment: environment)
    model.reload()
    return model
  }

  /// Enter on `line` with this very panel, and what it saves.
  private func save(_ line: String, into model: EntryDraftModel) throws -> TransactionDraft {
    let parsed = linesParser().parse(line, today: today)
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
    model.applyDefaults(today: today)
    return model.draftForSaving
  }

  private func preview(_ line: String, with model: EntryDraftModel) -> CurrencyCode {
    EntryPreview.currency(
      of: linesParser().parse(line, today: today), model: model, in: environment)
  }

  /// Dollars picked in the panel, then «кофе 1500,5 Kaspi»: the save keeps the dollars the owner
  /// picked and charges Kaspi its tenge apart, so the preview says dollars too.
  func testACurrencyPickedInThePanelBeatsTheAccountTheLineNames() throws {
    let model = try panel()
    model.applyDefaults(today: today)
    model.setCurrency(.usd)
    let shown = preview("кофе 1500,5 Kaspi", with: model)
    let saved = try save("кофе 1500,5 Kaspi", into: model)
    XCTAssertEqual(saved.currency, .usd)
    XCTAssertEqual(saved.paymentMethodId, kaspi.id)
    XCTAssertEqual(shown, .usd)
  }

  /// A category picked on Overview, Esc, then the tenge account's screen: the panel's rubles
  /// were laid off any screen, and the line is read in tenge now. A ruble chip names its
  /// rubles; «кофе 1500,5» is previewed in the tenge it is saved in.
  func testAChoiceCarriedFromOverviewToATengeScreen() throws {
    let model = try panel()
    model.setCategory(groceries.id, forPartAt: 0)
    model.applyDefaults(today: today)
    XCTAssertTrue(model.carriesChoices)
    environment.focusedAccountId = kaspi.id

    XCTAssertEqual(preview("кофе 1500,5", with: model), kzt)
    let line = Templates.line(
      for: coffee(.rub), categories: [groceries], in: environment, model: model)
    XCTAssertEqual(line, "кофе 250 RUB")
    let saved = try save(line, into: model)
    XCTAssertEqual(saved.currency, .rub)
    XCTAssertEqual(saved.amount, AmountE4(whole: 250))
    XCTAssertEqual(saved.paymentMethodId, kaspi.id)
  }

  /// The same with the line itself: «кофе 1500,5» after a choice carried to the tenge screen is
  /// saved in tenge on Kaspi, and its preview says so.
  func testThePreviewOfACarriedChoiceOnAnotherScreenIsWhatIsSaved() throws {
    let model = try panel()
    model.setCategory(groceries.id, forPartAt: 0)
    model.applyDefaults(today: today)
    environment.focusedAccountId = kaspi.id
    let shown = preview("кофе 1500,5", with: model)
    let saved = try save("кофе 1500,5", into: model)
    XCTAssertEqual(saved.currency, kzt)
    XCTAssertEqual(saved.paymentMethodId, kaspi.id)
    XCTAssertEqual(shown, saved.currency)
  }

  /// Freedom picked in the panel: a chip that names no currency is read in euros now, so it
  /// shows euros, and saves them.
  func testAChipWithoutACurrencyShowsTheCurrencyOfTheAccountPickedInThePanel() throws {
    let model = try panel()
    model.setPaymentMethod(freedom.id)
    let template = coffee(nil)
    let shown = Templates.currency(of: template, in: environment, model: model)
    let saved = try save(
      Templates.line(for: template, categories: [groceries], in: environment, model: model),
      into: model)
    XCTAssertEqual(saved.currency, .eur)
    XCTAssertEqual(shown, .eur)
  }

  /// A choice made on the euro account's screen is carried to the tenge one: the euros the panel
  /// holds were laid by the screen left behind, and the line is read in tenge now. A euro chip
  /// names its euros, or it would save 250 ₸.
  func testAEuroChipAfterAChoiceMadeOnTheEuroScreenSavesEurosOnTheTengeScreen() throws {
    let model = try panel()
    environment.focusedAccountId = freedom.id
    model.setCategory(groceries.id, forPartAt: 0)
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draft.currency, .eur)
    environment.focusedAccountId = kaspi.id

    let line = Templates.line(
      for: coffee(.eur), categories: [groceries], in: environment, model: model)
    XCTAssertEqual(line, "кофе 250 EUR")
    let saved = try save(line, into: model)
    XCTAssertEqual(saved.currency, .eur)
    XCTAssertEqual(saved.paymentMethodId, kaspi.id)
  }

  /// Every screen, every state the panel can be carried in, every kind of line: the preview
  /// says the currency Enter saves, and every chip shows the currency it saves — whether it
  /// names its own or not.
  func testThePreviewAndTheChipsAlwaysSayWhatIsSaved() throws {
    let screens: [UUID?] = [nil, kaspi.id, freedom.id, card.id]
    let states: [(String, (EntryDraftModel) -> Void)] = [
      ("idle", { _ in }),
      ("category", { $0.setCategory(self.groceries.id, forPartAt: 0) }),
      ("account Freedom", { $0.setPaymentMethod(self.freedom.id) }),
      ("account Kaspi", { $0.setPaymentMethod(self.kaspi.id) }),
      ("currency USD", { $0.setCurrency(.usd) }),
      ("currency KZT", { $0.setCurrency(self.kzt) }),
    ]
    let lines = ["кофе 1500,5", "кофе 1500,5 Kaspi", "кофе 1500,5 Freedom", "кофе 1500,5 usd"]
    let templates = [coffee(nil), coffee(.rub), coffee(.eur), coffee(kzt), coffee(.usd)]
    var checked = 0
    for before in screens {
      for after in screens {
        for (name, choose) in states {
          func carried() throws -> EntryDraftModel {
            let model = try panel()
            environment.focusedAccountId = before
            choose(model)
            model.applyDefaults(today: today)
            environment.focusedAccountId = after
            return model
          }
          let context =
            "chosen \(name) on \(String(describing: before)), now on \(String(describing: after))"
          for line in lines {
            let model = try carried()
            let shown = preview(line, with: model)
            XCTAssertEqual(shown, try save(line, into: model).currency, "\(line) — \(context)")
            checked += 1
          }
          for template in templates {
            let model = try carried()
            let shown = Templates.currency(of: template, in: environment, model: model)
            let line = Templates.line(
              for: template, categories: [groceries], in: environment, model: model)
            let saved = try save(line, into: model)
            XCTAssertEqual(shown, saved.currency, "chip \(line) — \(context)")
            if let own = template.currency {
              XCTAssertEqual(saved.currency, own, "chip \(line) — \(context)")
            }
            XCTAssertEqual(saved.amount, AmountE4(whole: 250), "chip \(line) — \(context)")
            checked += 1
          }
        }
      }
    }
    XCTAssertEqual(checked, 4 * 4 * 6 * 9)
  }
}
