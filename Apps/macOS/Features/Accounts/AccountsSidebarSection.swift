import AppCore
import AppDatabase
import SwiftUI

/// The «Счета» part of the sidebar: under the three sections, a section of the native list
/// headed «Счета» with «+», the «Всего» of the accounts in the summary, then the groups with
/// their totals and the accounts with their balances — in the order of every menu, the groups
/// left out of the summary last, each with `eye.slash` and «не в сводке». Content of a list,
/// never glass.
///
/// A click opens the screen of an account or of a group. The context menu of a row holds the
/// actions of the settings (`AccountActions`) and «Перевод…» and «Сверить…»; an account is
/// dragged to a new place. The sheets and questions hang on the list itself
/// (`accountsSidebarPresentations`).
struct AccountsSidebarSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  let model: AccountsSidebarModel
  @Binding var selection: SidebarItem

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  /// «без курса: USD, KZT».
  private func withoutRate(_ codes: String) -> String {
    environment.format("sidebar.withoutRate", table: AccountText.table, codes)
  }

  /// The accounts as the last calculation has them, in the order of the interface language.
  private var snapshot: AccountsSnapshot? {
    compute.snapshot?.planning.accounts.ordered(locale: environment.language.locale)
  }

  var body: some View {
    let snapshot = self.snapshot
    // The menus are built from the data on screen, not read from the database row by row;
    // every action reads the database afresh when it is taken.
    let live = AccountRules.ordered(
      snapshot?.sections.flatMap(\.accounts).map(\.account) ?? [],
      locale: environment.language.locale)
    Section {
      if let snapshot, !snapshot.sections.isEmpty {
        totalRow(snapshot)
        ForEach(snapshot.sections, id: \.sidebarId) { section in
          if let group = section.group {
            groupRow(section, group)
          }
          ForEach(section.accounts, id: \.account.id) { line in
            accountRow(
              line, indented: section.group != nil, live: live,
              section: section.accounts.map(\.account.id), snapshot: snapshot)
          }
          .onMove { source, destination in
            move(in: section, from: source, to: destination)
          }
        }
      }
    } header: {
      header(live: live)
    }
  }

  // MARK: Header

  private func header(live: [PaymentMethod]) -> some View {
    HStack(spacing: 4) {
      Text(verbatim: t("accounts.section.accounts"))
      Spacer()
      Menu {
        Button(t("accounts.newAccount")) { model.sheet = .account(nil) }
        Button(t("accounts.newGroup")) { model.sheet = .group(nil) }
        Divider()
        Button(t("accounts.transfer")) { model.sheet = .transfer(newTransfer(from: nil)) }
          .disabled(live.isEmpty)
        Button(t("accounts.reconcile")) { environment.showsReconciliation = true }
        if environment.accountSetup == .later {
          Divider()
          Button(environment.language("onboarding.card.action", table: "Onboarding")) {
            AccountSetupRequest.shared.isRequested = true
          }
        }
      } label: {
        Image(systemName: "plus")
          .accessibilityLabel(Text(verbatim: t("sidebar.add")))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(t("sidebar.add"))
      .accessibilityIdentifier("sidebar.accounts.add")
    }
  }

  // MARK: Rows

  /// «Всего»: the money of the accounts in the summary, in rubles at today's rates.
  private func totalRow(_ snapshot: AccountsSnapshot) -> some View {
    let missing = snapshot.inSummaryWithoutRate
    return HStack(alignment: .firstTextBaseline) {
      Label {
        Text(verbatim: t("sidebar.total"))
      } icon: {
        Image(systemName: "sum")
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 0) {
        Text(verbatim: snapshot.inSummaryTotalRub.map { environment.money.rounded($0) } ?? "—")
          .monospacedDigit()
        if !missing.isEmpty {
          Text(
            verbatim: environment.format(
              "sidebar.withoutRate", table: AccountText.table,
              missing.map(\.code).joined(separator: ", "))
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .help(snapshot.inSummaryTotalRub == nil ? t("sidebar.totalNotCounted") : t("sidebar.totalHint"))
    .tag(SidebarItem.allAccounts)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("sidebar.accounts.total")
  }

  private func groupRow(_ section: AccountsSnapshot.Section, _ group: AccountGroup) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Label {
        VStack(alignment: .leading, spacing: 0) {
          Text(verbatim: group.name)
            .lineLimit(1)
          if !section.inSummary {
            // Left out of the summary: said in words, with its own symbol, never by colour.
            Text(verbatim: t("sidebar.excluded"))
              .appFont(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } icon: {
        Image(systemName: section.inSummary ? "folder" : "eye.slash")
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 0) {
        Text(verbatim: section.totalRub.map { environment.money.rounded($0) } ?? "—")
          .monospacedDigit()
          .foregroundStyle(section.inSummary ? .primary : .secondary)
        if section.totalRub != nil, !section.withoutRate.isEmpty {
          // Money the total leaves out for want of a rate is named, not dropped in silence.
          Text(verbatim: withoutRate(section.withoutRate.map(\.code).joined(separator: ", ")))
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
    .tag(SidebarItem.group(group.id))
    .contextMenu { groupMenu(group, holdsMain: section.accounts.contains { $0.account.isDefault }) }
    .accessibilityElement(children: .combine)
  }

  private func accountRow(
    _ line: AccountsSnapshot.AccountLine, indented: Bool, live: [PaymentMethod],
    section: [UUID], snapshot: AccountsSnapshot
  ) -> some View {
    let figure = SidebarFigure.of(
      line, money: environment.money, words: t, withoutRate: withoutRate)
    return HStack(alignment: .firstTextBaseline) {
      Label {
        HStack(spacing: 4) {
          Text(verbatim: line.account.name)
            .lineLimit(1)
          if line.account.isDefault {
            // The main account is told by a symbol with a spoken word, never by colour.
            Image(systemName: "star.fill")
              .appFont(.caption2)
              .foregroundStyle(.secondary)
              .accessibilityLabel(Text(verbatim: t("accounts.main")))
          }
        }
      } icon: {
        Image(systemName: AccountText.kindSymbol(line.account.kind))
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 0) {
        Text(verbatim: figure.main)
          .monospacedDigit()
        if let caption = figure.caption {
          Text(verbatim: caption)
            .appFont(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
    .padding(.leading, indented ? 12 : 0)
    .tag(SidebarItem.account(line.account.id))
    .moveDisabled(line.account.isDefault)
    .help(figure.help ?? "")
    .contextMenu {
      accountMenu(line.account, live: live, section: section, snapshot: snapshot)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: Menus

  @ViewBuilder
  private func accountMenu(
    _ account: PaymentMethod, live: [PaymentMethod], section: [UUID], snapshot: AccountsSnapshot
  ) -> some View {
    Button(t("accounts.transfer")) { model.sheet = .transfer(newTransfer(from: account)) }
    Button(t("accounts.reconcile")) { reconcile(account) }
    Divider()
    Button(t("accounts.edit")) { model.sheet = .account(account) }
    if !account.isDefault {
      Button(t("accounts.makeMain")) { model.perform(actions.makeMain(account.id), about: account) }
      // Among the rows the account is shown with, as a drag moves it.
      let order = live.map(\.id)
      let main = live.first(where: \.isDefault)?.id
      Button(t("accounts.moveUp")) { step(account.id, by: -1, in: section) }
        .disabled(
          SidebarOrder.step(account.id, by: -1, in: section, main: main, ordered: order) == nil)
      Button(t("accounts.moveDown")) { step(account.id, by: 1, in: section) }
        .disabled(
          SidebarOrder.step(account.id, by: 1, in: section, main: main, ordered: order) == nil)
    }
    if live.contains(where: { $0.sort != 0 }) {
      Button(t("accounts.alphabetize")) { model.perform(actions.alphabetize()) }
    }
    // Another live account to merge into — for the main one, one in the summary, as
    // `AccountActions.mergeTargets` says.
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

  // MARK: Actions

  private var liveAccounts: [PaymentMethod] { actions.ordered(actions.all) }

  private func newTransfer(from account: PaymentMethod?) -> TransferForm {
    TransferForm(from: account, accounts: liveAccounts, day: environment.today)
  }

  /// «Сверить…»: the screen of the account, and the sheet of the reconciliation over it with
  /// that account's rows first.
  private func reconcile(_ account: PaymentMethod) {
    selection = .account(account.id)
    environment.focusedAccountId = account.id
    environment.showsReconciliation = true
  }

  /// «Выше» / «Ниже»: one row up or down among the rows of its section, carried over to the
  /// order of every list as a drag is.
  private func step(_ id: UUID, by offset: Int, in section: [UUID]) {
    let ordered = actions.ordered(actions.all)
    guard
      let move = SidebarOrder.step(
        id, by: offset, in: section, main: ordered.first(where: \.isDefault)?.id,
        ordered: ordered.map(\.id))
    else { return }
    model.perform(actions.reorder(from: move.source, to: move.destination))
  }

  /// A drag inside one section, carried over to the order of every list: the sections show
  /// the accounts in that order, only split by group.
  private func move(
    in section: AccountsSnapshot.Section, from source: IndexSet, to destination: Int
  ) {
    let ordered = actions.ordered(actions.all).map(\.id)
    guard
      let move = SidebarOrder.move(
        in: section.accounts.map(\.account.id), from: source, to: destination, ordered: ordered)
    else { return }
    model.perform(actions.reorder(from: move.source, to: move.destination))
  }
}

extension AccountsSnapshot.Section {
  /// The identity of a section in the sidebar: its group, or the accounts of no group.
  var sidebarId: String { group?.id.uuidString ?? "ungrouped" }
}

/// The figure a row of an account shows in the sidebar, rounded as Overview rounds: the
/// balance in its own currency with «≈ ₽» under it for another currency; for an account of
/// several currencies «≈ ₽» of them all, and each balance under it — with the currencies left
/// out of «≈ ₽» for want of a rate named, never dropped in silence.
struct SidebarFigure: Equatable {
  var main: String
  var caption: String?
  /// What the row says when the pointer rests on it: every balance, never rounded away, and
  /// the currencies «≈ ₽» leaves out.
  var help: String?
  /// «без курса: USD» — the currencies of «≈ ₽» of several that have no rate today.
  var missing: String?

  /// `withoutRate` words the codes of the currencies left out: «без курса: USD, KZT».
  @MainActor
  static func of(
    _ line: AccountsSnapshot.AccountLine, money: MoneyFormatter, words: (String) -> String,
    withoutRate: (String) -> String
  ) -> SidebarFigure {
    // A currency the account does not hold shows only while money is on it.
    let keys = line.keys.filter { $0.isHeld || !($0.balance?.isZero ?? true) }
    let help = keys.map { key in
      key.balance.map { money.exact($0, currency: key.key.currency) }
        ?? "\(key.key.currency.code): \(words("sidebar.notCounted"))"
    }.joined(separator: "\n")
    guard keys.count > 1 else {
      guard let key = keys.first, let balance = key.balance else {
        return SidebarFigure(main: "—", caption: words("sidebar.notCounted"), help: help)
      }
      let main = money.rounded(balance, currency: key.key.currency)
      guard key.key.currency != .rub else { return SidebarFigure(main: main, help: help) }
      let caption = key.rub.map { "≈\u{00A0}\(money.rounded($0))" } ?? words("sidebar.noRate")
      return SidebarFigure(main: main, caption: caption, help: help)
    }
    let main = line.totalRub.map { "≈\u{00A0}\(money.rounded($0))" } ?? "—"
    let caption = keys.map { key in
      key.balance.map { money.rounded($0, currency: key.key.currency) }
        ?? "—\u{00A0}\(money.symbol(for: key.key.currency))"
    }.joined(separator: " · ")
    guard line.totalRub != nil, !line.withoutRate.isEmpty else {
      return SidebarFigure(main: main, caption: caption, help: help)
    }
    let missing = withoutRate(line.withoutRate.map(\.code).joined(separator: ", "))
    return SidebarFigure(
      main: main, caption: caption, help: [help, missing].joined(separator: "\n"),
      missing: missing)
  }
}

/// The order of the accounts as the sidebar shows it: the order of every list, split by group.
enum SidebarOrder {
  /// A drag inside one section — `section` lists its accounts in order — in the terms of
  /// `onMove` over the whole ordered list of live accounts; `nil` when nothing moves.
  static func move(
    in section: [UUID], from source: IndexSet, to destination: Int, ordered: [UUID]
  ) -> (source: IndexSet, destination: Int)? {
    let moved = source.compactMap { section.indices.contains($0) ? section[$0] : nil }
    let global = IndexSet(moved.compactMap { ordered.firstIndex(of: $0) })
    guard !global.isEmpty else { return nil }
    let target: Int
    if destination < section.count, let index = ordered.firstIndex(of: section[destination]) {
      target = index
    } else if let last = section.last, let index = ordered.firstIndex(of: last) {
      target = index + 1
    } else {
      return nil
    }
    return (global, target)
  }

  /// «Выше» / «Ниже»: `id` one row up (`offset` −1) or down (+1) among the rows of its
  /// `section`, in the terms of `onMove` over the whole ordered list; `nil` when there is no
  /// row to pass there, or the row above is the main account, which stays first.
  static func step(
    _ id: UUID, by offset: Int, in section: [UUID], main: UUID?, ordered: [UUID]
  ) -> (source: IndexSet, destination: Int)? {
    guard let index = section.firstIndex(of: id), id != main else { return nil }
    let target = index + offset
    guard section.indices.contains(target), section[target] != main else { return nil }
    return move(
      in: section, from: IndexSet([index]), to: offset < 0 ? target : target + 1,
      ordered: ordered)
  }
}

// MARK: - Sheets and questions

/// What the «Счета» part of the sidebar has opened over the window: an editor, a merge, the
/// hand-over of the main account, a transfer; a deletion waiting for its answer; a refusal.
@MainActor
@Observable
final class AccountsSidebarModel {
  enum Sheet: Identifiable {
    case account(PaymentMethod?)
    case group(AccountGroup?)
    case merge(PaymentMethod)
    /// The main account leaves — into the archive, or deleted — and another takes over.
    case handOver(PaymentMethod, deletes: Bool, candidates: [PaymentMethod], preselected: UUID?)
    case transfer(TransferForm)
    /// «В архив» on an account that still holds money: where each currency of it goes.
    case archiveMoney(PaymentMethod, newMain: UUID?)

    var id: String {
      switch self {
      case .account(let account): "account.\(account?.id.uuidString ?? "new")"
      case .group(let group): "group.\(group?.id.uuidString ?? "new")"
      case .merge(let account): "merge.\(account.id.uuidString)"
      case .handOver(let account, _, _, _): "handOver.\(account.id.uuidString)"
      case .transfer(let form): "transfer.\(form.previous?.id.uuidString ?? "new")"
      case .archiveMoney(let account, _): "archiveMoney.\(account.id.uuidString)"
      }
    }
  }

  /// A refusal and the account it was about, for the way on it offers.
  struct Refusal: Identifiable {
    let reason: AccountRefusal
    let account: PaymentMethod?
    let id = UUID()
  }

  var sheet: Sheet?
  var refusal: Refusal?
  /// The account the owner asked to delete, waiting for the answer.
  var deleting: PaymentMethod?
  /// The group the owner asked to delete, waiting for the answer.
  var deletingGroup: AccountGroup?
  /// A write the database refused; the alert says so.
  var failed = false

  /// Says what came of an action. Returns whether it was done.
  @discardableResult
  func perform(_ outcome: AccountActionOutcome, about account: PaymentMethod? = nil) -> Bool {
    switch outcome {
    case .done: refusal = nil
    case .refused(let reason): refusal = Refusal(reason: reason, account: account)
    case .failed: failed = true
    }
    return outcome == .done
  }

  /// Into the archive; the main account first asks which one takes over. Money on it is asked
  /// about — where each currency goes — and moved with the archive in one step; a balance
  /// nobody knows keeps it out, and the refusal offers to count the account.
  func archive(_ account: PaymentMethod, newMain: UUID? = nil, actions: AccountActions) {
    Task {
      guard let books = await actions.books() else {
        failed = true
        return
      }
      let reason = actions.archiveRefusal(account, books: books)
      if account.isDefault, newMain == nil {
        if let reason, reason != .hasMoney {
          refusal = Refusal(reason: reason, account: account)
          return
        }
        let next = actions.successors(leaving: account.id, books: books)
        sheet = .handOver(
          account, deletes: false, candidates: next.all, preselected: next.preselected)
        return
      }
      if reason == .hasMoney {
        sheet = .archiveMoney(account, newMain: newMain)
        return
      }
      perform(actions.archive(account.id, newMain: newMain, books: books), about: account)
    }
  }

  /// Deleting: only an account nothing points at, asked first; the main account asks who takes
  /// over, which is the question of the deletion too.
  func askToDelete(_ account: PaymentMethod, actions: AccountActions) {
    guard let repository = actions.environment.accounts else { return }
    if let usage = try? repository.usage(of: account.id), usage.isUsed {
      refusal = Refusal(reason: .inUse(account.id, usage), account: account)
      return
    }
    guard account.isDefault, !account.archived else {
      deleting = account
      return
    }
    Task {
      guard let books = await actions.books() else {
        failed = true
        return
      }
      let next = actions.successors(leaving: account.id, books: books)
      sheet = .handOver(
        account, deletes: true, candidates: next.all, preselected: next.preselected)
    }
  }

  /// A group is asked about only when it can go: filed accounts, archived ones too, keep it.
  func askToDelete(_ group: AccountGroup, accounts: [PaymentMethod]) {
    guard !accounts.contains(where: { $0.groupId == group.id }) else {
      refusal = Refusal(reason: .groupInUse, account: nil)
      return
    }
    deletingGroup = group
  }
}

extension View {
  /// The sheets and questions of the «Счета» part of the sidebar, hung on the list.
  func accountsSidebarPresentations(
    _ model: AccountsSidebarModel, selection: Binding<SidebarItem>
  ) -> some View {
    modifier(AccountsSidebarPresentations(model: model, selection: selection))
  }
}

private struct AccountsSidebarPresentations: ViewModifier {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dependencies) private var dependencies
  @Bindable var model: AccountsSidebarModel
  @Binding var selection: SidebarItem

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  func body(content: Content) -> some View {
    content
      .sheet(item: $model.sheet) { sheet in
        sheetContent(sheet).handingOver(dependencies)
      }
      .alert(
        t("sidebar.refusal.title"),
        isPresented: Binding(
          get: { model.refusal != nil }, set: { if !$0 { model.refusal = nil } }),
        presenting: model.refusal
      ) { refusal in
        refusalButtons(refusal)
        Button(environment.language("action.ok"), role: .cancel) {}
      } message: { refusal in
        Text(verbatim: AccountText.message(refusal.reason, environment))
      }
      .confirmationDialog(
        model.deleting.map {
          environment.format("accounts.delete.titleOne", table: AccountText.table, $0.name)
        } ?? "",
        isPresented: Binding(
          get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } }),
        titleVisibility: .visible, presenting: model.deleting
      ) { account in
        Button(environment.language("action.delete"), role: .destructive) {
          model.deleting = nil
          model.perform(actions.delete([account.id]), about: account)
        }
        Button(environment.language("action.cancel"), role: .cancel) {}
      } message: { _ in
        Text(verbatim: t("accounts.delete.message"))
      }
      .confirmationDialog(
        model.deletingGroup.map {
          environment.format("accounts.deleteGroup.title", table: AccountText.table, $0.name)
        } ?? "",
        isPresented: Binding(
          get: { model.deletingGroup != nil }, set: { if !$0 { model.deletingGroup = nil } }),
        titleVisibility: .visible, presenting: model.deletingGroup
      ) { group in
        Button(environment.language("action.delete"), role: .destructive) {
          model.deletingGroup = nil
          model.perform(actions.deleteGroup(group.id))
        }
        Button(environment.language("action.cancel"), role: .cancel) {}
      } message: { _ in
        Text(verbatim: t("accounts.deleteGroup.message"))
      }
      .refusedWriteAlert($model.failed, environment)
  }

  /// The way on a refusal offers: money on an account to archive is transferred away or the
  /// account counted; an account in use is merged or archived; a name in the archive comes back.
  @ViewBuilder
  private func refusalButtons(_ refusal: AccountsSidebarModel.Refusal) -> some View {
    switch refusal.reason {
    case .hasMoney, .deletesWithMoney:
      if let account = refusal.account {
        Button(t("sidebar.moveBalance")) { moveBalance(of: account) }
      }
    case .balanceUnknown:
      if let account = refusal.account {
        Button(t("accounts.reconcile")) {
          selection = .account(account.id)
          environment.focusedAccountId = account.id
          environment.showsReconciliation = true
        }
      }
    case .inUse(let id, _):
      if let account = actions.all.first(where: { $0.id == id && !$0.archived }) {
        if !actions.mergeTargets(for: account).isEmpty {
          Button(t("accounts.mergeWith")) { model.sheet = .merge(account) }
        }
        Button(t("accounts.archive")) { model.archive(account, actions: actions) }
      }
    case .inArchive(let id):
      Button(t("account.refusal.restore")) { model.perform(actions.restore(id)) }
    default:
      EmptyView()
    }
  }

  /// «Перевести остаток…»: the transfer sheet with the money of the account in it — the
  /// currency that holds it and the whole of it —, read from the books as they are now.
  private func moveBalance(of account: PaymentMethod) {
    let actions = self.actions
    let day = environment.today
    Task {
      let books = await actions.books()
      model.sheet = .transfer(
        TransferForm(
          movingBalanceOf: account, balances: books?.balances ?? .empty,
          accounts: actions.ordered(actions.all), day: day))
    }
  }

  @ViewBuilder
  private func sheetContent(_ sheet: AccountsSidebarModel.Sheet) -> some View {
    switch sheet {
    case .account(let account):
      AccountEditor(previous: account, defaultCurrency: environment.defaultCurrency) { _ in
        model.sheet = nil
      }
    case .group(let group):
      AccountGroupEditor(previous: group) { _ in model.sheet = nil }
    case .merge(let account):
      AccountMergeSheet(
        source: account, targets: actions.mergeTargets(for: account), preselected: nil
      ) { _ in
        model.sheet = nil
      }
    case .handOver(let account, let deletes, let candidates, let preselected):
      MainHandOverSheet(
        leaving: account, candidates: candidates, preselected: preselected,
        confirmTitle: t(deletes ? "accounts.delete" : "accounts.archive"),
        note: deletes ? t("accounts.delete.message") : nil,
        confirm: { next in
          model.sheet = nil
          if deletes {
            model.perform(actions.delete([account.id], newMain: next), about: account)
          } else {
            model.archive(account, newMain: next, actions: actions)
          }
        },
        cancel: { model.sheet = nil })
    case .transfer(let form):
      TransferSheet(form: form) { _ in model.sheet = nil }
    case .archiveMoney(let account, let newMain):
      ArchivedMoneySheet(archiving: account, newMain: newMain) { _ in model.sheet = nil }
    }
  }
}
