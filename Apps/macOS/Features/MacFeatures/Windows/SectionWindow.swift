import AppCore
import SwiftUI

/// What a window of its own shows: a section of the main window, an account, a group of accounts
/// or a bank — two periods or two accounts side by side. Codable, so a window that macOS brings
/// back after a restart opens on the same screen.
struct SectionWindowValue: Codable, Hashable, Sendable {
  enum Kind: String, Codable, Sendable {
    case section, account, group, bank, allAccounts
  }

  var kind: Kind
  /// The section's raw value for a section; empty otherwise.
  var section: String = ""
  var id: UUID?

  init(_ item: SidebarItem) {
    switch item {
    case .section(let section):
      kind = .section
      self.section = section.rawValue
    case .account(let id):
      kind = .account
      self.id = id
    case .group(let id):
      kind = .group
      self.id = id
    case .bank(let id):
      kind = .bank
      self.id = id
    case .allAccounts:
      kind = .allAccounts
    }
  }

  var item: SidebarItem {
    switch kind {
    case .section: .section(MainWindow.Section(rawValue: section) ?? .overview)
    case .account: id.map(SidebarItem.account) ?? .section(.overview)
    case .group: id.map(SidebarItem.group) ?? .section(.overview)
    case .bank: id.map(SidebarItem.bank) ?? .section(.overview)
    case .allAccounts: .allAccounts
    }
  }
}

/// A screen of the main window in a window of its own: «Открыть в новом окне». It shows the same
/// views the main window does, without the sidebar and the entry line, and a menu of the
/// sections in its toolbar to switch what it shows. Closing it does not quit: it is a secondary
/// window (`AppWindows`), and it stands over the main window in full screen.
struct SectionWindow: View {
  let deps: AppDependencies
  @State private var item: SidebarItem
  @State private var actions = OperationActions()
  @State private var operations = OperationsScreenState()

  static let scene = "section"

  init(deps: AppDependencies, value: SectionWindowValue?) {
    self.deps = deps
    _item = State(initialValue: value?.item ?? .section(.overview))
  }

  private var environment: AppEnvironment { deps.environment }

  var body: some View {
    content
      .frame(minWidth: 640, minHeight: 480)
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .navigation) {
          Picker(selection: sectionBinding) {
            ForEach(MainWindow.Section.allCases) { section in
              Label(environment.language(section.titleKey), systemImage: section.symbol)
                .tag(section)
            }
          } label: {
            Text(verbatim: environment.language("mac.window.section", table: MacCommands.table))
          }
          .accessibilityIdentifier("sectionWindow.section")
        }
      }
      .background { Color.clear.appWindow(.secondary(scene: Self.scene)) }
  }

  private var sectionBinding: Binding<MainWindow.Section> {
    Binding(
      get: {
        if case .section(let section) = item { return section }
        return .overview
      },
      set: { item = .section($0) })
  }

  private var title: String {
    switch item {
    case .section(let section): return environment.language(section.titleKey)
    case .account(let id), .group(let id), .bank(let id):
      return deps.compute.snapshot?.dataset.paymentMethods.first { $0.id == id }?.name
        ?? deps.compute.snapshot?.dataset.banks.first { $0.id == id }?.name
        ?? environment.language("mac.window.accounts", table: MacCommands.table)
    case .allAccounts:
      return environment.language("mac.window.accounts", table: MacCommands.table)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch environment.state {
    case .starting, .failed:
      ProgressView()
    case .ready:
      switch item {
      case .section(.overview): OverviewView(actions: actions)
      case .section(.operations): OperationsScreen(deps: deps, actions: actions, state: operations)
      case .section(.planning): PlanningView()
      case .section(.debts): DebtsView()
      case .section(.calendar): CalendarView(actions: actions)
      case .section(.capital): CapitalView { item = .account($0) }
      case .section(.purchases): PurchasesScreen()
      case .account(let id): AccountScreen(accountId: id, actions: actions).id(id)
      case .group(let id):
        GroupScreen(scope: .group(id), actions: actions) { item = .account($0) }.id(id)
      case .bank(let id): BankScreen(bankId: id).id(id)
      case .allAccounts: GroupScreen(scope: .summary, actions: actions) { item = .account($0) }
      }
    }
  }
}

/// What the main window on screen shows, for the command that opens it in a window of its own.
struct SidebarSelectionKey: FocusedValueKey {
  typealias Value = SidebarItem
}

extension FocusedValues {
  var sidebarSelection: SidebarItem? {
    get { self[SidebarSelectionKey.self] }
    set { self[SidebarSelectionKey.self] = newValue }
  }
}

/// «Окно → Открыть в новом окне» (⌥⌘N): what the main window in front shows, in a window of its
/// own.
struct SectionWindowCommands: Commands {
  let environment: AppEnvironment
  @FocusedValue(\.sidebarSelection) private var selection
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(before: .windowList) {
      Button(environment.language("mac.window.open", table: MacCommands.table)) {
        openWindow(
          id: SectionWindow.scene, value: SectionWindowValue(selection ?? .section(.overview)))
      }
      .keyboardShortcut("n", modifiers: [.command, .option])
      .disabled(selection == nil)
      Divider()
    }
  }
}
