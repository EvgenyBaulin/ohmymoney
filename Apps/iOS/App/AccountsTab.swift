import AppCore
import SwiftUI

/// «Счета»: the list of banks, accounts and groups of the Mac sidebar, and the screen of what
/// is chosen. A split view, so a phone pushes the screen and an iPad shows both.
struct AccountsTab<Entry: View>: View {
  let deps: AppDependencies
  /// Where a request for an account or a group, from any screen, lands.
  let router: PhoneRouter
  let actions: OperationActions
  @ViewBuilder let entry: Entry

  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var model = AccountsSidebarModel()
  @State private var selection: SidebarItem = .allAccounts
  @State private var shown: SidebarItem?

  private var environment: AppEnvironment { deps.environment }

  init(
    deps: AppDependencies, router: PhoneRouter, actions: OperationActions,
    @ViewBuilder entry: () -> Entry
  ) {
    self.deps = deps
    self.router = router
    self.actions = actions
    self.entry = entry()
  }

  var body: some View {
    NavigationSplitView {
      List(
        selection: Binding<SidebarItem?>(
          get: { shown },
          set: {
            shown = $0
            if let chosen = $0 { selection = chosen }
          })
      ) {
        if environment.state == .ready {
          if sizeClass == .compact {
            // The phone shows the accounts as cards, as the design draws them.
            AccountCardsSection(model: model, selection: $selection)
          } else {
            AccountsSidebarSection(model: model, selection: $selection)
          }
        }
      }
      .accountsSidebarPresentations(model, selection: $selection)
      .onChange(of: selection) { _, new in shown = new }
      .onChange(of: router.accountsSelection, initial: true) { _, asked in
        guard let asked else { return }
        selection = asked
        shown = asked
        router.accountsSelection = nil
      }
      .navigationTitle(environment.language("accounts.section.accounts", table: "Accounts"))
      .phoneToolbar(deps: deps, router: router)
    } detail: {
      PhoneContent(deps: deps, actions: actions) {
        detail
      } entry: {
        entry
      }
    }
    .appDependencies(deps)
  }

  @ViewBuilder
  private var detail: some View {
    switch shown ?? selection {
    case .account(let id):
      AccountScreen(accountId: id, actions: actions).id(id)
    case .group(let id):
      GroupScreen(scope: .group(id), actions: actions) { shown = .account($0) }.id(id)
    case .bank(let id):
      BankScreen(bankId: id).id(id)
    default:
      GroupScreen(scope: .summary, actions: actions) { shown = .account($0) }
    }
  }
}
