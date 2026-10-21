import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Предложить лимиты…» in a window: the button of the «Лимиты» block opens the sheet, and an
/// amount typed over a row stays the owner's while «Как обычно» and «На 10 % меньше» are
/// switched — the rows not typed into follow the switch, and «Добавить» writes the typed one.
@MainActor
final class LimitSuggestionsWindowTests: XCTestCase {
  private var store: TransactionsStore!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private var compute: ComputeStore!
  private var environment: AppEnvironment!
  private var windows: [NSWindow] = []

  private let food = CoreKit.Category(kind: .expense, name: "Food")
  private let taxi = CoreKit.Category(kind: .expense, name: "Taxi")

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer), references: references, planning: planning)
    compute = ComputeStore(calendar: .utc, rebuildsInline: true)
    environment = AppEnvironment()
    for category in [food, taxi] { try references.save(category) }
    show()
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
  }

  private var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  /// Food (12,300 ₽) and Taxi (2,100 ₽) in each of the three full months before today.
  private func show() {
    let today = environment.today
    var entries: [TransactionEntry] = []
    var month = today.monthKey
    for _ in 0..<3 {
      month = month.previous
      entries.append(entry(food, rubles: 12_300, on: month.firstDay))
      entries.append(entry(taxi, rubles: 2_100, on: month.firstDay))
    }
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(entries: entries, categories: [food, taxi]),
        calendar: .utc, today: today, context: SnapshotContext(),
        version: DataVersion(load: 0)))
  }

  private func entry(
    _ category: CoreKit.Category, rubles: Int64, on day: DateOnly
  )
    -> TransactionEntry
  {
    let when = CalendarContext.utc.startOfDay(day).addingTimeInterval(12 * 3600)
    let transaction = Transaction(
      kind: .expense, occurredAt: when, amountE4: AmountE4(whole: rubles), createdAt: when,
      updatedAt: when)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: transaction.id, categoryId: category.id, quality: .neutral,
          qualitySource: .manual, amountE4: AmountE4(whole: rubles), forWhom: .me)
      ])
  }

  private func window<Content: View>(_ content: Content, size: CGSize) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: content.appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    settle()
    return window
  }

  private func settle(_ seconds: TimeInterval = 0.4) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func textFields(in view: NSView?) -> [NSTextField] {
    guard let view else { return [] }
    return view.subviews.flatMap { subview -> [NSTextField] in
      ((subview as? NSTextField).map { [$0] } ?? []) + textFields(in: subview)
    }
  }

  private func views<V: NSView>(of type: V.Type, in view: NSView?) -> [V] {
    guard let view else { return [] }
    return view.subviews.flatMap { subview -> [V] in
      ((subview as? V).map { [$0] } ?? []) + views(of: type, in: subview)
    }
  }

  /// The amount fields of the sheet, in the order of its rows: Food, then Taxi.
  private func amounts(in window: NSWindow) -> [NSTextField] {
    let prompt = environment.language("limits.suggest.amount", table: "Planning")
    return textFields(in: window.contentView).filter { $0.placeholderString == prompt }
  }

  /// The whole rubles a field shows: «13,000» is 13000.
  private func rubles(_ field: NSTextField) -> String {
    field.stringValue.filter(\.isNumber)
  }

  private func choose(_ segment: Int, in window: NSWindow) throws {
    let basis = try XCTUnwrap(
      views(of: NSSegmentedControl.self, in: window.contentView).first,
      "«Как обычно» / «На 10 % меньше»")
    basis.selectedSegment = segment
    _ = basis.sendAction(basis.action, to: basis.target)
    settle()
  }

  /// The button sits in the «Лимиты» block and opens the sheet over it.
  func testTheButtonOfTheBlockOpensTheSheet() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let window = window(
      LimitsBlock(sheet: .constant(nil)).frame(width: 520, height: 360),
      size: CGSize(width: 540, height: 400))
    let button = try XCTUnwrap(
      WindowAccessibility.element(identified: "limits.suggest.open", in: window),
      "«Предложить лимиты…» is not in the block")
    XCTAssertEqual(
      WindowAccessibility.text(of: button),
      environment.language("limits.suggest.open", table: "Planning"))
    WindowAccessibility.press(button)
    let deadline = Date().addingTimeInterval(3)
    while window.attachedSheet == nil, Date() < deadline { settle(0.1) }
    let sheet = try XCTUnwrap(window.attachedSheet, "no sheet opened")
    settle()
    XCTAssertEqual(amounts(in: sheet).count, 2, "a row for Food and one for Taxi")
  }

  /// A row typed over keeps its amount through both switches; the other row follows them; the
  /// typed amount is what «Добавить» writes.
  func testATypedAmountStaysThroughTheSwitch() throws {
    let window = window(LimitSuggestionsSheet(), size: CGSize(width: 540, height: 600))
    let fields = amounts(in: window)
    XCTAssertEqual(fields.count, 2)
    let food = try XCTUnwrap(fields.first), taxi = try XCTUnwrap(fields.last)
    XCTAssertEqual(rubles(food), "13000", "usual: 12,300 rounded up to a thousand")
    XCTAssertEqual(rubles(taxi), "2500", "usual: 2,100 rounded up to five hundred")

    XCTAssertTrue(window.makeFirstResponder(food))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.selectAll(nil)
    editor.insertText("15000", replacementRange: editor.selectedRange())
    settle(0.2)

    try choose(1, in: window)
    XCTAssertEqual(rubles(food), "15000", "the typed amount stays the owner's")
    XCTAssertEqual(rubles(taxi), "2000", "the other row follows «На 10 % меньше»")
    try choose(0, in: window)
    XCTAssertEqual(rubles(food), "15000", "and stays when switched back")
    XCTAssertEqual(rubles(taxi), "2500")

    // Leaving the field hands its text to the sheet's state on the next turn of the run loop.
    _ = window.makeFirstResponder(nil)
    settle(0.2)
    let returnKey = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
      keyCode: 36)!
    XCTAssertTrue(window.performKeyEquivalent(with: returnKey), "Return reached «Добавить»")
    settle()
    let written = try planning.budgets()
    XCTAssertEqual(
      written.first { $0.categoryId == self.food.id }?.amountE4, AmountE4(whole: 15_000))
    XCTAssertEqual(
      written.first { $0.categoryId == self.taxi.id }?.amountE4, AmountE4(whole: 2_500))
  }
}
