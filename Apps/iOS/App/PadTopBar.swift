import AppCore
import SwiftUI

/// The same bar on top of an iPad window, no wider than half of it: as many sections as fit
/// (`NavLayout`) and «Ещё», which opens a popover with the rest and the tools. It is laid out
/// again whenever the window changes width — Split View, Stage Manager, rotation.
struct PadTopBar<MoreContent: View>: View {
  let layout: NavLayout
  let router: PhoneRouter
  let title: (NavItem) -> String
  let moreTitle: String
  @Binding var showsMore: Bool
  @ViewBuilder let moreContent: MoreContent

  @Environment(\.appTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let colors = NavBarColors(theme: theme, colorScheme: colorScheme, contrast: contrast)
    HStack(spacing: 0) {
      HStack(spacing: 0) {
        ForEach(layout.visible) { item in
          NavBarButton(
            title: title(item), symbol: item.symbol, isActive: router.current == item,
            colors: colors
          ) { router.open(nav: item) }
        }
        NavBarButton(
          title: moreTitle, symbol: "ellipsis",
          isActive: router.isMoreLit(visible: layout.visible), colors: colors
        ) { showsMore.toggle() }
        .popover(isPresented: $showsMore, arrowEdge: .top) {
          moreContent.frame(minWidth: 340, minHeight: 480)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(colors.background, in: Capsule())
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
  }
}

/// What the popover of «Ещё» holds on an iPad: the sections that did not fit on the bar, the
/// tools and the application's own rows, with a search. Choosing one goes there and closes the
/// popover; the settings open in the «Ещё» page behind it, where they have room.
struct PadMoreList: View {
  let deps: AppDependencies
  let layout: NavLayout
  let router: PhoneRouter
  let close: () -> Void

  @State private var query = ""

  private var environment: AppEnvironment { deps.environment }

  private var menu: MoreMenu {
    MoreMenu.make(more: layout.more, tripIsOn: environment.tripEntryDefaults != nil)
      .filtered(by: query, title: title(of:))
  }

  var body: some View {
    NavigationStack {
      List {
        let menu = self.menu
        group(menu.sections)
        group(menu.app)
      }
      .searchable(
        text: $query,
        prompt: Text(verbatim: environment.language("nav.more.search", table: "Navigation"))
      )
      .navigationTitle(environment.language("phone.tab.more", table: "Phone"))
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  @ViewBuilder
  private func group(_ rows: [MoreRow]) -> some View {
    if !rows.isEmpty {
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
    }
  }

  private func title(of row: MoreRow) -> String {
    switch row {
    case .section(let item):
      environment.language(item.titleKey, table: item.titleTable ?? "Common")
    case .whatIf: environment.language("window.whatIf")
    case .trip: environment.language("nav.more.trip", table: "Navigation")
    case .reconcile: environment.language("action.reconcile")
    case .settings: environment.language("settings.title", table: "Settings")
    case .tour: environment.language("guide.menu.tour", table: "Guide")
    case .whatsNew: environment.language("guide.menu.whatsNew", table: "Guide")
    case .problemReport: environment.language("report.title", table: "Settings")
    }
  }

  private func perform(_ row: MoreRow) {
    switch row {
    case .section(let item): router.open(nav: item)
    case .whatIf: router.open(screen: .whatIf)
    case .trip: environment.showsTrip = true
    case .reconcile: environment.showsReconciliation = true
    case .settings: router.open(screen: .settings)
    case .tour: GuideStore.shared.show(GuideCatalog.firstLaunch)
    case .whatsNew:
      if let latest = GuideCatalog.whatsNew.last { GuideStore.shared.show(latest) }
    case .problemReport: environment.showsProblemReport = true
    }
  }
}
