import AppCore
import SwiftUI

/// What happened on an account — or on the accounts of a group —, day by day, newest first:
/// its operations and the transfers that moved its money. A transfer is listed once even
/// between two accounts of the group, and counts in no total of the day.
struct AccountHistory: Sendable {
  /// A line of a day: an operation, or a transfer.
  typealias Item = DayItem

  struct Day: Identifiable, Sendable {
    let day: DateOnly
    /// Newest first.
    let items: [Item]
    /// What the operations of the day come to; transfers are neither income nor spending.
    let totals: RowTotals
    var id: String { day.iso }
  }

  let days: [Day]
  /// The operations listed: the selection keeps only these.
  let operationIds: Set<UUID>
  /// The fee of each transfer listed that has one, by transfer.
  let fees: [UUID: TransactionEntry]
  /// When an operation was last written down on these accounts (`AccountLastRecord`): the
  /// moment of writing, not the day the operation names; `nil` when none was.
  var lastRecordedAt: Date? = nil

  static let empty = AccountHistory(days: [], operationIds: [], fees: [:])

  /// The history of `accountIds`. An operation with no account of its own is on the main
  /// account, as its balance counts it.
  static func build(
    accountIds: Set<UUID>, dataset: Dataset, refunds: RefundIndex = .empty,
    calendar: CalendarContext
  ) -> AccountHistory {
    let mainId = dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id
    var items: [Item] = []
    var ids: Set<UUID> = []
    var fees: [UUID: TransactionEntry] = [:]
    for entry in dataset.entries where !entry.transaction.isDeleted {
      if case .transferFee(let transferId) = OperationLink(externalId: entry.transaction.externalId)
      {
        fees[transferId] = entry
      }
      guard let account = entry.transaction.paymentMethodId ?? mainId,
        accountIds.contains(account)
      else { continue }
      items.append(.operation(entry))
      ids.insert(entry.id)
    }
    for transfer in dataset.transfers
    where accountIds.contains(transfer.fromAccountId) || accountIds.contains(transfer.toAccountId) {
      items.append(.transfer(transfer))
    }
    let byDay = Dictionary(grouping: items) { calendar.day(of: $0.occurredAt) }
    let debts = dataset.debtsById
    let days = byDay.keys.sorted(by: >).map { day in
      let listed = (byDay[day] ?? []).sorted(by: DayItem.newestFirst)
      let operations = listed.compactMap { item -> TransactionEntry? in
        if case .operation(let entry) = item { return entry }
        return nil
      }
      return Day(
        day: day, items: listed,
        totals: RowTotals(entries: operations, debts: debts, refunds: refunds))
    }
    let listedTransfers = Set(
      items.compactMap { item -> UUID? in
        if case .transfer(let transfer) = item { return transfer.id }
        return nil
      })
    return AccountHistory(
      days: days, operationIds: ids, fees: fees.filter { listedTransfers.contains($0.key) },
      lastRecordedAt: AccountLastRecord.latest(
        of: accountIds, in: AccountLastRecord.byAccount(dataset)))
  }

  /// The card names a history shows beside its operations, by card: only for the cards of an
  /// account that has more than one — archived ones counted —, where the name tells which one
  /// paid; one card alone says nothing its account does not.
  static func cardNames(of accountIds: Set<UUID>, cards: [PaymentCard]) -> [UUID: String] {
    let own = cards.filter { accountIds.contains($0.accountId) }
    let perAccount = Dictionary(grouping: own, by: \.accountId)
    var names: [UUID: String] = [:]
    for (_, cards) in perAccount where cards.count > 1 {
      for card in cards { names[card.id] = card.name }
    }
    return names
  }

  /// What a transfer did to the accounts on screen: «−1,000 ₽» when it left them, «+1,000 ₽»
  /// when it came in, «1,000 ₽ → 5,700 ₸» when it stayed inside them.
  static func amountText(
    _ transfer: Transfer, accountIds: Set<UUID>, money: MoneyFormatter
  )
    -> String
  {
    let sent = money.exact(transfer.fromAmountE4, currency: transfer.fromCurrency)
    let received = money.exact(transfer.toAmountE4, currency: transfer.toCurrency)
    let out = accountIds.contains(transfer.fromAccountId)
    let into = accountIds.contains(transfer.toAccountId)
    switch (out, into) {
    case (true, true): return transfer.isExchange ? "\(sent) → \(received)" : sent
    case (true, false): return "\u{2212}\(sent)"
    default: return "+\(received)"
    }
  }
}

/// The days of an account or of a group: operations as every list shows them, which can be
/// selected, edited and deleted like the days of Overview, and transfers as rows of their own
/// with ⇄, edited and deleted from their menu.
struct AccountHistoryList<Header: View>: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute

  let accountIds: Set<UUID>
  let history: AccountHistory?
  let actions: OperationActions
  @ViewBuilder var header: () -> Header
  /// A transfer to edit, or «Изменить…» of its menu.
  var editTransfer: (Transfer, TransactionEntry?) -> Void

  @Environment(\.dependencies) private var dependencies

  /// Why the transfer the owner deleted is still there.
  @State private var deleteRefusal: TransferRefusal?
  @State private var deleteFailed = false
  /// A deletion that would leave money on an account in the archive: asked where it goes.
  @State private var asking: TransferDeletionAsk?

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    @Bindable var actions = actions
    let cardNames = AccountHistory.cardNames(
      of: accountIds, cards: compute.snapshot?.dataset.cards ?? [])
    List(selection: $actions.selection) {
      header()
        .listRowSeparator(.hidden)
        .selectionDisabled()
      if let history {
        if history.days.isEmpty {
          Text(verbatim: t("account.screen.empty"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .listRowSeparator(.hidden)
            .selectionDisabled()
        }
        ForEach(history.days) { day in
          Section {
            ForEach(day.items) { item in
              switch item {
              case .operation(let entry):
                TransactionRow(
                  entry: entry, names: compute.snapshot?.ledger.tree ?? CategoryTree(),
                  quality: TransactionListing.quality(of: entry, ledger: compute.snapshot?.ledger),
                  cardName: entry.transaction.cardId.flatMap { cardNames[$0] }
                )
                .tag(entry.id)
              case .transfer(let transfer):
                AccountTransferRow(
                  transfer: transfer, fee: history.fees[transfer.id], accountIds: accountIds,
                  edit: { editTransfer(transfer, history.fees[transfer.id]) },
                  delete: { delete(transfer) })
              }
            }
          } header: {
            DayHeader(day: day.day, totals: day.totals)
          }
        }
      } else {
        // Before the first data: «Считается, ожидайте», as every block says it.
        ComputedBlock<Int, EmptyView>(
          title: nil, state: .calculating, style: .plain, retry: nil
        ) { _ in EmptyView() }
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
        .selectionDisabled()
      }
    }
    .listStyle(.inset)
    .contextMenu(forSelectionType: UUID.self) { ids in
      BulkMenuItems(ids: ids, actions: actions, offersEdit: true)
    } primaryAction: { ids in
      actions.edit(ids, store: store)
    }
    // ↓ in the entry line walks the list from its newest row; Esc clears the selection and
    // hands the keyboard back to the line.
    .walkedFromTheEntryLine(
      firstRow: OperationsWalk.firstRow(of: (history?.days ?? []).map(\.items)),
      selection: $actions.selection
    )
    .onExitCommand {
      actions.selection = []
      NotificationCenter.default.post(name: .returnToEntryLine, object: nil)
    }
    .onDeleteCommand {
      guard !actions.selection.isEmpty else { return }
      actions.requestDeletion(of: actions.selection, store: store)
    }
    // A deletion refused — its fee has a refund or money back — says so in words.
    .alert(
      t("transfer.delete.refused"),
      isPresented: Binding(
        get: { deleteRefusal != nil }, set: { if !$0 { deleteRefusal = nil } }),
      presenting: deleteRefusal
    ) { _ in
      Button(environment.language("action.ok"), role: .cancel) {}
    } message: { refusal in
      Text(verbatim: TransferText.message(refusal, environment))
    }
    .refusedWriteAlert($deleteFailed, environment)
    .sheet(item: $asking) { asked in
      ArchivedMoneySheet(
        check: asked.check,
        confirm: { settling in
          asking = nil
          let transfers = TransferActions(environment: environment, store: store)
          said(transfers.delete(asked.transfer, books: asked.books, settling: settling))
        },
        cancel: { asking = nil }
      )
      .handingOver(dependencies)
    }
  }

  /// A transfer goes with its fee as the books have it now, one step of ⌘Z; ⌘Z brings it
  /// back. Only when it would leave money on an account in the archive — or take it below zero
  /// — is the owner asked which live account takes it, and the transfers that settle it go in
  /// the same step. What kept it is said.
  private func delete(_ transfer: Transfer) {
    let transfers = TransferActions(environment: environment, store: store)
    Task {
      switch await transfers.deleteAsking(transfer) {
      case .finished(let outcome): said(outcome)
      case .ask(let check, let books):
        asking = TransferDeletionAsk(transfer: transfer, check: check, books: books)
      }
    }
  }

  private func said(_ outcome: TransferOutcome) {
    switch outcome {
    case .done: break
    case .refused(let refusal): deleteRefusal = refusal
    case .failed: deleteFailed = true
    }
  }
}

/// A transfer whose deletion asks where the money of an archived account goes: what it would
/// leave there, and the books the question was worked out from.
struct TransferDeletionAsk: Identifiable {
  let id = UUID()
  let transfer: Transfer
  let check: ArchivedMoneyCheck
  let books: AccountBooks
}

/// A transfer in a list of days: ⇄, «Перевод: Сбер → Kaspi», what it did to the accounts on
/// screen, the rate of an exchange and the fee. It is no operation: it cannot be selected
/// with them, and its «…» and context menu edit or delete it.
struct AccountTransferRow: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let transfer: Transfer
  let fee: TransactionEntry?
  let accountIds: Set<UUID>
  let edit: () -> Void
  let delete: () -> Void

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "arrow.left.arrow.right")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title)
          .lineLimit(1)
        if let caption {
          Text(verbatim: caption)
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      Text(
        verbatim: AccountHistory.amountText(
          transfer, accountIds: accountIds, money: environment.money)
      )
      .monospacedDigit()
      Menu {
        items
      } label: {
        Image(systemName: "ellipsis.circle")
          // «Действия с «Перевод: Сбер → Kaspi»»: the row it acts on named, as in every list.
          .accessibilityLabel(Text(verbatim: SettingsRowMenu.label(title, environment)))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2, perform: edit)
    .contextMenu { items }
    .selectionDisabled()
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var items: some View {
    Button(t("accounts.edit"), action: edit)
    Button(t("transfer.row.delete"), role: .destructive, action: delete)
  }

  /// «Перевод: Сбер → Kaspi», «Обмен в Freedom: RUB → KZT» — the words the lists of Overview
  /// and Transactions give the same transfer; an account gone is named `unknown`.
  static func title(
    _ transfer: Transfer, names: [UUID: String], unknown: String, language: AppLanguage
  ) -> String {
    var names = names
    for id in [transfer.fromAccountId, transfer.toAccountId] where names[id] == nil {
      names[id] = unknown
    }
    return TransferRowText(transfer, names: names).title(language: language)
  }

  private var title: String {
    let names = Dictionary(
      (compute.snapshot?.dataset.paymentMethods ?? []).map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first })
    return Self.title(
      transfer, names: names, unknown: t("transfer.unknownAccount"),
      language: environment.language)
  }

  /// The rate of an exchange, the fee and the comment, the ones there are.
  private var caption: String? {
    var parts: [String] = []
    if let rate = TransferText.rate(
      sent: transfer.fromAmountE4, from: transfer.fromCurrency, received: transfer.toAmountE4,
      to: transfer.toCurrency, money: environment.money)
    {
      parts.append(environment.format("transfer.row.rate", table: AccountText.table, rate))
    }
    if let fee {
      parts.append(
        environment.format(
          "transfer.row.fee", table: AccountText.table,
          environment.money.exact(fee.transaction.amountE4, currency: fee.transaction.currency)))
    }
    if let note = transfer.note, !note.isEmpty { parts.append(note) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

/// The balance of an account per currency, as a card at the top of its screen: each in its own
/// currency, exact — it is compared with the bank —, «≈ ₽» for another currency, when it was
/// counted, and what is not known yet.
struct AccountBalancesCard: View {
  @Dependency(\.environment) private var environment
  let line: AccountsSnapshot.AccountLine

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: t("account.screen.balances"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      ForEach(line.keys, id: \.key) { key in
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: key.key.currency.code)
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .leading)
          VStack(alignment: .leading, spacing: 2) {
            if let balance = key.balance {
              Text(verbatim: environment.money.exact(balance, currency: key.key.currency))
                .appFont(.title3.monospacedDigit())
            } else {
              Label {
                Text(verbatim: t("account.screen.notCounted"))
              } icon: {
                Image(systemName: "hourglass")
              }
              .foregroundStyle(.secondary)
            }
            if let caption = caption(key) {
              Text(verbatim: caption)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .accessibilityElement(children: .combine)
      }
      if line.keys.filter({ $0.balance != nil }).count > 1, let total = line.totalRub {
        Divider()
        Text(verbatim: totalLine(total))
          .monospacedDigit()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentCard()
  }

  /// «Всего ≈ 120,000 ₽», and the currencies left out of it for want of a rate.
  private func totalLine(_ total: AmountE4) -> String {
    let sum = environment.format(
      "account.screen.total", table: AccountText.table, environment.money.rounded(total))
    guard !line.withoutRate.isEmpty else { return sum }
    let missing = environment.format(
      "sidebar.withoutRate", table: AccountText.table,
      line.withoutRate.map(\.code).joined(separator: ", "))
    return "\(sum) · \(missing)"
  }

  /// «≈ 1,020,000 ₽ · сверено 26.09, 14:05», «нет курса», «вне списка валют».
  private func caption(_ key: AccountsSnapshot.KeyLine) -> String? {
    var parts: [String] = []
    if key.balance != nil, key.key.currency != .rub {
      parts.append(
        key.rub.map { "≈\u{00A0}\(environment.money.rounded($0))" } ?? t("sidebar.noRate"))
    }
    if let at = key.anchorAt {
      parts.append(
        environment.format(
          "account.screen.countedAt", table: AccountText.table, environment.dates.moment(at)))
    }
    if !key.isHeld { parts.append(t("account.screen.notHeld")) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

/// The screen of one account: its balance per currency and its forecast, its cards, the
/// cashback of the month, the interest it earns and the payments paid from it, its operations and transfers by day,
/// and «Перевод…», «Сверить…», «Изменить…». While it is open, an operation typed in the entry
/// line goes to this account unless the line or the panel names another.
struct AccountScreen: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  let accountId: UUID
  /// The selection of the window, shared with Overview: its bar floats in the entry bar.
  let actions: OperationActions

  @State private var history: AccountHistory?
  @State private var sheet: Sheet?

  enum Sheet: Identifiable {
    case transfer(TransferForm)
    case edit(PaymentMethod)

    var id: String {
      switch self {
      case .transfer(let form): "transfer.\(form.previous?.id.uuidString ?? "new")"
      case .edit(let account): "edit.\(account.id.uuidString)"
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  private var line: AccountsSnapshot.AccountLine? {
    compute.snapshot?.planning.accounts.line(of: accountId)
  }

  private var account: PaymentMethod? {
    line?.account ?? compute.snapshot?.dataset.paymentMethods.first { $0.id == accountId }
  }

  var body: some View {
    AccountHistoryList(
      accountIds: [accountId], history: history, actions: actions,
      header: { header },
      editTransfer: { transfer, fee in
        sheet = .transfer(
          TransferForm(
            editing: transfer, fee: fee?.transaction.amountE4, calendar: environment.calendar))
      }
    )
    .task(id: HistoryKey(ids: [accountId], generation: compute.generation)) {
      await reload()
    }
    .sheet(item: $sheet) { sheet in
      sheetContent(sheet).handingOver(dependencies)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let account {
          Image(systemName: AccountText.kindSymbol(account.kind))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text(verbatim: account.name)
            .appFont(.title2.weight(.semibold))
          if account.isDefault {
            Label {
              Text(verbatim: t("accounts.main"))
            } icon: {
              Image(systemName: "star.fill")
            }
            .labelStyle(.titleAndIcon)
            .appFont(.caption)
            .foregroundStyle(.secondary)
          }
          if account.cushion {
            Label {
              Text(verbatim: t("accounts.cushion"))
            } icon: {
              Image(systemName: CushionText.symbol)
            }
            .labelStyle(.titleAndIcon)
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("account.screen.cushion")
          }
        }
        Spacer()
        buttons
      }
      LastRecordCaption(history: history)
      if let caption = groupCaption {
        Text(verbatim: caption)
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      if let line {
        AccountBalancesCard(line: line)
        AccountForecastCard(accountId: accountId)
      } else if compute.snapshot == nil {
        ComputedBlock<Int, EmptyView>(
          title: t("account.screen.balances"), state: .calculating, retry: nil
        ) { _ in EmptyView() }
      }
      // What pays from the account and what it earns: its cards, the cashback of the month,
      // the interest of a deposit or a savings account, and the payments and subscriptions
      // paid from it.
      if account != nil {
        AccountCreditBlock(accountId: accountId)
        AccountCardsBlock(accountId: accountId)
        AccountCashbackBlock(accountId: accountId)
        AccountInterestBlock(accountId: accountId)
        AccountPaymentsBlock(accountId: accountId)
      }
      Label {
        Text(verbatim: t("account.screen.entryHint"))
      } icon: {
        Image(systemName: "text.cursor")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 8)
  }

  private var buttons: some View {
    HStack(spacing: 8) {
      Button {
        guard let account else { return }
        sheet = .transfer(
          TransferForm(
            from: account, accounts: AccountActions(environment: environment, store: store).all,
            day: environment.today))
      } label: {
        Label {
          Text(verbatim: t("accounts.transfer"))
        } icon: {
          Image(systemName: "arrow.left.arrow.right")
        }
      }
      .accessibilityIdentifier("account.transfer")
      Button {
        environment.focusedAccountId = accountId
        environment.showsReconciliation = true
      } label: {
        Label {
          Text(verbatim: t("accounts.reconcile"))
        } icon: {
          Image(systemName: "checkmark.seal")
        }
      }
      .accessibilityIdentifier("account.reconcile")
      Button {
        if let account { sheet = .edit(account) }
      } label: {
        Label {
          Text(verbatim: t("accounts.edit"))
        } icon: {
          Image(systemName: "pencil")
        }
      }
      .accessibilityIdentifier("account.edit")
    }
    .buttonStyle(.bordered)
    .disabled(account == nil)
  }

  /// The group of the account, and that its money is kept out of the summary.
  private var groupCaption: String? {
    guard let groupId = account?.groupId,
      let section = compute.snapshot?.planning.accounts.sections.first(where: {
        $0.group?.id == groupId
      }),
      let group = section.group
    else { return nil }
    return section.inSummary ? group.name : "\(group.name) · \(t("sidebar.excluded"))"
  }

  @ViewBuilder
  private func sheetContent(_ sheet: Sheet) -> some View {
    switch sheet {
    case .transfer(let form):
      TransferSheet(form: form) { _ in self.sheet = nil }
    case .edit(let account):
      AccountEditor(previous: account, defaultCurrency: environment.defaultCurrency) { _ in
        self.sheet = nil
      }
    }
  }

  private func reload() async {
    guard let snapshot = compute.snapshot,
      let built = await AccountHistoryBuilder.build(
        accountIds: [accountId], snapshot: snapshot, calendar: environment.calendar)
    else { return }
    history = built
    actions.keep(only: built.operationIds)
    actions.reloadDictionaries(from: snapshot.dataset)
  }
}

/// What a screen's history is built for: the accounts, and the data they were read from.
struct HistoryKey: Hashable {
  let ids: Set<UUID>
  let generation: Int
}

/// Builds a history off the main thread: a year of operations is a moment's work, but not one
/// to do where the window draws.
enum AccountHistoryBuilder {
  /// `nil` when the screen gave the build up meanwhile — newer data, another account —: a
  /// build that finishes after a newer one must not lay old rows over it, nor bring back a
  /// transfer just deleted.
  static func build(
    accountIds: Set<UUID>, snapshot: DataSnapshot, calendar: CalendarContext
  ) async -> AccountHistory? {
    let dataset = snapshot.dataset
    let refunds = snapshot.ledger.refundIndex
    let built = await Task.detached(priority: .userInitiated) {
      AccountHistory.build(
        accountIds: accountIds, dataset: dataset, refunds: refunds, calendar: calendar)
    }.value
    return Task.isCancelled ? nil : built
  }
}
