import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The open ↓ panel reads the line at every keystroke, so it also reads every half-typed word
/// on the way: «батон» passes through «бат», the baht; «магнитик» through «Магнит», a shop;
/// «авансом» through «аванс», a salary. What the line says when it is done is what the panel
/// holds — a field a half-typed word filled goes back to what it was once the word reads as
/// something else, while whatever the owner chose in the panel stays.
@MainActor
final class EntryTypedWordsTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!

  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private let card = PaymentMethod(name: "Карта", isDefault: true)
  private let sber = PaymentMethod(name: "Сбер")
  private let shop = Place(name: "Магнит")
  private let trip = Event(
    name: "Отпуск", startDate: DateOnly(year: 2026, month: 9, day: 1),
    endDate: DateOnly(year: 2026, month: 9, day: 30))

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(card)
    try references.save(sber)
    try references.save(shop)
    try references.save(trip)
  }

  private func makeModel() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.reload()
    model.applyDefaults(today: today)
    return model
  }

  private func parser() throws -> InputLineParser {
    InputLineParser(
      vocabulary: try references.vocabulary(enabledCurrencies: CurrencyCode.defaultEnabled),
      calendar: .utc)
  }

  /// What the entry bar does with the panel open (`readTheLineIntoThePanel`): every change of
  /// the text is read and applied; Enter applies the whole line once more.
  private func type(_ line: String, into model: EntryDraftModel) throws {
    let parser = try parser()
    var text = ""
    for character in line {
      text.append(character)
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let parsed = parser.parse(trimmed, today: today, kind: model.draft.kind)
      guard parsed.dateProblem == nil else { continue }
      var amount = model.draft.amount
      if let typed = parsed.amount {
        guard let read = try? AmountE4(decimal: typed) else { continue }
        amount = read
      }
      model.apply(parsed, amount: amount, today: today, text: trimmed, whileTyping: true)
    }
  }

  private func enter(_ line: String, into model: EntryDraftModel) throws {
    let parsed = try parser().parse(line, today: today, kind: model.draft.kind)
    let amount = try parsed.amount.map { try AmountE4(decimal: $0) } ?? model.draft.amount
    model.apply(parsed, amount: amount, today: today, text: line)
  }

  /// «батон 60» passes through «бат»: the loaf is not bought in baht.
  func testAWordThatBeginsLikeACurrencyLeavesTheCurrencyAlone() throws {
    let model = makeModel()
    try type("батон 60", into: model)
    try enter("батон 60", into: model)
    XCTAssertEqual(model.draft.currency, .rub)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 60))
    XCTAssertEqual(model.draft.note, "батон")
  }

  /// «магнитик 300» passes through «Магнит»: a fridge magnet is not a purchase at the shop.
  func testAWordThatBeginsLikeAPlaceLeavesThePlaceAlone() throws {
    let model = makeModel()
    try type("магнитик 300", into: model)
    try enter("магнитик 300", into: model)
    XCTAssertNil(model.draft.placeId)
    XCTAssertEqual(model.draft.note, "магнитик")
  }

  /// «ремонт 5000 авансом» passes through «аванс»: paying ahead is not a salary.
  func testAWordThatBeginsLikeAKindLeavesTheKindAlone() throws {
    let model = makeModel()
    try type("ремонт 5000 авансом", into: model)
    try enter("ремонт 5000 авансом", into: model)
    XCTAssertEqual(model.draft.kind, .expense)
  }

  /// «сумку другую 3000» passes through «другу», «for a friend».
  func testAWordThatBeginsLikeForWhomLeavesForWhomAlone() throws {
    let model = makeModel()
    try type("сумка другую 3000", into: model)
    try enter("сумка другую 3000", into: model)
    XCTAssertEqual(model.draft.parts[0].forWhom, .me)
  }

  /// «сберкнижка 300» passes through «Сбер», an account: the main account stays.
  func testAWordThatBeginsLikeAnAccountLeavesTheAccountAlone() throws {
    let model = makeModel()
    try type("сберкнижка 300", into: model)
    try enter("сберкнижка 300", into: model)
    XCTAssertEqual(model.draft.paymentMethodId, card.id)
  }

  /// «отпускные 300» passes through «Отпуск», an event.
  func testAWordThatBeginsLikeAnEventLeavesTheEventAlone() throws {
    let model = makeModel()
    try type("подарок отпускные 300", into: model)
    try enter("подарок отпускные 300", into: model)
    XCTAssertNil(model.draft.parts[0].eventId)
  }

  /// A word typed in full keeps what it names: «хлеб 60 бат» is in baht, «чай 300 в Магните»
  /// at the shop, «аванс 30000» a salary, «на Сбер» the account.
  func testAWordTypedInFullKeepsWhatItNames() throws {
    let baht = makeModel()
    try type("хлеб 60 бат", into: baht)
    try enter("хлеб 60 бат", into: baht)
    XCTAssertEqual(baht.draft.currency, CurrencyCode("THB"))

    let place = makeModel()
    try type("чай 300 в Магните", into: place)
    try enter("чай 300 в Магните", into: place)
    XCTAssertEqual(place.draft.placeId, shop.id)

    let salary = makeModel()
    try type("аванс 30000", into: salary)
    try enter("аванс 30000", into: salary)
    XCTAssertEqual(salary.draft.kind, .income)

    let account = makeModel()
    try type("кофе 300 сбер", into: account)
    try enter("кофе 300 сбер", into: account)
    XCTAssertEqual(account.draft.paymentMethodId, sber.id)
  }

  /// A word erased from the line takes back what it filled: «кофе 5 евро», then the currency
  /// rubbed out, is in the default currency again.
  func testAWordErasedFromTheLineTakesBackWhatItFilled() throws {
    let model = makeModel()
    try type("кофе 5 евро", into: model)
    XCTAssertEqual(model.draft.currency, .eur)
    try type("кофе 5", into: model)
    try enter("кофе 5", into: model)
    XCTAssertEqual(model.draft.currency, .rub)
  }

  /// A number rubbed out of the line takes its amount back with it: «кофе 250» erased to «кофе»
  /// passes through «кофе 2», and the panel is not left holding 2 for Enter to save.
  func testAnAmountErasedFromTheLineIsTakenBack() throws {
    let model = makeModel()
    try type("кофе 250", into: model)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 250))
    try type("кофе 25", into: model)
    try type("кофе 2", into: model)
    try type("кофе", into: model)
    XCTAssertEqual(model.draft.amount, .zero)
    XCTAssertNil(model.draft.amountExpression)
  }

  /// A formula half typed — «250+» reads as no amount — leaves the amount it had, and an amount
  /// the owner typed in the panel stays when the line is only words.
  func testAnAmountOfThePanelOrAHalfTypedFormulaStays() throws {
    let model = makeModel()
    try type("кофе 250+", into: model)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 250))
    try type("кофе 250+50", into: model)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 300))

    let panel = makeModel()
    try type("кофе 250", into: panel)
    panel.setTotal(AmountE4(whole: 400), typed: "400")
    try type("кофе", into: panel)
    try enter("кофе", into: panel)
    XCTAssertEqual(panel.draft.amount, AmountE4(whole: 400))
  }

  /// What the owner chose in the panel stays, whatever the line goes through after it: the
  /// currency picked in the panel is not taken back by a word that passes through «бат».
  func testWhatThePanelChoseStays() throws {
    let model = makeModel()
    try type("хлеб 60", into: model)
    model.setCurrency(.usd)
    try type("хлеб 60 батон", into: model)
    try enter("хлеб 60 батон", into: model)
    XCTAssertEqual(model.draft.currency, .usd)
  }
}
