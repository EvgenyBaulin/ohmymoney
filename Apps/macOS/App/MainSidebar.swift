import SwiftUI

/// What the sidebar of the main window has chosen: one of its sections, an account or a group
/// of accounts.
enum SidebarItem: Hashable, Sendable {
  case section(MainWindow.Section)
  case account(UUID)
  case group(UUID)
  /// «Всего»: every account of the summary, as one screen of a group.
  case allAccounts

  var section: MainWindow.Section? {
    if case .section(let section) = self { return section }
    return nil
  }

  /// The account whose screen is open: the entry line puts a new operation on it.
  var focusedAccountId: UUID? {
    if case .account(let id) = self { return id }
    return nil
  }

  /// The word the journal writes for what is on screen: the name of a section, or «account» /
  /// «group» — never the name of an account.
  var journalToken: String {
    switch self {
    case .section(let section): section.rawValue
    case .account: "account"
    case .group: "group"
    case .allAccounts: "accounts"
    }
  }

  /// A screen of operations: «Операции» and the screens of an account and of a group list them,
  /// select them and float the selection bar.
  var listsOperations: Bool {
    switch self {
    case .section(let section): section == .operations
    case .account, .group, .allAccounts: true
    }
  }

  /// Where the window goes back to when what was chosen is gone: an account or a group
  /// archived, merged away or deleted, from here or from the settings. `nil` keeps the choice.
  /// `liveAccounts` and `liveGroups` are what the sidebar lists.
  func fallback(liveAccounts: Set<UUID>, liveGroups: Set<UUID>) -> SidebarItem? {
    switch self {
    case .section, .allAccounts: nil
    case .account(let id): liveAccounts.contains(id) ? nil : .section(.overview)
    case .group(let id): liveGroups.contains(id) ? nil : .section(.overview)
    }
  }
}

#if os(macOS)
  /// The sidebar of the main window: its sections, chosen by a click or by ⌘1 … ⌘6,
  /// whose menu items, and the limits card of Overview, post `.selectSection` with the number of
  /// the section; and under them the accounts and their groups (`AccountsSidebarSection`).
  struct MainSidebar: View {
    @Dependency(\.environment) private var environment
    @Binding var selection: SidebarItem
    /// The sheets, questions and refusals of the accounts, presented from the list itself: the
    /// rows are redrawn with every change of the data, and a sheet hung on one would go with it.
    @State private var accounts = AccountsSidebarModel()

    var body: some View {
      List(selection: $selection) {
        Section {
          ForEach(MainWindow.Section.allCases) { item in
            Label {
              Text(verbatim: environment.language(item.titleKey))
            } icon: {
              Image(systemName: item.symbol)
            }
            .tag(SidebarItem.section(item))
            .accessibilityIdentifier("sidebar.\(item.rawValue)")
            .guideTarget("sidebar.\(item.rawValue)")
          }
        }
        if environment.state == .ready {
          AccountsSidebarSection(model: accounts, selection: $selection)
        }
      }
      .accountsSidebarPresentations(accounts, selection: $selection)
      .guideOverlay(GuideStore.shared)
      .onReceive(NotificationCenter.default.publisher(for: .selectSection)) { note in
        guard let index = note.object as? Int,
          let chosen = MainWindow.Section.allCases.first(where: { $0.shortcutIndex == index })
        else { return }
        selection = .section(chosen)
      }
      // «Открыть «Всего»» of a breakdown of Overview, and any other place that names an item of
      // the sidebar itself rather than a section by its number.
      .onReceive(NotificationCenter.default.publisher(for: .openSidebarItem)) { note in
        guard let item = note.object as? SidebarItem else { return }
        selection = item
      }
    }
  }

#endif

extension Notification.Name {
  /// Chooses an item of the sidebar of the main window; the object is the `SidebarItem`.
  static let openSidebarItem = Notification.Name("io.github.EvgenyBaulin.ohmymoney.openSidebarItem")
}

/// The way into «Операции» from outside the sidebar: ⌘⇧T, ⌘F, the button of the toolbar and the
/// reconciliation's «look for the missing operations». There is no window of Transactions any
/// more: the main window comes forward on its screen of operations.
@MainActor
enum OperationsScreenOpening {
  static func open(with openWindow: OpenWindowAction) {
    // Closing the main window quits the app, so it is there; a test host may have none.
    #if os(macOS)
      if !choose(), !AppEnvironment.isTestHost { openWindow(id: "main") }
    #else
      choose()
    #endif
  }

  /// Every main window shows «Операции», and the main window comes forward. Whether there was
  /// one to bring.
  @discardableResult
  static func choose() -> Bool {
    NotificationCenter.default.post(
      name: .openSidebarItem, object: SidebarItem.section(.operations))
    #if os(macOS)
      return AppWindows.bringForward(.main) != nil
    #else
      return true
    #endif
  }
}
