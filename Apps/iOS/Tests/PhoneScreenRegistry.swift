import AppCore
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// A modal screen the phone's root or «Ещё» opens from a row or a button, listed by hand: a
/// sheet cannot be enumerated from the navigation. `PhonePresentationBaseline` makes a new
/// sheet anywhere in the sources fail a test until it is looked at and listed here or there.
enum PhoneSheet: String, CaseIterable, Hashable {
  case reconciliation, trip, problemReport, tabsEditor
}

/// Every screen of the iPhone, built from the enumerations the navigation itself is made of:
/// the tabs, what «Ещё» pushes, the sections of the settings, and the sheets. A new tab,
/// destination or settings section changes `all` by itself, and `PhoneScreenRegistry.open`
/// has no `default`, so a new case does not compile until it says how to be shown.
enum PhoneScreen: Hashable, CustomStringConvertible {
  case tab(PhoneTab)
  case more(MoreDestination)
  case setting(SettingsSection)
  case sheet(PhoneSheet)

  static var all: [PhoneScreen] {
    PhoneTab.allCases.map(PhoneScreen.tab)
      + MoreDestination.allCases.map(PhoneScreen.more)
      + SettingsSection.allCases.map(PhoneScreen.setting)
      + PhoneSheet.allCases.map(PhoneScreen.sheet)
  }

  var description: String {
    switch self {
    case .tab(let tab): "tab.\(tab.rawValue)"
    case .more(let destination): "more.\(destination)"
    case .setting(let section): "settings.\(section.rawValue)"
    case .sheet(let sheet): "sheet.\(sheet.rawValue)"
    }
  }

  /// The screen a row of «Ещё» leads to, or nil for a row that only does something (the tour).
  /// Exhaustive on purpose: a new row must say where it goes.
  static func screen(of row: MoreRow) -> PhoneScreen? {
    switch row {
    case .section(let item):
      if let destination = item.moreDestination { return .more(destination) }
      switch item {
      case .overview: return .tab(.overview)
      case .operations: return .tab(.operations)
      case .planning: return .tab(.planning)
      case .accounts: return .tab(.accounts)
      case .goals: return .tab(.planning)
      case .calendar, .capital, .debts, .analytics, .reports: return nil
      }
    case .summaries: return .more(.summaries)
    case .purchases: return .more(.purchases)
    case .whatIf: return .more(.whatIf)
    case .settings: return .more(.settings)
    case .conflicts: return .more(.conflicts)
    case .trip: return .sheet(.trip)
    case .reconcile: return .sheet(.reconciliation)
    case .problemReport: return .sheet(.problemReport)
    case .tour, .whatsNew: return nil
    }
  }
}

/// A screen on show: its window, and the view whose tree is its own (a sheet's, or the window).
struct PhoneScreenShown {
  let window: UIWindow
  let content: UIView
  /// Whether the bar of the sections and the round «+» stand in it.
  let hasShell: Bool
}

/// The shell of the phone around one page, as `PhoneRoot` builds it: the floating bar of the
/// sections under the page, the round «+» above the bar, the fade over the page's bottom edge.
/// `PhoneRoot` itself is not hosted: its `TabView` lays itself out for the simulator's screen
/// and not for the window the test makes, which shifts every page by the width of a side bar a
/// phone does not have. The pieces are the app's own (`PhoneTabBar`, `PhoneEntryButton`,
/// `PhoneContent`, `phoneToolbar`).
private struct PhoneShellHost<Page: View>: View {
  let deps: AppDependencies
  let router: PhoneRouter
  let width: CGFloat
  @ViewBuilder let page: Page

  @State private var gate = PhoneEntryGate()
  @State private var barHeight: CGFloat = 0

  var body: some View {
    let environment = deps.environment
    let layout = NavLayout.make(
      width: Double(width), isPad: false, phoneTabs: NavItem.defaultPhoneTabs)
    page
      .environment(\.fadesOverNavBar, true)
      .environment(\.phoneEntryGate, gate)
      .environment(\.windowWidth, width)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        PhoneTabBar(
          layout: layout, router: router,
          title: { environment.language($0.titleKey, table: $0.titleTable ?? "Common") },
          moreTitle: environment.language("phone.tab.more", table: "Phone")
        )
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          barHeight = $0
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if PhoneEntryState.hostsEntry(router.tab) {
          PhoneEntryButton(
            gate: gate, title: environment.language("phone.entry.new", table: "Phone")
          )
          .padding(.trailing, PhoneEntryButton.sideMargin)
          .padding(
            .bottom,
            PhoneEntryButton.bottomPadding(placement: layout.placement, barHeight: barHeight))
        }
      }
  }
}

/// The sheets the phone's root hangs on its content, over an empty page.
private struct PhoneSheetsHost: View {
  let deps: AppDependencies

  var body: some View {
    Color.clear.modifier(PhoneSheets(deps: deps, router: PhoneRouter()))
  }
}

@MainActor
enum PhoneScreenRegistry {
  /// A tab or a page of «Ещё» inside the shell, with the router at the place of the screen.
  private static func shelled(
    tab: PhoneTab, more: MoreDestination? = nil, harness: PhoneHarness, size: CGSize, dark: Bool,
    idiom: LayoutIdiom
  ) -> PhoneScreenShown {
    let deps = harness.deps
    let environment = harness.environment
    let router = PhoneRouter()
    router.tab = tab
    if let more { router.morePath = [more] }
    let actions = OperationActions()
    let page: AnyView
    switch tab {
    case .overview:
      let screen = OverviewScreen()
      page = AnyView(
        NavigationStack {
          PhoneContent(
            deps: deps, actions: actions,
            content: { OverviewView(actions: actions, screen: screen) },
            entry: { EmptyView() }
          )
          .environment(\.overviewEditsInChrome, true)
          .environment(
            \.overviewTitleRow,
            OverviewTitleRow(
              title: environment.language("section.overview"),
              trailing: AnyView(OverviewTitleActions(deps: deps, router: router, screen: screen)))
          )
          .toolbarVisibility(.hidden, for: .navigationBar)
          .navigationBarTitleDisplayMode(.inline)
        })
    case .operations:
      page = AnyView(
        NavigationStack {
          PhoneContent(
            deps: deps, actions: actions,
            content: {
              OperationsScreen(deps: deps, actions: actions, state: OperationsScreenState())
            },
            entry: { EmptyView() }
          )
          .navigationTitle(environment.language("section.operations"))
          .navigationBarTitleDisplayMode(.inline)
          .phoneToolbar(deps: deps, router: router)
        })
    case .planning:
      page = AnyView(
        NavigationStack {
          PhoneContent(
            deps: deps, actions: actions, content: { PlanningView() }, entry: { EmptyView() }
          )
          .navigationTitle(environment.language("section.planning"))
          .navigationBarTitleDisplayMode(.inline)
          .phoneToolbar(deps: deps, router: router)
        })
    case .accounts:
      page = AnyView(
        AccountsTab(deps: deps, router: router, actions: actions, entry: { EmptyView() }))
    case .more:
      page = AnyView(
        MoreTab(
          deps: deps, session: harness.session, lock: harness.lock, router: router,
          actions: actions, phoneTabs: .constant(NavItem.defaultPhoneTabs),
          entry: { AnyView(EmptyView()) }))
    }
    // A tablet has a side bar and no bar of the sections; its pages stand bare.
    let (window, _) =
      idiom == .pad
      ? harness.host(page, size: size, dark: dark, idiom: .pad)
      : harness.host(
        PhoneShellHost(deps: deps, router: router, width: size.width) { page }, size: size,
        dark: dark)
    harness.settleStable(window)
    return PhoneScreenShown(window: window, content: window, hasShell: idiom == .phone)
  }

  /// Puts `screen` on show in a window of `size`.
  static func open(
    _ screen: PhoneScreen, in harness: PhoneHarness, size: CGSize, dark: Bool = false,
    idiom: LayoutIdiom = .phone
  ) -> PhoneScreenShown {
    let environment = harness.environment
    switch screen {
    case .tab(let tab):
      return shelled(tab: tab, harness: harness, size: size, dark: dark, idiom: idiom)

    case .more(let destination):
      return shelled(
        tab: .more, more: destination, harness: harness, size: size, dark: dark, idiom: idiom)

    case .setting(let section):
      let view = NavigationStack {
        PhoneSettingsList.section(section)
          .navigationTitle(environment.language(section.titleKey, table: "Settings"))
          .navigationBarTitleDisplayMode(.inline)
      }
      let (window, _) = harness.host(
        view, size: size, dark: dark, idiom: idiom == .pad ? .pad : nil)
      harness.settleStable(window)
      return PhoneScreenShown(window: window, content: window, hasShell: false)

    case .sheet(let sheet):
      switch sheet {
      case .tabsEditor:
        let (window, _) = harness.host(
          PhoneTabsEditor(deps: harness.deps, tabs: .constant(NavItem.defaultPhoneTabs)),
          size: size, dark: dark)
        harness.settleStable(window)
        return PhoneScreenShown(window: window, content: window, hasShell: false)
      case .reconciliation, .trip, .problemReport:
        let (window, controller) = harness.host(
          PhoneSheetsHost(deps: harness.deps), size: size, dark: dark)
        harness.settle(window)
        switch sheet {
        case .reconciliation: environment.showsReconciliation = true
        case .trip: environment.showsTrip = true
        default: environment.showsProblemReport = true
        }
        harness.settleStable(window)
        let presented = controller.presentedViewController?.view
        environment.showsReconciliation = false
        environment.showsTrip = false
        environment.showsProblemReport = false
        return PhoneScreenShown(
          window: window, content: presented ?? window, hasShell: false)
      }
    }
  }
}
