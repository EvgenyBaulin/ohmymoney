import AppCore
import SwiftUI

@main
struct OhMyMoneyApp: App {
  /// Quitting puts the database down in order before the process goes.
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  @State private var environment = AppEnvironment()
  @State private var store = TransactionsStore()
  @State private var compute = ComputeStore(calendar: .system)

  init() {
    // A word of the command line that AppKit cannot pair with a `-key` is not a document to
    // open. Opened as one, it makes the launch windowless — and the database is opened from
    // a window, so nothing would start (`--measure --data-set bench`, LaunchOptions).
    UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    // Every window is a window of its own: no tabs, and no tab items in the menus, which AppKit
    // adds only while automatic tabbing is allowed when the menus are made (`AppWindows`).
    AppWindows.disallowTabs()
    // Before any window is made: the frames the secondary windows kept from their early
    // placeholders go once, so their present sizes apply (`WindowFrames`).
    if !AppEnvironment.isTestHost { WindowFrames.resetOnce(in: .standard) }
    // The tips on the spot, with the switch of Settings → General.
    GuideTips.configure()
  }

  /// What every window gets, made from the three objects the app owns.
  private var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  var body: some Scene {
    WindowGroup(id: "main") {
      AppScenes.root(deps, window: .main) { MainWindow(deps: $0) }
        .measuresWindowWidth()
        .privacyCurtain(environment)
        .onOpenURL { url in
          // A double click on an archive in Finder lands here.
          guard url.pathExtension == ArchiveService.fileExtension else { return }
          ArchiveImportFlow.begin(with: url, environment: environment)
        }
    }
    .defaultSize(width: 1120, height: 760)
    .commands {
      AppCommands(environment: environment, store: store, compute: compute)
      FileCommands(environment: environment, store: store)
      HelpCommands(environment: environment)
      AboutCommands(environment: environment)
      #if DEBUG
        DebugCommands(environment: environment, compute: compute)
      #endif
    }

    Window(environment.language("window.analytics"), id: "analytics") {
      AppScenes.root(deps, window: .analytics) { deps in
        SecondaryWindow(
          titleKey: "window.analytics", scene: "analytics", minWidth: AnalyticsWindow.minimumWidth
        ) {
          AnalyticsWindow(deps: deps)
        }
      }
      .privacyCurtain(environment)
    }
    .defaultSize(width: 1100, height: 760)
    // The item of the Window menu is `AppCommands`' own: a `Window` scene given
    // `.keyboardShortcut` listed itself there without the key (MenuTests).
    .commandsRemoved()

    Window(environment.language("window.reports"), id: "reports") {
      AppScenes.root(deps, window: .reports) { deps in
        SecondaryWindow(
          titleKey: "window.reports", scene: "reports", minWidth: ReportsWindow.minimumWidth
        ) {
          ReportsWindow(deps: deps)
        }
      }
      .privacyCurtain(environment)
    }
    .defaultSize(width: 960, height: 680)
    // The item of the Window menu is `AppCommands`' own: a `Window` scene given
    // `.keyboardShortcut` listed itself there without the key (MenuTests).
    .commandsRemoved()

    Window(environment.language("window.whatIf"), id: "whatif") {
      AppScenes.root(deps, window: .whatIf) { deps in
        SecondaryWindow(
          titleKey: "window.whatIf", scene: "whatif", minWidth: WhatIfWindow.minimumWidth
        ) {
          WhatIfWindow(deps: deps)
        }
      }
      .privacyCurtain(environment)
    }
    .defaultSize(width: 900, height: 600)
    // The item of the Window menu is `AppCommands`' own (MenuTests).
    .commandsRemoved()

    Settings {
      // The store and the pipeline too: a new quality of a category is carried over to the
      // past through the store, one step of ⌘Z, after counting over the pipeline's ledger.
      AppScenes.root(deps, window: .settings) { SettingsView(deps: $0) }
        .appWindow(.settings)
        .privacyCurtain(environment)
    }
    // Never smaller than its tabs are laid out for (`SettingsView.minimumSize`). The corner to
    // drag it larger is given from inside the window: the scene itself gives it none
    // (`ResizableSettingsWindow`).
    .windowResizability(.contentMinSize)
  }
}

/// Menu commands and their shortcuts. System shortcuts are left alone, and every caption
/// goes through the interface language like the rest of the app.
struct AppCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  let environment: AppEnvironment
  let store: TransactionsStore?
  let compute: ComputeStore

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button(environment.language("action.add")) {
        NotificationCenter.default.post(name: .focusEntryLine, object: nil)
      }
      .keyboardShortcut("n", modifiers: .command)
    }

    // ⌘Z belongs to the operation being edited, but not while text is being typed: there
    // it must still undo the typing, and ⌘⇧Z must still redo it. The system shortcuts are
    // not taken away («Системные сочетания не перехватывать»). Whether the items are on
    // is read from `TextEditingWatch`, which SwiftUI observes: the field itself it does not.
    CommandGroup(replacing: .undoRedo) {
      let editing = TextEditingWatch.shared.state
      Button(environment.language("action.undo")) {
        switch TextEditingUndo.undoTarget(storeCanUndo: store?.canUndo == true) {
        case .field: _ = TextEditingUndo.undoInFocusedField()
        case .store: store?.undo()
        case .none: NSSound.beep()
        }
      }
      .keyboardShortcut("z", modifiers: .command)
      .disabled(editing.undoTarget(storeCanUndo: store?.canUndo == true) == .none)

      Button(environment.language("action.redo")) {
        _ = TextEditingUndo.redoInFocusedField()
      }
      .keyboardShortcut("z", modifiers: [.command, .shift])
      .disabled(!editing.canRedo)
    }

    CommandGroup(after: .toolbar) {
      // A new run replaces the one in progress («Recompute во время расчёта отменяет
      // текущий прогон»).
      Button(environment.language("action.recompute")) { compute.run() }
        .keyboardShortcut("r", modifiers: .command)

      // «Проверить обновления…» where an update can arrive, «Перезапустить» where it cannot; in
      // the store build the page of the app is where updates come from.
      //
      // No shortcut: ⌘⇧R opens Reports, and restarting the application is not something to
      // put one keystroke away from ⌘R anyway.
      Button(UpdateService.title(environment)) { UpdateService.press() }
      if UpdateService.kind == .restartAndStorePage {
        Button(environment.language("action.openStorePage")) { UpdateService.openStorePage() }
      }

      // ⌃⌘F is the system's shortcut for full screen; the app asks for it itself, so it works
      // whichever window of the app is in front.
      Button(environment.language("action.fullScreen")) { AppWindows.toggleFullScreen() }
        .keyboardShortcut("f", modifiers: [.command, .control])

      // «Скрыть суммы»: ⌃⌘H, since ⌘H hides the app and ⌥⌘H the others; ⇧⌘H is free in the
      // system but is Finder's Home, and a habit of the hand is better left to mean one thing.
      Divider()
      Button(PrivacyCommands.amountsTitle(environment)) { environment.amounts.toggle() }
        .keyboardShortcut("h", modifiers: [.command, .control])
      // No shortcut: ⌃⌘Q locks the whole Mac, and that is the stronger habit to keep.
      if PrivacyCommands.offersLockNow(environment.lock) {
        Button(environment.language("privacy.lockNow")) {
          environment.lock.lock(because: .menu)
        }
        .disabled(environment.lock.isLocked)
      }
    }

    CommandGroup(after: .textEditing) {
      Button(environment.language("transactions.search", table: "Transactions")) {
        // The search lives in «Операции» of the main window, so ⌘F opens it. The flag waits
        // for the screen: a notification posted now would reach nobody while the screen is
        // still being made, and the first ⌘F would be lost.
        environment.pendingSearchFocus = true
        OperationsScreenOpening.open(with: openWindow)
      }
      .keyboardShortcut("f", modifiers: .command)
    }

    // «Операции» of the main window and the secondary windows, each with its shortcut: ⌘⇧T,
    // ⌘⇧A, ⌘⇧R. Transactions is a screen of the main window now; the shortcut the owner has
    // used since 1.0 brings it forward.
    CommandGroup(before: .windowList) {
      Button(environment.language("window.transactions")) {
        OperationsScreenOpening.open(with: openWindow)
      }
      .keyboardShortcut("t", modifiers: [.command, .shift])
      Button(environment.language("window.analytics")) {
        AppWindows.open("analytics", with: openWindow)
      }
      .keyboardShortcut("a", modifiers: [.command, .shift])
      Button(environment.language("window.reports")) {
        AppWindows.open("reports", with: openWindow)
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      Button(environment.language("window.whatIf")) {
        AppWindows.open("whatif", with: openWindow)
      }
      Divider()
    }

    CommandGroup(after: .sidebar) {
      Divider()
      Button(environment.language("section.overview")) {
        NotificationCenter.default.post(name: .selectSection, object: 1)
      }
      .keyboardShortcut("1", modifiers: .command)

      Button(environment.language("section.planning")) {
        NotificationCenter.default.post(name: .selectSection, object: 2)
      }
      .keyboardShortcut("2", modifiers: .command)

      Button(environment.language("section.debts")) {
        NotificationCenter.default.post(name: .selectSection, object: 3)
      }
      .keyboardShortcut("3", modifiers: .command)

      Button(environment.language("section.operations")) {
        NotificationCenter.default.post(name: .selectSection, object: 4)
      }
      .keyboardShortcut("4", modifiers: .command)

      Button(environment.language("section.calendar")) {
        NotificationCenter.default.post(name: .selectSection, object: 5)
      }
      .keyboardShortcut("5", modifiers: .command)

      Button(environment.language("section.capital")) {
        NotificationCenter.default.post(name: .selectSection, object: 6)
      }
      .keyboardShortcut("6", modifiers: .command)
    }

    // «Перейти → Команды…» (⌘K): the palette of commands. Every fixed command of the palette is
    // an item of this menu too, so the owner can give it a shortcut of his own in the system
    // keyboard settings (App Shortcuts match a menu item by its title).
    CommandMenu(QuestionsText.t("questions.menu.go", environment)) {
      Button(QuestionsText.t("questions.menu.palette", environment)) {
        NotificationCenter.default.post(name: .showCommandPalette, object: nil)
      }
      .keyboardShortcut("k", modifiers: .command)
      Divider()
      ForEach(PaletteCatalog.menuCommandIds, id: \.self) { id in
        Button(QuestionsText.t("palette.\(id)", environment)) {
          NotificationCenter.default.post(name: .runPaletteCommand, object: id)
        }
      }
    }

    // «Отчёты»: the Reports window, the saved reports and filters, and saving the filters
    // of «Операции» under a name.
    SavedViewsCommands(environment: environment, compute: compute)
  }
}

/// The menu «Отчёты» of the menu bar (the owner's choice for where the saved views live).
struct SavedViewsCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  let environment: AppEnvironment
  let compute: ComputeStore

  var body: some Commands {
    let book = compute.snapshot?.dataset.savedViews ?? SavedViewsBook()
    CommandMenu(QuestionsText.t("questions.menu.reports", environment)) {
      Button(environment.language("window.reports")) {
        AppWindows.open("reports", with: openWindow)
      }
      Divider()
      Section(QuestionsText.t("questions.saved.reports", environment)) {
        ForEach(book.reports) { report in
          Button(report.name) {
            NotificationCenter.default.post(name: .openSavedView, object: report.id)
          }
        }
      }
      Section(QuestionsText.t("questions.saved.filters", environment)) {
        ForEach(book.filters) { filter in
          Button(filter.name) {
            NotificationCenter.default.post(name: .openSavedView, object: filter.id)
          }
        }
      }
      Divider()
      Button(QuestionsText.t("questions.saved.save.filter", environment)) {
        NotificationCenter.default.post(name: .saveOperationsFilter, object: nil)
      }
      Button(QuestionsText.t("questions.saved.manage", environment)) {
        NotificationCenter.default.post(name: .manageSavedViews, object: nil)
      }
    }
  }
}

/// Undo and redo of plain text editing, which belongs to the field the cursor is in.
///
/// AppKit's key window, its first responder and their undo managers all belong to the main
/// actor, and so does everything here: the menu commands that call it are on the main actor
/// already.
@MainActor
enum TextEditingUndo {
  private static var editor: NSTextView? {
    NSApp.keyWindow?.firstResponder as? NSTextView
  }

  /// What ⌘Z takes back.
  enum UndoTarget: Equatable {
    /// The typing in the field the cursor is in.
    case field
    /// The last step of the store.
    case store
    case none
  }

  /// What ⌘Z takes back now, in the key window as it is (`State.current()`).
  static func undoTarget(storeCanUndo: Bool) -> UndoTarget {
    State.current().undoTarget(storeCanUndo: storeCanUndo)
  }

  /// The typing in the focused field goes first. With nothing typed to take back, ⌘Z reaches
  /// the store from a window: the entry line keeps the cursor after a save, and ⌘Z there
  /// takes the saved operation back. From a sheet or a popover it never does: they are
  /// opened over what the last step wrote — a reimbursement lists the parts of the purchase
  /// ⌘Z would purge, an edit sheet holds the operation it would take away — and only their
  /// own typing is theirs to take back.
  static func undoTarget(
    isEditingText: Bool, fieldCanUndo: Bool, storeCanUndo: Bool, inSheet: Bool
  ) -> UndoTarget {
    if isEditingText, fieldCanUndo { return .field }
    guard !inSheet else { return .none }
    return storeCanUndo ? .store : .none
  }

  /// Returns true when the keystroke was handled by the text field.
  static func undoInFocusedField() -> Bool {
    guard let manager = editor?.undoManager, manager.canUndo else { return false }
    manager.undo()
    return true
  }

  static func redoInFocusedField() -> Bool {
    guard let manager = editor?.undoManager, manager.canRedo else { return false }
    manager.redo()
    return true
  }
}

struct MainWindow: View {
  let deps: AppDependencies

  /// The window makes its own `OperationActions`; a test hands in the one it holds, so it can
  /// show the selection bar the way a selection does (`MainWindowLayoutTests`). `opensDetails`
  /// is the same idea for the ↓ panel, which a key press cannot reach without a key window,
  /// `selection` for the screen the window opens on, which a click in the sidebar chooses, and
  /// `operations` for what «Операции» holds — the operation in its editor, say.
  init(
    deps: AppDependencies, actions: OperationActions = OperationActions(),
    opensDetails: Bool = false, selection: SidebarItem = .section(.overview),
    operations: OperationsScreenState = OperationsScreenState()
  ) {
    self.deps = deps
    self.opensDetails = opensDetails
    _overviewActions = State(initialValue: actions)
    _selection = State(initialValue: selection)
    _operations = State(initialValue: operations)
  }

  private let opensDetails: Bool

  private var environment: AppEnvironment { deps.environment }
  private var store: TransactionsStore { deps.store }
  private var compute: ComputeStore { deps.compute }
  @Environment(\.openWindow) private var openWindow
  /// The public way into the `Settings` scene: the gear of the toolbar and the Help menu
  /// both go through it, instead of the private selector the menu used to send.
  @Environment(\.openSettings) private var openSettings
  @Environment(\.windowWidth) private var windowWidth
  /// What the sidebar has chosen: a section, an account or a group.
  @State private var selection: SidebarItem = .section(.overview)
  /// The account this window last gave the entry line; `nil` for none.
  @State private var focusGiven: UUID?
  /// Whether this is the window the owner works in.
  @Environment(\.appearsActive) private var appearsActive
  /// The selection of the Overview list and everything opened from it. It lives here
  /// because its bar floats in the entry bar and its sheets hang on the window's root.
  @State private var overviewActions: OperationActions
  /// The filters, the search and the editor of «Операции», kept while another screen is shown.
  @State private var operations: OperationsScreenState
  /// The reminders of the day, shown once, and the due dates passed and unpaid, asked about
  /// once a launch.
  @State private var remindersShown: RemindersShown?
  /// The list of conflicts of the exchange with the other devices, over the window.
  @State private var showsConflicts = false

  struct RemindersShown: Identifiable {
    let reminders: [Reminder]
    /// The sheet opens with the overdue due dates on top.
    var asksOverdue = false
    var id: Int {
      var hasher = Hasher()
      hasher.combine(reminders)
      hasher.combine(asksOverdue)
      return hasher.finalize()
    }
  }

  /// The day the reminders were last shown, per data set: the owner's are never spent on a
  /// set of synthetic data.
  private static var remindersShownKey: String {
    "reminders.shownOn" + (AppPaths.dataSet.map { ".\($0.rawValue)" } ?? "")
  }

  /// Changes when the reminders of the pipeline are counted.
  private var remindersDay: Date? {
    if case .ready(_, let at) = compute.states.reminders { return at }
    return nil
  }

  /// The entry line of the app puts a new operation on the account this window shows.
  private func pointEntryLine(at chosen: SidebarItem) {
    focusGiven = chosen.focusedAccountId
    environment.focusedAccountId = chosen.focusedAccountId
  }

  /// The reminders of the day once a day, and the due dates passed and unpaid at every launch
  /// (`RemindersPresentation`).
  private func showRemindersOnce() {
    guard case .ready(let reminders, _) = compute.states.reminders,
      !AppEnvironment.isTestHost, remindersShown == nil,
      // One question at a time: the setup of the accounts is answered first, then the offer
      // of a report after a crash, then the currencies the bank does not publish, and the
      // reminders follow.
      !asksSetup, !environment.offersProblemReport, environment.currenciesMissingAtBank.isEmpty
    else { return }
    let today = environment.today.iso
    let defaults = UserDefaults.standard
    let overdue = compute.snapshot?.planning.overdue ?? []
    guard
      let shown = RemindersPresentation.decide(
        daily: reminders, overdue: overdue,
        shownToday: defaults.string(forKey: Self.remindersShownKey) == today,
        askedThisLaunch: environment.overdueAskedThisLaunch,
        suppressed: LaunchOptions.current.suppressesReminders, locked: environment.lock.isLocked)
    else { return }
    if shown.marksDailyShown { defaults.set(today, forKey: Self.remindersShownKey) }
    if shown.asksOverdue {
      environment.overdueAskedThisLaunch = true
      AppLog.info(
        "reminders.overdue.asked", .ui, "the overdue due dates were asked about",
        [
          LogPair("scheduled", .count(overdue.filter { !$0.isDebt }.count)),
          LogPair("debts", .count(overdue.filter(\.isDebt).count)),
        ])
    }
    remindersShown = RemindersShown(reminders: shown.daily, asksOverdue: shown.asksOverdue)
  }

  /// «Разобрать…» of the free sum: the overdue section alone, whatever was asked at launch.
  private func showOverdue() {
    guard environment.showsOverdue else { return }
    environment.showsOverdue = false
    guard remindersShown == nil else { return }
    remindersShown = RemindersShown(reminders: [], asksOverdue: true)
  }

  var body: some View {
    NavigationSplitView {
      MainSidebar(selection: $selection)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        // Every column of a split view is laid out in a host of its own, and on macOS 26 a
        // host of its own does not always get the environment of the scene — the crash of
        // 19.09 in the inspector, and the journal line `dependencies.missing … DayList.swift`
        // of 21.09 in this window. The window holds the dependencies as a value, so it hands
        // them over again here; below the root nothing has to trust the environment.
        .appDependencies(deps)
    } detail: {
      HStack(spacing: 0) {
        // The entry bar takes its width from the whole window, and the detail column it
        // floats over only keeps it clear of its sides.
        GeometryReader { proxy in
          content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedWindowBackground()
            // The tutorial's strip: «Учебный режим · 3 из 10», the tasks, the way out.
            .safeAreaInset(edge: .top, spacing: 0) {
              if guide.isTutorial, environment.state == .ready { TutorialBar(guide: guide) }
            }
            // The trip that is on, its day's allowance, and the card of the return.
            .safeAreaInset(edge: .top, spacing: 0) {
              if environment.state == .ready { TripBanner() }
            }
            // Records another device changed apart from this one, waiting for the owner.
            .safeAreaInset(edge: .top, spacing: 0) {
              if environment.state == .ready { SyncConflictsStrip(showsList: $showsConflicts) }
            }
            // The bar floats over the last rows and keeps them clear of it. The room it needs
            // is left to the safe area and never measured back into `@State`: a height handed
            // back into the layout of its own branch is what kept the window of Transactions
            // asking for another Update Constraints pass until AppKit threw.
            .safeAreaInset(edge: .bottom, spacing: 0) {
              entryDock(detailWidth: proxy.size.width)
            }
            // The root of the screen: the selection bar reports its frame in this space, and
            // the sheets, popovers and confirmations of the list hang here, not on its rows.
            .coordinateSpace(.named(OperationActions.coordinateSpace))
            .operationPresentations(overviewActions)
            .guideOverlay(guide, toolbar: true)
        }
        // The form of a new operation, when the owner chose it in Settings → «Ввод»: a column
        // of its own at the right, always there, in place of the line (`EntryStyle.form`).
        if environment.entryStyle == .form, environment.state == .ready {
          Divider()
          EntryBar(
            windowWidth: windowWidth, detailWidth: 0, style: .form, operations: overviewActions
          ) { EmptyView() }
          .frame(width: Self.entryFormWidth)
          .background(.background)
          // A root of the guide of its own: the quick line of the form is cut out of its shade.
          .guideOverlay(guide)
        }
      }
      // The other column of the same split, for the same reason.
      .appDependencies(deps)
      .toolbar { toolbarContent }
    }
    .navigationTitle(windowTitle)
    // Closing it quits the app; the secondary windows stand over it in full screen
    // (`AppWindows`).
    .appWindow(.main)
    // ⌘K, the question sheet, filters set by an answer or a saved view, and the saved views.
    .questionsHost(deps: deps, operations: operations)
    .navigationSubtitle(RecomputeText.subtitle(compute: compute, environment: environment))
    .journalsSection(selection.journalToken, in: .main)
    // The cards of the first launch, of «Что нового» or of the Help menu.
    // Like every question the app raises by itself, never over the cover of the locked app.
    .sheet(item: environment.lock.presenting(Bindable(guide).cards)) { scenario in
      GuideCardsView(scenario: scenario) { skipped in
        guide.cardsDone(version: Self.version, skipped: skipped)
      }
      .appDependencies(deps)
    }
    .modifier(GuideWhereToClickKeys(guide: guide))
    .onChange(of: environment.state, initial: true) { _, state in
      guard state == .ready else { return }
      guide.begin(
        databaseInUse: environment.accountSetup != nil, version: Self.version,
        dataSet: AppPaths.dataSet)
    }
    // The tutorial's tasks are found done by what the data holds after every change.
    .onChange(of: compute.generation, initial: true) { _, _ in
      if let dataset = compute.snapshot?.dataset { guide.check(dataset) }
    }
    // ↓ in the entry line over a screen without a list: «Операции» opens and takes it.
    .onReceive(NotificationCenter.default.publisher(for: .walkOperationsList)) { _ in
      guard environment.state == .ready, !selection.listsOperations else { return }
      selection = .section(.operations)
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(150))
        NotificationCenter.default.post(name: .walkOperationsList, object: nil)
      }
    }
    .task {
      LaunchWindows.open(with: openWindow, today: environment.today)
      // `--open transactions` opened a window of its own once; it is a screen of this one now.
      if LaunchOptions.current.windows.contains(.transactions) {
        selection = .section(.operations)
      }
      if let name = LaunchOptions.current.section, let chosen = Section.named(name) {
        selection = .section(chosen)
      }
    }
    // The entry line puts a new operation on the account whose screen is open, in the window
    // the owner works in: a choice made here, or this window coming to the front, gives it the
    // account; a window closed takes back only the account it gave, never another window's.
    .onChange(of: selection, initial: true) { _, chosen in pointEntryLine(at: chosen) }
    .onChange(of: appearsActive) { _, active in
      if active { pointEntryLine(at: selection) }
    }
    .onDisappear {
      if environment.focusedAccountId == focusGiven { environment.focusedAccountId = nil }
    }
    // An account or a group archived, merged away or deleted — here, in the settings or by
    // ⌘Z — takes its screen along, and the window goes back to Overview.
    .onChange(of: compute.generation) { _, _ in leaveWhatIsGone() }
    // Sheets are laid out by hosts of their own: they get the dependencies handed over.
    .sheet(
      isPresented: Binding(
        get: { environment.showsReconciliation },
        set: { environment.showsReconciliation = $0 })
    ) {
      ReconcileSheet().appDependencies(deps)
    }
    // Statements: from the File menu, or files dropped on the window.
    .statementImportSheet(deps)
    .receiptSheet(deps)
    .sheet(isPresented: environment.lock.presenting($showsConflicts)) {
      if let sync = environment.sync {
        ConflictsSheet(coordinator: sync).appDependencies(deps)
      }
    }
    .sheet(
      isPresented: Binding(
        get: { environment.showsTrip },
        set: { environment.showsTrip = $0 })
    ) {
      TripStartSheet().appDependencies(deps)
    }
    .sheet(item: environment.lock.presenting($remindersShown)) { shown in
      RemindersSheet(reminders: shown.reminders, asksOverdue: shown.asksOverdue) {
        selection = .section($0)
      }
      .appDependencies(deps)
    }
    // After the reminders, one at a time: the debts made before 1.9, the offer of
    // self-employment.
    .launchQuestions(
      deps,
      waits: remindersShown != nil || compute.states.reminders.phase == .calculating || asksSetup
        || environment.offersProblemReport || !environment.currenciesMissingAtBank.isEmpty
    )
    .onChange(of: environment.showsOverdue) { _, _ in showOverdue() }
    // A restore or an import this launch could not put in place: said once, with the way on,
    // instead of tried again in silence at every launch. This alert and the two after it wait
    // for the setup of the accounts, the first question of the window.
    .alert(
      environment.language("replacement.notApplied.title"),
      isPresented: Binding(
        get: {
          environment.lock.lets(
            AccountSetupOffer.lets(
              environment.replacementProblem == .notApplied, asksSetup: asksSetup))
        },
        set: { if !$0, !environment.lock.isLocked { environment.replacementProblem = nil } })
    ) {
      Button(environment.language("action.retry")) { AppRestart.relaunch() }
      Button(environment.language("replacement.giveUp"), role: .destructive) {
        AppPaths.discardPendingReplacement()
      }
    } message: {
      Text(verbatim: environment.language("replacement.notApplied.message"))
    }
    // A restore or an import whose database this build would not open: it was not put in
    // place, and the data there was is open.
    .alert(
      environment.language("replacement.refused.title"),
      isPresented: Binding(
        get: {
          environment.lock.lets(
            AccountSetupOffer.lets(environment.replacementProblem == .refused, asksSetup: asksSetup)
          )
        },
        set: { if !$0, !environment.lock.isLocked { environment.replacementProblem = nil } })
    ) {
      Button(environment.language("action.ok")) {}
    } message: {
      Text(verbatim: environment.language("replacement.refused.message"))
    }
    // «После импорта приложение просит заново выбрать папку для копий бэкапов».
    .alert(
      environment.language("backups.afterImport.title", table: "Settings"),
      isPresented: Binding(
        get: {
          environment.lock.lets(
            AccountSetupOffer.lets(environment.asksForMirrorFolder, asksSetup: asksSetup))
        },
        set: { if !$0, !environment.lock.isLocked { environment.asksForMirrorFolder = false } })
    ) {
      Button(environment.language("settings.backups.choose", table: "Settings")) {
        // After the alert is gone: the panel is modal of its own.
        Task { @MainActor in BackupSettingsView.chooseAfterImport(in: environment) }
      }
      Button(environment.language("backups.afterImport.later", table: "Settings"), role: .cancel) {}
    } message: {
      Text(verbatim: environment.language("backups.afterImport.message", table: "Settings"))
    }
    .onChange(of: remindersDay) { _, _ in showRemindersOnce() }
    // What waited for the unlock is asked now: the reminders, and an archive from Finder.
    .onChange(of: environment.lock.isLocked) { _, locked in
      guard !locked else { return }
      showRemindersOnce()
      Task { @MainActor in ArchiveImportFlow.resumeDeferred(in: environment) }
    }
    // An archive double-clicked in Finder before the database opened waits for the start to be
    // over. After this update: its questions are modal alerts of their own.
    .onChange(of: environment.state, initial: true) { _, _ in
      Task { @MainActor in ArchiveImportFlow.resumeDeferred(in: environment) }
    }
    // The first question of the window: the setup of the accounts, while it is due.
    .modifier(AccountSetupOffer(deps: deps))
    .onChange(of: asksSetup) { _, asks in
      if !asks { showRemindersOnce() }
    }
    // The offer of a report waits for the start, for an archive from Finder and for the
    // setup: raised before the window knows whether the setup comes, it would be taken down
    // by the sheet with the report it led to. It hangs on a view of its own behind the
    // window, so the window's content keeps its identity when the offer comes.
    .background {
      if AccountSetupOffer.letsReportOffer(environment, setupIsUp: asksSetup) {
        Color.clear.modifier(ProblemReportOffer(deps: deps))
      }
    }
    .onChange(of: environment.offersProblemReport) { _, offers in
      if !offers { showRemindersOnce() }
    }
    .modifier(CurrencyNotice(deps: deps, waits: remindersShown != nil || asksSetup))
    .onChange(of: environment.currenciesMissingAtBank) { _, missing in
      if missing.isEmpty { showRemindersOnce() }
    }
  }

  /// The width of the form of a new operation at the right of the window.
  static let entryFormWidth: CGFloat = 380

  /// The guide of this Mac: the cards, the tutorial and «Показать, куда нажимать».
  private var guide: GuideStore { GuideStore.shared }

  /// The version of the app, as «Что нового» counts them.
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
  }

  /// What stands at the bottom of the list: the entry line with the selection bar in its glass
  /// container, or — with the form at the side, which has no line to carry it — the selection bar
  /// alone.
  @ViewBuilder
  private func entryDock(detailWidth: CGFloat) -> some View {
    switch environment.entryStyle {
    case .line:
      EntryBar(
        windowWidth: windowWidth, detailWidth: detailWidth, opensDetails: opensDetails
      ) {
        if showsOperations {
          SelectionBar(actions: overviewActions)
        }
      }
      // The selection bar morphs out of the capsule and back only inside an animated
      // change, and the selection changes in many places — the native list, ×, Esc, a
      // popover, a deletion — besides a large write that holds the bar with nothing
      // selected. Animating by its visibility here covers them all, moves the chips
      // above it smoothly, and leaves a selection that merely grows alone.
      .animation(.snappy, value: showsSelectionBar)
    case .form:
      if showsSelectionBar {
        SelectionDock(actions: overviewActions)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch environment.state {
    case .starting:
      ProgressView()
    case .failed(let failure):
      DatabaseFailureView(failure: failure, deps: deps)
    case .ready:
      switch selection {
      case .section(.overview): OverviewView(actions: overviewActions)
      case .section(.operations):
        OperationsScreen(deps: deps, actions: overviewActions, state: operations)
      case .section(.planning): PlanningView()
      case .section(.debts): DebtsView()
      case .section(.calendar): CalendarView(actions: overviewActions)
      case .section(.capital): CapitalView { selection = .account($0) }
      case .account(let id):
        AccountScreen(accountId: id, actions: overviewActions)
          .id(id)
      case .group(let id):
        GroupScreen(scope: .group(id), actions: overviewActions) { selection = .account($0) }
          .id(id)
      case .bank(let id):
        BankScreen(bankId: id)
          .id(id)
      case .allAccounts:
        GroupScreen(scope: .summary, actions: overviewActions) { selection = .account($0) }
      }
    }
  }

  /// Back to Overview when the account or the group on screen is no longer among the live ones
  /// the sidebar lists. Judged by the data once it is there, never before.
  private func leaveWhatIsGone() {
    guard let accounts = compute.snapshot?.planning.accounts else { return }
    let live = Set(accounts.sections.flatMap(\.accounts).map(\.account.id))
    let groups = Set(accounts.sections.compactMap(\.group?.id))
    if let fallback = selection.fallback(liveAccounts: live, liveGroups: groups) {
      selection = fallback
    }
  }

  /// The setup of the accounts is on screen — asked by the window or opened from the card of
  /// Overview: every other question of the window waits.
  private var asksSetup: Bool { AccountSetupOffer.isUp(environment) }

  /// Overview, or the screen of an account or of a group: operations are listed and selected
  /// there, and the selection bar floats in the entry bar.
  private var showsOperations: Bool {
    environment.state == .ready && selection.listsOperations
  }

  /// A selection, or a large write landing with nothing selected (`SelectionBar.Form`).
  private var showsSelectionBar: Bool {
    showsOperations
      && SelectionBar.form(
        selection: overviewActions.selection, writing: store.isWritingInBackground) != .hidden
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(id: "entry.add", placement: .primaryAction) {
      Button {
        NotificationCenter.default.post(name: .focusEntryLine, object: nil)
      } label: {
        Label {
          Text(verbatim: environment.language("action.add"))
        } icon: {
          Image(systemName: "plus")
        }
      }
      // ⌘N belongs to the menu item of `AppCommands` and is declared there once. Declared
      // twice, the main menu shadows the toolbar anyway (`MenuTests`).
      .labelStyle(.titleAndIcon)
      .help("\(environment.language("action.add")) ⌘N")
      .accessibilityIdentifier("entry.add")
    }

    ToolbarItemGroup {
      // The palette of commands. ⌘K belongs to the menu item «Перейти → Команды…», declared there
      // once.
      Button {
        NotificationCenter.default.post(name: .showCommandPalette, object: nil)
      } label: {
        Label {
          Text(verbatim: QuestionsText.t("questions.menu.palette", environment))
        } icon: {
          Image(systemName: "command")
        }
      }
      .help("\(QuestionsText.t("questions.menu.palette", environment)) ⌘K")
      .accessibilityIdentifier("toolbar.palette")

      // «Скрыть суммы» — the eye says what a click will do, the label says it in words.
      Button {
        environment.amounts.toggle()
      } label: {
        Label {
          Text(verbatim: PrivacyCommands.amountsTitle(environment))
        } icon: {
          Image(systemName: environment.amounts.hidesAmounts ? "eye" : "eye.slash")
        }
      }
      .help(PrivacyCommands.amountsTitle(environment))
      .accessibilityIdentifier("toolbar.hideAmounts")

      if compute.isRunning {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(Text(verbatim: environment.language("compute.recomputing")))
      }
      Button {
        compute.run()
      } label: {
        Label {
          Text(verbatim: environment.language("action.recompute"))
        } icon: {
          Image(systemName: "arrow.clockwise")
        }
      }
      .help("\(environment.language("action.recompute")) ⌘R")

      Button {
        environment.showsReconciliation = true
      } label: {
        Label {
          Text(verbatim: environment.language("action.reconcile"))
        } icon: {
          Image(systemName: "checkmark.seal")
        }
      }
      .help(environment.language("reconcile.help", table: "Planning"))

      // «Я в поездке»: the trip mode on for a trip to pick or make, or off again.
      Button {
        environment.showsTrip = true
      } label: {
        Label {
          Text(verbatim: TravelText.t("travel.start.button", environment))
        } icon: {
          Image(systemName: "airplane")
        }
      }
      .help(TravelText.t("travel.start.help", environment))
      .accessibilityIdentifier("toolbar.trip")

      Button {
        selection = .section(.operations)
      } label: {
        Label {
          Text(verbatim: environment.language("window.transactions"))
        } icon: {
          Image(systemName: "list.bullet")
        }
      }

      Button {
        AppWindows.open("analytics", with: openWindow)
      } label: {
        Label {
          Text(verbatim: environment.language("window.analytics"))
        } icon: {
          Image(systemName: "chart.xyaxis.line")
        }
      }

      Button {
        AppWindows.open("reports", with: openWindow)
      } label: {
        Label {
          Text(verbatim: environment.language("window.reports"))
        } icon: {
          Image(systemName: "tablecells")
        }
      }

      // The last two actions of the toolbar. Each runs the flow of its menu item —
      // the warning about personal data first for the export, Sparkle's check or a plain restart
      // by the build for the other — rather than a copy of it.
      Button {
        FileCommands(environment: environment, store: store).exportCSV()
      } label: {
        Label {
          Text(verbatim: environment.language("action.export"))
        } icon: {
          Image(systemName: "square.and.arrow.up")
        }
      }

      Button {
        UpdateService.press()
      } label: {
        Label {
          Text(verbatim: UpdateService.title(environment))
        } icon: {
          Image(systemName: UpdateService.symbol)
        }
      }
      .help(UpdateService.title(environment))

      // ⌘, opens the settings from the menu bar and always did; the owner asked for a way in
      // that can be seen without opening a menu (21.09). It rides in the same group as the
      // other seven, so it shares their system glass and no glass lands on glass.
      // No shortcut of its own: ⌘, is a system combination and already belongs to the item
      // the `Settings` scene makes («Системные сочетания не перехватывать»).
      Button {
        openSettings()
      } label: {
        Label {
          Text(verbatim: environment.language("settings.title", table: "Settings"))
        } icon: {
          Image(systemName: "gearshape")
        }
      }
      .accessibilityIdentifier("toolbar.settings")
    }
  }

  /// «OhMyMoney — DEBUG», and the data set when one is open: «OhMyMoney — DEBUG · SAMPLE», or
  /// «OhMyMoney — BENCH» in Release. Synthetic data is never taken for the real one.
  private var windowTitle: String {
    var badges: [String] = []
    #if DEBUG
      badges.append(environment.language("common.debugBadge"))
    #endif
    if let dataSet = AppPaths.dataSet {
      badges.append(
        dataSet == .learn
          ? environment.language("guide.tutorial.badge", table: "Guide") : dataSet.badge)
    }
    let name = environment.language("app.name")
    return badges.isEmpty ? name : "\(name) — \(badges.joined(separator: " · "))"
  }
}

/// Measures the window once, at the root of the scene, and hands the width down.
private struct WindowWidthReader: ViewModifier {
  @State private var width: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .environment(\.windowWidth, width)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        width = $0
      }
  }
}

extension View {
  fileprivate func measuresWindowWidth() -> some View {
    modifier(WindowWidthReader())
  }
}

struct SecondaryWindow<Content: View>: View {
  @Dependency(\.environment) private var environment
  let titleKey: String
  /// The id of the scene; with one, the window is marked as a secondary window of the app
  /// (`AppWindows`). A test hosting the content in a window of its own gives none.
  var scene: String?
  /// The narrowest the window may be (`contentMinSize`). It is never below what the content
  /// asks for: a window narrower than its content lays the content out wider than itself and
  /// cuts it off at both edges. And AppKit shows a sidebar inside the window only while the
  /// window, less the sidebar, stays at least this wide — narrower, showing the sidebar widens
  /// the window by its width for good.
  var minWidth: CGFloat
  @ViewBuilder let content: Content

  init(
    titleKey: String, scene: String? = nil, minWidth: CGFloat = 720,
    @ViewBuilder content: () -> Content
  ) {
    self.titleKey = titleKey
    self.scene = scene
    self.minWidth = minWidth
    self.content = content()
  }

  var body: some View {
    content
      .frame(minWidth: minWidth, minHeight: 480)
      .navigationTitle(environment.language(titleKey))
      .background {
        if let scene { Color.clear.appWindow(.secondary(scene: scene)) }
      }
  }
}
