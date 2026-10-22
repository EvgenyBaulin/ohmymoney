import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The owner's rules and the tags in the entry being written: what a rule fills before Enter,
/// what the owner's own choice keeps, what is taken back when the line changes.
@MainActor
final class RuleEntryTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!

  private let groceries = CoreKit.Category(kind: .expense, name: "Продукты")
  private let cafe = CoreKit.Category(kind: .expense, name: "Кафе")
  private let shop = Place(name: "Пятёрочка", aliases: ["5ka"])
  private let family = Person(name: "Маша")
  private let tag = Tag(name: "еда")

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(groceries)
    try references.save(cafe)
    try references.save(shop)
    try references.save(family)
  }

  private func model(editing: Bool = false) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: editing)
    model.reload()
    model.draft.amount = AmountE4(whole: 1_200)
    model.draft.normalizeSinglePart()
    return model
  }

  private func groceriesRule(_ extra: [RuleAction] = []) -> Rule {
    Rule(
      name: "Пятёрочка", conditions: [.textContains("пятёрочка")],
      actions: [.setCategory(groceries.id)] + extra)
  }

  private func apply(_ model: EntryDraftModel, _ rules: [Rule], tags: [String] = []) {
    model.applyRules(rules, lineTags: tags, calendar: .utc)
  }

  // MARK: The line without its tags

  func testTheLineIsReadWithoutItsTags() {
    let interpreter = TaggingInterpreter(
      base: CoreLineInterpreter(vocabulary: ParserVocabulary(), calendar: .utc))
    let today = DateOnly(year: 2026, month: 9, day: 18)
    let parsed = interpreter.interpret("ужин 3500 #отпуск #турция", today: today)
    XCTAssertEqual(parsed.amount, 3_500)
    XCTAssertEqual(parsed.note, "ужин")
    XCTAssertEqual(TagText.extract(from: "ужин 3500 #отпуск #турция").tags, ["отпуск", "турция"])
  }

  func testAHashWordThatIsNoTagStaysInTheLine() {
    let interpreter = TaggingInterpreter(
      base: CoreLineInterpreter(vocabulary: ParserVocabulary(), calendar: .utc))
    let today = DateOnly(year: 2026, month: 9, day: 18)
    let parsed = interpreter.interpret("кофе 250 #1", today: today)
    XCTAssertEqual(parsed.amount, 250)
    XCTAssertTrue(parsed.note.contains("#1"), "«#1» is a number sign, not a tag")
  }

  // MARK: What a rule fills

  func testARuleFillsTheCategoryAndSaysWhoDidIt() {
    let model = model()
    model.draft.note = "пятёрочка"
    let rule = groceriesRule()
    apply(model, [rule])
    XCTAssertEqual(model.draft.parts[0].categoryId, groceries.id)
    XCTAssertEqual(model.draft.parts[0].categorySource, .template)
    XCTAssertEqual(model.ruleState.filled.category, groceries.id)
    XCTAssertEqual(model.ruleState.verdict.category?.ruleId, rule.id)
    XCTAssertEqual(model.ruleState.verdict.matchedRuleIds.count, 1)
  }

  func testAPlaceNamedByAnAliasMatchesTheTextCondition() {
    let model = model()
    model.draft.placeId = shop.id
    apply(model, [groceriesRule()])
    XCTAssertEqual(model.draft.parts[0].categoryId, groceries.id, "the place's name is read")
  }

  func testWhatTheOwnerChoseIsNotTouchedButTheRuleIsStillSaid() {
    let model = model()
    model.draft.note = "пятёрочка"
    model.setCategory(cafe.id, forPartAt: 0)
    apply(model, [groceriesRule()])
    XCTAssertEqual(model.draft.parts[0].categoryId, cafe.id, "your choice beats the rule")
    XCTAssertEqual(model.draft.parts[0].categorySource, .manual)
    XCTAssertNil(model.ruleState.filled.category)
    XCTAssertEqual(model.ruleState.verdict.category?.value, groceries.id)
  }

  func testARuleBeatsHistoryAndTheModel() {
    for source in [CategorySource.history, .model] {
      let model = model()
      model.draft.note = "пятёрочка"
      model.setCategory(cafe.id, forPartAt: 0, source: source)
      apply(model, [groceriesRule()])
      XCTAssertEqual(model.draft.parts[0].categoryId, groceries.id, "rule over \(source)")
    }
  }

  func testWhenTheLineStopsSayingItTheRuleIsTakenBack() {
    let model = model()
    model.draft.note = "пятёрочка"
    apply(model, [groceriesRule()])
    XCTAssertEqual(model.draft.parts[0].categoryId, groceries.id)
    model.draft.note = "кофе"
    model.retractRules()
    apply(model, [groceriesRule()])
    XCTAssertNil(model.draft.parts[0].categoryId)
    XCTAssertTrue(model.ruleState.verdict.matchedRuleIds.isEmpty)
    XCTAssertEqual(model.ruleState.filled, EntryRuleState.Filled())
  }

  func testWhatTheOwnerSetAfterTheRuleSurvivesTheRetraction() {
    let model = model()
    model.draft.note = "пятёрочка"
    apply(model, [groceriesRule()])
    model.setCategory(cafe.id, forPartAt: 0)
    model.retractRules()
    XCTAssertEqual(model.draft.parts[0].categoryId, cafe.id)
  }

  func testARuleFillsThePlaceTheQualityAndForWhom() {
    let model = model()
    model.draft.note = "пятёрочка"
    let rule = Rule(
      conditions: [.textContains("пятёрочка")],
      actions: [.setPlace(shop.id), .setQuality(.bad), .setForPerson(family.id)])
    apply(model, [rule])
    XCTAssertEqual(model.draft.placeId, shop.id)
    XCTAssertEqual(model.draft.parts[0].quality, .bad)
    XCTAssertEqual(model.draft.parts[0].qualitySource, .manual)
    XCTAssertEqual(model.draft.parts[0].forPersonId, family.id)
    model.draft.note = "кофе"
    model.retractRules()
    XCTAssertNil(model.draft.placeId)
    XCTAssertNil(model.draft.parts[0].forPersonId)
  }

  func testTheAmountConditionReadsTheAmountInRubles() {
    let model = model()
    model.draft.note = "такси"
    let rule = Rule(
      conditions: [.textContains("такси"), .amountAbove(AmountE4(whole: 1_000))],
      actions: [.setCategory(cafe.id)])
    apply(model, [rule])
    XCTAssertEqual(model.draft.parts[0].categoryId, cafe.id)
    model.retractRules()
    model.draft.amount = AmountE4(whole: 900)
    model.draft.parts[0].amount = AmountE4(whole: 900)
    apply(model, [rule])
    XCTAssertNil(model.draft.parts[0].categoryId, "900 is not above 1,000")
  }

  func testASavedOperationBeingEditedIsNeverTouchedByARule() {
    let model = model(editing: true)
    model.draft.note = "пятёрочка"
    apply(model, [groceriesRule()])
    XCTAssertNil(model.draft.parts[0].categoryId)
    XCTAssertTrue(model.ruleState.verdict.matchedRuleIds.isEmpty)
  }

  func testAGoalContributionADebtPaymentAndMoneyBackAreLeftToTheirOwnRules() {
    let rule = groceriesRule([.setQuality(.bad), .setForPerson(family.id)])
    let goal = model()
    goal.draft.note = "пятёрочка"
    goal.draft.parts[0].goalId = UUID()
    apply(goal, [rule])
    XCTAssertNil(goal.draft.parts[0].categoryId, "a contribution stays in Goals")
    XCTAssertEqual(goal.ruleState.verdict.category?.value, groceries.id, "the rule is still said")

    let debt = model()
    debt.draft.note = "пятёрочка"
    debt.draft.debtId = UUID()
    apply(debt, [rule])
    XCTAssertNil(debt.draft.parts[0].categoryId, "a payment stays with its debt")
    XCTAssertNil(debt.draft.parts[0].forPersonId)

    let back = model()
    back.draft.kind = .reimbursement
    back.draft.note = "пятёрочка"
    apply(back, [rule])
    XCTAssertNil(back.draft.parts[0].categoryId, "money back has no category")
    XCTAssertNil(back.draft.parts[0].quality)
  }

  func testACategoryOfTheOtherKindOrArchivedIsNotFilled() throws {
    let salary = CoreKit.Category(kind: .income, name: "Зарплата")
    try references.save(salary)
    var gone = CoreKit.Category(kind: .expense, name: "Старая")
    gone.archived = true
    try references.save(gone)
    let model = model()
    model.reload()
    model.draft.note = "пятёрочка"
    let rule = Rule(conditions: [.textContains("пятёрочка")], actions: [.setCategory(salary.id)])
    apply(model, [rule])
    XCTAssertNil(model.draft.parts[0].categoryId, "an income category on an expense")
    apply(model, [Rule(conditions: [.textContains("пятёрочка")], actions: [.setCategory(gone.id)])])
    XCTAssertNil(model.draft.parts[0].categoryId, "an archived category")
  }

  // MARK: Tags

  func testRuleTagsAddUpAndCanBeTakenOffForThisOperation() {
    let model = model()
    model.draft.note = "пятёрочка"
    let rules = [
      groceriesRule([.addTag(tag.id)]),
      Rule(conditions: [.amountAbove(AmountE4(whole: 1))], actions: [.addTag(tag.id)]),
    ]
    apply(model, rules, tags: ["отпуск"])
    XCTAssertEqual(model.ruleState.ruleTags.map(\.value), [tag.id], "once, whoever named it")
    XCTAssertEqual(model.ruleState.lineTags, ["отпуск"])
    model.dismissRuleTag(tag.id)
    XCTAssertTrue(model.ruleState.ruleTags.isEmpty)
  }

  func testTagsTypedInTheLineAndThePanelAreOneListWithoutRepeats() {
    let model = model()
    apply(model, [], tags: ["Отпуск", "турция"])
    XCTAssertTrue(model.addPanelTag("#отпуск"), "already there, and that is fine")
    XCTAssertTrue(model.addPanelTag("кофе"))
    XCTAssertFalse(model.addPanelTag("#1"), "no letter, no tag")
    XCTAssertFalse(model.addPanelTag("a b"))
    XCTAssertEqual(model.ruleState.typedTags, ["Отпуск", "турция", "кофе"])
    model.removePanelTag("КОФЕ")
    XCTAssertEqual(model.ruleState.typedTags, ["Отпуск", "турция"])
  }

  func testTheNextOperationStartsWithoutTheLastOnesRulesAndTags() {
    let model = model()
    model.draft.note = "пятёрочка"
    apply(model, [groceriesRule([.addTag(tag.id)])], tags: ["отпуск"])
    model.addPanelTag("кофе")
    model.reset()
    XCTAssertEqual(model.ruleState, EntryRuleState())
  }

  // MARK: Under the line

  func testTheHintNamesTheRulesAndWhatTheySay() {
    let model = model()
    model.draft.note = "пятёрочка"
    let rule = groceriesRule([.addTag(tag.id)])
    apply(model, [rule])
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      let wording = RuleWording(
        environment: environment,
        names: RuleNames(
          tree: CategoryTree([groceries, cafe]), tags: [tag.id: tag.name]))
      let hint = EntryLineRules.hint(model.ruleState.verdict, rules: [rule], wording: wording)
      XCTAssertEqual(
        hint, (choice == .russian ? "По правилу" : "By rule") + " «Пятёрочка»: Продукты · #еда")
    }
    AppEnvironment().language.choice = .system
    XCTAssertNil(
      EntryLineRules.hint(
        RuleVerdict(), rules: [rule],
        wording: RuleWording(environment: AppEnvironment(), names: RuleNames())),
      "no rule, no sentence")
  }

  func testTheLineAloneIsEnoughToSeeTheRule() {
    let interpreter = TaggingInterpreter(
      base: CoreLineInterpreter(
        vocabulary: ParserVocabulary(
          places: [.init(id: shop.id, name: shop.name, aliases: shop.aliases)]),
        calendar: .utc))
    let today = DateOnly(year: 2026, month: 9, day: 18)
    let reading = interpreter.read("пятёрочка 1200 #еда", today: today, kind: nil)
    let tree = CategoryTree([groceries, cafe])
    let subject = EntryLineRules.subject(
      reading: reading, noteWords: "", places: [shop.id: shop], fallback: nil, tree: tree,
      calendar: .utc, now: Date())
    let verdict = RuleEngine.evaluate(subject, rules: [groceriesRule()], tree: tree)
    XCTAssertEqual(verdict.category?.value, groceries.id)
    XCTAssertEqual(subject.amountRubE4, AmountE4(whole: 1_200))
  }
}
