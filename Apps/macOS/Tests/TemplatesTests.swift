import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The chips under the entry line («Шаблоны — кнопки-«чипы» под строкой:
/// частые операции из истории и закреплённые мной»). A chip puts a line into the entry line,
/// and Enter saves what that line says — so the line has to say what the operation was.
@MainActor
final class TemplatesTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!

  private let salary = CoreKit.Category(kind: .income, name: "Gifts received")
  private let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    try references.save(salary)
    try references.save(groceries)
  }

  private func parse(_ line: String) -> ParsedInput {
    InputLineParser(vocabulary: .empty, calendar: .utc).parse(line, today: today)
  }

  private func draft(
    _ kind: TransactionKind, note: String, amount: Int64, currency: CurrencyCode = .rub,
    category: UUID? = nil
  ) -> TransactionDraft {
    var draft = TransactionDraft(
      kind: kind, currency: currency, amount: AmountE4(whole: amount), note: note)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = category
    return draft
  }

  // MARK: The line of a chip

  func testAnIncomeTemplateReEntersAsIncomeInItsCurrency() {
    let template = Template(
      text: "подарок", categoryId: salary.id, amountE4: AmountE4(whole: 50_000), currency: .usd)

    let parsed = parse(Templates.line(for: template, categories: [salary, groceries]))

    XCTAssertEqual(parsed.kind, .income)
    XCTAssertEqual(parsed.currency, .usd)
    XCTAssertEqual(parsed.amount, 50_000)
    XCTAssertEqual(parsed.note, "подарок")
  }

  func testAForeignCurrencyExpenseKeepsItsCurrency() {
    let template = Template(
      text: "lunch", categoryId: groceries.id,
      amountE4: try! AmountE4(decimal: Decimal(string: "20.5")!),
      currency: .usd)

    let parsed = parse(Templates.line(for: template, categories: [salary, groceries]))

    XCTAssertEqual(parsed.kind, .expense)
    XCTAssertEqual(parsed.currency, .usd)
    XCTAssertEqual(parsed.amount, Decimal(string: "20.5"))
    XCTAssertEqual(parsed.note, "lunch")
  }

  func testARubleExpenseStaysAPlainLine() {
    let template = Template(
      text: "кофе", categoryId: groceries.id, amountE4: AmountE4(whole: 250), currency: .rub)

    let line = Templates.line(for: template, categories: [salary, groceries])

    XCTAssertEqual(line, "кофе 250")
    XCTAssertEqual(parse(line).kind, .expense)
  }

  /// A chip writes its amount the way the app writes numbers. «1500.5» would still read right,
  /// but the line then shows a hint above it asking whether that is what was meant.
  func testAnAmountWithKopecksIsWrittenTheWayTheAppWritesNumbers() throws {
    let template = Template(
      text: "обед", categoryId: groceries.id,
      amountE4: try AmountE4(decimal: Decimal(string: "1500.5")!), currency: .rub)

    let line = Templates.line(for: template, categories: [salary, groceries])

    XCTAssertEqual(line, "обед 1,500.50")
    XCTAssertEqual(parse(line).amount, Decimal(string: "1500.5"))
    XCTAssertNil(parse(line).amountToPreview)
  }

  // MARK: What is remembered

  /// A chip can say an expense, an income filed under an income category («+»), the amount
  /// and the currency. What it cannot say — a refund, money given back on a debt, a payment
  /// of a debt, a contribution to a goal, an income with no category to tell it by — is not
  /// made a chip: its chip would enter a ruble expense instead.
  func testOnlyWhatAChipCanSayAgainIsRemembered() throws {
    let categories = [salary, groceries]
    Templates.remember(
      draft(.expense, note: "кофе", amount: 250, category: groceries.id),
      categories: categories, in: references)
    Templates.remember(
      draft(.income, note: "подарок", amount: 5_000, category: salary.id),
      categories: categories, in: references)
    Templates.remember(
      draft(.income, note: "премия", amount: 9_000), categories: categories, in: references)
    Templates.remember(
      draft(.refund, note: "кроссовки", amount: 7_000, category: groceries.id),
      categories: categories, in: references)
    var payment = draft(.expense, note: "платёж", amount: 30_000)
    payment.debtId = UUID()
    Templates.remember(payment, categories: categories, in: references)
    var contribution = draft(.expense, note: "взнос", amount: 5_000)
    contribution.parts[0].goalId = UUID()
    Templates.remember(contribution, categories: categories, in: references)

    let remembered = try references.templates().map(\.text).sorted()
    XCTAssertEqual(remembered, ["кофе", "подарок"])
  }

  /// The same words entered as an expense after an income: the chip follows the last use and
  /// no longer carries the income category that made it read «+».
  func testAChipFollowsTheKindItWasLastUsedAs() throws {
    let categories = [salary, groceries]
    Templates.remember(
      draft(.income, note: "подарок", amount: 5_000, category: salary.id),
      categories: categories, in: references)
    Templates.remember(
      draft(.expense, note: "подарок", amount: 1_500), categories: categories, in: references)

    let template = try XCTUnwrap(try references.templates().first)
    XCTAssertEqual(template.useCount, 2)
    XCTAssertEqual(parse(Templates.line(for: template, categories: categories)).kind, .expense)
  }

  // MARK: The strip

  /// The strip read its chips when it appeared and after a chip was picked or pinned, and the
  /// entry line wrote new templates behind its back: on a fresh database no chip appeared
  /// however many operations were saved, and counts and amounts stayed as they were until the
  /// window was opened again. A save now reaches the list the strip shows.
  func testASavedOperationReachesTheChipsTheStripShows() throws {
    let categories = [salary, groceries]
    let model = TemplatesModel()
    model.attach(references)
    XCTAssertTrue(model.templates.isEmpty)

    model.remember(
      draft(.expense, note: "кофе", amount: 250, category: groceries.id), categories: categories)
    XCTAssertEqual(model.templates.map(\.text), ["кофе"])

    model.remember(
      draft(.expense, note: "кофе", amount: 300, category: groceries.id), categories: categories)
    XCTAssertEqual(model.templates.first?.useCount, 2)
    XCTAssertEqual(model.templates.first?.amountE4, AmountE4(whole: 300))
  }
}
