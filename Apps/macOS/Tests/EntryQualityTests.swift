import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Плохая» chosen while an expense is being created: the quality is a menu like every
/// other field of the ↓ panel — symbol and name for every value, chosen by a click or from the
/// keyboard — and what is chosen there is what the operation is saved with.
@MainActor
final class EntryQualityTests: XCTestCase {
  private var windows: [NSWindow] = []
  private var directory: URL?

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
    unsetenv("OHMYMONEY_DATA_DIR")
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

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

  private final class Tracked: @unchecked Sendable {
    var items: [NSMenuItem] = []
    var menu: NSMenu?
  }

  /// Opens a menu the way VoiceOver presses it and reads its items; given a title, chooses that
  /// item as a click would. The menu is closed either way.
  @discardableResult
  private func open(_ menu: NSObject, choosing title: String? = nil) -> [NSMenuItem] {
    let tracked = Tracked()
    let token = NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
    ) { note in
      guard let open = note.object as? NSMenu else { return }
      tracked.menu = open
      tracked.items = open.items
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

  private func show(
    _ view: some View, with deps: AppDependencies, width: CGFloat = 760
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: view.appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    settle()
    return window
  }

  /// The quality of a new expense is a menu that shows the rating chosen and offers the three,
  /// each with its symbol and its name; the type row is the one segmented control left.
  func testTheQualityIsAMenuWithASymbolForEveryValue() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let environment = AppEnvironment()
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let model = EntryDraftModel(references: nil, transactions: nil, calendar: .utc)
    model.draft.parts[0].quality = .neutral
    model.draft.parts[0].qualitySource = .category
    let window = show(DetailsPanel(model: model), with: deps)

    let names = Quality.allCases.map { environment.language(Palette.qualityKey($0)) }
    let neutral = environment.language(Palette.qualityKey(.neutral))
    let menu = try XCTUnwrap(
      elements(in: window, role: "AXPopUpButton").first {
        attribute($0, "accessibilityValue") as? String == neutral
      }, "no menu shows the quality")
    let items = open(menu)
    XCTAssertEqual(items.map(\.title), names)
    XCTAssertTrue(items.allSatisfy { $0.image != nil }, "a symbol for every value")
    // Only the kind of the operation and «За кого» of an expense are chosen by segments; the
    // quality is not among them.
    let typeNames = TransactionKind.allCases.map { environment.language("kind.\($0.rawValue)") }
    let groups = elements(in: window, role: "AXRadioGroup")
    XCTAssertEqual(groups.count, 2, "the type row and «За кого» are the segmented controls")
    XCTAssertEqual(
      groups.filter { attribute($0, "accessibilityIdentifier") as? String == "entry.payingFor" }
        .count, 1, "one of them is «За кого»")
    let payingForNames = EntryDraftModel.PayingForWay.allCases.map {
      environment.language("entry.payingFor.\($0.rawValue)", table: "Entry")
    }
    for name in names {
      XCTAssertFalse(typeNames.contains(name))
      XCTAssertFalse(payingForNames.contains(name))
    }
  }

  /// «Bad» picked in the menu of the open panel, a line typed and Return: the operation is
  /// saved bad, the rating the owner's.
  func testAQualityChosenInThePanelIsSavedWithTheOperation() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("entry-quality-\(UUID().uuidString)", isDirectory: true)
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let transactions = try XCTUnwrap(environment.transactions)
    let references = try XCTUnwrap(environment.references)
    // History files «coffee» already: the line is determined, and saves at the first Return.
    let cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)
    try references.save(cafe)
    var earlier = TransactionDraft(amount: AmountE4(whole: 200), note: "coffee")
    earlier.normalizeSinglePart()
    earlier.parts[0].categoryId = cafe.id
    try transactions.save(try earlier.materialize())
    let store = TransactionsStore()
    store.attach(
      transactions, references: references, planning: try XCTUnwrap(environment.planning))
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    let window = show(
      EntryBar(windowWidth: 900, detailWidth: 900, opensDetails: true) { EmptyView() },
      with: deps, width: 900)

    let neutral = environment.language(Palette.qualityKey(.neutral))
    let bad = environment.language(Palette.qualityKey(.bad))
    let menu = try XCTUnwrap(
      elements(in: window, role: "AXPopUpButton").first {
        attribute($0, "accessibilityValue") as? String == neutral
      }, "no menu shows the quality")
    open(menu, choosing: bad)

    let prompt = environment.language("entry.placeholder", table: "Entry")
    let line = try XCTUnwrap(
      textFields(in: try XCTUnwrap(window.contentView)).first { $0.placeholderString == prompt })
    XCTAssertTrue(window.makeFirstResponder(line))
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.insertText("coffee 250", replacementRange: editor.selectedRange())
    settle(0.1)
    editor.insertNewline(nil)
    settle()

    let saved = try transactions.recentEntries(limit: 5).first {
      $0.transaction.amountE4 == AmountE4(whole: 250)
    }
    let part = try XCTUnwrap(saved?.parts.first, "the operation was saved")
    XCTAssertEqual(part.quality, .bad)
    XCTAssertEqual(part.qualitySource, .manual)
  }

  private func textFields(in view: NSView) -> [NSTextField] {
    view.subviews.flatMap { subview -> [NSTextField] in
      ((subview as? NSTextField).map { [$0] } ?? []) + textFields(in: subview)
    }
  }
}
