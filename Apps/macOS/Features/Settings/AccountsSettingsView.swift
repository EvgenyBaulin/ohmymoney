import AppCore
import AppDatabase
import SwiftUI

/// Settings → Счета: every bank, account and group, the archived ones too.
///
/// The banks come first, each with how many accounts and cards stand under it: «bank → account →
/// card». A new bank brings its first account and card; an account is added to a bank from its
/// menu; a bank is merged into another — its accounts move under that one, one step of ⌘Z —, goes
/// to the archive once every account under it has, and is deleted only with no account under it —
/// an account deleted leaves its bank where it was. Accounts merge only within one bank.
///
/// The accounts are listed the way every menu lists them — the main account first and marked,
/// then in the order the owner dragged them to, alphabetical until then — and can be dragged,
/// put back in alphabetical order, edited, made main, merged, archived and brought back, and
/// deleted while nothing points at them. The groups carry «Учитывать в общей сводке». The cards
/// of an account are lines inside its row, each with its own «…»: edit, cashback rules, archive,
/// delete while unused. Each change is one step of ⌘Z, but a merge and a deletion of an account
/// or a group, which are not undone.
struct AccountsSettingsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  @State private var accounts: [PaymentMethod] = []
  @State private var groups: [AccountGroup] = []
  @State private var banks: [Bank] = []
  @State private var cards: [PaymentCard] = []
  @State private var rules: [CashbackRule] = []
  /// The card the owner asked to delete, waiting for the answer.
  @State private var deletingCard: PaymentCard?
  /// What the last action on a card was refused for, said under the list.
  @State private var cardRefusal: CardRefusal?
  /// Accounts picked in the list, for «Удалить» of several unused ones at once.
  @State private var selection: Set<UUID> = []
  @State private var showsArchive = false
  @State private var sheet: Sheet?
  /// What the last action was refused for, said under the list.
  @State private var refusal: AccountRefusal?
  /// The deletion the owner asked for, waiting for the answer.
  @State private var deleting: Deletion?
  /// The group the owner asked to delete, waiting for the answer.
  @State private var deletingGroup: AccountGroup?
  /// The bank the owner asked to delete, waiting for the answer.
  @State private var deletingBank: Bank?
  /// A write the database refused; the alert says so.
  @State private var failed = false

  /// What the tab shows over itself.
  enum Sheet: Identifiable {
    case account(PaymentMethod?)
    /// A new account added to this bank.
    case accountInBank(UUID)
    case bank(Bank?)
    case group(AccountGroup?)
    case merge(PaymentMethod, into: UUID?)
    case handOver(PaymentMethod, Hand, candidates: [PaymentMethod], preselected: UUID?)
    /// «В архив» on an account that still holds money: where each currency of it goes.
    case archiveMoney(PaymentMethod, newMain: UUID?)
    /// A new card of the account, or an edit of one.
    case card(PaymentCard?, accountId: UUID)
    /// The cashback rules of a card, or of an account without cards.
    case cashback(accountId: UUID, CashbackHolder)
    /// «Объединить с…» of a card: into another live card of its account.
    case mergeCard(PaymentCard)
    /// «Объединить с…» of a bank: into another live bank.
    case mergeBank(Bank)

    /// What the main account is leaving for: the archive, or a deletion of these accounts —
    /// the main one and any others picked with it.
    enum Hand {
      case archive
      case delete([UUID])
    }

    var id: String {
      switch self {
      case .account(let account): "account.\(account?.id.uuidString ?? "new")"
      case .accountInBank(let bank): "accountInBank.\(bank.uuidString)"
      case .bank(let bank): "bank.\(bank?.id.uuidString ?? "new")"
      case .group(let group): "group.\(group?.id.uuidString ?? "new")"
      case .merge(let account, _): "merge.\(account.id.uuidString)"
      case .handOver(let account, _, _, _): "handOver.\(account.id.uuidString)"
      case .archiveMoney(let account, _): "archiveMoney.\(account.id.uuidString)"
      case .card(let card, let accountId):
        "card.\(card?.id.uuidString ?? "new").\(accountId.uuidString)"
      case .cashback(let accountId, let holder): "cashback.\(accountId.uuidString).\(holder)"
      case .mergeCard(let card): "mergeCard.\(card.id.uuidString)"
      case .mergeBank(let bank): "mergeBank.\(bank.id.uuidString)"
      }
    }
  }

  /// Accounts about to be deleted for good, asked first.
  struct Deletion: Identifiable {
    let ids: [UUID]
    let names: [String]
    var id: [UUID] { ids }
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }
  private var cardActions: CardActions { CardActions(environment: environment, store: store) }

  private func t(_ key: String) -> String { environment.language(key, table: "Accounts") }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Toggle(isOn: $showsArchive) {
          Text(verbatim: t("accounts.showArchive"))
        }
        .toggleStyle(.checkbox)
        Spacer()
        Button(t("accounts.alphabetize")) { perform(actions.alphabetize()) }
          .disabled(!live.contains { $0.sort != 0 } || store.isWritingInBackground)
          .help(t("accounts.alphabetizeHint"))
        Button {
          sheet = .group(nil)
        } label: {
          Label {
            Text(verbatim: t("accounts.newGroup"))
          } icon: {
            Image(systemName: "folder.badge.plus")
          }
        }
        Button {
          sheet = .bank(nil)
        } label: {
          Label {
            Text(verbatim: t("accounts.newBank"))
          } icon: {
            Image(systemName: "building.columns")
          }
        }
        .accessibilityIdentifier("accounts.newBank")
        Button {
          sheet = .account(nil)
        } label: {
          Label {
            Text(verbatim: t("accounts.newAccount"))
          } icon: {
            Image(systemName: "plus")
          }
        }
        .accessibilityIdentifier("accounts.newAccount")
      }
      list
      // Under the list, not as footers of its sections: a footer of a list is one line and
      // cuts these off.
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: t("accounts.orderHint"))
        Text(verbatim: t("accounts.groupsHint"))
        Text(verbatim: t("accounts.banksHint"))
      }
      .appFont(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      footer
    }
    .padding()
    .onAppear(perform: reload)
    // A change made elsewhere — the sidebar, the setup, ⌘Z — shows here at once.
    .onChange(of: compute.generation) { reload() }
    .sheet(item: $sheet) { sheet in
      sheetContent(sheet).handingOver(dependencies)
    }
    .confirmationDialog(
      deleting.map(deleteTitle) ?? "", isPresented: isAskingToDelete, titleVisibility: .visible,
      presenting: deleting
    ) { question in
      Button(environment.language("action.delete"), role: .destructive) { delete(question) }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { question in
      Text(verbatim: deleteMessage(count: question.ids.count))
    }
    // A bank is deleted for good and the ⌘Z history with it: asked first, like a group.
    .confirmationDialog(
      deletingBank.map {
        environment.format("accounts.deleteBank.title", table: "Accounts", $0.name)
      } ?? "",
      isPresented: isAskingToDeleteBank, titleVisibility: .visible, presenting: deletingBank
    ) { bank in
      Button(environment.language("action.delete"), role: .destructive) {
        deletingBank = nil
        perform(actions.deleteBank(bank.id))
      }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { _ in
      Text(verbatim: t("accounts.deleteBank.message"))
    }
    // A card goes with its rules; ⌘Z brings both back.
    .confirmationDialog(
      deletingCard.map {
        environment.format("card.delete.title", table: CardText.table, $0.name)
      } ?? "",
      isPresented: Binding(get: { deletingCard != nil }, set: { if !$0 { deletingCard = nil } }),
      titleVisibility: .visible, presenting: deletingCard
    ) { card in
      Button(environment.language("action.delete"), role: .destructive) {
        deletingCard = nil
        perform(cardActions.delete(card.id))
      }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { _ in
      Text(verbatim: environment.language("card.delete.message", table: CardText.table))
    }
    .refusedWriteAlert($failed, environment)
  }

  // MARK: The list

  private var list: some View {
    List(selection: $selection) {
      Section {
        if liveBanks.isEmpty {
          Text(verbatim: t("accounts.noBanks"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
        }
        ForEach(liveBanks, id: \.id) { bank in
          bankRow(bank)
            .selectionDisabled()
        }
      } header: {
        Text(verbatim: t("accounts.section.banks"))
          .settingsHeaderStyle()
      }

      Section {
        ForEach(live, id: \.id) { account in
          accountRow(account)
            .tag(account.id)
            .moveDisabled(account.isDefault)
        }
        .onMove { source, destination in
          perform(actions.reorder(from: source, to: destination))
        }
      } header: {
        Text(verbatim: t("accounts.section.accounts"))
          .settingsHeaderStyle()
      }

      Section {
        if liveGroups.isEmpty {
          Text(verbatim: t("accounts.noGroups"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
        }
        ForEach(liveGroups, id: \.id) { group in
          groupRow(group)
            .selectionDisabled()
        }
      } header: {
        Text(verbatim: t("accounts.section.groups"))
          .settingsHeaderStyle()
      }

      if showsArchive {
        Section {
          if archived.isEmpty && archivedGroups.isEmpty && archivedCards.isEmpty
            && archivedBanks.isEmpty
          {
            Text(verbatim: t("accounts.archiveEmpty"))
              .appFont(.callout)
              .foregroundStyle(.secondary)
          }
          ForEach(archived, id: \.id) { account in
            archivedRow(account)
              .tag(account.id)
          }
          ForEach(archivedCards, id: \.id) { card in
            archivedCardRow(card)
              .selectionDisabled()
          }
          ForEach(archivedGroups, id: \.id) { group in
            archivedGroupRow(group)
              .selectionDisabled()
          }
          ForEach(archivedBanks, id: \.id) { bank in
            archivedBankRow(bank)
              .selectionDisabled()
          }
        } header: {
          Text(verbatim: t("accounts.section.archive"))
            .settingsHeaderStyle()
        }
      }
    }
    .frame(minHeight: 280)
    .accessibilityIdentifier("accounts.list")
    // A group is deleted for good and the ⌘Z history with it: asked first, like an account.
    .confirmationDialog(
      deletingGroup.map {
        environment.format("accounts.deleteGroup.title", table: "Accounts", $0.name)
      } ?? "",
      isPresented: isAskingToDeleteGroup, titleVisibility: .visible, presenting: deletingGroup
    ) { group in
      Button(environment.language("action.delete"), role: .destructive) {
        deletingGroup = nil
        perform(actions.deleteGroup(group.id))
      }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { _ in
      Text(verbatim: t("accounts.deleteGroup.message"))
    }
    // The menu of the rows picked and the double click — or Return — that opens the editor,
    // the way a list of the system does it; a gesture of the row's own would take the click
    // from the selection.
    .contextMenu(forSelectionType: UUID.self) { ids in
      if ids.count == 1, let account = accounts.first(where: { ids.contains($0.id) }) {
        if account.archived {
          archivedMenuItems(account)
        } else {
          accountMenuItems(account)
        }
      } else if ids.count > 1 {
        Button(t("accounts.deleteSelected"), role: .destructive) { askToDelete(Array(ids)) }
      }
    } primaryAction: { ids in
      guard ids.count == 1, let account = accounts.first(where: { ids.contains($0.id) }) else {
        return
      }
      sheet = .account(account)
    }
  }

  /// The account, and its live cards as lines inside its row: the row is what is dragged, so a
  /// card never lands between two accounts.
  private func accountRow(_ account: PaymentMethod) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      accountLine(account)
      ForEach(liveCards(of: account.id), id: \.id) { card in
        cardLine(card)
      }
    }
  }

  private func accountLine(_ account: PaymentMethod) -> some View {
    HStack(spacing: 8) {
      Image(systemName: AccountText.kindSymbol(account.kind))
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(verbatim: account.name)
          if account.isDefault {
            // The main account is told by a symbol and a word, never by colour alone.
            Label {
              Text(verbatim: t("accounts.main"))
            } icon: {
              Image(systemName: "star.fill")
            }
            .labelStyle(.titleAndIcon)
            .appFont(.callout)
            .foregroundStyle(.secondary)
          }
        }
        Text(verbatim: caption(of: account))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      accountMenu(account)
    }
  }

  /// A card inside its account's row: its name, how many cashback rules it keeps of its own —
  /// none, it follows its account's —, and its own «…».
  private func cardLine(_ card: PaymentCard) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "creditcard")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(verbatim: card.name)
          if isMainCard(card) {
            // The main card is told by a symbol and a word, like the main account.
            Label {
              Text(verbatim: environment.language("card.main", table: CardText.table))
            } icon: {
              Image(systemName: "star.fill")
            }
            .labelStyle(.titleAndIcon)
            .appFont(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("accounts.card.main")
          }
        }
        Text(
          verbatim: ([card.aliases.isEmpty ? nil : card.aliases.joined(separator: ", ")]
            + [cardRulesCaption(card)]).compactMap { $0 }.joined(separator: " · ")
        )
        .appFont(.callout)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Menu {
        cardMenuItems(card)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(Text(verbatim: SettingsRowMenu.label(card.name, environment)))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .padding(.leading, 26)
    .contextMenu { cardMenuItems(card) }
  }

  /// «своих правил кэшбэка: 2», or «правила — как у счёта» for a card with none of its own.
  private func cardRulesCaption(_ card: PaymentCard) -> String {
    let own = rules.filter { $0.cardId == card.id }.count
    guard own > 0 else { return environment.language("card.captionFollows", table: CardText.table) }
    return environment.format("card.caption", table: CardText.table, counts: own)
  }

  /// Whether the card is the main one of its account: purchases on the account are made with
  /// it unless they name another card or «со счёта».
  private func isMainCard(_ card: PaymentCard) -> Bool {
    guard let account = accounts.first(where: { $0.id == card.accountId }) else { return false }
    return CardRules.validMainCard(of: account, cards: cards) == card.id
  }

  @ViewBuilder
  private func cardMenuItems(_ card: PaymentCard) -> some View {
    Button(environment.language("action.edit")) {
      sheet = .card(card, accountId: card.accountId)
    }
    if !card.archived, !isMainCard(card) {
      Button(environment.language("card.makeMain", table: CardText.table)) {
        perform(cardActions.makeMain(card.id))
      }
    }
    Button(environment.language("card.cashback", table: CardText.table)) {
      sheet = .cashback(accountId: card.accountId, .card(card.id))
    }
    if liveCards(of: card.accountId).count > 1 {
      Button(environment.language("card.merge", table: CardText.table)) {
        sheet = .mergeCard(card)
      }
    }
    Divider()
    Button(environment.language("card.archive", table: CardText.table)) {
      perform(cardActions.archive(card.id))
    }
    Button(environment.language("card.delete", table: CardText.table), role: .destructive) {
      deletingCard = card
    }
  }

  /// A card in the archive, named with its account: «Вернуть», and «Удалить…» while unused.
  private func archivedCardRow(_ card: PaymentCard) -> some View {
    let account = accounts.first { $0.id == card.accountId }?.name ?? ""
    return HStack(spacing: 8) {
      Image(systemName: "archivebox")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      Label {
        Text(verbatim: account + AccountLabels.separator + card.name)
      } icon: {
        Image(systemName: "creditcard")
      }
      Spacer()
      Button(environment.language("card.restore", table: CardText.table)) {
        perform(cardActions.restore(card.id))
      }
      Menu {
        Button(environment.language("card.restore", table: CardText.table)) {
          perform(cardActions.restore(card.id))
        }
        Divider()
        Button(environment.language("card.delete", table: CardText.table), role: .destructive) {
          deletingCard = card
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(Text(verbatim: SettingsRowMenu.label(card.name, environment)))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  /// Its kind, currencies — the main one first —, group, and the bank when that is called
  /// otherwise than the account.
  private func caption(of account: PaymentMethod) -> String {
    var parts = [t(AccountText.kindKey(account.kind))]
    if account.credit != nil {
      parts.append(environment.language("accounts.caption.credit", table: "Settings"))
    }
    parts.append(account.currencies.map(\.code).joined(separator: ", "))
    if let id = account.groupId, let group = groups.first(where: { $0.id == id }) {
      parts.append(AccountText.groupTitle(group, environment))
    }
    if let id = account.bankId, let bank = banks.first(where: { $0.id == id }),
      NameKey.fold(bank.name) != NameKey.fold(account.name)
    {
      parts.append(environment.format("accounts.caption.bank", table: "Accounts", bank.name))
    }
    return parts.joined(separator: " · ")
  }

  /// The visible «…» of a row, the same items as its context menu.
  private func accountMenu(_ account: PaymentMethod) -> some View {
    Menu {
      accountMenuItems(account)
    } label: {
      Image(systemName: "ellipsis.circle")
        .accessibilityLabel(Text(verbatim: SettingsRowMenu.label(account.name, environment)))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  @ViewBuilder
  private func accountMenuItems(_ account: PaymentMethod) -> some View {
    Button(t("accounts.edit")) { sheet = .account(account) }
    if !account.isDefault {
      Button(t("accounts.makeMain")) { perform(actions.makeMain(account.id)) }
      // The order without a drag, for the keyboard and VoiceOver; nothing goes above the
      // main account.
      let index = live.firstIndex { $0.id == account.id }
      Button(t("accounts.moveUp")) { perform(actions.move(account.id, by: -1)) }
        .disabled(index.map { $0 == 0 || live[$0 - 1].isDefault } ?? true)
      Button(t("accounts.moveDown")) { perform(actions.move(account.id, by: 1)) }
        .disabled(index.map { $0 == live.count - 1 } ?? true)
    }
    if !actions.mergeTargets(for: account).isEmpty {
      Button(t("accounts.mergeWith")) { sheet = .merge(account, into: nil) }
    }
    Divider()
    Button(environment.language("card.add", table: CardText.table)) {
      sheet = .card(nil, accountId: account.id)
    }
    // The rules belong to the account, whatever cards it has: its cards follow them.
    Button(environment.language("card.cashback", table: CardText.table)) {
      sheet = .cashback(accountId: account.id, .account(account.id))
    }
    // The terms of a credit card live in the editor of its account: the same sheet, over the
    // settings.
    if account.kind == .card || account.credit != nil {
      Button(environment.language("accounts.creditTerms", table: "Settings")) {
        sheet = .account(account)
      }
    }
    Divider()
    Button(t("accounts.archive")) { archive(account) }
    Button(t("accounts.delete"), role: .destructive) { askToDelete([account.id]) }
  }

  /// A bank: its name, how many accounts and cards stand under it, and its own «…».
  private func bankRow(_ bank: Bank) -> some View {
    let live = accounts.filter { $0.bankId == bank.id && !$0.archived }
    let liveIds = Set(live.map(\.id))
    let cardCount = cards.filter { !$0.archived && liveIds.contains($0.accountId) }.count
    return HStack(spacing: 8) {
      Image(systemName: "building.columns")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: bank.name)
        Text(verbatim: bankCaption(accounts: live.count, cards: cardCount))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Menu {
        bankMenuItems(bank)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(Text(verbatim: SettingsRowMenu.label(bank.name, environment)))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { sheet = .bank(bank) }
    .contextMenu { bankMenuItems(bank) }
  }

  /// «2 счёта · 3 карты»; «Нет счетов» for a bank all of whose accounts are gone or archived.
  private func bankCaption(accounts: Int, cards: Int) -> String {
    guard accounts > 0 else { return t("bank.caption.none") }
    return [
      environment.format("bank.caption.accounts", table: "Accounts", counts: accounts),
      environment.format("bank.caption.cards", table: "Accounts", counts: cards),
    ].joined(separator: " · ")
  }

  @ViewBuilder
  private func bankMenuItems(_ bank: Bank) -> some View {
    Button(t("accounts.edit")) { sheet = .bank(bank) }
    Button(t("bank.addAccount")) { sheet = .accountInBank(bank.id) }
    if BankMerge.offered(for: bank, banks: banks) {
      Button(t("accounts.mergeWith")) { sheet = .mergeBank(bank) }
    }
    Divider()
    Button(t("accounts.archive")) { perform(actions.archiveBank(bank.id)) }
    Button(t("accounts.delete"), role: .destructive) { askToDelete(bank) }
  }

  private func archivedBankRow(_ bank: Bank) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "archivebox")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      Text(verbatim: environment.format("accounts.archivedBank", table: "Accounts", bank.name))
      Spacer()
      Button(t("accounts.restore")) { perform(actions.restoreBank(bank.id)) }
      Button(t("accounts.delete"), role: .destructive) { askToDelete(bank) }
    }
  }

  private func groupRow(_ group: AccountGroup) -> some View {
    let holdsMain = accounts.contains { $0.isDefault && !$0.archived && $0.groupId == group.id }
    let count = accounts.filter { $0.groupId == group.id && !$0.archived }.count
    return HStack(spacing: 8) {
      Image(systemName: group.inSummary ? "folder" : "eye.slash")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: group.name)
        // Why its switch cannot be moved, said in words beside the greyed switch.
        Text(
          verbatim: holdsMain
            ? environment.format(
              "accounts.group.countWithMain", table: "Accounts", counts: count)
            : environment.format("accounts.group.count", table: "Accounts", counts: count)
        )
        .appFont(.callout)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Toggle(
        isOn: Binding(
          get: { group.inSummary },
          set: { perform(actions.setInSummary(group.id, $0)) })
      ) {
        Text(verbatim: t("account.group.inSummary"))
      }
      .toggleStyle(.switch)
      .controlSize(.small)
      .fixedSize()
      .disabled(holdsMain || store.isWritingInBackground)
      .help(holdsMain ? t("account.group.holdsMain") : t("account.group.inSummaryHint"))
      Menu {
        groupMenuItems(group)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(Text(verbatim: SettingsRowMenu.label(group.name, environment)))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { sheet = .group(group) }
    .contextMenu { groupMenuItems(group) }
  }

  @ViewBuilder
  private func groupMenuItems(_ group: AccountGroup) -> some View {
    Button(t("accounts.edit")) { sheet = .group(group) }
    Divider()
    Button(t("accounts.archive")) { perform(actions.archiveGroup(group.id)) }
    Button(t("accounts.delete"), role: .destructive) { askToDelete(group) }
  }

  private func archivedRow(_ account: PaymentMethod) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "archivebox")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: account.name)
        Text(verbatim: caption(of: account))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button(t("accounts.restore")) { perform(actions.restore(account.id)) }
      Menu {
        archivedMenuItems(account)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(Text(verbatim: SettingsRowMenu.label(account.name, environment)))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  @ViewBuilder
  private func archivedMenuItems(_ account: PaymentMethod) -> some View {
    Button(t("accounts.restore")) { perform(actions.restore(account.id)) }
    Button(t("accounts.edit")) { sheet = .account(account) }
    Divider()
    Button(t("accounts.delete"), role: .destructive) { askToDelete([account.id]) }
  }

  private func archivedGroupRow(_ group: AccountGroup) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "archivebox")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      Text(verbatim: environment.format("accounts.archivedGroup", table: "Accounts", group.name))
      Spacer()
      Button(t("accounts.restore")) { perform(actions.restoreGroup(group.id)) }
      Button(t("accounts.delete"), role: .destructive) { askToDelete(group) }
    }
  }

  @ViewBuilder
  private var footer: some View {
    if let cardRefusal {
      CardRefusalNote(refusal: cardRefusal)
    }
    if let refusal {
      // An account in use cannot be deleted: the note offers a merge and the archive instead,
      // while it is live.
      AccountRefusalNote(
        refusal: refusal, restore: { perform(actions.restore($0)) },
        merge: mergeInstead(of: refusal), archive: archiveInstead(of: refusal))
    }
    if selection.count > 1 {
      HStack {
        Text(
          verbatim: environment.format(
            "accounts.selected", table: "Accounts", counts: selection.count)
        )
        .appFont(.callout)
        .foregroundStyle(.secondary)
        Spacer()
        Button(t("accounts.deleteSelected"), role: .destructive) {
          askToDelete(Array(selection))
        }
        .disabled(store.isWritingInBackground)
      }
    }
  }

  /// «Объединить с…» for a live account a deletion was refused for, when it has a target.
  private func mergeInstead(of refusal: AccountRefusal) -> ((UUID) -> Void)? {
    guard let account = live.first(where: { $0.id == refusal.accountInUse }),
      !actions.mergeTargets(for: account).isEmpty
    else { return nil }
    return { _ in sheet = .merge(account, into: nil) }
  }

  /// «В архив» for a live account a deletion was refused for.
  private func archiveInstead(of refusal: AccountRefusal) -> ((UUID) -> Void)? {
    guard let account = live.first(where: { $0.id == refusal.accountInUse }) else { return nil }
    return { _ in archive(account) }
  }

  // MARK: Sheets

  @ViewBuilder
  private func sheetContent(_ sheet: Sheet) -> some View {
    switch sheet {
    case .account(let account):
      AccountEditor(previous: account, defaultCurrency: environment.defaultCurrency) { saved in
        self.sheet = nil
        if saved != nil { refusal = nil }
        reload()
      }
    case .accountInBank(let bank):
      AccountEditor(previous: nil, defaultCurrency: environment.defaultCurrency, bank: bank) {
        saved in
        self.sheet = nil
        if saved != nil { refusal = nil }
        reload()
      }
    case .bank(let bank):
      BankEditor(previous: bank) { saved in
        self.sheet = nil
        if saved != nil { refusal = nil }
        reload()
      }
    case .group(let group):
      AccountGroupEditor(previous: group) { saved in
        self.sheet = nil
        if saved != nil { refusal = nil }
        reload()
      }
    case .merge(let account, let target):
      AccountMergeSheet(
        source: account, targets: actions.mergeTargets(for: account), preselected: target
      ) { merged in
        self.sheet = nil
        if merged {
          refusal = nil
          selection = []
        }
        reload()
      }
    case .handOver(let account, let hand, let candidates, let preselected):
      switch hand {
      case .archive:
        MainHandOverSheet(
          leaving: account, candidates: candidates, preselected: preselected,
          confirmTitle: t("accounts.archive"),
          confirm: { next in
            self.sheet = nil
            archive(account, newMain: next)
          },
          cancel: { self.sheet = nil })
      case .delete(let ids):
        // The choice of the new main account is also the confirmation of the deletion, so
        // the sheet says it cannot be undone.
        MainHandOverSheet(
          leaving: account, candidates: candidates, preselected: preselected,
          confirmTitle: t("accounts.delete"), note: deleteMessage(count: ids.count),
          confirm: { next in
            self.sheet = nil
            if perform(actions.delete(ids, newMain: next)) { selection = [] }
          },
          cancel: { self.sheet = nil })
      }
    case .archiveMoney(let account, let newMain):
      ArchivedMoneySheet(archiving: account, newMain: newMain) { archived in
        self.sheet = nil
        if archived {
          refusal = nil
          selection = []
        }
        reload()
      }
    case .card(let card, let accountId):
      CardEditor(previous: card, accountId: accountId) { _ in
        self.sheet = nil
        reload()
      }
    case .cashback(let accountId, let holder):
      CashbackRulesSheet(accountId: accountId, holder: holder) {
        self.sheet = nil
        reload()
      }
    case .mergeCard(let card):
      CardMergeSheet(card: card) { merged in
        self.sheet = nil
        if merged { cardRefusal = nil }
        reload()
      }
    case .mergeBank(let bank):
      BankMergeSheet(bank: bank) { merged in
        self.sheet = nil
        if merged { refusal = nil }
        reload()
      }
    }
  }

  // MARK: Actions

  /// Into the archive; the main account first asks which one takes over. Money still on the
  /// account is asked about — where each currency goes — and moved with the archive in one
  /// step; a balance nobody knows keeps it out, and the note under the list says so.
  private func archive(_ account: PaymentMethod, newMain: UUID? = nil) {
    Task {
      guard let books = await actions.books() else {
        failed = true
        return
      }
      let reason = actions.archiveRefusal(account, books: books)
      if account.isDefault, newMain == nil {
        // What keeps it out is said before the question of who takes over.
        if let reason, reason != .hasMoney {
          refusal = reason
          return
        }
        let next = actions.successors(leaving: account.id, books: books)
        sheet = .handOver(account, .archive, candidates: next.all, preselected: next.preselected)
        return
      }
      if reason == .hasMoney {
        sheet = .archiveMoney(account, newMain: newMain)
        return
      }
      perform(actions.archive(account.id, newMain: newMain, books: books))
    }
  }

  /// Deleting: only accounts nothing points at, asked first. When the main account is among
  /// them, the question of who takes over — which none of the others can — asks it.
  private func askToDelete(_ ids: [UUID]) {
    guard let repository = environment.accounts else { return }
    for id in ids {
      if let usage = try? repository.usage(of: id), usage.isUsed {
        refusal = .inUse(id, usage)
        return
      }
    }
    if let main = accounts.first(where: { ids.contains($0.id) && $0.isDefault && !$0.archived }) {
      Task {
        guard let books = await actions.books() else {
          failed = true
          return
        }
        let next = actions.successors(leaving: Set(ids), books: books)
        sheet = .handOver(
          main, .delete(ids), candidates: next.all, preselected: next.preselected)
      }
      return
    }
    let names = accounts.filter { ids.contains($0.id) }.map(\.name)
    deleting = Deletion(ids: ids, names: names)
  }

  private func delete(_ question: Deletion) {
    deleting = nil
    if perform(actions.delete(question.ids)) { selection = [] }
  }

  private var isAskingToDelete: Binding<Bool> {
    Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
  }

  /// A group is asked about only when it can go: filed accounts, archived ones too, keep it.
  private func askToDelete(_ group: AccountGroup) {
    guard !accounts.contains(where: { $0.groupId == group.id }) else {
      refusal = .groupInUse
      return
    }
    deletingGroup = group
  }

  private var isAskingToDeleteGroup: Binding<Bool> {
    Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } })
  }

  /// A bank is asked about only when it can go: an account under it, archived ones too, keeps it.
  private func askToDelete(_ bank: Bank) {
    guard BankRules.canBeDeleted(bank.id, among: accounts) else {
      refusal = .bankInUse
      return
    }
    deletingBank = bank
  }

  private var isAskingToDeleteBank: Binding<Bool> {
    Binding(get: { deletingBank != nil }, set: { if !$0 { deletingBank = nil } })
  }

  /// That nothing refers to the account — or to the accounts — and that a deletion is not
  /// undone.
  private func deleteMessage(count: Int) -> String {
    t(count == 1 ? "accounts.delete.message" : "accounts.delete.messageMany")
  }

  private func deleteTitle(_ question: Deletion) -> String {
    question.names.count == 1
      ? environment.format("accounts.delete.titleOne", table: "Accounts", question.names[0])
      : environment.format(
        "accounts.delete.titleMany", table: "Accounts", counts: question.names.count)
  }

  /// Says what came of an action and shows the lists as they are now. Returns whether it was
  /// done.
  @discardableResult
  private func perform(_ outcome: AccountActionOutcome) -> Bool {
    switch outcome {
    case .done: refusal = nil
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
    cardRefusal = nil
    reload()
    return outcome == .done
  }

  /// The same for an action on a card.
  private func perform(_ outcome: CardActionOutcome) {
    switch outcome {
    case .done: cardRefusal = nil
    case .refused(let reason): cardRefusal = reason
    case .failed: failed = true
    }
    reload()
  }

  // MARK: Data

  private var live: [PaymentMethod] { actions.ordered(accounts) }

  private var archived: [PaymentMethod] {
    accounts.filter(\.archived).sorted {
      $0.name.compare($1.name, options: [.caseInsensitive], locale: environment.language.locale)
        == .orderedAscending
    }
  }

  private var liveGroups: [AccountGroup] { groups.filter { !$0.archived } }
  private var archivedGroups: [AccountGroup] { groups.filter(\.archived) }

  private var liveBanks: [Bank] { BankRules.ordered(banks, locale: environment.language.locale) }
  private var archivedBanks: [Bank] {
    banks.filter(\.archived).sorted {
      BankRules.precedes($0, $1, locale: environment.language.locale)
    }
  }

  /// The live cards of an account, in the order of the lists.
  private func liveCards(of accountId: UUID) -> [PaymentCard] {
    CardRules.ordered(cards, of: accountId, locale: environment.language.locale)
  }

  /// The archived cards of the live accounts; an archived account's cards go and come back
  /// with it.
  private var archivedCards: [PaymentCard] {
    let live = Set(accounts.filter { !$0.archived }.map(\.id))
    return cards.filter { $0.archived && live.contains($0.accountId) }
      .sorted { CardRules.precedes($0, $1, locale: environment.language.locale) }
  }

  private func reload() {
    accounts = actions.all
    groups = actions.groups
    banks = actions.banks
    cards = cardActions.cards
    rules = cardActions.rules
    selection = selection.filter { id in accounts.contains { $0.id == id } }
  }
}
