import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The difference a count of an account records follows the books by itself: opened in the
/// editor, its amount, kind, account, currency, rate, date and debt are locked — the panel says
/// why — and its category may be changed, but never to one under «Цели» or to one of the app.
///
/// A menu of SwiftUI is no `NSPopUpButton`: the menus are found the way VoiceOver finds them,
/// by their accessibility, which a CI runner does not build.
@MainActor
final class EntryReconcileDifferenceTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let card = PaymentMethod(name: "Card", isDefault: true)
  private let dollars = PaymentMethod(name: "Dollars", currency: .usd)
  private let loan = Debt(direction: .iOwe, type: .loan, name: "Car loan")
  private let reconcile = CoreKit.Category(kind: .expense, name: "Сверка")
  private let home = CoreKit.Category(kind: .expense, name: "Дом")
  private let goals = CoreKit.Category(kind: .expense, name: "Цели", systemRole: .goals)
  private lazy var trip = CoreKit.Category(parentId: goals.id, kind: .expense, name: "Отпуск")
  private let loans = CoreKit.Category(kind: .expense, name: "Кредиты", systemRole: .loans)
  private let unknown = CoreKit.Category(kind: .expense, name: "Не помню", systemRole: .unknown)
  private var windows: [NSWindow] = []

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(card)
    try references.save(dollars)
    try references.save(loan)
    for category in [reconcile, home, goals, trip, loans, unknown] {
      try references.save(category)
    }
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
  }

  private func save(
    externalId: String?, on account: PaymentMethod? = nil, currency: CurrencyCode = .rub
  ) throws -> TransactionEntry {
    let moment = Date(timeIntervalSince1970: 1_789_000_000)
    var draft = TransactionDraft(
      occurredAt: moment, currency: currency, amount: AmountE4(whole: 300),
      rate: currency == .rub ? nil : 90,
      rateDate: currency == .rub ? nil : CalendarContext.utc.day(of: moment),
      rateSource: currency == .rub ? nil : .cbr,
      note: "difference", paymentMethodId: (account ?? card).id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = reconcile.id
    var entry = try draft.materialize()
    entry.transaction.externalId = externalId
    return try transactions.save(entry)
  }

  private func editor(of entry: TransactionEntry) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: true)
    model.reload()
    model.draft = TransactionDraft(entry: entry)
    return model
  }

  func testADifferenceOperationsMoneyIsLocked() throws {
    let difference = try save(externalId: "reconcile:\(UUID().uuidString):\(UUID().uuidString)")
    let model = editor(of: difference)
    XCTAssertTrue(model.isReconcileDifference)
    XCTAssertFalse(model.canSplit)
    XCTAssertFalse(model.canMarkPaidForSomeone)

    let ordinary = editor(of: try save(externalId: nil))
    XCTAssertFalse(ordinary.isReconcileDifference)

    let content = try XCTUnwrap(show(model).contentView)
    let amount = try XCTUnwrap(
      views(of: NSTextField.self, in: content).first { $0.placeholderString == "0" })
    XCTAssertFalse(amount.isEnabled, "the amount of a difference is not typed over")
    let note = views(of: NSTextField.self, in: content).first {
      $0.placeholderString != "0" && $0.isEditable
    }
    XCTAssertNotNil(note, "its note can still be written")
    let days = views(of: NSDatePicker.self, in: content)
    XCTAssertFalse(days.isEmpty, "the date of the panel")
    XCTAssertTrue(days.allSatisfy { !$0.isEnabled }, "the moment of a difference is the count's")
    let kinds = try XCTUnwrap(
      views(of: NSSegmentedControl.self, in: content).first, "the type row")
    XCTAssertFalse(kinds.isEnabled, "a difference stays what the count found")

    // An ordinary expense is changed as ever.
    let open = try XCTUnwrap(show(ordinary).contentView)
    XCTAssertTrue(
      try XCTUnwrap(views(of: NSTextField.self, in: open).first { $0.placeholderString == "0" })
        .isEnabled)
    XCTAssertTrue(views(of: NSDatePicker.self, in: open).allSatisfy(\.isEnabled))
    XCTAssertTrue(try XCTUnwrap(views(of: NSSegmentedControl.self, in: open).first).isEnabled)
  }

  /// A count of an account in dollars records its difference in dollars, at the rate of its day;
  /// that rate is not typed over either.
  func testTheRateOfADifferenceInAnotherCurrencyIsLocked() throws {
    let difference = try save(
      externalId: "reconcile:\(UUID().uuidString):\(UUID().uuidString)", on: dollars,
      currency: .usd)
    let content = try XCTUnwrap(show(editor(of: difference)).contentView)
    let rateTitle = environment.language("entry.rate", table: "Entry")
    let rate = try XCTUnwrap(
      views(of: NSTextField.self, in: content).first { $0.placeholderString == rateTitle },
      "the rate of the panel")
    XCTAssertFalse(rate.isEnabled, "the rate of a difference is the day's")
    let amount = try XCTUnwrap(
      views(of: NSTextField.self, in: content).first { $0.placeholderString == "0" })
    XCTAssertFalse(amount.isEnabled)
  }

  /// The panel says why, with the lock beside the words; the menus of its money — the kind, the
  /// account, the currency and the debt — are off. A debt picked for a difference would turn
  /// it into a payment of that debt, whose balance would then follow every recount.
  func testTheLockIsSaidAndCoversTheMenusOfTheMoney() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let difference = try save(externalId: "reconcile:\(UUID().uuidString):\(UUID().uuidString)")
    let window = show(editor(of: difference))
    XCTAssertFalse(
      elements(in: window) { identifier($0) == "entry.reconcileDifference.locked" }.isEmpty,
      "the panel says why")
    let menus = elements(in: window) { role($0) == "AXPopUpButton" }
    let account = try XCTUnwrap(menus.first { value($0) == card.name }, "the account menu")
    XCTAssertEqual(isEnabled(account), false, "the account of a difference is the count's")
    let currency = try XCTUnwrap(menus.first { value($0) == "RUB" }, "the currency menu")
    XCTAssertEqual(isEnabled(currency), false, "the currency of a difference is the count's")
    let debt = try XCTUnwrap(menus.first { identifier($0) == "entry.debt" }, "the debt menu")
    XCTAssertEqual(isEnabled(debt), false, "a difference pays no debt")
    let kinds = try XCTUnwrap(
      elements(in: window) { role($0) == "AXRadioGroup" }.first, "the type row")
    XCTAssertEqual(isEnabled(kinds), false)

    // The same debt is offered to an ordinary expense.
    let other = show(editor(of: try save(externalId: nil)))
    XCTAssertTrue(
      elements(in: other) { identifier($0) == "entry.reconcileDifference.locked" }.isEmpty)
    let open = try XCTUnwrap(
      elements(in: other) { role($0) == "AXPopUpButton" && identifier($0) == "entry.debt" }
        .first, "the debt menu of an ordinary expense")
    XCTAssertEqual(isEnabled(open), true)
  }

  func testItsCategoryOptionsLeaveOutGoalsAndSystemCategories() throws {
    let model = editor(
      of: try save(externalId: "reconcile:\(UUID().uuidString):\(UUID().uuidString)"))
    let offered = Set(model.categoryOptions(forPartAt: 0).map(\.id))
    XCTAssertTrue(offered.contains(reconcile.id))
    XCTAssertTrue(offered.contains(home.id))
    XCTAssertFalse(offered.contains(goals.id))
    XCTAssertFalse(offered.contains(loans.id))
    XCTAssertFalse(offered.contains(unknown.id))

    let ordinary = editor(of: try save(externalId: nil))
    XCTAssertTrue(Set(ordinary.categoryOptions(forPartAt: 0).map(\.id)).contains(goals.id))
  }

  private lazy var environment = AppEnvironment()

  /// The ↓ panel of `model` in a window of its own, drawn and settled.
  private func show(_ model: EntryDraftModel) -> NSWindow {
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: DetailsPanel(model: model).appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    return window
  }

  private func views<V: NSView>(of type: V.Type, in view: NSView) -> [V] {
    view.subviews.flatMap { subview -> [V] in
      ((subview as? V).map { [$0] } ?? []) + views(of: type, in: subview)
    }
  }

  // MARK: Accessibility

  private func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  private func role(_ element: NSObject) -> String? {
    attribute(element, "accessibilityRole") as? String
  }

  private func value(_ element: NSObject) -> String? {
    attribute(element, "accessibilityValue") as? String
  }

  private func identifier(_ element: NSObject) -> String? {
    attribute(element, "accessibilityIdentifier") as? String
  }

  private func isEnabled(_ element: NSObject) -> Bool? {
    guard element.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return nil }
    return element.value(forKey: "accessibilityEnabled") as? Bool
  }

  /// Every element of the window that `matches`, in the order VoiceOver reads them.
  private func elements(in window: NSWindow, where matches: (NSObject) -> Bool) -> [NSObject] {
    var found: [NSObject] = []
    func walk(_ element: Any) {
      guard let object = element as? NSObject else { return }
      if matches(object) { found.append(object) }
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] { walk(child) }
    }
    if let root = window.contentView { walk(root) }
    return found
  }
}
