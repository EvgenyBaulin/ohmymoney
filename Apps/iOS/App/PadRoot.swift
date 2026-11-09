import AppCore
import SwiftUI

/// The iPad: the sidebar of the Mac (the sections, the accounts and «Настройки» at the foot)
/// beside the screen of what is chosen, in a system `NavigationSplitView`. Wider than 1100 pt the
/// panel stays and a button hides it; from 600 to 1100 pt it comes over the content; narrower
/// than that it is the first screen and a section opens with a way back (`PadLayout`). What the
/// phone keeps in «Ещё» besides the sections — the tools, the receipt by QR, the lessons, the
/// folder of copies, privacy — is one button of the panel's foot, a sheet.
struct PadRoot<Entry: View>: View {
  let deps: AppDependencies
  let session: AppSession
  let lock: AppLock
  let router: PhoneRouter
  let actions: OperationActions
  let operations: OperationsScreenState
  let overviewScreen: OverviewScreen
  let width: CGFloat
  /// The form of a new operation is docked at the right of the window, beside this.
  var besideTheForm = false
  /// The entry bar of the screen on view; the argument is the tab that hosts its line.
  let entry: (PhoneTab) -> Entry

  @State private var visibility: NavigationSplitViewVisibility = .all
  @State private var compactColumn: NavigationSplitViewColumn = .detail
  @State private var accounts = AccountsSidebarModel()
  @State private var accountSelection: SidebarItem = .allAccounts
  @State private var showsTools = false

  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.appTheme) private var theme

  private var environment: AppEnvironment { deps.environment }
  private var mode: PadSidebarMode { PadLayout.mode(forWidth: Double(width)) }

  /// Where the screen on view is, for the moments the panel gives way to it.
  private var place: PhoneRoute {
    PhoneRoute(
      tab: router.tab, more: router.morePath.last,
      account: router.tab == .accounts ? accountSelection : nil)
  }

  var body: some View {
    Group {
      if router.showsSettingsScreen {
        PadSettingsScreen(deps: deps) { router.open(pad: .overview) }
      } else {
        split
      }
    }
    .environment(
      \.overviewColumnsOverride,
      PadLayout.overviewColumns(forWidth: Double(width), besideTheForm: besideTheForm))
    .sheet(isPresented: $showsTools) {
      PadToolsSheet(deps: deps, session: session, lock: lock, router: router) {
        showsTools = false
      }
      .appDependencies(deps)
    }
  }

  // MARK: Split view

  private var split: some View {
    NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
      sidebar
    } detail: {
      NavigationStack { page }
    }
    .modifier(PadSplitStyle(permanent: mode == .permanent))
    .onChange(of: mode, initial: true) { _, mode in
      visibility = mode == .permanent ? .all : .detailOnly
      compactColumn = mode == .firstScreen ? .sidebar : .detail
    }
    // A section asked for from anywhere (a notification, a link in a card) takes the screen:
    // an overlay panel goes away, the first screen gives way to it.
    .onChange(of: place) { _, _ in showDetail() }
  }

  private func showDetail() {
    if mode != .permanent { visibility = .detailOnly }
    compactColumn = .detail
  }

  // MARK: Sidebar

  private var sidebar: some View {
    List(selection: accountList) {
      Section {
        ForEach(PadSection.allCases) { section in sectionRow(section) }
      }
      if environment.state == .ready {
        AccountsSidebarSection(model: accounts, selection: $accountSelection)
      }
    }
    .accountsSidebarPresentations(accounts, selection: $accountSelection)
    .navigationSplitViewColumnWidth(PadLayout.sidebarWidth)
    .navigationTitle(Text(verbatim: "OhMyMoney"))
    .safeAreaInset(edge: .bottom, spacing: 0) { foot }
    .onChange(of: accountSelection) { _, new in
      if router.tab != .accounts || router.accountsSelection != nil { router.open(item: new) }
    }
    .onChange(of: router.accountsSelection, initial: true) { _, asked in
      guard let asked else { return }
      accountSelection = asked
      router.accountsSelection = nil
    }
  }

  /// The list's own selection belongs to the accounts; the sections are buttons that light by
  /// the router, as on the Mac.
  private var accountList: Binding<SidebarItem?> {
    Binding(
      get: { router.tab == .accounts ? accountSelection : nil },
      set: { chosen in
        guard let chosen else { return }
        accountSelection = chosen
        router.open(item: chosen)
        showDetail()
      })
  }

  private func sectionRow(_ section: PadSection) -> some View {
    let lit = SidebarHighlight(isSelected: router.padSection == section)
    return Button {
      router.open(pad: section)
      showDetail()
    } label: {
      Label {
        Text(verbatim: environment.language(section.titleKey))
      } icon: {
        Image(systemName: section.symbol)
      }
      .foregroundStyle(lit.text(theme))
      .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .listRowBackground(
      RoundedRectangle(cornerRadius: 8).fill(lit.plate(theme)).padding(.horizontal, 4)
    )
    .accessibilityAddTraits(lit.isSelected ? [.isSelected] : [])
    .accessibilityIdentifier("sidebar.\(section.rawValue)")
  }

  /// «Настройки» at the foot of the panel, and the button of the tools beside it.
  private var foot: some View {
    VStack(spacing: 0) {
      Divider()
      HStack {
        Button {
          router.open(screen: .settings)
        } label: {
          Label {
            Text(verbatim: environment.language("settings.title", table: "Settings"))
          } icon: {
            Image(systemName: "gearshape")
          }
        }
        .accessibilityIdentifier("sidebar.settings")
        Spacer()
        Button {
          showsTools = true
        } label: {
          Image(systemName: "ellipsis.circle")
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(Text(verbatim: environment.language("phone.tab.more", table: "Phone")))
        .accessibilityIdentifier("sidebar.tools")
      }
      .buttonStyle(.plain)
      .foregroundStyle(surfaces.primary)
      .padding(.horizontal, 16)
      .padding(.vertical, 4)
    }
  }

  // MARK: Screens

  @ViewBuilder
  private var page: some View {
    switch router.tab {
    case .overview: overviewPage
    case .operations:
      sectionPage("section.operations") {
        OperationsScreen(deps: deps, actions: actions, state: operations)
      }
    case .planning:
      sectionPage("section.planning") { PlanningView() }
    case .accounts:
      accountPage
    case .more:
      if let destination = router.morePath.last {
        MoreDestinationScreen(
          deps: deps, router: router, actions: actions, destination: destination
        ) { entry(router.padEntryHost) }
        .phoneToolbar(deps: deps, router: router)
        .appDependencies(deps)
      } else {
        overviewPage
      }
    }
  }

  private func sectionPage<Content: View>(
    _ titleKey: String, @ViewBuilder content: () -> Content
  ) -> some View {
    PhoneContent(deps: deps, actions: actions, content: content) { entry(router.tab) }
      .navigationTitle(environment.language(titleKey))
      .navigationBarTitleDisplayMode(.inline)
      .phoneToolbar(deps: deps, router: router)
  }

  /// Overview keeps the large title of the design with «Изменить» on its row, scrolling with the
  /// tiles; the navigation bar above holds the button of the panel and the tools.
  private var overviewPage: some View {
    PhoneContent(
      deps: deps, actions: actions,
      content: { OverviewView(actions: actions, screen: overviewScreen) },
      entry: { entry(.overview) }
    )
    .environment(\.overviewEditsInChrome, true)
    .environment(
      \.overviewTitleRow,
      OverviewTitleRow(
        title: environment.language("section.overview"),
        trailing: AnyView(
          OverviewTitleActions(deps: deps, router: router, screen: overviewScreen)))
    )
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(removing: .title)
  }

  /// The account, group or bank chosen in the panel, with the entry bar below.
  private var accountPage: some View {
    PhoneContent(deps: deps, actions: actions) {
      accountContent
    } entry: {
      entry(.accounts)
    }
    .navigationTitle(environment.language("accounts.section.accounts", table: "Accounts"))
    .navigationBarTitleDisplayMode(.inline)
    .phoneToolbar(deps: deps, router: router)
  }

  @ViewBuilder
  private var accountContent: some View {
    switch accountSelection {
    case .account(let id):
      AccountScreen(accountId: id, actions: actions).id(id)
    case .group(let id):
      GroupScreen(scope: .group(id), actions: actions) { accountSelection = .account($0) }.id(id)
    case .bank(let id):
      BankScreen(bankId: id).id(id)
    default:
      GroupScreen(scope: .summary, actions: actions) { accountSelection = .account($0) }
    }
  }
}

/// The balanced style keeps the permanent panel beside the content; the prominent one lets the
/// panel of a narrower window come over it.
private struct PadSplitStyle: ViewModifier {
  let permanent: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if permanent {
      content.navigationSplitViewStyle(.balanced)
    } else {
      content.navigationSplitViewStyle(.prominentDetail)
    }
  }
}

/// The settings of an iPad: a screen of their own with a sidebar of their own (300 pt), the way
/// back at its top, and the section chosen beside it.
struct PadSettingsScreen: View {
  let deps: AppDependencies
  let back: () -> Void

  @State private var selection: SettingsSection? = .general
  @State private var compactColumn: NavigationSplitViewColumn = .detail
  @Environment(\.appTheme) private var theme

  private var environment: AppEnvironment { deps.environment }
  private var list: PhoneSettingsList { PhoneSettingsList(deps: deps) }

  var body: some View {
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      // No list selection: it would paint the system highlight over the theme's plate.
      List {
        ForEach(SettingsSection.allCases, id: \.self) { section in
          let lit = SidebarHighlight(isSelected: selection == section)
          Button {
            selection = section
          } label: {
            Label {
              Text(verbatim: environment.language(section.titleKey, table: "Settings"))
            } icon: {
              Image(systemName: section.symbol)
            }
            .foregroundStyle(lit.text(theme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .listRowBackground(
            RoundedRectangle(cornerRadius: 8).fill(lit.plate(theme)).padding(.horizontal, 4)
          )
          .accessibilityAddTraits(lit.isSelected ? [.isSelected] : [])
        }
      }
      .navigationSplitViewColumnWidth(PadLayout.settingsSidebarWidth)
      .navigationTitle(Text(verbatim: environment.language("settings.title", table: "Settings")))
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: back) {
            Label {
              Text(verbatim: environment.language("nav.pad.back", table: "Navigation"))
            } icon: {
              Image(systemName: "chevron.backward")
            }
          }
          .accessibilityIdentifier("settings.back")
        }
      }
      .onChange(of: selection) { _, new in if new != nil { compactColumn = .detail } }
    } detail: {
      NavigationStack {
        if let selection {
          list.content(of: selection)
            .navigationTitle(environment.language(selection.titleKey, table: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .id(selection)
        }
      }
      .appDependencies(deps)
    }
    .navigationSplitViewStyle(.balanced)
  }
}

/// What the phone keeps in «Ещё» and the sidebar does not carry: «Что если…», the trip, the
/// reconciliation, the conflicts, the guide, the report of a problem, and under them the receipt
/// by QR, the lessons, the set of data, the folder of copies and privacy.
struct PadToolsSheet: View {
  let deps: AppDependencies
  let session: AppSession
  let lock: AppLock
  let router: PhoneRouter
  let close: () -> Void

  private var environment: AppEnvironment { deps.environment }

  private var rows: [MoreRow] {
    PadLayout.tools(
      tripIsOn: environment.tripEntryDefaults != nil,
      hasConflicts: !(environment.sync?.conflicts.isEmpty ?? true))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          ForEach(rows) { row in
            Button {
              perform(row)
              close()
            } label: {
              Label {
                Text(verbatim: title(of: row))
              } icon: {
                Image(systemName: row.symbol)
              }
            }
          }
        }
        MoreExtrasSections(deps: deps, session: session, lock: lock)
      }
      .navigationTitle(environment.language("phone.tab.more", table: "Phone"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(environment.language("action.close"), action: close)
        }
      }
    }
  }

  private func title(of row: MoreRow) -> String {
    switch row {
    case .section(let item):
      environment.language(item.titleKey, table: item.titleTable ?? "Common")
    case .purchases: environment.language("section.purchases")
    case .whatIf: environment.language("window.whatIf")
    case .trip: environment.language("nav.more.trip", table: "Navigation")
    case .reconcile: environment.language("action.reconcile")
    case .settings: environment.language("settings.title", table: "Settings")
    case .conflicts: environment.language("sync.conflicts.title", table: "Sync")
    case .tour: environment.language("guide.menu.tour", table: "Guide")
    case .whatsNew: environment.language("guide.menu.whatsNew", table: "Guide")
    case .problemReport: environment.language("report.title", table: "Settings")
    }
  }

  private func perform(_ row: MoreRow) {
    switch row {
    case .section(let item): router.open(nav: item)
    case .purchases: router.open(pad: .purchases)
    case .whatIf: router.open(screen: .whatIf)
    case .trip: environment.showsTrip = true
    case .reconcile: environment.showsReconciliation = true
    case .settings: router.open(screen: .settings)
    case .conflicts: router.open(PhoneRoute(tab: .more, more: .conflicts))
    case .tour: GuideStore.shared.show(GuideCatalog.firstLaunch)
    case .whatsNew:
      if let latest = GuideCatalog.whatsNew.last { GuideStore.shared.show(latest) }
    case .problemReport: environment.showsProblemReport = true
    }
  }
}
