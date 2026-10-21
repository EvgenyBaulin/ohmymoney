import AppCore
import SwiftUI

/// The tabs of the phone: Overview, Operations, Planning, Accounts and More. The same shared
/// screens the Mac window shows, in a `NavigationStack` each; on an iPad they simply get more
/// room (no layout of its own). The entry bar floats over the bottom of the first four, as it
/// floats over the Mac window. What the Mac opens as a window of its own — Analytics, Reports,
/// «Что если…» — covers the tabs here, and the shared screens ask for it the way they ask the
/// Mac window: by notification (`PhoneRouter`).
struct PhoneRoot: View {
  let deps: AppDependencies
  let session: AppSession
  let lock: AppLock

  @State private var router = PhoneRouter()
  @State private var actions = OperationActions()
  @State private var operations = OperationsScreenState()
  @State private var width: CGFloat = 0

  private var environment: AppEnvironment { deps.environment }
  private var guide: GuideStore { GuideStore.shared }

  var body: some View {
    TabView(selection: $router.tab) {
      page(.overview, titleKey: "section.overview", symbol: "chart.pie") {
        OverviewView(actions: actions)
      }
      page(.operations, titleKey: "section.operations", symbol: "list.bullet.rectangle") {
        OperationsScreen(deps: deps, actions: actions, state: operations)
      }
      page(.planning, titleKey: "section.planning", symbol: "calendar") {
        PlanningView()
      }
      AccountsTab(deps: deps, router: router, actions: actions, entry: { entryBar })
        .tabItem {
          Label(
            environment.language("accounts.section.accounts", table: "Accounts"),
            systemImage: "building.columns")
        }
        .tag(PhoneTab.accounts)
      MoreTab(deps: deps, session: session, lock: lock, router: router, actions: actions)
        .tabItem {
          Label(
            environment.language("phone.tab.more", table: "Phone"), systemImage: "ellipsis.circle")
        }
        .tag(PhoneTab.more)
    }
    .environment(\.windowWidth, width)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .modifier(PhoneRequests(router: router))
    .modifier(PhoneSheets(deps: deps, router: router))
    .modifier(PhoneLaunch(deps: deps, router: router))
    .onChange(of: deps.compute.generation, initial: true) { _, _ in
      if let dataset = deps.compute.snapshot?.dataset { guide.check(dataset) }
    }
  }

  /// A tab with a stack of its own, the toolbar of the phone and the entry bar at the bottom.
  private func page<Content: View>(
    _ tag: PhoneTab, titleKey: String, symbol: String, @ViewBuilder content: () -> Content
  ) -> some View {
    NavigationStack {
      PhoneContent(deps: deps, actions: actions, content: content) { entryBar }
        .navigationTitle(environment.language(titleKey))
        .navigationBarTitleDisplayMode(.inline)
        .phoneToolbar(deps: deps, router: router)
    }
    .tabItem { Label(environment.language(titleKey), systemImage: symbol) }
    .tag(tag)
  }

  @ViewBuilder
  private var entryBar: some View {
    EntryBar(windowWidth: width, detailWidth: width, operations: actions) {
      SelectionBar(actions: actions)
    }
  }
}

/// What the shared screens ask of the window by notification: a section by its number, an item of
/// the sidebar, a window of the Mac. The phone goes where `PhoneNavigation` says.
struct PhoneRequests: ViewModifier {
  let router: PhoneRouter

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .selectSection)) { note in
        if let index = note.object as? Int { router.open(shortcutIndex: index) }
      }
      .onReceive(NotificationCenter.default.publisher(for: .openSidebarItem)) { note in
        if let item = note.object as? SidebarItem { router.open(item: item) }
      }
      .onReceive(NotificationCenter.default.publisher(for: .openAppScreen)) { note in
        if let screen = note.object as? AppScreen { router.open(screen: screen) }
      }
      // ↓ in the entry line over a screen without a list: «Операции» takes it.
      .onReceive(NotificationCenter.default.publisher(for: .walkOperationsList)) { _ in
        if router.tab != .operations && router.tab != .accounts && router.tab != .overview {
          router.open(section: .operations)
        }
      }
  }
}

/// The sheets the Mac main window hangs on its root — the reconciliation, «Я в поездке», the
/// report of a problem — and the covers that stand for its secondary windows.
struct PhoneSheets: ViewModifier {
  let deps: AppDependencies
  let router: PhoneRouter

  private var environment: AppEnvironment { deps.environment }

  func body(content: Content) -> some View {
    content
      // Sheets are laid out by hosts of their own: they get the dependencies handed over, and
      // none stays over the cover of the locked app.
      .sheet(
        isPresented: environment.lock.presenting(
          Binding(
            get: { environment.showsReconciliation },
            set: { environment.showsReconciliation = $0 }))
      ) {
        ReconcileSheet().appDependencies(deps)
      }
      .sheet(
        isPresented: environment.lock.presenting(
          Binding(get: { environment.showsTrip }, set: { environment.showsTrip = $0 }))
      ) {
        TripStartSheet().appDependencies(deps)
      }
      .sheet(
        isPresented: environment.lock.presenting(
          Binding(
            get: { environment.showsProblemReport },
            set: { environment.showsProblemReport = $0 }))
      ) {
        ProblemReportSheet(height: 380).appDependencies(deps)
      }
      .fullScreenCover(
        item: environment.lock.presenting(
          Binding(get: { router.cover }, set: { router.cover = $0 }))
      ) { screen in
        PhoneCover(screen: screen, deps: deps) { router.closeCover() }
      }
  }
}

extension AppScreen: Identifiable {
  var id: String { rawValue }
}

/// A secondary window of the Mac, as a cover with its way out.
struct PhoneCover: View {
  let screen: AppScreen
  let deps: AppDependencies
  let close: () -> Void

  var body: some View {
    let environment = deps.environment
    VStack(spacing: 0) {
      HStack {
        Text(verbatim: environment.language(titleKey))
          .appFont(.headline)
        Spacer()
        Button(environment.language("action.close"), action: close)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      Divider()
      switch screen {
      case .analytics: AnalyticsWindow(deps: deps)
      case .reports: ReportsWindow(deps: deps)
      case .whatIf: WhatIfWindow(deps: deps)
      case .settings: EmptyView()
      }
    }
    .appDependencies(deps)
  }

  private var titleKey: String {
    switch screen {
    case .analytics: "window.analytics"
    case .reports: "window.reports"
    case .whatIf: "window.whatIf"
    case .settings: "settings.title"
    }
  }
}

/// What a tab shows once the database is there: the screen with the presentations of the
/// operations on it and the entry bar below; the wait or the failure before that. The strip of
/// the tutorial and the one of the trip stand over it, as they stand over the Mac window.
struct PhoneContent<Content: View, Entry: View>: View {
  let deps: AppDependencies
  let actions: OperationActions
  @ViewBuilder let content: Content
  @ViewBuilder let entry: Entry

  init(
    deps: AppDependencies, actions: OperationActions,
    @ViewBuilder content: () -> Content, @ViewBuilder entry: () -> Entry
  ) {
    self.deps = deps
    self.actions = actions
    self.content = content()
    self.entry = entry()
  }

  var body: some View {
    switch deps.environment.state {
    case .starting:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let failure):
      DatabaseFailureView(failure: failure, deps: deps)
    case .ready:
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
          VStack(spacing: 0) {
            if GuideStore.shared.isTutorial { TutorialBar(guide: GuideStore.shared) }
            TripBanner()
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { entry }
        .coordinateSpace(.named(OperationActions.coordinateSpace))
        .operationPresentations(actions)
    }
  }
}

extension View {
  /// Undo, the eye that hides the amounts, a new calculation, and a menu of what the Mac's toolbar
  /// holds: the buttons of the phone.
  func phoneToolbar(deps: AppDependencies, router: PhoneRouter) -> some View {
    modifier(PhoneToolbar(deps: deps, router: router))
  }
}

struct PhoneToolbar: ViewModifier {
  let deps: AppDependencies
  let router: PhoneRouter

  func body(content: Content) -> some View {
    let environment = deps.environment
    content.toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          deps.store.undo()
        } label: {
          Label {
            Text(verbatim: environment.language("action.undo"))
          } icon: {
            Image(systemName: "arrow.uturn.backward")
          }
        }
        .disabled(!deps.store.canUndo)
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          environment.amounts.toggle()
        } label: {
          Label {
            Text(verbatim: PrivacyCommands.amountsTitle(environment))
          } icon: {
            Image(systemName: environment.amounts.hidesAmounts ? "eye" : "eye.slash")
          }
        }
        Button {
          deps.compute.run()
        } label: {
          Label {
            Text(verbatim: environment.language("action.recompute"))
          } icon: {
            Image(systemName: "arrow.clockwise")
          }
        }
        Menu {
          Button {
            environment.showsReconciliation = true
          } label: {
            Label {
              Text(verbatim: environment.language("action.reconcile"))
            } icon: {
              Image(systemName: "checkmark.seal")
            }
          }
          Button {
            environment.showsTrip = true
          } label: {
            Label {
              Text(verbatim: TravelText.t("travel.start.button", environment))
            } icon: {
              Image(systemName: "airplane")
            }
          }
          Button {
            router.open(screen: .analytics)
          } label: {
            Label {
              Text(verbatim: environment.language("window.analytics"))
            } icon: {
              Image(systemName: "chart.xyaxis.line")
            }
          }
          Button {
            router.open(screen: .reports)
          } label: {
            Label {
              Text(verbatim: environment.language("window.reports"))
            } icon: {
              Image(systemName: "tablecells")
            }
          }
        } label: {
          Label {
            Text(verbatim: environment.language("phone.tab.more", table: "Phone"))
          } icon: {
            Image(systemName: "ellipsis.circle")
          }
        }
      }
    }
  }
}
