import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The guide as the owner meets it: the Help menu and what each of its items does, the cards
/// turned by Return, the arrows and Esc, the places «Показать, куда нажимать» names, and each
/// task of the tutorial found done by the action it asks for — on a store of the test's own,
/// in the tutorial, so the views' reports can be watched.
@MainActor
final class GuideFlowTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private var appGuide: GuideStore!
  private var guide: GuideStore!
  private var windows: [NSWindow] = []
  private var directory: URL?
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    suite = "ohmymoney.tests.guideFlow.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
    appGuide = GuideStore.shared
    guide = GuideStore(defaults: defaults, tutorial: true)
    GuideStore.shared = guide
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
  }

  override func tearDown() async throws {
    for window in windows {
      if let sheet = window.attachedSheet { window.endSheet(sheet) }
      window.contentViewController = nil
      window.contentView = nil
      window.close()
    }
    windows = []
    GuideStore.shared = appGuide
    RelaunchCarry.next = nil
    UserDefaults().removePersistentDomain(forName: suite)
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: Helpers

  /// A key of a table in Russian and in English, as the bundle has them.
  static func texts(_ key: String, table: String) -> [String] {
    ["ru", "en"].compactMap { code in
      Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))?
        .localizedString(forKey: key, value: nil, table: table)
    }
  }

  static func russian(_ key: String, table: String) -> String {
    texts(key, table: table).first ?? key
  }

  /// Every item of the menu bar, submenus included.
  private func items(_ menu: NSMenu? = NSApp.mainMenu) -> [NSMenuItem] {
    (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
  }

  private func item(_ key: String) -> NSMenuItem? {
    let titles = Self.texts(key, table: "Guide")
    return items().first { titles.contains($0.title) }
  }

  private func press(_ item: NSMenuItem) {
    guard let menu = item.menu else { return XCTFail("«\(item.title)» is in no menu") }
    menu.update()
    menu.performActionForItem(at: menu.index(of: item))
    settle()
  }

  private func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func show<V: View>(_ view: V, width: CGFloat = 900, height: CGFloat = 640) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: every caller hands them to its view with `.appDependencies`
    window.contentView = NSHostingView(rootView: view)
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    settle()
    return window
  }

  private func plainDependencies() -> AppDependencies {
    AppDependencies(
      environment: AppEnvironment(), store: TransactionsStore(),
      compute: ComputeStore(calendar: .utc))
  }

  /// An environment started on an empty database in a folder of its own.
  private func startedDependencies() async throws -> AppDependencies {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-guide-flow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    self.directory = directory
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: try XCTUnwrap(environment.references),
      planning: try XCTUnwrap(environment.planning))
    // The blocks show what they hold once there is data: an empty book, counted.
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(), calendar: .system, today: environment.today,
        context: SnapshotContext(), version: DataVersion(load: 0)))
    return AppDependencies(environment: environment, store: store, compute: compute)
  }

  /// The ids of the places a view marks for the guide (`guideTarget`), as the root of a window
  /// would read them.
  private final class Marks { var ids: Set<String> = [] }

  private struct Recorder: View {
    let ids: [String]
    let marks: Marks
    var body: some View {
      marks.ids.formUnion(ids)
      return Color.clear
    }
  }

  private func marks<V: View>(of view: V, width: CGFloat = 900) -> Set<String> {
    let marks = Marks()
    _ = show(
      view.overlayPreferenceValue(GuideTargetKey.self) { anchors in
        Recorder(ids: Array(anchors.keys), marks: marks)
      }, width: width)
    settle(0.5)
    return marks.ids
  }

  private static func key(_ characters: String, code: UInt16) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: code)!
  }

  // MARK: The Help menu

  /// «Справка»: «Знакомство с OhMyMoney», «Что нового», «Показать, куда нажимать», the tutorial's
  /// way in — or, inside it, out and «Начать учебный режим заново» — and the report.
  func testTheHelpMenuOffersTheGuide() {
    for key in ["guide.menu.tour", "guide.menu.whatsNew", "guide.menu.whereToClick"] {
      XCTAssertNotNil(item(key), "the Help menu has no «\(Self.russian(key, table: "Guide"))»")
    }
    XCTAssertTrue(
      item("guide.menu.tutorial") != nil
        || (item("guide.tutorial.exit") != nil && item("guide.menu.restart") != nil),
      "the Help menu has no way into the tutorial, nor out of it")
    XCTAssertEqual(Self.russian("guide.menu.tour", table: "Guide"), "Знакомство с OhMyMoney")
    XCTAssertEqual(Self.russian("guide.menu.whatsNew", table: "Guide"), "Что нового")
    XCTAssertEqual(
      Self.russian("guide.menu.whereToClick", table: "Guide"), "Показать, куда нажимать")
    XCTAssertEqual(Self.russian("guide.menu.tutorial", table: "Guide"), "Учебный режим")
    XCTAssertEqual(
      Self.russian("guide.menu.restart", table: "Guide"), "Начать учебный режим заново")
  }

  /// Each item does what it says: the cards of the first launch, of the latest «Что нового», the
  /// labels of «Показать, куда нажимать».
  func testTheItemsOfTheHelpMenuShowTheGuide() throws {
    press(try XCTUnwrap(item("guide.menu.tour")))
    XCTAssertEqual(guide.cards?.id, "firstLaunch")
    guide.cards = nil

    press(try XCTUnwrap(item("guide.menu.whatsNew")))
    XCTAssertEqual(guide.cards?.id, GuideCatalog.whatsNew.last?.id)
    guide.cards = nil

    press(try XCTUnwrap(item("guide.menu.whereToClick")))
    XCTAssertTrue(guide.showsWhereToClick)
    guide.showsWhereToClick = false
  }

  /// «Учебный режим» relaunches into the tutorial's set; inside it «Выйти» relaunches on the own
  /// data and «Начать заново» forgets the tasks and relaunches into the set again.
  func testTheTutorialItemsRelaunch() throws {
    let asked = AppRestart.askedInTestHost
    if let enter = item("guide.menu.tutorial") {
      press(enter)
      XCTAssertEqual(RelaunchCarry.next, ["--data-set", "learn"])
      XCTAssertEqual(AppRestart.askedInTestHost, asked + 1)
    } else {
      press(try XCTUnwrap(item("guide.menu.restart")))
      XCTAssertEqual(RelaunchCarry.next, ["--data-set", "learn"])
      press(try XCTUnwrap(item("guide.tutorial.exit")))
      XCTAssertEqual(RelaunchCarry.next, [])
      XCTAssertEqual(AppRestart.askedInTestHost, asked + 2)
    }
    // The ways the strip and the menu call, whichever the menu shows now.
    GuideActions.enterTutorial()
    XCTAssertEqual(RelaunchCarry.next, ["--data-set", "learn"])
    GuideActions.leaveTutorial()
    XCTAssertEqual(RelaunchCarry.next, [], "out of the tutorial: the own data, no set")
  }

  // MARK: The cards

  /// «Знакомство»: seven cards, the first «Итого — учёт денег на этом Mac», the last button
  /// «Начать»; «Что нового в 1.4» names every feature of the release.
  func testTheCardsSayWhatTheHandCheckExpects() {
    let first = GuideCatalog.firstLaunch.cards
    XCTAssertEqual(first.count, 7)
    XCTAssertEqual(first.first?.title.russian, "OhMyMoney — учёт денег на этом Mac")
    XCTAssertEqual(Self.russian("guide.done", table: "Guide"), "Начать")
    XCTAssertEqual(Self.russian("guide.skip", table: "Guide"), "Пропустить")
    XCTAssertEqual(Self.russian("guide.next", table: "Guide"), "Далее")
    XCTAssertEqual(
      String(format: Self.russian("guide.whatsNew.title", table: "Guide"), "1.4"),
      "Что нового в 1.4")
    XCTAssertEqual(
      GuideCatalog.whatsNew14.cards.map(\.id),
      [
        "new14.guide", "new14.starter", "new14.spending", "new14.approx", "new14.currencyChart",
        "new14.forSomebody", "new14.transfer", "new14.expected", "new14.quickEntry",
      ])
  }

  /// Return turns to the next card and closes on the last — «Начать», not skipped; Esc is
  /// «Пропустить» at once.
  func testReturnTurnsTheCardsAndEscSkipsThem() {
    var closed: [Bool] = []
    let window = show(
      GuideCardsView(scenario: GuideCatalog.firstLaunch) { closed.append($0) }
        .appDependencies(plainDependencies()), width: 560, height: 440)
    let count = GuideCatalog.firstLaunch.cards.count
    for turn in 1..<count {
      XCTAssertTrue(window.performKeyEquivalent(with: Self.key("\r", code: 36)))
      settle(0.2)
      XCTAssertEqual(closed, [], "closed after \(turn) of \(count) cards")
    }
    XCTAssertTrue(window.performKeyEquivalent(with: Self.key("\r", code: 36)))
    settle(0.2)
    XCTAssertEqual(closed, [false], "«Начать» on the last card closes them, seen through")

    var skipped: [Bool] = []
    let other = show(
      GuideCardsView(scenario: GuideCatalog.whatsNew14) { skipped.append($0) }
        .appDependencies(plainDependencies()), width: 560, height: 440)
    XCTAssertTrue(other.performKeyEquivalent(with: Self.key("\u{1b}", code: 53)))
    settle(0.2)
    XCTAssertEqual(skipped, [true], "Esc is «Пропустить»")
  }

  /// → and ← turn the cards: → to the last, ← one back, and it takes two Returns to finish.
  func testTheArrowsTurnTheCards() {
    var closed: [Bool] = []
    let window = show(
      GuideCardsView(scenario: GuideCatalog.firstLaunch) { closed.append($0) }
        .appDependencies(plainDependencies()), width: 560, height: 440)
    settle(0.3)
    func send(_ scalar: Int, code: UInt16) {
      let characters = String(UnicodeScalar(scalar)!)
      window.sendEvent(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
      settle(0.15)
    }
    for _ in 0..<10 { send(NSRightArrowFunctionKey, code: 124) }
    send(NSLeftArrowFunctionKey, code: 123)
    XCTAssertTrue(window.performKeyEquivalent(with: Self.key("\r", code: 36)))
    settle(0.2)
    XCTAssertEqual(closed, [], "← went one back from the last card, Return turned to it")
    XCTAssertTrue(window.performKeyEquivalent(with: Self.key("\r", code: 36)))
    settle(0.2)
    XCTAssertEqual(closed, [false])
  }

  // MARK: «Показать, куда нажимать»

  /// The places «Показать, куда нажимать» walks through, one at a time, with their keys:
  /// «Запись операции ⌘N», «Все поля Tab», the six sections of the sidebar «Обзор ⌘1» to
  /// «Капитал ⌘6», and the three buttons of the toolbar — named in words, since a toolbar item
  /// lends the window no place to cut out.
  func testWhereToClickNamesEveryPlaceWithItsKeys() {
    XCTAssertEqual(
      GuideCatalog.whereToClick.map { step in
        [step.text.russian, step.keys].compactMap { $0 }.joined(separator: " ")
      },
      [
        "Запись операции ⌘N", "Все поля Tab", "Обзор ⌘1", "Планирование ⌘2", "Долги ⌘3",
        "Операции ⌘4", "Календарь ⌘5", "Капитал ⌘6", "Таблица операций — на панели вверху ⌘⇧T",
        "Сверка остатка — на панели вверху", "Настройки — на панели вверху ⌘,",
      ])
    guide.showsWhereToClick = true
    XCTAssertEqual(guide.walk?.current.target, GuideTarget.entryLine)
    guide.showsWhereToClick = false
    XCTAssertNil(guide.walk)
  }

  /// Esc leaves «Показать, куда нажимать».
  func testEscClosesTheLabels() {
    guide.showsWhereToClick = true
    let window = show(
      Color.clear.frame(width: 300, height: 200).modifier(GuideWhereToClickKeys(guide: guide)),
      width: 300, height: 200)
    XCTAssertTrue(window.performKeyEquivalent(with: Self.key("\u{1b}", code: 53)))
    settle(0.2)
    XCTAssertFalse(guide.showsWhereToClick, "Esc left the walk on")
  }

  /// Every place «Показать, куда нажимать» cuts out is marked by the view it lives in: the line
  /// and its toggle by the entry bar, the sections by the sidebar.
  func testEveryLabelOfTheWindowHasItsPlace() async throws {
    let deps = try await startedDependencies()
    var marked = marks(
      of: MainSidebar(selection: .constant(.section(.overview))).appDependencies(deps))
    marked.formUnion(
      marks(
        of: EntryBar(windowWidth: 900, detailWidth: 900, style: .line, opensDetails: true) {
          EmptyView()
        }
        .appDependencies(deps)))
    for step in GuideCatalog.whereToClick
    where !GuideTarget.outsideTheContent.contains(step.target) {
      XCTAssertTrue(marked.contains(step.target), "nothing marks «\(step.target)»: \(marked)")
    }
  }

  /// Every step of every task that points into the main window has its place: the line, its
  /// toggle and «За кого» of the panel, the sections of the sidebar, the table and the search of
  /// «Операции», the blocks of Planning, «+ Долг» of Debts.
  func testThePlacesOfTheTasksAreMarked() async throws {
    let deps = try await startedDependencies()
    var marked = marks(
      of: MainSidebar(selection: .constant(.section(.overview))).appDependencies(deps))
    marked.formUnion(
      marks(
        of: EntryBar(windowWidth: 900, detailWidth: 900, style: .line, opensDetails: true) {
          EmptyView()
        }
        .appDependencies(deps)))
    marked.formUnion(
      marks(
        of: OperationsScreen(
          deps: deps, actions: OperationActions(), state: OperationsScreenState()
        ).appDependencies(deps)))
    marked.formUnion(marks(of: PlanningView().appDependencies(deps), width: 980))
    marked.formUnion(marks(of: DebtsView().appDependencies(deps), width: 980))
    // A toolbar item and the settings window have no place in the window to cut out: those
    // steps say where to press in words, in the middle of the window, and leave it open to
    // clicks.
    let elsewhere = GuideTarget.outsideTheContent
    for task in GuideCatalog.tutorial.tasks {
      for step in task.hints where !elsewhere.contains(step.target) {
        XCTAssertTrue(
          marked.contains(step.target), "«\(task.id)» points at «\(step.target)», unmarked")
      }
    }
  }

  // MARK: The tutorial

  /// The strip: «Учебный режим», «0 из 10», «Задания», «Выйти из учебного режима», and the title
  /// of the window says «УЧЕБНЫЙ».
  func testTheStripSaysWhereTheTutorialIs() {
    XCTAssertTrue(guide.isTutorial)
    XCTAssertEqual(guide.tutorial.tasks.count, 10)
    XCTAssertEqual(guide.tutorial.done, 0)
    XCTAssertEqual(
      String(format: Self.russian("guide.tutorial.progress", table: "Guide"), 0, 10), "0 из 10")
    XCTAssertEqual(Self.russian("guide.tutorial.title", table: "Guide"), "Учебный режим")
    XCTAssertEqual(Self.russian("guide.tutorial.tasks", table: "Guide"), "Задания")
    XCTAssertEqual(
      Self.russian("guide.tutorial.exit", table: "Guide"), "Выйти из учебного режима")
    XCTAssertEqual(Self.russian("guide.tutorial.badge", table: "Guide"), "УЧЕБНЫЙ")
    XCTAssertFalse(GuideStore(defaults: defaults, tutorial: false).isTutorial)
  }

  /// «Задания»: ten, from «Запишите «кофе 300»» to «Посмотрите график валюты»; the first points
  /// at the entry line.
  func testTheTasksAreListedFromCoffeeToTheCurrencyChart() {
    let tasks = guide.tutorial.tasks
    XCTAssertEqual(tasks.first?.title.russian, "Запишите «кофе 300»")
    XCTAssertEqual(tasks[1].title.russian, "Поменяйте категорию операции")
    XCTAssertEqual(tasks.last?.title.russian, "Посмотрите график валюты")
    XCTAssertEqual(tasks.first?.hints.first?.target, "entry.line")
  }

  /// «кофе 300» written: «1 из 10», the task ticked; «Траты» opened: «2 из 10». A framed task
  /// that is done is no longer framed.
  func testCoffeeAndSpendingAreTickedOffOneByOne() throws {
    let (dataset, start) = learnSet()
    guide.check(dataset)
    XCTAssertEqual(guide.tutorial.done, 0, "the set alone does nothing: \(start)")
    guide.framedTask = "task.coffee"

    // Written after the tutorial began: the first check above took that moment.
    var after = dataset
    after.entries.append(try coffee(in: dataset, at: Date().addingTimeInterval(1)))
    guide.check(after)
    XCTAssertEqual(guide.tutorial.done, 1)
    XCTAssertTrue(guide.isDone(try task("task.coffee")))
    XCTAssertNil(guide.framedTask, "a task done is framed no more")

    guide.report(GuideEvent.operationsOpened)
    guide.check(after)
    XCTAssertEqual(guide.tutorial.done, 2)
    XCTAssertTrue(guide.isDone(try task("task.spending")))
    // Kept on this Mac: the next launch finds the same.
    XCTAssertEqual(GuideStore(defaults: defaults, tutorial: true).tutorial.done, 2)
  }

  /// «Начать учебный режим заново»: the tasks forgotten, the next launch makes the set anew —
  /// asked once —, and what was written in the set is gone with it.
  func testStartingOverForgetsTheTasksAndMakesTheSetAnew() throws {
    guide.report(GuideEvent.operationsOpened)
    guide.check(Dataset())
    XCTAssertEqual(guide.tutorial.done, 1)
    guide.restartTutorial()
    XCTAssertEqual(guide.tutorial.done, 0)
    XCTAssertTrue(guide.takeRestart(), "the next launch makes the set anew")
    XCTAssertFalse(guide.takeRestart(), "once")

    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-guide-restart-\(UUID().uuidString)", isDirectory: true)
    directory = scratch
    let learn = scratch.appendingPathComponent("Sets/learn", isDirectory: true)
    let today = DateOnly(year: 2026, month: 10, day: 7)
    func make() throws -> DatabaseStack {
      try DataSetGeneration.prepare(
        directory: learn, generation: .months(DataSetGeneration.learnMonths), today: today,
        calendar: .utc, language: "ru", schema: BundleSchemaSource(bundle: .main))
    }
    var stack = try make()
    var draft = TransactionDraft(amount: AmountE4(whole: 300), note: "кофе 300 из учебного")
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())
    try stack.close()

    stack = try make()
    let notes = try TransactionRepository(writer: stack.writer)
      .entries(from: .distantPast, to: .distantFuture).compactMap(\.transaction.note)
    try stack.close()
    XCTAssertFalse(notes.contains("кофе 300 из учебного"), "the set was not made anew")
  }

  // MARK: Each task by its action

  /// The tutorial's set as it is made, and the moment the tutorial began.
  private func learnSet() -> (Dataset, Date) {
    let set = DataSetGeneration.generate(
      .months(2), today: DateOnly(year: 2026, month: 10, day: 7), calendar: .utc, language: "ru")
    let dataset = Dataset(
      entries: set.entries, categories: set.categories, planning: set.planningBook,
      transfers: set.transfers)
    let start = (dataset.entries.map(\.transaction.createdAt).max() ?? Date())
      .addingTimeInterval(1)
    return (dataset, start)
  }

  private func task(_ id: String) throws -> GuideTask {
    try XCTUnwrap(GuideCatalog.tutorial.tasks.first { $0.id == id })
  }

  private func coffee(in dataset: Dataset, at moment: Date) throws -> TransactionEntry {
    var entry = try XCTUnwrap(dataset.entries.first { $0.transaction.kind == .expense })
    entry.transaction.id = UUID()
    entry.transaction.note = "кофе"
    entry.transaction.amountE4 = AmountE4(whole: 300)
    entry.transaction.currency = .rub
    entry.transaction.externalId = nil
    entry.transaction.deletedAt = nil
    entry.transaction.createdAt = moment
    entry.transaction.updatedAt = moment
    let id = entry.transaction.id
    entry.parts = entry.parts.prefix(1).map { part in
      var part = part
      part.transactionId = id
      part.reimbursable = false
      part.forPersonId = nil
      return part
    }
    entry.transaction.debtId = nil
    return entry
  }

  /// What the facts of a set say about one task, after `change` was made to it.
  private func isDone(
    _ id: String, after change: (inout Dataset, Date) throws -> Void
  ) throws -> Bool {
    let (dataset, start) = learnSet()
    let baseline = GuideBaseline(of: dataset, at: start)
    XCTAssertFalse(
      try task(id).done.isMet(by: GuideFactsReader.facts(of: dataset, since: baseline)),
      "«\(id)» was done before anything")
    var after = dataset
    try change(&after, start.addingTimeInterval(5))
    return try task(id).done.isMet(by: GuideFactsReader.facts(of: after, since: baseline))
  }

  /// «Поменяйте категорию операции»: an operation of the set whose category was chosen by hand
  /// after the tutorial began.
  func testChangingACategoryIsTheCategoryTask() throws {
    XCTAssertTrue(
      try isDone("task.category") { dataset, moment in
        let index = try XCTUnwrap(dataset.entries.firstIndex { $0.transaction.kind == .expense })
        dataset.entries[index].transaction.updatedAt = moment
        dataset.entries[index].parts[0].categorySource = .manual
      })
  }

  func testAPaymentAddedIsTheSubscriptionTask() throws {
    XCTAssertTrue(
      try isDone("task.subscription") { dataset, _ in
        dataset.planning.scheduled.append(
          ScheduledPayment(
            name: "Музыка", amountE4: AmountE4(whole: 299),
            nextDate: DateOnly(year: 2026, month: 10, day: 20)))
      })
  }

  func testACountMadeIsTheCountTask() throws {
    XCTAssertTrue(
      try isDone("task.count") { dataset, moment in
        dataset.planning.reconciliations.append(
          Reconciliation(
            date: DateOnly(year: 2026, month: 10, day: 7), reconciledAt: moment,
            actualTotalRubE4: .zero, kind: .accounts))
      })
  }

  func testATransferAddedIsTheTransferTask() throws {
    XCTAssertTrue(
      try isDone("task.transfer") { dataset, moment in
        let accounts =
          dataset.paymentMethods.isEmpty
          ? [PaymentMethod(name: "А"), PaymentMethod(name: "Б")] : dataset.paymentMethods
        dataset.transfers.append(
          Transfer(
            occurredAt: moment, fromAccountId: accounts[0].id, fromCurrency: .rub,
            fromAmountE4: AmountE4(whole: 1000), toAccountId: accounts[1].id, toCurrency: .rub,
            toAmountE4: AmountE4(whole: 1000), createdAt: moment, updatedAt: moment))
      })
    var facts = GuideFacts()
    facts.events.insert(GuideEvent.transferFromLine)
    XCTAssertTrue(try task("task.transfer").done.isMet(by: facts), "or the line reported it")
  }

  /// «Заплатите за другого»: a part for somebody who pays back, or a gift for a person.
  func testAnOperationForSomebodyIsThatTask() throws {
    for paysBack in [true, false] {
      XCTAssertTrue(
        try isDone("task.forSomebody") { dataset, moment in
          var entry = try self.coffee(in: dataset, at: moment)
          entry.parts[0].forPersonId = UUID()
          entry.parts[0].reimbursable = paysBack
          if paysBack { entry.parts[0].debtorPersonId = entry.parts[0].forPersonId }
          dataset.entries.append(entry)
        }, "paysBack: \(paysBack)")
    }
  }

  /// «Операции» reports itself opened, and its search used; Planning, that the free sum was seen;
  /// the card of the currency chart, that it was on the screen.
  func testTheScreensReportTheirTasks() throws {
    let deps = plainDependencies()
    let spending = show(
      OperationsScreen(deps: deps, actions: OperationActions(), state: OperationsScreenState())
        .appDependencies(deps))
    XCTAssertTrue(guide.progress.events.contains(GuideEvent.operationsOpened))
    let prompt = deps.environment.language("operations.search.prompt", table: "Transactions")
    let search = try XCTUnwrap(
      textFields(in: spending.contentView).first { $0.placeholderString == prompt },
      "the search of «Операции»")
    XCTAssertTrue(spending.makeFirstResponder(search))
    let editor = try XCTUnwrap(spending.firstResponder as? NSTextView)
    editor.insertText("кофе", replacementRange: editor.selectedRange())
    settle()
    XCTAssertTrue(guide.progress.events.contains(GuideEvent.searched))

    _ = show(PlanningView().appDependencies(deps), width: 980)
    XCTAssertTrue(
      guide.progress.events.contains(GuideEvent.freeToSpendSeen),
      "Planning never says the free sum was seen: «Посмотрите, сколько свободно» is never done")

    _ = show(CurrencyChartCard().appDependencies(deps), width: 400, height: 300)
    XCTAssertTrue(guide.progress.events.contains(GuideEvent.currencyChartSeen))

    guide.check(Dataset())
    for id in ["task.spending", "task.search", "task.free", "task.currencyChart"] {
      XCTAssertTrue(guide.isDone(try task(id)), "\(id)")
    }
  }

  /// Outside the tutorial nothing is heard: the owner's own guide keeps no tasks.
  func testOutsideTheTutorialNothingIsHeard() {
    let own = GuideStore(defaults: defaults, tutorial: false)
    own.report(GuideEvent.operationsOpened)
    XCTAssertTrue(own.progress.events.isEmpty)
  }

  private func textFields(in view: NSView?) -> [NSTextField] {
    guard let view else { return [] }
    return view.subviews.flatMap { subview -> [NSTextField] in
      ((subview as? NSTextField).map { [$0] } ?? []) + textFields(in: subview)
    }
  }
}
