import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Add…» in the ↓ panel as it is on screen: the last item of every menu of a dictionary, a
/// sheet of its kind when it is chosen — the choice staying as it was — and a sheet that has
/// the app's dependencies, saves on Return without saving the operation, and closes on
/// «Cancel» having written nothing.
///
/// A menu of SwiftUI is no `NSPopUpButton`: it is found the way VoiceOver finds it, by its
/// accessibility, opened by the press VoiceOver makes, and read and answered while it tracks.
@MainActor
final class AddFromPickerSheetTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private var windows: [NSWindow] = []
  /// What the windows of a test are drawn with, and so the language every word a test looks
  /// for is read in. The choice of language lives in the app's defaults, which every test host
  /// of the app on this Mac shares: a fresh `AppLanguage()` made a moment after the window can
  /// read another language than the one on screen — a test of another process switched it in
  /// between — and «Add…» is then looked for under a title the menu does not have.
  private var environment: AppEnvironment!
  /// The set is the process's: other classes read it after this one (`DependenciesTests`).
  private var missingReadersBefore: Set<String> = []

  private let food = CoreKit.Category(kind: .expense, name: "Food")
  private lazy var bakery = CoreKit.Category(parentId: food.id, kind: .expense, name: "Bakery")
  private let market = Place(name: "Green Market")
  private let anya = Person(name: "Anya")
  private let olga = Person(name: "Olga")
  private let card = PaymentMethod(name: "Card", isDefault: true)
  private lazy var trip = Event(name: "Trip", startDate: today, endDate: today)

  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }

  override func setUp() async throws {
    missingReadersBefore = AppDependencies.missingReaders
    AppDependencies.missingReaders = []
    environment = AppEnvironment()
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(food)
    try references.save(bakery)
    try references.save(market)
    try references.save(anya)
    try references.save(olga)
    try references.save(card)
    try references.save(trip)
  }

  override func tearDown() async throws {
    for window in windows {
      if let sheet = window.attachedSheet { window.endSheet(sheet) }
      window.contentViewController = nil
      window.close()
    }
    windows = []
    environment = nil
    AppDependencies.missingReaders = missingReadersBefore
  }

  private final class Count { var value = 0 }

  private var addTitle: String { environment.language("entry.add", table: "Entry") }

  private func makeModel() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.reload()
    model.setTotal(AmountE4(whole: 300))
    model.applyDefaults(today: today)
    return model
  }

  /// A draft whose every menu shows a choice of its own, so each menu is found by what it shows.
  private func makeChosenModel() -> EntryDraftModel {
    let model = makeModel()
    model.setSubcategory(bakery.id, forPartAt: 0)
    model.draft.parts[0].forWhom = .other
    model.draft.parts[0].forPersonId = anya.id
    model.setPlace(market.id, today: today)
    model.draft.parts[0].eventId = trip.id
    model.setPaymentMethod(card.id)
    return model
  }

  /// The panel in a window of its own, as the edit sheet has it, with the dependencies of a
  /// window of the app handed to it.
  private func show(_ model: EntryDraftModel, submitted: Count = Count()) -> NSWindow {
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let window = NSWindow(
      contentViewController: NSHostingController(
        rootView: DetailsPanel(model: model, submit: { submitted.value += 1 })
          .appDependencies(deps)))
    window.setContentSize(CGSize(width: 760, height: 900))
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    settle(0.3)
    return window
  }

  private func settle(_ seconds: TimeInterval = 0.2) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func waitFor(_ condition: () -> Bool, seconds: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { settle(0.05) }
  }

  // MARK: Menus, by their accessibility

  private func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  /// Every element of `role` in the window, in the order VoiceOver reads them.
  private func elements(in window: NSWindow, role: String) -> [NSObject] {
    var found: [NSObject] = []
    func walk(_ element: Any) {
      guard let object = element as? NSObject else { return }
      if attribute(object, "accessibilityRole") as? String == role { found.append(object) }
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] { walk(child) }
    }
    if let root = window.contentView { walk(root) }
    return found
  }

  private func menus(in window: NSWindow) -> [NSObject] {
    elements(in: window, role: "AXPopUpButton")
  }

  /// What a menu shows: its chosen item.
  private func shown(_ menu: NSObject) -> String {
    attribute(menu, "accessibilityValue") as? String ?? ""
  }

  private func isEnabled(_ menu: NSObject) -> Bool {
    attribute(menu, "isAccessibilityEnabled") as? Bool ?? false
  }

  private func menu(showing value: String, in window: NSWindow) throws -> NSObject {
    try XCTUnwrap(menus(in: window).first { shown($0) == value }, "no menu shows «\(value)»")
  }

  private final class Tracked: @unchecked Sendable {
    var items: [String] = []
    var menu: NSMenu?
  }

  /// Opens a menu the way a click does and reads its items, a separator as «|»; given a title,
  /// chooses that item as a click would. The menu is closed either way.
  @discardableResult
  private func open(_ menu: NSObject, choosing title: String? = nil) -> [String] {
    let tracked = Tracked()
    let token = NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
    ) { note in
      guard let open = note.object as? NSMenu else { return }
      tracked.menu = open
      tracked.items = open.items.map { $0.isSeparatorItem ? "|" : $0.title }
      let index = title.flatMap { title in open.items.firstIndex { $0.title == title } }
      RunLoop.main.perform(inModes: [.common]) {
        MainActor.assumeIsolated {
          if let index { tracked.menu?.performActionForItem(at: index) }
          tracked.menu?.cancelTracking()
        }
      }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    _ = menu.perform(NSSelectorFromString("accessibilityPerformPress"))
    settle(0.3)
    return tracked.items
  }

  // MARK: The item

  /// Every menu that lists a dictionary — category, subcategory, «для кого», place, event,
  /// payment method — ends with «Add…» after a line; a menu of fixed values, the currency, has
  /// nothing to add to (the «for whom» menu holds the people too, so it ends with «Add…» as well).
  func testEveryMenuOfADictionaryEndsWithAdd() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let window = show(makeChosenModel())
    for value in ["Food", "Bakery", "Anya", "Green Market", "Trip", "Card"] {
      let items = open(try menu(showing: value, in: window))
      XCTAssertTrue(items.contains(value), "\(value): \(items)")
      XCTAssertEqual(items.suffix(2), ["|", addTitle], "\(value): \(items)")
    }
    for value in ["RUB"] {
      let items = open(try menu(showing: value, in: window))
      XCTAssertFalse(items.isEmpty, "\(value): the menu did not open")
      XCTAssertFalse(items.contains(addTitle), "\(value): \(items)")
    }
  }

  /// The debtor of a part paid for someone is chosen from people too, and added the same way.
  func testTheDebtorMenuEndsWithAdd() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let model = makeModel()
    model.markLastPartPaidForSomeone()
    model.draft.parts[1].debtorPersonId = olga.id
    let window = show(model)
    let items = open(try menu(showing: "Olga", in: window))
    XCTAssertEqual(items.suffix(2), ["|", addTitle], "\(items)")
  }

  /// With nothing in a dictionary its menu is still there to open: «Add…» is what there is to
  /// choose. A menu without «Add…» — the debt, the subcategory of no category — stays off.
  func testAnEmptyDictionaryStillOffersAdd() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let empty = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let model = EntryDraftModel(
      references: ReferenceRepository(writer: empty.writer),
      transactions: TransactionRepository(writer: empty.writer), calendar: .utc)
    model.reload()
    let window = show(model)

    let dashes = menus(in: window).filter { shown($0) == "—" }
    // Category, subcategory, place, event, payment method, debt (the person is in the menu of
    // «for whom», which shows a group, not a dash).
    XCTAssertEqual(dashes.count, 6)
    // Category, place, event, payment method.
    XCTAssertEqual(dashes.filter(isEnabled).count, 4)
    for menu in dashes.filter(isEnabled) {
      XCTAssertEqual(open(menu).suffix(2), ["|", addTitle])
    }
  }

  /// Choosing «Add…» opens the sheet of its kind and chooses nothing: the menu still shows what
  /// was chosen before, and the draft still holds it.
  func testChoosingAddOpensTheSheetOfItsKindAndKeepsTheChoice() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let model = makeChosenModel()
    let window = show(model)
    let before = model.draft
    for (value, kind): (String, AddFromPicker.Kind) in [
      ("Food", .category(part: 0)), ("Bakery", .subcategory(part: 0)),
      ("Anya", .person(part: 0)), ("Green Market", .place), ("Trip", .event(part: 0)),
      ("Card", .paymentMethod),
    ] {
      open(try menu(showing: value, in: window), choosing: addTitle)
      waitFor { window.attachedSheet != nil }
      XCTAssertNotNil(window.attachedSheet, "\(value): no sheet")
      XCTAssertEqual(model.adding, kind, value)
      XCTAssertEqual(model.draft, before, "\(value): «Add…» changed the draft")
      XCTAssertNoThrow(try menu(showing: value, in: window), "\(value): the menu shows «Add…»")

      model.adding = nil
      waitFor { window.attachedSheet == nil }
      XCTAssertNil(window.attachedSheet, "\(value): the sheet stayed")
    }
  }

  // MARK: The sheet

  /// The sheet is laid out by a host of its own, like every sheet: it gets the dependencies
  /// where it is presented, or its words and its «Save» read the stand-in.
  func testTheSheetGetsTheDependenciesHandedToIt() throws {
    for kind: AddFromPicker.Kind in [
      .category(part: 0), .subcategory(part: 0), .person(part: 0), .place, .event(part: 0),
      .paymentMethod,
    ] {
      let model = makeModel()
      model.setCategory(food.id, forPartAt: 0)
      model.adding = kind
      let window = show(model)
      waitFor { window.attachedSheet != nil }
      let sheet = try XCTUnwrap(window.attachedSheet, "\(kind): the sheet was not shown")
      sheet.contentView?.layoutSubtreeIfNeeded()
      settle()
      XCTAssertEqual(
        AppDependencies.missingReaders, [], "\(kind): the sheet went without the dependencies")
      model.adding = nil
      waitFor { window.attachedSheet == nil }
    }
  }

  private func editor(_ deps: AppDependencies) throws -> TransactionEditorModel {
    let draft = TransactionDraft(
      amount: AmountE4(whole: 250), note: "coffee", parts: [PartDraft(amount: AmountE4(whole: 250))]
    )
    return TransactionEditorModel(entry: try draft.materialize(), environment: deps.environment)
  }

  private func window(_ root: some View) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: the roots of these tests hand them over themselves, as the app's do
    window.contentView = NSHostingView(rootView: root)
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    settle(0.5)
    return window
  }

  /// The inspector of Transactions is a host of its own, and the sheet is presented from
  /// inside it: it still gets the dependencies the inspector was handed.
  func testTheSheetOpensFromTheInspectorOfTransactions() throws {
    let deps = AppDependencies.forTests(AppEnvironment())
    let editor = try editor(deps)
    let window = window(
      NavigationSplitView {
        Text(verbatim: "sidebar")
      } detail: {
        Text(verbatim: "detail")
          .inspector(isPresented: .constant(true)) {
            TransactionInspector(deps: deps, editor: editor) {}
          }
      })

    editor.draft.adding = .place
    waitFor { window.attachedSheet != nil }
    XCTAssertNotNil(window.attachedSheet, "no sheet over the inspector")
    settle()
    XCTAssertEqual(AppDependencies.missingReaders, [])
    editor.draft.adding = nil
    waitFor { window.attachedSheet == nil }
    XCTAssertNil(window.attachedSheet)
  }

  /// The editor of the main window is a sheet itself: the sheet of «Add…» comes over it.
  func testTheSheetOpensOverTheEditSheetOfTheMainWindow() throws {
    let deps = AppDependencies.forTests(AppEnvironment())
    let editor = try editor(deps)
    let window = window(
      Color.clear
        .sheet(isPresented: .constant(true)) {
          TransactionEditor(editor: editor, style: .sheet) {}
            .handingOver(deps)
        }
        .appDependencies(deps))
    waitFor { window.attachedSheet != nil }
    let editSheet = try XCTUnwrap(window.attachedSheet, "no edit sheet")

    editor.draft.adding = .paymentMethod
    waitFor { editSheet.attachedSheet != nil }
    XCTAssertNotNil(editSheet.attachedSheet, "no sheet over the edit sheet")
    settle()
    XCTAssertEqual(AppDependencies.missingReaders, [])
    editor.draft.adding = nil
    waitFor { editSheet.attachedSheet == nil }
    XCTAssertNil(editSheet.attachedSheet)
  }

  /// The ↓ panel of the main window floats on glass over the list, laid over the entry line:
  /// the sheet comes from there too.
  func testTheSheetOpensFromThePanelOfTheEntryLine() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("add-from-picker-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // The files of the environment go to a folder of this test, never the owner's.
    let before = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    defer {
      if let before {
        setenv("OHMYMONEY_DATA_DIR", before, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
      try? FileManager.default.removeItem(at: directory)
    }
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    try XCTUnwrap(environment.references).save(Place(name: "Green Market"))
    let deps = AppDependencies.forTests(environment)
    let window = window(
      EntryBar(windowWidth: 900, detailWidth: 900, opensDetails: true) { EmptyView() }
        .appDependencies(deps))

    let places = try XCTUnwrap(
      menus(in: window).first { open($0).contains("Green Market") }, "no menu of places")
    open(places, choosing: addTitle)
    waitFor { window.attachedSheet != nil }
    let sheet = try XCTUnwrap(window.attachedSheet, "no sheet over the panel")
    settle()
    XCTAssertEqual(AppDependencies.missingReaders, [])

    let cancel = try XCTUnwrap(
      elements(in: sheet, role: "AXButton").first {
        attribute($0, "accessibilityLabel") as? String == environment.language("action.cancel")
      }, "no «Cancel» in the sheet")
    _ = cancel.perform(NSSelectorFromString("accessibilityPerformPress"))
    waitFor { window.attachedSheet == nil }
    XCTAssertNil(window.attachedSheet, "the sheet stayed open")
  }

  private func all<View: NSView>(_ type: View.Type, in view: NSView) -> [View] {
    view.subviews.flatMap { subview -> [View] in
      ((subview as? View).map { [$0] } ?? []) + all(type, in: subview)
    }
  }

  /// The name the line could not match is in the field; Return saves the place, chooses it and
  /// closes the sheet — and does not save the operation behind it.
  func testReturnInTheSheetSavesThePlaceAndChoosesIt() throws {
    let model = makeModel()
    model.apply(
      InputLineParser(vocabulary: .empty, calendar: .utc)
        .parse("кофе 300 в Кофемании", today: today),
      amount: AmountE4(whole: 300), today: today)
    model.adding = .place
    let submitted = Count()
    let window = show(model, submitted: submitted)
    waitFor { window.attachedSheet != nil }
    let sheet = try XCTUnwrap(window.attachedSheet, "no sheet")
    settle()

    let field = try XCTUnwrap(
      all(NSTextField.self, in: try XCTUnwrap(sheet.contentView)).first {
        $0.isEditable && $0.stringValue == "Кофемании"
      }, "the name the line read is not in the field")
    XCTAssertTrue(sheet.makeFirstResponder(field))
    let editor = try XCTUnwrap(sheet.firstResponder as? NSTextView, "the field editor")
    editor.selectAll(nil)
    editor.insertText("Кофемания", replacementRange: editor.selectedRange())
    settle(0.1)
    editor.insertNewline(nil)
    waitFor { window.attachedSheet == nil }

    XCTAssertNil(window.attachedSheet, "the sheet stayed open")
    let place = try XCTUnwrap(try references.places().first { $0.name == "Кофемания" })
    XCTAssertEqual(model.draft.placeId, place.id)
    XCTAssertNil(model.adding)
    XCTAssertEqual(submitted.value, 0, "Return in the sheet saved the operation too")
  }

  /// «Cancel» closes the sheet and leaves everything as it was.
  func testCancelClosesTheSheetAndChangesNothing() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let model = makeChosenModel()
    model.adding = .place
    let draft = model.draft
    let window = show(model)
    waitFor { window.attachedSheet != nil }
    let sheet = try XCTUnwrap(window.attachedSheet, "no sheet")
    settle()

    let cancel = try XCTUnwrap(
      elements(in: sheet, role: "AXButton").first {
        attribute($0, "accessibilityLabel") as? String == environment.language("action.cancel")
      }, "no «Cancel» in the sheet")
    _ = cancel.perform(NSSelectorFromString("accessibilityPerformPress"))
    waitFor { window.attachedSheet == nil }

    XCTAssertNil(window.attachedSheet, "the sheet stayed open")
    XCTAssertNil(model.adding)
    XCTAssertEqual(model.draft, draft)
    XCTAssertEqual(try references.places().map(\.id), [market.id])
  }
}
