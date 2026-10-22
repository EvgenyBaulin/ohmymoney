import AppCore
import SwiftUI

/// The accounts on a phone: «Всего на счетах» on a card, then a card for each account — the
/// bank and the name, when it was last counted, the balance — on a gradient of a colour of the
/// theme's chart palette, the groups left out of the summary last. A row of the sidebar list
/// (so a tap pushes the screen of the account) with the chrome of the row taken off; the
/// actions of the row stay in its context menu. Content, never glass; the words carry the
/// meaning, the colour only tells the cards apart.
struct AccountCardsSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.appTheme) private var theme
  let model: AccountsSidebarModel
  @Binding var selection: SidebarItem

  @State private var banks: [UUID: String] = [:]

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }
  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  private func withoutRate(_ codes: String) -> String {
    environment.format("sidebar.withoutRate", table: AccountText.table, codes)
  }

  private var snapshot: AccountsSnapshot? {
    compute.snapshot?.planning.accounts.ordered(locale: environment.language.locale)
  }

  /// The colours of the cards, one after another; the accent first.
  private var tints: [Color] {
    [theme.accentDefault, theme.chart2, theme.chart3, theme.chart6, theme.chart4, theme.chart7]
  }

  var body: some View {
    let snapshot = self.snapshot
    let live = AccountRules.ordered(
      snapshot?.sections.flatMap(\.accounts).map(\.account) ?? [],
      locale: environment.language.locale)
    Group {
      addRow(live: live)
      if let snapshot, !snapshot.sections.isEmpty {
        totalCard(snapshot)
        let all = snapshot.sections.flatMap(\.accounts)
        ForEach(snapshot.sections, id: \.sidebarId) { section in
          if let group = section.group {
            groupHeader(section, group)
          }
          ForEach(section.accounts, id: \.account.id) { line in
            accountCard(
              line, tint: tints[(all.firstIndex(of: line) ?? 0) % tints.count],
              live: live, snapshot: snapshot)
          }
        }
      }
    }
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    .task(id: compute.generation) {
      banks = Dictionary(
        actions.banks.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
  }

  // MARK: The cards

  private func addRow(live: [PaymentMethod]) -> some View {
    HStack {
      Spacer()
      Menu {
        Button(t("accounts.newAccount")) { model.sheet = .account(nil) }
        Button(t("accounts.newGroup")) { model.sheet = .group(nil) }
        Divider()
        Button(t("accounts.transfer")) { model.sheet = .transfer(newTransfer(from: nil)) }
          .disabled(live.isEmpty)
        Button(t("accounts.reconcile")) { environment.showsReconciliation = true }
      } label: {
        Image(systemName: "plus")
          .appFont(.title3)
          .frame(width: 44, height: 44)
          .background(Color(theme.palette.surfaceCard), in: .circle)
          .overlay { Circle().strokeBorder(Color(theme.palette.borderCard), lineWidth: 0.5) }
          .accessibilityLabel(Text(verbatim: t("sidebar.add")))
      }
      .accessibilityIdentifier("sidebar.accounts.add")
    }
  }

  private func totalCard(_ snapshot: AccountsSnapshot) -> some View {
    let missing = snapshot.inSummaryWithoutRate
    return VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: t("sidebar.total"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
      Text(verbatim: snapshot.inSummaryTotalRub.map { environment.money.rounded($0) } ?? "—")
        .appFont(.largeTitle.bold().monospacedDigit())
        .minimumScaleFactor(0.6)
        .lineLimit(1)
      if !missing.isEmpty {
        Text(verbatim: withoutRate(missing.map(\.code).joined(separator: ", ")))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .background(Color(theme.palette.surfaceCard), in: .rect(cornerRadius: 20))
    .overlay {
      RoundedRectangle(cornerRadius: 20).strokeBorder(
        Color(theme.palette.borderCard), lineWidth: 0.5)
    }
    .tag(SidebarItem.allAccounts)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("sidebar.accounts.total")
  }

  private func groupHeader(
    _ section: AccountsSnapshot.Section, _ group: AccountGroup
  )
    -> some View
  {
    HStack(spacing: 6) {
      Image(systemName: section.inSummary ? "folder" : "eye.slash")
        .accessibilityHidden(true)
      Text(verbatim: section.inSummary ? group.name : "\(group.name) · \(t("sidebar.excluded"))")
        .lineLimit(1)
      Spacer(minLength: 8)
      Text(verbatim: section.totalRub.map { environment.money.rounded($0) } ?? "—")
        .monospacedDigit()
    }
    .appFont(.callout.weight(.semibold))
    .foregroundStyle(.secondary)
    .padding(.top, 8)
    .tag(SidebarItem.group(group.id))
    .contextMenu { groupMenu(group, holdsMain: section.accounts.contains { $0.account.isDefault }) }
    .accessibilityElement(children: .combine)
  }

  private func accountCard(
    _ line: AccountsSnapshot.AccountLine, tint: Color, live: [PaymentMethod],
    snapshot: AccountsSnapshot
  ) -> some View {
    let figure = SidebarFigure.of(
      line, money: environment.money, words: t, withoutRate: withoutRate)
    let account = line.account
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(verbatim: title(of: account))
          .appFont(.callout.weight(.semibold))
          .lineLimit(1)
        if account.isDefault {
          // The main account is told by a symbol with a spoken word, never by colour.
          Image(systemName: "star.fill")
            .appFont(.caption)
            .accessibilityLabel(Text(verbatim: t("accounts.main")))
        }
        Spacer(minLength: 8)
      }
      Text(verbatim: countedCaption(line))
        .appFont(.caption)
        .opacity(0.85)
        .padding(.top, 8)
      Text(verbatim: figure.main)
        .appFont(.title.bold().monospacedDigit())
        .minimumScaleFactor(0.6)
        .lineLimit(1)
      if let caption = figure.caption {
        Text(verbatim: caption)
          .appFont(.caption.monospacedDigit())
          .opacity(0.85)
          .lineLimit(1)
      }
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(
      LinearGradient(
        colors: [tint, tint.mix(with: .black, by: 0.3)], startPoint: .topLeading,
        endPoint: .bottomTrailing),
      in: .rect(cornerRadius: 20)
    )
    .tag(SidebarItem.account(account.id))
    .contextMenu { accountMenu(account, live: live, snapshot: snapshot) }
    .accessibilityElement(children: .combine)
  }

  /// «Сбер · Основная карта»: the bank and the account, or the account alone when it is named
  /// the same as its bank.
  private func title(of account: PaymentMethod) -> String {
    guard let bank = account.bankId.flatMap({ banks[$0] }), bank != account.name else {
      return account.name
    }
    return "\(bank) \u{00B7} \(account.name)"
  }

  /// «сверено сегодня» / «сверено 20 октября» — the latest count of any currency of the
  /// account —, or «не сверен».
  private func countedCaption(_ line: AccountsSnapshot.AccountLine) -> String {
    guard let latest = line.keys.compactMap(\.anchorAt).max() else {
      return t("sidebar.notCounted")
    }
    let day = environment.calendar.day(of: latest)
    let text =
      day == environment.today
      ? environment.language("common.today").lowercased() : environment.dates.longDay(day)
    return environment.format("account.screen.countedAt", table: AccountText.table, text)
  }

  // MARK: Menus

  @ViewBuilder
  private func accountMenu(
    _ account: PaymentMethod, live: [PaymentMethod], snapshot: AccountsSnapshot
  ) -> some View {
    Button(t("accounts.transfer")) { model.sheet = .transfer(newTransfer(from: account)) }
    Button(t("accounts.reconcile")) {
      selection = .account(account.id)
      environment.focusedAccountId = account.id
      environment.showsReconciliation = true
    }
    Divider()
    Button(t("accounts.edit")) { model.sheet = .account(account) }
    if !account.isDefault {
      Button(t("accounts.makeMain")) { model.perform(actions.makeMain(account.id), about: account) }
    }
    if live.contains(where: {
      $0.id != account.id && !(account.isDefault && !snapshot.isInSummary($0.id))
    }) {
      Button(t("accounts.mergeWith")) { model.sheet = .merge(account) }
    }
    Divider()
    Button(t("accounts.archive")) { model.archive(account, actions: actions) }
    Button(t("accounts.delete"), role: .destructive) {
      model.askToDelete(account, actions: actions)
    }
  }

  @ViewBuilder
  private func groupMenu(_ group: AccountGroup, holdsMain: Bool) -> some View {
    Button(t("accounts.edit")) { model.sheet = .group(group) }
    if group.inSummary {
      Button(t("sidebar.excludeFromSummary")) {
        model.perform(actions.setInSummary(group.id, false))
      }
      .disabled(holdsMain)
    } else {
      Button(t("sidebar.includeInSummary")) { model.perform(actions.setInSummary(group.id, true)) }
    }
    Divider()
    Button(t("accounts.archive")) { model.perform(actions.archiveGroup(group.id)) }
    Button(t("accounts.delete"), role: .destructive) {
      model.askToDelete(group, accounts: actions.all)
    }
  }

  private func newTransfer(from account: PaymentMethod?) -> TransferForm {
    TransferForm(from: account, accounts: actions.ordered(actions.all), day: environment.today)
  }
}
