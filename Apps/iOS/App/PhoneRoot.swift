import AppCore
import SwiftUI
import UIKit

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
  @State private var phoneTabs = PhoneTabsPreference.load()
  @State private var showsMore = false
  @State private var overviewScreen = OverviewScreen()
  /// Whether the entry line is up. By default it is not, and the keyboard with it.
  @State private var entryGate = PhoneEntryGate()
  /// The height of the bar of the sections at the bottom, for the «+» above it.
  @State private var barHeight: CGFloat = 0

  private var environment: AppEnvironment { deps.environment }
  private var guide: GuideStore { GuideStore.shared }

  private var layout: NavLayout {
    NavLayout.make(
      width: Double(width), isPad: UIDevice.current.userInterfaceIdiom == .pad,
      phoneTabs: phoneTabs)
  }

  private func title(_ item: NavItem) -> String {
    environment.language(item.titleKey, table: item.titleTable ?? "Common")
  }

  var body: some View {
    TabView(selection: $router.tab) {
      overviewPage
      page(.operations, titleKey: "section.operations", symbol: "list.bullet.rectangle") {
        OperationsScreen(deps: deps, actions: actions, state: operations)
      }
      page(.planning, titleKey: "section.planning", symbol: "calendar") {
        PlanningView()
      }
      AccountsTab(deps: deps, router: router, actions: actions, entry: { entryBar(.accounts) })
        .toolbarVisibility(.hidden, for: .tabBar)
        .tabItem {
          Label(
            environment.language("accounts.section.accounts", table: "Accounts"),
            systemImage: "building.columns")
        }
        .tag(PhoneTab.accounts)
      MoreTab(
        deps: deps, session: session, lock: lock, router: router, actions: actions,
        layout: layout, phoneTabs: $phoneTabs
      )
      .toolbarVisibility(.hidden, for: .tabBar)
      .tabItem {
        Label(
          environment.language("phone.tab.more", table: "Phone"), systemImage: "ellipsis.circle")
      }
      .tag(PhoneTab.more)
    }
    // The system bar is hidden on every tab (it must be said on the tab's own content, not on
    // the `TabView`): the bar of the app (`PhoneTabBar`, `PadTopBar`) takes its place.
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if layout.placement == .bottom {
        PhoneTabBar(
          layout: layout, router: router, title: title,
          moreTitle: environment.language("phone.tab.more", table: "Phone")
        )
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          barHeight = $0
        }
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if layout.placement == .top {
        PadTopBar(
          layout: layout, router: router, title: title,
          moreTitle: environment.language("phone.tab.more", table: "Phone"),
          showsMore: $showsMore
        ) {
          PadMoreList(deps: deps, layout: layout, router: router) { showsMore = false }
        }
      }
    }
    .environment(\.fadesOverNavBar, layout.placement == .bottom)
    .environment(\.phoneEntryGate, entryGate)
    // The round «+» that brings up the entry line: above the bar of a phone, in the corner of a
    // tablet. It is gone while the line is up and on the sections that have no line.
    .overlay(alignment: .bottomTrailing) {
      if entryGate.showsPlus, environment.state == .ready {
        PhoneEntryButton(
          gate: entryGate, title: environment.language("phone.entry.new", table: "Phone")
        )
        .padding(.trailing, PhoneEntryButton.sideMargin)
        .padding(
          .bottom,
          PhoneEntryButton.bottomPadding(placement: layout.placement, barHeight: barHeight)
        )
        .transition(.scale.combined(with: .opacity))
      }
    }
    // A section switched to puts the line away with its keyboard; none opens the keyboard.
    .onChange(of: router.tab, initial: true) { _, tab in entryGate.send(.tabChanged(tab)) }
    // ⌘N on a hardware keyboard: the line comes up with the keyboard.
    .background {
      Button("") {
        NotificationCenter.default.post(name: .focusEntryLine, object: nil)
      }
      .keyboardShortcut("n", modifiers: .command)
      .opacity(0)
      .accessibilityHidden(true)
    }
    .onChange(of: phoneTabs) { _, tabs in PhoneTabsPreference.save(tabs) }
    .environment(\.windowWidth, width)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .modifier(PhoneRequests(router: router))
    .modifier(PhoneSheets(deps: deps, router: router))
    // The palette, the question sheet and the saved views, as on the Mac.
    .questionsHost(deps: deps, operations: operations)
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
      PhoneContent(deps: deps, actions: actions, content: content) { entryBar(tag) }
        .navigationTitle(environment.language(titleKey))
        .navigationBarTitleDisplayMode(.inline)
        // On an iPad the bar of the app stands in the row of the title: the title would run under it.
        .toolbar(removing: layout.placement == .top ? .title : nil)
        .phoneToolbar(deps: deps, router: router)
    }
    .toolbarVisibility(.hidden, for: .tabBar)
    .tabItem { Label(environment.language(titleKey), systemImage: symbol) }
    .tag(tag)
  }

  /// Overview has the large title of the design with «Изменить» on its row, scrolling with the
  /// tiles (the navigation bar is hidden); undo, the eye, a new calculation and the rest of what
  /// the Mac's toolbar holds are one menu.
  private var overviewPage: some View {
    NavigationStack {
      PhoneContent(
        deps: deps, actions: actions,
        content: { OverviewView(actions: actions, screen: overviewScreen) },
        entry: { entryBar(.overview) }
      )
      .environment(\.overviewEditsInChrome, true)
      .environment(
        \.overviewTitleRow,
        OverviewTitleRow(
          title: environment.language("section.overview"),
          trailing: AnyView(
            OverviewTitleActions(deps: deps, router: router, screen: overviewScreen)))
      )
      // On a tablet the bar of the app floats in the row of the empty navigation bar, and the
      // title row starts under it; on a phone the bar is gone and the row starts at the top.
      .toolbarVisibility(layout.placement == .top ? .automatic : .hidden, for: .navigationBar)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar(removing: layout.placement == .top ? .title : nil)
    }
    .toolbarVisibility(.hidden, for: .tabBar)
    .tabItem {
      Label(environment.language("section.overview"), systemImage: "chart.pie")
    }
    .tag(PhoneTab.overview)
  }

  @ViewBuilder
  private func entryBar(_ tab: PhoneTab) -> some View {
    if environment.shield.isReadOnly {
      ReadOnlyStrip()
    } else {
      EntryBar(
        windowWidth: width, detailWidth: width, operations: actions,
        phone: PhoneEntryAccess(gate: entryGate, tab: tab)
      ) {
        SelectionBar(actions: actions)
      }
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
      .receiptSheet(deps)
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
  @Environment(\.fadesOverNavBar) private var fades
  @Environment(\.phoneEntryGate) private var entryGate

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
        // Over the bar of the phone the page fades out instead of ending in a hard edge.
        .overlay(alignment: .bottom) { if fades { NavBarFade() } }
        // A tap on the screen outside the line puts the line away, with its keyboard.
        .overlay {
          if entryGate?.isShown == true {
            Color.clear
              .contentShape(Rectangle())
              .onTapGesture { entryGate?.send(.tappedOutside) }
              .accessibilityHidden(true)
          }
        }
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

/// The navigation bar of Overview: «Изменить» (while editing «Готово») in words, and one round
/// menu with the rest — undo, the amounts, a new calculation, reconciliation, a trip, Analytics
/// and Reports.
struct OverviewTitleActions: View {
  let deps: AppDependencies
  let router: PhoneRouter
  let screen: OverviewScreen
  @Environment(\.themeSurfaces) private var surfaces

  var body: some View {
    let environment = deps.environment
    HStack(spacing: 12) {
      if screen.isEditing {
        Button(environment.language("overview.edit.done", table: "Overview")) { screen.done() }
          .fontWeight(.semibold)
          .accessibilityIdentifier("overview.edit.done")
      } else {
        Button(environment.language("overview.edit", table: "Overview")) { screen.edit() }
          .accessibilityIdentifier("overview.edit")
      }
      Group {
        Menu {
          Button {
            NotificationCenter.default.post(name: .showCommandPalette, object: nil)
          } label: {
            Label {
              Text(verbatim: QuestionsText.t("questions.menu.palette", environment))
            } icon: {
              Image(systemName: "command")
            }
          }
          Button {
            NotificationCenter.default.post(name: .showQuestionSheet, object: nil)
          } label: {
            Label {
              Text(verbatim: QuestionsText.t("questions.sheet.title", environment))
            } icon: {
              Image(systemName: "questionmark.bubble")
            }
          }
          Divider()
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
          Divider()
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
          // The round button of the design: the card colour, a hairline, 44 pt to touch.
          Image(systemName: "ellipsis")
            .appFont(.body)
            .foregroundStyle(surfaces.primary)
            .frame(width: 44, height: 44)
            .background(surfaces.card, in: .circle)
            .overlay { Circle().strokeBorder(surfaces.cardBorder, lineWidth: 0.5) }
            .accessibilityLabel(
              Text(verbatim: environment.language("phone.tab.more", table: "Phone")))
        }
      }
    }
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
        // The palette of commands and the question, a sheet on the phone.
        Button {
          NotificationCenter.default.post(name: .showCommandPalette, object: nil)
        } label: {
          Label {
            Text(verbatim: QuestionsText.t("questions.menu.palette", environment))
          } icon: {
            Image(systemName: "command")
          }
        }
        .accessibilityIdentifier("toolbar.palette")
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
