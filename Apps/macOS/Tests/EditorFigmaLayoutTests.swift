import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The editor of a saved operation as the design draws it, in its sheet (1 440 pt) and in its
/// inspector (360 pt), in both languages: the fields in the design's order and in two columns, a
/// foot that never covers a field, an inspector closed by its × alone, a long name that wraps in
/// the title, and an operation of several parts that opens with all of them.
@MainActor
final class EditorFigmaLayoutTests: SectionFigmaHarness {
  override func setUp() async throws {
    try await super.setUp()
    // SwiftUI builds the accessibility tree the frames are read from only for an assistive client.
    try TestEnvironment.requireSwiftUIAccessibility()
  }

  private struct Cast {
    let groceries: CoreKit.Category
    let cafe: CoreKit.Category
    let gifts: CoreKit.Category
    let card: PaymentMethod
  }

  private func seed() throws -> Cast {
    let references = try XCTUnwrap(environment.references)
    let cast = Cast(
      groceries: CoreKit.Category(kind: .expense, name: "Groceries", quality: .good),
      cafe: CoreKit.Category(kind: .expense, name: "Cafes", quality: .neutral),
      gifts: CoreKit.Category(kind: .expense, name: "Gifts", quality: .neutral),
      card: PaymentMethod(name: "Debit card", kind: .card, currency: .rub, isDefault: true))
    for category in [cast.groceries, cast.cafe, cast.gifts] { try references.save(category) }
    try references.save(cast.card)
    return cast
  }

  private func entry(
    _ cast: Cast, note: String, parts: [(CoreKit.Category, Int64)]
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: environment.now(), currency: .rub,
      amount: AmountE4(whole: parts.reduce(0) { $0 + $1.1 }), rate: nil, rateDate: nil,
      rateSource: nil, note: note, paymentMethodId: cast.card.id)
    draft.parts = parts.map { category, whole in
      PartDraft(categoryId: category.id, quality: category.quality, amount: AmountE4(whole: whole))
    }
    return try draft.materialize(rublesConverter: { $0 })
  }

  private func model(for entry: TransactionEntry, _ cast: Cast) -> TransactionEditorModel {
    TransactionEditorModel(
      entry: entry, environment: environment,
      tree: CategoryTree([cast.groceries, cast.cafe, cast.gifts]))
  }

  /// A tall window, so the whole editor is laid out without scrolling; the accessibility frames
  /// read from it are in screen coordinates, y up.
  private func tallWindow(
    _ editor: TransactionEditorModel, style: TransactionEditor.Style, width: CGFloat,
    height: CGFloat = 2_400
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    windows.append(window)
    let root = TransactionEditor(editor: editor, style: style) {}
      .frame(width: width, height: height)
      .appDependencies(deps)
    window.contentView = NSHostingView(rootView: root)
    window.makeKeyAndOrderFront(nil)
    settle(window, passes: 40)
    return window
  }

  private func frame(_ identifier: String, _ window: NSWindow) throws -> CGRect {
    var found: [AnyObject] = []
    let root = try XCTUnwrap(window.contentView)
    Self.elements(in: root, into: &found) { $0.accessibilityIdentifier?() == identifier }
    let frames = found.compactMap { $0.accessibilityFrame?() }.filter { $0.width > 0 }
    return try XCTUnwrap(
      frames.max(by: { $0.width * $0.height < $1.width * $1.height }),
      "\(identifier) was not found")
  }

  private func exists(_ identifier: String, _ window: NSWindow) -> Bool {
    guard let root = window.contentView else { return false }
    var found: [AnyObject] = []
    Self.elements(in: root, into: &found) { $0.accessibilityIdentifier?() == identifier }
    return !found.isEmpty
  }

  private let languages: [AppLanguage.Choice] = [.english, .russian]

  // MARK: An operation of several parts

  /// An operation saved in three parts opens in the editor with three parts, the first of them
  /// not standing for the whole: nothing of it is dropped when the form loads.
  func testAnOperationOfThreePartsOpensWithAllThree() throws {
    let cast = try seed()
    let saved = try entry(
      cast, note: "Shop and a gift",
      parts: [(cast.groceries, 1_800), (cast.cafe, 900), (cast.gifts, 700)])
    let editor = model(for: saved, cast)
    XCTAssertEqual(editor.draft.draft.parts.count, 3)
    XCTAssertTrue(editor.draft.isSplit)
    XCTAssertEqual(editor.draft.draft.parts.map { $0.amount.raw / 10_000 }, [1_800, 900, 700])
    XCTAssertTrue(editor.draft.draft.isBalanced)
    XCTAssertFalse(editor.hasChanges)
  }

  // MARK: Order and columns

  /// The design puts the date and the currency before the comment, which stands last; an order
  /// nobody chose is the design's.
  func testTheDateAndTheCurrencyStandAboveTheComment() throws {
    XCTAssertEqual(EntryFieldOrder.forEditor(environment.entryFieldOrder).last, .note)
    let cast = try seed()
    let saved = try entry(cast, note: "Weekly shop", parts: [(cast.groceries, 1_250)])
    for language in languages {
      environment.language.choice = language
      for (style, width) in [(TransactionEditor.Style.sheet, 1_440.0), (.inspector, 360.0)] {
        let window = tallWindow(model(for: saved, cast), style: style, width: width)
        let place = "\(language.rawValue) \(style) \(Int(width))"
        let date = try frame("entry.date", window)
        let currency = try frame("entry.currency", window)
        let note = try frame("entry.note", window)
        // y is up: higher on the screen is larger.
        XCTAssertGreaterThan(date.midY, note.midY, "the date is below the comment: \(place)")
        XCTAssertGreaterThan(currency.midY, note.midY, "the currency is below it: \(place)")
        window.contentView = nil
      }
    }
  }

  /// The sheet and the inspector flow their fields in two columns, not three: the category and
  /// the subcategory side by side, each wider than a third of the panel; the date and the
  /// currency on one row.
  func testTheEditorFlowsInTwoColumns() throws {
    let cast = try seed()
    let saved = try entry(cast, note: "Weekly shop", parts: [(cast.groceries, 1_250)])
    for language in languages {
      environment.language.choice = language
      for (style, width) in [(TransactionEditor.Style.sheet, 1_440.0), (.inspector, 360.0)] {
        let window = tallWindow(model(for: saved, cast), style: style, width: width)
        let place = "\(language.rawValue) \(style) \(Int(width))"
        let category = try frame("entry.category", window)
        let date = try frame("entry.date", window)
        let currency = try frame("entry.currency", window)
        XCTAssertEqual(date.midY, currency.midY, accuracy: 24, "date and currency: \(place)")
        XCTAssertGreaterThan(currency.minX, date.minX, "two columns: \(place)")
        // Three columns of the 720 pt panel are 233 pt wide; two are 355.
        let panel = min(720, width - 32)
        XCTAssertGreaterThan(category.width, panel / 3 + 10, "a column too narrow: \(place)")
        window.contentView = nil
      }
    }
  }

  // MARK: The foot and the head

  /// The inspector has «Удалить» and «Сохранить» in its foot and closes with its ×: no «Отмена».
  /// The sheet keeps «Отмена». Neither foot reaches past the window.
  func testTheInspectorFootHasTwoButtonsAndTheSheetKeepsCancel() throws {
    let cast = try seed()
    let saved = try entry(cast, note: "Weekly shop", parts: [(cast.groceries, 1_250)])
    for language in languages {
      environment.language.choice = language
      let inspector = tallWindow(
        model(for: saved, cast), style: .inspector, width: 360, height: 900)
      XCTAssertFalse(exists("editor.cancel", inspector), "an inspector with «Cancel»")
      XCTAssertTrue(exists("editor.close", inspector))
      let delete = try frame("editor.delete", inspector)
      let save = try frame("editor.save", inspector)
      XCTAssertLessThan(delete.maxX, save.minX)
      XCTAssertLessThanOrEqual(save.maxX, inspector.frame.maxX - 8)
      inspector.contentView = nil

      let sheet = tallWindow(model(for: saved, cast), style: .sheet, width: 1_440, height: 900)
      XCTAssertTrue(exists("editor.cancel", sheet))
      let cancel = try frame("editor.cancel", sheet)
      let sheetSave = try frame("editor.save", sheet)
      XCTAssertLessThan(cancel.maxX, sheetSave.minX)
      sheet.contentView = nil
    }
  }

  /// A long name wraps in the title of the inspector, in two lines at most, and stays clear of
  /// the ×.
  func testALongNameWrapsInTheInspectorTitle() throws {
    let cast = try seed()
    let saved = try entry(
      cast, note: "Dinner with a very long description of what exactly was bought today",
      parts: [(cast.groceries, 1_250)])
    for language in languages {
      environment.language.choice = language
      let window = tallWindow(
        model(for: saved, cast), style: .inspector, width: 360, height: 900)
      // The title is the element of the header that reads the note.
      var found: [AnyObject] = []
      let root = try XCTUnwrap(window.contentView)
      Self.elements(in: root, into: &found) {
        ($0.accessibilityLabel?() ?? "").contains("Dinner with a very long")
      }
      let title = try XCTUnwrap(
        found.compactMap { $0.accessibilityFrame?() }.filter { $0.width > 0 }.first,
        "the title was not found: \(language.rawValue)")
      let close = try frame("editor.close", window)
      XCTAssertLessThanOrEqual(title.maxX, close.minX + 1, "under the ×: \(language.rawValue)")
      XCTAssertGreaterThan(title.height, 28, "one cut line, not two: \(language.rawValue)")
      XCTAssertLessThan(title.height, 64, "more than two lines: \(language.rawValue)")
      window.contentView = nil
    }
  }

  /// The head of the sheet names the operation and says when it was recorded.
  func testTheSheetHeadSaysWhenTheOperationWasRecorded() throws {
    let cast = try seed()
    let saved = try entry(cast, note: "Weekly shop", parts: [(cast.groceries, 1_250)])
    let editor = model(for: saved, cast)
    for (language, word) in [(AppLanguage.Choice.english, "recorded"), (.russian, "записано")] {
      environment.language.choice = language
      let line = TransactionEditorModel.recordedLine(
        title: editor.title, occurredAt: saved.transaction.occurredAt, environment: environment)
      XCTAssertTrue(line.hasPrefix("Weekly shop · "), line)
      XCTAssertTrue(line.contains(word), line)
    }
  }

  /// The last field scrolls clear of the foot: the scrolling fields end with room under them.
  func testTheFieldsScrollClearOfTheFoot() {
    XCTAssertGreaterThanOrEqual(TransactionEditor.scrollEndInset, 16)
  }

  // MARK: The block of parts

  /// An operation of three parts with 300 left over: the remainder is said in a plaque with its
  /// reason, the largest part is offered the remainder, and giving it leaves the parts adding up.
  func testTheRemainderIsGivenToTheLargestPart() throws {
    let cast = try seed()
    let saved = try entry(
      cast, note: "Shop and a gift",
      parts: [(cast.groceries, 1_800), (cast.cafe, 900), (cast.gifts, 700)])
    let draft = model(for: saved, cast).draft
    XCTAssertNil(draft.remainderTargetIndex, "nothing is left, nothing is offered")
    draft.draft.parts[2].amount = AmountE4(whole: 400)
    XCTAssertEqual(draft.draft.unallocated, AmountE4(whole: 300))
    XCTAssertEqual(draft.saveRefusalKey, "entry.error.notBalanced")
    XCTAssertEqual(draft.remainderTargetIndex, 0)
    draft.giveRemainderAway()
    XCTAssertEqual(draft.draft.parts[0].amount, AmountE4(whole: 2_100))
    XCTAssertTrue(draft.draft.unallocated.isZero)
    XCTAssertNotEqual(draft.saveRefusalKey, "entry.error.notBalanced")
  }

  /// Parts that exceed the total offer nothing to give away, and equal parts give to the first.
  func testNothingIsGivenWhenThePartsExceedTheTotalAndTiesGoToTheFirst() throws {
    let cast = try seed()
    let saved = try entry(
      cast, note: "Two halves", parts: [(cast.groceries, 1_000), (cast.cafe, 1_000)])
    let draft = model(for: saved, cast).draft
    draft.draft.parts[1].amount = AmountE4(whole: 1_300)
    XCTAssertEqual(draft.draft.unallocated, AmountE4(whole: -300))
    XCTAssertNil(draft.remainderTargetIndex)
    draft.giveRemainderAway()
    XCTAssertEqual(draft.draft.parts[1].amount, AmountE4(whole: 1_300), "nothing was given")
    draft.draft.parts[1].amount = AmountE4(whole: 1_000)
    draft.draft.amount = AmountE4(whole: 2_500)
    XCTAssertEqual(draft.remainderTargetIndex, 0)
  }

  /// The block of parts has its title with «+ Часть», the plaque of the remainder with the button
  /// that gives it away, and stays inside the sheet and the inspector in both languages.
  func testTheBlockOfPartsStaysInsideAndSaysTheRemainder() throws {
    let cast = try seed()
    let saved = try entry(
      cast, note: "Shop and a gift",
      parts: [(cast.groceries, 1_800), (cast.cafe, 900), (cast.gifts, 700)])
    for language in languages {
      environment.language.choice = language
      for (style, width) in [(TransactionEditor.Style.sheet, 1_440.0), (.inspector, 360.0)] {
        let editor = model(for: saved, cast)
        editor.draft.draft.parts[2].amount = AmountE4(whole: 400)
        let window = tallWindow(editor, style: style, width: width)
        let place = "\(language.rawValue) \(style)"
        let block = try frame("entry.split.block", window)
        XCTAssertGreaterThanOrEqual(block.minX, window.frame.minX, place)
        XCTAssertLessThanOrEqual(block.maxX, window.frame.maxX, place)
        // Parts are read by their words: an identifier on a container reaches its children.
        let root = try XCTUnwrap(window.contentView)
        func found(_ matches: @escaping (String) -> Bool) -> [CGRect] {
          var elements: [AnyObject] = []
          Self.elements(in: root, into: &elements) { matches($0.accessibilityLabel?() ?? "") }
          return elements.compactMap { $0.accessibilityFrame?() }.filter { $0.width > 0 }
        }
        let add = found { $0 == (language == .russian ? "+ Часть" : "+ Part") }
        XCTAssertFalse(add.isEmpty, "«+ Part»: \(place)")
        let give = found {
          $0.hasPrefix(language == .russian ? "Отдать остаток" : "Give the remainder")
        }
        XCTAssertFalse(give.isEmpty, "the button that gives the remainder away: \(place)")
        for frame in add + give {
          XCTAssertGreaterThanOrEqual(frame.minX, window.frame.minX, place)
          XCTAssertLessThanOrEqual(frame.maxX, window.frame.maxX, "past the edge: \(place)")
        }
        window.contentView = nil
      }
    }
  }

  /// «Вернёт ли человек деньги?» is a block of its own with its answer, in the sheet and in the
  /// inspector, inside the column.
  func testThePaysBackQuestionIsABlockOfItsOwn() throws {
    let cast = try seed()
    let saved = try entry(cast, note: "Gift", parts: [(cast.gifts, 1_000)])
    let references = try XCTUnwrap(environment.references)
    let person = Person(name: "Alex", relation: .friend)
    try references.save(person)
    for language in languages {
      environment.language.choice = language
      for (style, width) in [(TransactionEditor.Style.sheet, 1_440.0), (.inspector, 360.0)] {
        let editor = model(for: saved, cast)
        editor.draft.reload()
        editor.draft.choosePayingFor(.somebody(person.id, paysBack: true))
        let window = tallWindow(editor, style: style, width: width)
        let place = "\(language.rawValue) \(style)"
        let block = try frame("entry.payingFor.paysBackBlock", window)
        XCTAssertLessThanOrEqual(block.maxX, window.frame.maxX, place)
        window.contentView = nil
      }
    }
  }

  // MARK: Smaller things

  /// A converted sum «≈ …» stands on a line of its own under the amount, in one line, also in the
  /// inspector.
  func testTheConvertedSumStandsUnderTheAmount() throws {
    let cast = try seed()
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(), calendar: .system, today: environment.today,
        context: SnapshotContext(rubPerUnit: [.usd: 95]), version: DataVersion(load: 0)))
    var draft = TransactionDraft(
      occurredAt: environment.now(), currency: .usd, amount: AmountE4(whole: 120), rate: 95,
      rateDate: nil, rateSource: .manual, note: "Online order", paymentMethodId: cast.card.id)
    draft.parts = [PartDraft(categoryId: cast.groceries.id, amount: AmountE4(whole: 120))]
    let saved = try draft.materialize(rublesConverter: { try AmountE4(decimal: $0.decimal * 95) })
    for language in languages {
      environment.language.choice = language
      let window = tallWindow(model(for: saved, cast), style: .inspector, width: 360)
      let hint = try frame("entry.approximate", window)
      let amount = try frame("entry.totalAmount", window)
      XCTAssertLessThanOrEqual(hint.maxY, amount.minY, "below the amount: \(language.rawValue)")
      XCTAssertLessThan(hint.height, 24, "one line: \(language.rawValue)")
      window.contentView = nil
    }
  }

  /// The chosen kind lifts off the track in the dark themes, where card and track are one colour.
  func testTheChosenKindLiftsOffTheTrackInTheDarkThemes() {
    let card = Color.white
    XCTAssertEqual(EntryKindTabs.chipFill(card: card, scheme: .light), card)
    XCTAssertNotEqual(EntryKindTabs.chipFill(card: card, scheme: .dark), card)
  }

  /// «Split…» stands beside «Записать» in the foot of the ↓ panel of an operation not split yet,
  /// and the foot of the editor offers nothing once the block of parts has «+ Часть».
  func testSplitStandsBesideSaveInTheFootOfThePanel() throws {
    let cast = try seed()
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.draft.amount = AmountE4(whole: 1_000)
    model.draft.paymentMethodId = cast.card.id
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 760, height: 1_800), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    windows.append(window)
    window.contentView = NSHostingView(
      rootView: DetailsPanel(model: model, submit: {}, offersTransfer: true, showsSave: true)
        .padding(16).frame(width: 760, height: 1_800, alignment: .top).appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
    settle(window, passes: 40)
    let split = try frame("entry.split", window)
    let save = try frame("entry.panel.save", window)
    XCTAssertLessThan(split.maxX, save.minX)
    XCTAssertEqual(split.midY, save.midY, accuracy: 12, "on the row of «Записать»")
    window.contentView = nil
  }
}
