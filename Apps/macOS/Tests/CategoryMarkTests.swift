import AppCore
import AppKit
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// The mark of a category in the list of operations: its symbol and the tint of its tone, kept
/// readable on every theme, chosen from short lists whose every entry exists and has a name in
/// both languages.
@MainActor
final class CategoryMarkPaletteTests: XCTestCase {
  func testEverySymbolOfTheListIsASystemSymbolOfThisSystem() {
    for icon in CategoryIcon.all {
      XCTAssertNotNil(
        NSImage(systemSymbolName: icon, accessibilityDescription: nil), "\(icon) is no SF Symbol")
    }
  }

  func testEverySymbolAndEveryToneHasANameInBothLanguages() {
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for language in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = language
      for icon in CategoryIcon.all {
        let key = CategoryAppearanceText.iconNameKey(icon)
        XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(icon) \(language)")
      }
      for tone in CategoryTone.allCases {
        XCTAssertNotEqual(
          environment.language(tone.nameKey, table: "Settings"), tone.nameKey,
          "\(tone.key) \(language)")
      }
    }
  }

  /// The symbol is drawn on its own tint over the card: text-grade contrast on every theme, in
  /// both schemes, and in the Contrast theme «Увеличить контраст» swaps in.
  func testEveryInkReadsOnItsTintOnEveryThemeInBothSchemes() {
    for theme in ThemeCatalog.all {
      for (scheme, palette) in [("light", theme.light), ("dark", theme.dark)] {
        for tone in CategoryTone.allCases {
          let ground = tone.tint(in: palette).composited(over: palette.surfaceCard)
          XCTAssertGreaterThanOrEqual(
            tone.ink(in: palette).contrast(on: ground), 4.5, "\(theme.id) \(scheme) \(tone.key)")
        }
      }
    }
    XCTAssertTrue(ThemeCatalog.all.contains { $0.id == ThemeResolver.contrastTheme })
  }

  /// Each tone is a theme's slot, so it changes with the theme: not one fixed colour.
  func testTheTonesFollowTheTheme() {
    let first = ThemeCatalog.all[0].light
    let other = ThemeCatalog.all[ThemeCatalog.all.count / 2].light
    XCTAssertTrue(
      CategoryTone.allCases.contains { $0.ink(in: first) != $0.ink(in: other) },
      "a theme that paints every tone the same would not be a theme")
  }

  func testNoTwoTonesAreTheSameInTheDefaultTheme() {
    let palette = ThemeCatalog.all[0].light
    let tints = CategoryTone.allCases.map { $0.tint(in: palette) }
    XCTAssertEqual(Set(tints).count, tints.count)
  }
}

@MainActor
final class CategoryMarkRowTests: XCTestCase {
  private let calendar = CalendarContext.utc
  private let marked = CoreKit.Category(
    id: UUID(), kind: .expense, name: "Еда",
    appearance: CategoryAppearance(icon: "cart", color: "tone1"))
  private let bare = CoreKit.Category(kind: .expense, name: "Прочее")
  private lazy var coffee = CoreKit.Category(
    parentId: marked.id, kind: .expense, name: "Кофе")

  private func entry(_ note: String, categories: [CoreKit.Category]) throws -> TransactionEntry {
    let moment = calendar.startOfDay(DateOnly(year: 2026, month: 9, day: 16))
      .addingTimeInterval(12 * 3600)
    var draft = TransactionDraft(
      kind: .expense, occurredAt: moment, currency: .rub,
      amount: AmountE4(whole: 100 * Int64(categories.count)), note: note)
    draft.normalizeSinglePart()
    if categories.count > 1 {
      draft.parts = categories.map { category in
        var part = draft.parts[0]
        part.id = UUID()
        part.amount = AmountE4(whole: 100)
        part.categoryId = category.id
        return part
      }
    } else {
      draft.parts[0].categoryId = categories.first?.id
    }
    return try draft.materialize(now: moment, timeZone: CalendarContext.utc.timeZone)
  }

  private func rows(_ entries: [TransactionEntry]) -> [TransactionRowItem] {
    let ledger = Ledger(
      dataset: Dataset(entries: entries, categories: [marked, bare, coffee]),
      calendar: calendar)
    return TransactionListing.build(matching: .none, in: ledger).sections.flatMap(\.rows)
  }

  func testAnOperationOfAMarkedCategoryCarriesItsSymbolAndTone() throws {
    let row = try XCTUnwrap(rows([try entry("обед", categories: [marked])]).first)
    XCTAssertEqual(row.categoryMark?.icon, "cart")
    XCTAssertEqual(row.categoryMark?.tone, .tone1)
    guard case .one = row.category else {
      return XCTFail("the name of the category is still in the row")
    }
  }

  func testASubcategoryWithoutAMarkWearsItsParents() throws {
    let row = try XCTUnwrap(rows([try entry("латте", categories: [coffee])]).first)
    XCTAssertEqual(row.categoryMark?.icon, "cart")
  }

  func testACategoryWithoutAMarkKeepsTheMarkOfItsKind() throws {
    let row = try XCTUnwrap(rows([try entry("мелочь", categories: [bare])]).first)
    XCTAssertNil(row.categoryMark)
    XCTAssertEqual(OperationBadgeKind(row), .expense)
  }

  func testASymbolWithoutAColourTakesTheAccent() throws {
    let tree = CategoryTree([
      CoreKit.Category(
        id: marked.id, kind: .expense, name: "Еда",
        appearance: CategoryAppearance(icon: "cart", color: nil))
    ])
    XCTAssertEqual(CategoryMark(of: marked.id, tree: tree)?.tone, .accent)
  }

  func testASymbolThisBuildDoesNotKnowKeepsTheMarkOfTheKind() {
    let tree = CategoryTree([
      CoreKit.Category(
        id: marked.id, kind: .expense, name: "Еда",
        appearance: CategoryAppearance(icon: "future.symbol", color: "tone1"))
    ])
    XCTAssertNil(CategoryMark(of: marked.id, tree: tree))
  }

  func testASplitOverTwoCategoriesKeepsTheMarkOfTheKindButOverOneCategoryWearsIt() throws {
    let mixed = try entry("вперемешку", categories: [marked, bare])
    let row = try XCTUnwrap(rows([mixed]).first)
    XCTAssertNil(row.categoryMark)
    let alike = try entry("две еды", categories: [marked, marked])
    XCTAssertEqual(try XCTUnwrap(rows([alike]).first).categoryMark?.icon, "cart")
  }

  func testAPartOfASplitAndAnOperationWithoutACategoryHaveNoMark() throws {
    let mixed = try entry("вперемешку", categories: [marked, marked])
    let listed = rows([mixed])
    for part in listed.flatMap({ $0.parts ?? [] }) {
      XCTAssertNil(part.categoryMark, "a part sits under its split without a mark of its own")
    }
    let none = try entry("без категории", categories: [])
    XCTAssertNil(try XCTUnwrap(rows([none]).first).categoryMark)
  }

  func testARefundAndMoneyGivenBackKeepTheMarkOfTheirKind() throws {
    for kind in [TransactionKind.refund, .reimbursement] {
      var made = try entry("возврат", categories: [marked])
      made.transaction.kind = kind
      let row = try XCTUnwrap(rows([made]).first)
      XCTAssertNil(row.categoryMark, "\(kind)")
    }
  }

  func testATransferKeepsTheMarkOfItsKind() throws {
    let ledger = Ledger(
      dataset: Dataset(
        categories: [marked],
        transfers: [
          Transfer(
            occurredAt: calendar.startOfDay(DateOnly(year: 2026, month: 9, day: 16)),
            fromAccountId: UUID(), fromCurrency: .rub, fromAmountE4: AmountE4(whole: 10),
            toAccountId: UUID(), toCurrency: .rub, toAmountE4: AmountE4(whole: 10))
        ]),
      calendar: calendar)
    let listed = TransactionListing.build(matching: .none, in: ledger).sections.flatMap(\.rows)
    let row = try XCTUnwrap(listed.first)
    XCTAssertTrue(row.isTransfer)
    XCTAssertNil(row.categoryMark)
  }
}

@MainActor
final class StarterCategoryMarkTests: XCTestCase {
  /// A new database starts with a mark on every top-level category, in every language, and its
  /// subcategories follow them: its rows in «Операции» show the symbol of the category at once.
  func testFirstLaunchGivesEveryTopLevelCategoryAMarkAndSubcategoriesFollow() {
    for language in ["ru", "en", "de", "ja"] {
      let all = StarterCategories.tree(language: language)
      let tree = CategoryTree(all)
      for category in all {
        let drawn = tree.appearance(of: category.id)
        XCTAssertNotNil(drawn.icon, "\(category.name) \(language)")
        XCTAssertNotNil(drawn.tone, "\(category.name) \(language)")
      }
    }
  }
}
