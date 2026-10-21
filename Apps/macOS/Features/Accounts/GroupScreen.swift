import AppCore
import SwiftUI

/// The screen of a group of accounts, or of «Всего» — every account of the summary: its
/// total, whether it counts in the summary, its accounts with their balances — a click opens
/// one —, what is planned for them, when an operation was last added, and their history.
struct GroupScreen: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  let scope: GroupScope
  /// The selection of the window, shared with Overview.
  let actions: OperationActions
  /// Opens the screen of an account of the group.
  let openAccount: (UUID) -> Void

  @State private var history: AccountHistory?
  @State private var sheet: Sheet?

  enum Sheet: Identifiable {
    case transfer(TransferForm)
    case edit(AccountGroup)

    var id: String {
      switch self {
      case .transfer(let form): "transfer.\(form.previous?.id.uuidString ?? "new")"
      case .edit(let group): "edit.\(group.id.uuidString)"
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  private var section: GroupContent? {
    compute.snapshot.flatMap {
      scope.content(in: $0.planning.accounts.ordered(locale: environment.language.locale))
    }
  }

  private var accountIds: Set<UUID> { section?.accountIds ?? [] }

  var body: some View {
    AccountHistoryList(
      accountIds: accountIds, history: history, actions: actions,
      header: { header },
      editTransfer: { transfer, fee in
        sheet = .transfer(
          TransferForm(
            editing: transfer, fee: fee?.transaction.amountE4, calendar: environment.calendar))
      }
    )
    .task(id: HistoryKey(ids: accountIds, generation: compute.generation)) {
      await reload()
    }
    .sheet(item: $sheet) { sheet in
      sheetContent(sheet).handingOver(dependencies)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let section {
          Image(
            systemName: section.group == nil ? "sum" : section.inSummary ? "folder" : "eye.slash"
          )
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
          Text(verbatim: section.group?.name ?? t("sidebar.total"))
            .appFont(.title2.weight(.semibold))
        }
        Spacer()
        buttons
      }
      LastRecordCaption(history: history)
      if let section {
        summary(section)
        accounts(section)
        GroupPlanBlock(accountIds: section.accountIds)
      }
    }
    .padding(.vertical, 8)
  }

  private var buttons: some View {
    HStack(spacing: 8) {
      Button {
        let first = section?.accounts.first?.account
        sheet = .transfer(
          TransferForm(
            from: first, accounts: AccountActions(environment: environment, store: store).all,
            day: environment.today))
      } label: {
        Label {
          Text(verbatim: t("accounts.transfer"))
        } icon: {
          Image(systemName: "arrow.left.arrow.right")
        }
      }
      if let group = section?.group {
        Button {
          sheet = .edit(group)
        } label: {
          Label {
            Text(verbatim: t("accounts.edit"))
          } icon: {
            Image(systemName: "pencil")
          }
        }
      }
    }
    .buttonStyle(.bordered)
    .disabled(section == nil)
  }

  /// The total and, for a group left out of the summary, what that means — in words and with
  /// its own symbol.
  private func summary(_ section: GroupContent) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: t("sidebar.total"))
          .foregroundStyle(.secondary)
        Text(verbatim: section.totalRub.map { environment.money.rounded($0) } ?? "—")
          .appFont(.title3.monospacedDigit())
        if !section.withoutRate.isEmpty {
          Text(
            verbatim: environment.format(
              "sidebar.withoutRate", table: AccountText.table,
              section.withoutRate.map(\.code).joined(separator: ", "))
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)
      if !section.inSummary {
        Label {
          Text(verbatim: t("group.screen.excluded"))
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "eye.slash")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentCard()
  }

  /// The accounts of the group with their balances; a click opens the account.
  private func accounts(_ section: GroupContent) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: t("account.group.accounts"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      ForEach(section.accounts, id: \.account.id) { line in
        let figure = SidebarFigure.of(
          line, money: environment.money, words: t,
          withoutRate: {
            environment.format("sidebar.withoutRate", table: AccountText.table, $0)
          })
        Button {
          openAccount(line.account.id)
        } label: {
          HStack(alignment: .firstTextBaseline) {
            Label {
              Text(verbatim: line.account.name)
            } icon: {
              Image(systemName: AccountText.kindSymbol(line.account.kind))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
              Text(verbatim: figure.main)
                .monospacedDigit()
              if let caption = figure.caption {
                Text(verbatim: caption)
                  .appFont(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Image(systemName: "chevron.right")
              .appFont(.caption)
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(figure.help ?? "")
      }
      if section.accounts.isEmpty {
        Text(verbatim: t("group.screen.noAccounts"))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentCard()
  }

  @ViewBuilder
  private func sheetContent(_ sheet: Sheet) -> some View {
    switch sheet {
    case .transfer(let form):
      TransferSheet(form: form) { _ in self.sheet = nil }
    case .edit(let group):
      AccountGroupEditor(previous: group) { _ in self.sheet = nil }
    }
  }

  private func reload() async {
    guard let snapshot = compute.snapshot,
      let built = await AccountHistoryBuilder.build(
        accountIds: accountIds, snapshot: snapshot, calendar: environment.calendar)
    else { return }
    history = built
    actions.keep(only: built.operationIds)
    actions.reloadDictionaries(from: snapshot.dataset)
  }
}
