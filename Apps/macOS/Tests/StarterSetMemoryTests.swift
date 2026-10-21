import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The starter set of the sheet is the set of the tutorial: «Добавить» remembers the ways of
/// living and the answers in the guide's memory of this Mac — and does so when «Добавится» says
/// there is nothing new to add, since the owner still chose the set.
@MainActor
final class StarterSetMemoryTests: XCTestCase {
  private var store: TransactionsStore!
  private var references: ReferenceRepository!
  private var compute: ComputeStore!
  private var environment: AppEnvironment!
  private var windows: [NSWindow] = []
  private var guideBefore: GuideStore!
  private var suite = ""
  private var defaults: UserDefaults!
  private var askedBefore: Any?

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer), references: references, planning: planning)
    environment = AppEnvironment()
    compute = ComputeStore(calendar: .utc, rebuildsInline: true)
    try references.seedCategoriesIfEmpty(SampleCatalog.makeCategories(language: "ru"))
    try showTheCategories()
    suite = "ohmymoney.tests.starter-memory.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    guideBefore = GuideStore.shared
    GuideStore.shared = GuideStore(defaults: defaults, tutorial: true)
    askedBefore = UserDefaults.standard.object(forKey: StarterSetActions.askedKey)
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
    GuideStore.shared = guideBefore
    defaults?.removePersistentDomain(forName: suite)
    if let askedBefore {
      UserDefaults.standard.set(askedBefore, forKey: StarterSetActions.askedKey)
    } else {
      UserDefaults.standard.removeObject(forKey: StarterSetActions.askedKey)
    }
    StarterSetOffer.shared.isRequested = false
  }

  /// The categories of the database on screen: what the sheet compares its set against.
  private func showTheCategories() throws {
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(categories: try references.categories(includeArchived: true)),
        calendar: .utc, today: environment.today, context: SnapshotContext(),
        version: DataVersion(load: 0)))
  }

  private func openTheSheet() -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 600, height: 660), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: StarterSetSheet().appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    settle()
    return window
  }

  private func settle(_ seconds: TimeInterval = 0.4) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  /// Return, as the window hands it to the default button «Добавить».
  private func pressReturn(in window: NSWindow) -> Bool {
    let key = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
      keyCode: 36)!
    let reached = window.performKeyEquivalent(with: key)
    settle()
    return reached
  }

  /// «С детьми», «Работаю» and «Есть кредиты» chosen in the sheet, «Добавить»: the guide
  /// remembers exactly that set, and the tasks of the tutorial follow it.
  func testApplyingTheSheetRemembersTheSet() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    XCTAssertNil(GuideStore.shared.progress.profile, "no set before")
    let window = openTheSheet()
    for lifestyle in ["kids", "working"] {
      WindowAccessibility.press(
        try XCTUnwrap(
          WindowAccessibility.element(identified: "starter.lifestyle.\(lifestyle)", in: window),
          lifestyle))
      settle(0.2)
    }
    let loans = environment.language("starter.loans", table: "Onboarding")
    WindowAccessibility.press(
      try XCTUnwrap(
        WindowAccessibility.elements(in: window).first {
          WindowAccessibility.text(of: $0) == loans
        }, "«Есть кредиты»"))
    settle(0.2)
    WindowAccessibility.press(
      try XCTUnwrap(WindowAccessibility.element(identified: "starter.apply", in: window)))
    settle()

    let profile = try XCTUnwrap(GuideStore.shared.progress.profile, "the set was not remembered")
    XCTAssertEqual(
      profile.lifestyles, Set(["kids", "working"].compactMap(GuideLifestyle.init(rawValue:))))
    XCTAssertTrue(profile.hasLoans)
    XCTAssertFalse(profile.hasSubscriptions)
    let tasks = GuideStore.shared.tutorial.tasks.map(\.id)
    XCTAssertTrue(tasks.contains("task.kids"), "\(tasks)")
    XCTAssertTrue(tasks.contains("task.loan"), "\(tasks)")
    XCTAssertFalse(StarterSetOffer.shared.isRequested, "the sheet closed")
  }

  /// Everything of the set is already there: «Ничего — всё уже есть.», and «Добавить» still
  /// remembers the set the owner chose — it writes nothing and leaves no step of ⌘Z.
  func testNothingNewToAddStillRemembersTheSet() throws {
    let empty = StarterChoice()
    let first = StarterSetActions.additions(
      for: empty, dataset: compute.snapshot?.dataset, environment: environment)
    XCTAssertTrue(StarterSetActions.apply(first, store: store, environment: environment))
    try showTheCategories()
    XCTAssertTrue(
      StarterSetActions.additions(
        for: empty, dataset: compute.snapshot?.dataset, environment: environment
      ).isEmpty, "nothing left to add")
    store.forgetUndoHistory()
    let count = try references.categories(includeArchived: true).count

    // A set remembered before, so the empty one chosen now is seen to replace it.
    GuideStore.shared.remember(StarterChoice(lifestyles: [.kids], hasLoans: true))
    let window = openTheSheet()
    XCTAssertTrue(pressReturn(in: window), "Return reached no «Добавить»")

    XCTAssertEqual(
      GuideStore.shared.progress.profile, GuideProfile(),
      "the set chosen in the sheet was not remembered")
    XCTAssertEqual(try references.categories(includeArchived: true).count, count)
    XCTAssertFalse(store.canUndo, "nothing written, no step of ⌘Z")
    XCTAssertFalse(StarterSetOffer.shared.isRequested, "the sheet closed")
  }
}
