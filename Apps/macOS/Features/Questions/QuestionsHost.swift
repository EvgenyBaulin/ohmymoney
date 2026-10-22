import AppCore
import SwiftUI

extension OperationColumnLayout {
  /// The text of `operations.columns` that shows exactly `keys`, in that order, and hides the
  /// other columns that can be hidden. The description and the amount are never hidden, wherever
  /// the keys leave them.
  static func storage(showing keys: [String]) -> String {
    let shown = keys.compactMap(OperationColumn.init(rawValue:))
    let rest = OperationColumn.allCases.filter { !shown.contains($0) }
    return (shown.map(\.rawValue) + rest.map { "-" + $0.rawValue }).joined(separator: ",")
  }
}

/// What the window raises over itself for a command of the palette that needs a sheet.
private enum PaletteSheet: Identifiable {
  case debt
  case goal
  case transfer(TransferForm)

  var id: String {
    switch self {
    case .debt: "debt"
    case .goal: "goal"
    case .transfer: "transfer"
    }
  }
}

/// The filters of «Операции» waiting for a name.
private struct FilterToSave: Identifiable {
  let id = UUID()
  var filters: TransactionFilters
  var columns: [String]
}

/// The window that owns «Операции» listens for everything the question line, the palette and
/// the saved views ask of the app: ⌘K and its sheet, the sheet of one question, a filter set
/// from an answer or a saved view, the saving of the filters on screen, the list of saved
/// views, and a command run from a menu item. It sits on the window (not on the screen), so
/// an ask made while the screen is not on show is not lost. The Mac's main window and the
/// phone's root both carry it.
struct QuestionsHost: ViewModifier {
  let deps: AppDependencies
  let operations: OperationsScreenState

  @Environment(\.openWindow) private var openWindow
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif
  @State private var showsPalette = false
  @State private var showsQuestion = false
  @State private var showsSaved = false
  @State private var pending: PaletteAction?
  @State private var paletteSheet: PaletteSheet?
  @State private var toSave: FilterToSave?

  private var environment: AppEnvironment { deps.environment }
  private var compute: ComputeStore { deps.compute }

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
        guard environment.state == .ready else { return }
        showsPalette = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .showQuestionSheet)) { _ in
        guard environment.state == .ready else { return }
        showsQuestion = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .applyOperationsFilter)) { note in
        if let request = note.object as? OperationsFilterRequest { show(request) }
      }
      .onReceive(NotificationCenter.default.publisher(for: .openSavedView)) { note in
        if let id = note.object as? UUID { openSavedView(id) }
      }
      .onReceive(NotificationCenter.default.publisher(for: .saveOperationsFilter)) { _ in
        guard environment.state == .ready else { return }
        toSave = FilterToSave(
          filters: operations.filters,
          columns: OperationColumnLayout(
            storage: UserDefaults.standard.string(forKey: OperationColumnLayout.storageKey)
          ).visible.map(\.rawValue))
      }
      .onReceive(NotificationCenter.default.publisher(for: .manageSavedViews)) { _ in
        guard environment.state == .ready else { return }
        showsSaved = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .runPaletteCommand)) { note in
        guard environment.state == .ready, let id = note.object as? String,
          let entry = PaletteCatalog.fixedEntries.first(where: { $0.id == id }),
          let action = PaletteAction.action(for: entry)
        else { return }
        perform(action)
      }
      // The palette closes first and the deed follows: a sheet cannot open over a sheet that
      // is still going away.
      .sheet(
        isPresented: environment.lock.presenting($showsPalette),
        onDismiss: {
          guard let action = pending else { return }
          pending = nil
          perform(action)
        }
      ) {
        CommandPaletteView(
          entries: PaletteSource.entries(for: compute.snapshot?.dataset ?? Dataset()),
          run: { entry in
            pending = PaletteAction.action(for: entry)
            showsPalette = false
          },
          close: { showsPalette = false }
        )
        .appDependencies(deps)
      }
      .sheet(isPresented: environment.lock.presenting($showsQuestion)) {
        AskQuestionSheet().appDependencies(deps)
      }
      .sheet(item: environment.lock.presenting($paletteSheet)) { sheet in
        switch sheet {
        case .debt: DebtWizard().appDependencies(deps)
        case .goal: GoalForm(original: nil).appDependencies(deps)
        case .transfer(let form):
          TransferSheet(form: form) { _ in paletteSheet = nil }.appDependencies(deps)
        }
      }
      .sheet(isPresented: environment.lock.presenting($showsSaved)) {
        SavedViewsSheet(open: { id in
          showsSaved = false
          openSavedView(id)
        })
        .appDependencies(deps)
      }
      .sheet(item: environment.lock.presenting($toSave)) { save in
        SaveViewSheet(subject: .filter(save.filters, columns: save.columns))
          .appDependencies(deps)
      }
  }

  // MARK: Showing things

  private func show(_ request: OperationsFilterRequest) {
    let tree = compute.snapshot?.dataset.categories ?? []
    operations.filters = TransactionFilters(
      request.filter, today: environment.today, tree: tree)
    if let columns = request.columns {
      UserDefaults.standard.set(columns, forKey: OperationColumnLayout.storageKey)
    }
    NotificationCenter.default.post(
      name: .openSidebarItem, object: SidebarItem.section(.operations))
  }

  private func openSavedView(_ id: UUID) {
    guard let book = compute.snapshot?.dataset.savedViews else { return }
    let today = environment.today
    if let filter = book.filters.first(where: { $0.id == id }) {
      show(
        OperationsFilterRequest(
          filter: filter.entryFilter(today: today),
          columns: filter.columns.map { OperationColumnLayout.storage(showing: $0) }))
    } else if let report = book.reports.first(where: { $0.id == id }) {
      QuestionOpening.prepareReports(report, today: today)
      AppScreens.open(.reports, with: openWindow)
    }
  }

  private func select(_ section: MainWindow.Section) {
    NotificationCenter.default.post(name: .selectSection, object: section.shortcutIndex)
  }

  // MARK: Deeds

  private func perform(_ action: PaletteAction) {
    let dataset = compute.snapshot?.dataset
    switch action {
    case .newOperation:
      NotificationCenter.default.post(name: .focusEntryLine, object: nil)
    case .newDebt:
      select(.debts)
      paletteSheet = .debt
    case .newGoal:
      select(.planning)
      paletteSheet = .goal
    case .newTransfer(let from):
      let accounts = (dataset?.paymentMethods ?? []).filter { !$0.archived }
      let account = from.flatMap { id in accounts.first { $0.id == id } }
      paletteSheet = .transfer(
        TransferForm(from: account, accounts: accounts, day: environment.today))
    case .reconcile:
      environment.showsReconciliation = true
    case .askQuestion:
      showsQuestion = true
    case .recompute:
      compute.run()
    case .export:
      #if os(macOS)
        FileCommands(environment: environment, store: deps.store).exportCSV()
      #endif
    case .checkForUpdates:
      #if os(macOS)
        UpdateService.press()
      #endif
    case .openSettings:
      #if os(macOS)
        openSettings()
      #else
        NotificationCenter.default.post(name: .openAppScreen, object: AppScreen.settings)
      #endif
    case .openSection(let section):
      select(section)
    case .openAnalytics:
      AppScreens.open(.analytics, with: openWindow)
    case .openReports:
      AppScreens.open(.reports, with: openWindow)
    case .openAccount(let id):
      NotificationCenter.default.post(name: .openSidebarItem, object: SidebarItem.account(id))
    case .openDebts:
      select(.debts)
    case .openPlanning:
      select(.planning)
    case .operationsOfCategory(let id):
      var filter = EntryFilter()
      if dataset?.categories.first(where: { $0.id == id })?.parentId != nil {
        filter.subcategoryId = id
      } else {
        filter.categoryId = id
      }
      show(OperationsFilterRequest(filter: filter, columns: nil))
    case .operationsOfPerson(let id):
      show(OperationsFilterRequest(filter: EntryFilter(personId: id), columns: nil))
    }
  }
}

extension View {
  /// The question line, the palette and the saved views for this window.
  func questionsHost(deps: AppDependencies, operations: OperationsScreenState) -> some View {
    modifier(QuestionsHost(deps: deps, operations: operations))
  }
}
