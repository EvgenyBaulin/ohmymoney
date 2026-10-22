import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The words and the editor model of the rules: pure, no window, no database.
@MainActor
final class RuleScreensTests: XCTestCase {
  private let groceries = CoreKit.Category(kind: .expense, name: "Продукты")
  private let place = Place(name: "Яндекс Go")
  private let tag = Tag(name: "работа")

  override func tearDown() async throws {
    environment(.system).language.choice = .system
  }

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func names() -> RuleNames {
    RuleNames(
      tree: CategoryTree([groceries]), places: [place.id: place.name],
      tags: [tag.id: tag.name])
  }

  // MARK: Words

  func testAConditionAndAnActionReadInBothLanguages() {
    let rule = Rule(
      name: "",
      conditions: [.textContains("Яндекс Go"), .amountAbove(AmountE4(whole: 1_000))],
      actions: [.addTag(tag.id), .setCategory(groceries.id)])
    let ru = environment(.russian)
    XCTAssertEqual(
      RuleWording(environment: ru, names: names()).summary(rule),
      "Если место или описание содержит «Яндекс Go» и сумма больше "
        + ru.money.exact(AmountE4(whole: 1_000)) + ", то #работа, категория Продукты")
    let en = environment(.english)
    XCTAssertEqual(
      RuleWording(environment: en, names: names()).summary(rule),
      "If place or description contains «Яндекс Go» and amount is above "
        + en.money.exact(AmountE4(whole: 1_000)) + ", then #работа, category Продукты")
  }

  func testTheTitleIsTheNameOrTheSummary() {
    var rule = Rule(name: "  Такси ", conditions: [.place(place.id)], actions: [.addTag(tag.id)])
    let wording = RuleWording(environment: environment(.russian), names: names())
    XCTAssertEqual(wording.title(rule), "Такси")
    rule.name = " "
    XCTAssertEqual(wording.title(rule), wording.summary(rule))
  }

  func testWeekdaysAndClockReadAsTheyAreWritten() {
    let wording = RuleWording(environment: environment(.russian), names: names())
    XCTAssertEqual(
      wording.condition(.weekdays([7, 6])).lowercased(), "день недели: сб, вс",
      "Monday first, in the order of the week")
    XCTAssertEqual(
      wording.condition(.timeBetween(fromMinute: 22 * 60, toMinute: 6 * 60 + 5)),
      "время с 22:00 до 06:05")
    XCTAssertEqual(RuleWording.clock(0), "00:00")
  }

  func testEveryProblemSaysSomethingInBothLanguages() {
    let problems: [RuleProblem] = [
      .noConditions, .noActions, .emptyText, .negativeAmount, .badWeekdays, .badTime,
      .unknownCategory(groceries.id), .retiredCategory(groceries.id),
      .systemCategory(groceries.id), .mixedCategoryKinds, .twoActionsOnOneField(.category),
      .unknownTag(tag.id), .categoryNeverFits,
    ]
    var seen: Set<String> = []
    for choice in [AppLanguage.Choice.russian, .english] {
      let wording = RuleWording(environment: environment(choice), names: names())
      for problem in problems {
        let text = wording.problem(problem)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.hasPrefix("rules.problem"), "\(problem) has no words in \(choice)")
        seen.insert("\(choice)|\(text)")
      }
    }
    XCTAssertEqual(seen.count, problems.count * 2, "no two problems say the same")
  }

  func testEveryKindOfRowAndFieldHasWordsInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let env = environment(choice)
      let wording = RuleWording(environment: env, names: names())
      for kind in ConditionKind.allCases {
        let text = RulesText.t(kind.titleKey, env)
        XCTAssertNotEqual(text, kind.titleKey, "\(kind) in \(choice)")
      }
      for kind in ActionKind.allCases {
        XCTAssertNotEqual(RulesText.t(kind.titleKey, env), kind.titleKey, "\(kind) in \(choice)")
      }
      for kind in TransactionKind.allCases {
        XCTAssertFalse(wording.kindName(kind).hasPrefix("rules."))
      }
      for field in RuleField.allCases {
        XCTAssertFalse(wording.fieldName(field).hasPrefix("rules."))
      }
      for reason in BulkSkipReason.allCases {
        XCTAssertFalse(wording.skip(reason).hasPrefix("bulk."), "\(reason) in \(choice)")
      }
      for pane in RulesSettingsView.Pane.allCases {
        XCTAssertNotEqual(RulesText.t(pane.titleKey, env), pane.titleKey)
      }
      for key in ["rules.origin.import", "rules.origin.exchange"] {
        XCTAssertNotEqual(RulesText.t(key, env), key)
      }
    }
  }

  func testOnlyImportedAndExchangedRulesCarryAnOriginNote() {
    let wording = RuleWording(environment: environment(.russian), names: names())
    XCTAssertNil(wording.origin(.manual))
    XCTAssertEqual(wording.origin(.imported), "из импорта")
    XCTAssertEqual(wording.origin(.exchange), "из файла")
  }

  // MARK: The editor model

  func testABlankDraftCannotBeSaved() {
    let draft = RuleDraft()
    let found = draft.problems(tree: CategoryTree([groceries]), book: TagBook())
    XCTAssertTrue(found.core.contains(.noConditions))
    XCTAssertEqual(found.unfinished, 2, "the empty condition and the empty action")
    XCTAssertFalse(draft.canSave(tree: CategoryTree([groceries]), book: TagBook()))
  }

  func testADraftBuildsTheRuleItDescribes() {
    var draft = RuleDraft()
    draft.name = "Такси"
    draft.conditions = [
      ConditionRow(.textContains("Яндекс")),
      {
        var row = ConditionRow(kind: .amountAbove)
        row.amountText = "1000.5"
        return row
      }(),
    ]
    draft.actions = [
      ActionRow(.setCategory(groceries.id)),
      {
        var row = ActionRow(kind: .tag)
        row.tagText = "#Работа"
        return row
      }(),
    ]
    let book = TagBook(tags: [tag])
    let built = draft.build(book: book)
    XCTAssertEqual(built.skippedRows, 0)
    XCTAssertTrue(built.newTagIds.isEmpty, "«#Работа» is the tag «работа»")
    XCTAssertEqual(
      built.rule.conditions,
      [.textContains("Яндекс"), .amountAbove(try! AmountE4(decimal: Decimal(string: "1000.5")!))])
    XCTAssertEqual(built.rule.actions, [.setCategory(groceries.id), .addTag(tag.id)])
    XCTAssertTrue(draft.canSave(tree: CategoryTree([groceries]), book: book))
  }

  func testATagTypedThatDoesNotExistIsMadeWithTheRule() {
    var draft = RuleDraft()
    draft.conditions = [ConditionRow(.textContains("кофе"))]
    var row = ActionRow(kind: .tag)
    row.tagText = "кофе-брейк"
    draft.actions = [row]
    let built = draft.build(book: TagBook())
    XCTAssertEqual(built.newTagIds.count, 1)
    XCTAssertEqual(built.book.tags.map(\.name), ["кофе-брейк"])
    XCTAssertEqual(built.rule.actions, [.addTag(built.book.tags[0].id)])
    XCTAssertTrue(draft.canSave(tree: CategoryTree(), book: TagBook()))
  }

  func testRowsThatSayTooLittleAreCountedAndKeepTheDraftFromBeingSaved() {
    var draft = RuleDraft()
    draft.conditions = [ConditionRow(.textContains("кофе")), ConditionRow(kind: .place)]
    draft.actions = [ActionRow(.setQuality(.good)), ActionRow(kind: .tag)]
    let built = draft.build(book: TagBook())
    XCTAssertEqual(built.skippedRows, 2, "no place chosen, no tag typed")
    XCTAssertEqual(built.rule.conditions.count, 1)
    XCTAssertEqual(built.rule.actions.count, 1)
    XCTAssertFalse(draft.canSave(tree: CategoryTree(), book: TagBook()))
  }

  func testAFigureThatIsNoNumberBuildsToNothing() {
    var row = ConditionRow(kind: .amountBelow)
    XCTAssertNil(row.condition)
    row.amountText = "много"
    XCTAssertNil(row.condition)
    row.amountText = "300"
    XCTAssertEqual(row.condition, .amountBelow(AmountE4(whole: 300)))
    row.amountText = "-5"
    XCTAssertEqual(
      RuleValidator.problems(
        of: Rule(conditions: [row.condition!], actions: [.setQuality(.good)]),
        tree: CategoryTree()),
      [.negativeAmount])
  }

  func testAnEditedRuleComesBackAsItWasWritten() {
    let rule = Rule(
      name: "Ночью", position: 3, enabled: false, origin: .exchange,
      conditions: [
        .timeBetween(fromMinute: 1_380, toMinute: 300), .weekdays([5, 6]),
        .kind(.expense), .category(groceries.id), .amountBelow(AmountE4(whole: 90)),
      ],
      actions: [.setForWhom(.partner), .setQuality(.bad), .setPlace(place.id), .addTag(tag.id)])
    let draft = RuleDraft(rule, book: TagBook(tags: [tag]))
    XCTAssertFalse(draft.isNew)
    let built = draft.build(book: TagBook(tags: [tag])).rule
    XCTAssertEqual(built.conditions, rule.conditions)
    XCTAssertEqual(built.actions, rule.actions)
    XCTAssertEqual(built.id, rule.id)
    XCTAssertEqual(built.position, 3, "editing keeps the place in the list")
    XCTAssertFalse(built.enabled)
    XCTAssertEqual(built.origin, .exchange)
    XCTAssertEqual(built.name, "Ночью")
  }

  func testTheChoicesLeaveOutWhatCannotBeChosen() {
    let archived = CoreKit.Category(kind: .expense, name: "Старое", archived: true)
    let child = CoreKit.Category(parentId: groceries.id, kind: .expense, name: "Овощи")
    let old = Place(name: "Закрытое", archived: true)
    let dataset = Dataset(
      categories: [groceries, archived, child], places: [place, old],
      tagBook: TagBook(tags: [tag, Tag(name: "прошлое", archived: true)]))
    let choices = RuleChoices(dataset: dataset)
    XCTAssertEqual(choices.actionCategories.map(\.title), ["Продукты", "Продукты › Овощи"])
    XCTAssertEqual(choices.places.map(\.title), ["Яндекс Go"])
    XCTAssertEqual(choices.tags.map(\.title), ["работа"])
  }

  func testTheTrialCountsFromAPlan() throws {
    let wording = environment(.english)
    var draft = TransactionDraft(
      occurredAt: Date(), amount: AmountE4(whole: 250), note: "pyaterochka")
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    let rule = Rule(
      conditions: [.textContains("pyaterochka")], actions: [.setCategory(groceries.id)])
    let plan = RuleBackfill.plan(
      rules: [rule], entries: [entry], tree: CategoryTree([groceries]))
    let result = RuleTrialResult(plan: plan)
    XCTAssertEqual(result.scanned, 1)
    XCTAssertEqual(result.matched, 1)
    XCTAssertEqual(result.changed, 1)
    XCTAssertEqual(result.samples.first?.fields, [.category])
    XCTAssertEqual(
      result.summary(wording), "Matches: 1 of 1 operations · would change: 1")
    let none = RuleTrialResult(
      plan: RuleBackfill.plan(rules: [rule], entries: [], tree: CategoryTree([groceries])))
    XCTAssertEqual(none.summary(wording), "No operation of the history matches this rule.")
  }

  // MARK: The views lay out

  /// Each pane fits beside the sidebar of the smallest settings window, and each sheet makes a
  /// view with a size, in either language and with no data yet.
  func testThePanesAndTheSheetsLayOutInBothLanguages() {
    let room = CGSize(
      width: SettingsView.minimumSize.width - SettingsView.sidebarWidth.max,
      height: SettingsView.minimumSize.height)
    for choice in [AppLanguage.Choice.russian, .english] {
      let env = environment(choice)
      let deps = AppDependencies.forTests(env)
      let panes: [(String, AnyView)] = [
        ("rules", AnyView(RulesPane().appDependencies(deps))),
        ("tags", AnyView(TagsPane().appDependencies(deps))),
        ("exchange", AnyView(RuleExchangePane().appDependencies(deps))),
        ("section", AnyView(RulesSettingsView().appDependencies(deps))),
      ]
      for (name, view) in panes {
        let size = NSHostingController(rootView: view).sizeThatFits(in: room)
        XCTAssertGreaterThan(size.height, 0, "\(name) in \(choice)")
        XCTAssertLessThanOrEqual(size.width, room.width + 0.5, "\(name) in \(choice)")
      }
      let sheets: [(String, AnyView)] = [
        ("editor", AnyView(RuleEditorSheet(draft: RuleDraft()).appDependencies(deps))),
        ("backfill", AnyView(BackfillSheet().appDependencies(deps))),
        ("export", AnyView(RuleExportSheet(rules: []).appDependencies(deps))),
        ("import", AnyView(RuleImportSheet(bundle: RuleBundle()).appDependencies(deps))),
        ("report", AnyView(TagReportSheet().appDependencies(deps))),
        ("tags row", AnyView(EntryTagsRow(model: entryModel()).appDependencies(deps))),
      ]
      for (name, view) in sheets {
        let size = NSHostingController(rootView: view).sizeThatFits(
          in: CGSize(width: 700, height: 900))
        XCTAssertGreaterThan(size.width, 0, "\(name) in \(choice)")
        XCTAssertGreaterThan(size.height, 0, "\(name) in \(choice)")
      }
    }
  }

  private func entryModel() -> EntryDraftModel {
    EntryDraftModel(references: nil, transactions: nil, calendar: .utc)
  }
}
