import AppCore
import AppDatabase
import SwiftUI

/// Settings → Счета: one tree of every group, bank, account and card, with the panel of the row
/// chosen beside it — the design's «единое дерево с правкой справа».
///
/// * The tree (`AccountsTree`): group → bank → account → card, each with its money; «Без
///   группы», «Скрытые» and the archive after the groups. A chevron folds a row, «Свернуть всё»
///   folds them all, the search keeps what it finds and the rows above it.
/// * A click chooses a row and the panel on the right edits it at once: an account's bank,
///   group, name, currency, colour, cashback, main card, «В сводке» of its group and «Скрыть
///   счёт»; each change is one step of ⌘Z. The editor of every field of an account, the cashback
///   rules, a merge, the hand-over of the main account and the money of an archived account stay
///   sheets over the settings.
/// * The marks pick accounts for «В группу…», «Скрыть» and «В архив» together; an account is
///   dragged to another group and place. «+» on a bank adds an account to it, on an account a
///   card. Every action of the old list is in the menu of its row.
/// * On an iPhone the tree stands alone: a row pushes its panel, and «Изменить» shows the marks
///   and the handles.
///
/// The list is made empty and filled in `onAppear`: SwiftUI handed a table its rows while it made
/// it, and AppKit touched the table from its own delegate.
struct AccountsSettingsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.appTheme) private var theme
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  @State private var accounts: [PaymentMethod] = []
  @State private var groups: [AccountGroup] = []
  @State private var banks: [Bank] = []
  @State private var cards: [PaymentCard] = []
  @State private var rules: [CashbackRule] = []
  /// The rows folded.
  @State private var folded: Set<String> = AccountsTree.foldedAtFirst
  @State private var query = ""
  /// The row the panel edits.
  @State private var chosen: String?
  /// On an iPhone: the row whose panel is pushed.
  @State private var pushed: String?
  /// The accounts marked for the bar under the tree.
  @State private var marked: Set<UUID> = []
  /// On an iPhone: «Изменить» shows the marks and the handles.
  @State private var editing = false
  /// The row the pointer is over: its «…» shows.
  @State private var hovered: String?
  /// The deletion of a card asked, waiting for the answer.
  @State private var deletingCard: PaymentCard?
  /// What the last action on a card was refused for, said under the tree.
  @State private var cardRefusal: CardRefusal?
  @State private var sheet: Sheet?
  /// What the last action was refused for, said under the tree.
  @State private var refusal: AccountRefusal?
  @State private var deleting: Deletion?
  @State private var deletingGroup: AccountGroup?
  @State private var deletingBank: Bank?
  /// What a deletion was refused for: said by an alert at once.
  @State private var deleteRefusal: AccountRefusal?
  /// A write the database refused; the alert says so.
  @State private var failed = false
  /// The name typed in the panel, written when the field is left or Return pressed.
  @State private var nameDraft = ""
  @FocusState private var nameFocused: Bool

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
      case delete([UUID], [HeldMoney])
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
    /// The money counts put on these accounts, which leaves every total with them.
    var held: [HeldMoney] = []
    var id: [UUID] { ids }
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }
  private var cardActions: CardActions { CardActions(environment: environment, store: store) }

  private func t(_ key: String) -> String { environment.language(key, table: "Accounts") }
  private func w(_ key: String) -> String { environment.language(key, table: EntryLinks.table) }

  /// The tree stands alone and pushes its panel: an iPhone.
  private var isCompact: Bool {
    #if os(iOS)
      sizeClass == .compact
    #else
      false
    #endif
  }

  /// The marks and the handles show: always on a Mac and an iPad, after «Изменить» on an iPhone.
  private var showsMarks: Bool { !isCompact || editing }

  var body: some View {
    VStack(alignment: .leading, spacing: AccountsTreeMetrics.searchGap) {
      searchRow
      HStack(alignment: .top, spacing: AccountsTreeMetrics.columnGap) {
        treeCard
          .frame(minWidth: AccountsTreeMetrics.treeMinWidth, maxWidth: .infinity)
        if !isCompact {
          panelCard
            .frame(width: AccountsTreeMetrics.panelWidth)
        }
      }
      .frame(maxHeight: .infinity)
      footer
    }
    .padding(.horizontal, isCompact ? 16 : SettingsChromeMetrics.contentInset)
    .padding(.top, isCompact ? 8 : 8)
    .padding(.bottom, isCompact ? 16 : SettingsChromeMetrics.contentInset)
    .onAppear(perform: reload)
    // A change made elsewhere — the sidebar, the setup, ⌘Z — shows here at once.
    .onChange(of: compute.generation) { reload() }
    .onChange(of: chosen) { takeTheName() }
    #if os(iOS)
      .toolbar {
        if isCompact {
          ToolbarItem(placement: .topBarTrailing) {
            Button(w(editing ? "tree.done" : "tree.edit")) {
              editing.toggle()
              if !editing { marked = [] }
            }
            .accessibilityIdentifier("accounts.tree.edit")
          }
        }
      }
      .navigationDestination(
        isPresented: Binding(get: { pushed != nil }, set: { if !$0 { pushed = nil } })
      ) {
        ScrollView { panel.padding(16) }
        .navigationTitle(chosenNode.map(title(of:)) ?? "")
      }
    #endif
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
      Text(verbatim: deleteMessage(question))
    }
    .alert(
      t("sidebar.refusal.title"),
      isPresented: Binding(get: { deleteRefusal != nil }, set: { if !$0 { deleteRefusal = nil } }),
      presenting: deleteRefusal
    ) { _ in
      Button(environment.language("action.ok"), role: .cancel) {}
    } message: { reason in
      Text(verbatim: AccountText.message(reason, environment))
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
    .refusedWriteAlert($failed, environment)
  }

  // MARK: The search

  /// The search over the names, and «Свернуть всё» — «Развернуть всё» once everything is folded.
  private var searchRow: some View {
    HStack(spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 12))  // font-fixed: 14 pt symbol of the field
          .foregroundStyle(theme.contentSecondary)
          .frame(width: 14, height: 14)
          .accessibilityHidden(true)
        TextField(
          text: $query, prompt: Text(verbatim: w("tree.search.prompt"))
        ) { Text(verbatim: w("tree.search.prompt")) }
        .labelsHidden()
        .textFieldStyle(.plain)
        .appFont(.callout)
        .accessibilityIdentifier("accounts.tree.search")
      }
      .padding(.horizontal, 10)
      .frame(height: AccountsTreeMetrics.searchHeight)
      .background(theme.surfaceSegmented, in: .rect(cornerRadius: AccountsTreeMetrics.searchRadius))
      let everything = AccountsTree.folders(tree)
      let allFolded = !everything.isEmpty && everything.isSubset(of: folded)
      Button(w(allFolded ? "tree.expandAll" : "tree.collapseAll")) {
        folded = allFolded ? AccountsTree.foldedAtFirst : everything
      }
      .buttonStyle(.plain)
      .appFont(AppFont.callout.weight(.medium))
      .foregroundStyle(theme.accentContent)
      .accessibilityIdentifier("accounts.tree.fold")
    }
  }

  // MARK: The tree

  private var tree: [AccountsTree.Node] {
    AccountsTree.build(
      accounts: accounts, groups: groups, banks: banks, cards: cards,
      snapshot: compute.snapshot?.planning.accounts,
      partHidden: compute.snapshot?.coveredAccounts?.sectionsWithHiddenPart ?? [],
      locale: environment.language.locale)
  }

  private var treeCard: some View {
    let rows = AccountsTree.rows(tree, collapsed: folded, query: query)
    return VStack(spacing: 0) {
      List {
        ForEach(rows) { row in
          rowView(row)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .moveDisabled(!isDraggable(row))
        }
        .onMove { source, destination in
          guard let from = source.first,
            let drop = AccountsTree.drop(rows, from: from, to: destination)
          else { return }
          perform(actions.place(drop))
        }
        if showsMarks { addRow }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, AccountsTreeMetrics.rowHeight)
      #if os(iOS)
        .environment(\.editMode, .constant(editing ? .active : .inactive))
      #endif
      .accessibilityIdentifier("accounts.list")
      if !marked.isEmpty { bulkBar }
    }
    .padding(AccountsTreeMetrics.treeInset)
    .background(theme.surfaceCard, in: .rect(cornerRadius: AccountsTreeMetrics.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: AccountsTreeMetrics.cardRadius)
        .strokeBorder(theme.borderCard, lineWidth: 1)
    }
  }

  private func isDraggable(_ row: AccountsTree.Row) -> Bool {
    guard showsMarks, query.isEmpty, row.takesAccounts, let account = row.node.account else {
      return false
    }
    return !account.archived
  }

  private func rowView(_ row: AccountsTree.Row) -> some View {
    let node = row.node
    let isChosen = chosen == node.id
    return AccountsTreeRow(
      row: row, title: title(of: node), caption: caption(of: node), badge: badge(of: node),
      amount: amount(of: node), currency: currencyCode(of: node), isChosen: isChosen,
      mark: mark(of: node), showsHandle: isDraggable(row), showsMarks: showsMarks,
      plusHelp: plusHelp(of: node),
      toggleFold: {
        if folded.contains(node.id) { folded.remove(node.id) } else { folded.insert(node.id) }
      },
      toggleMark: { toggleMark(node) },
      plus: { plus(node) }
    )
    .overlay(alignment: .trailing) {
      // The menu of the row, named for VoiceOver; on the screen only under the pointer.
      rowMenuButton(node, shown: hovered == node.id || isChosen)
        .padding(.trailing, plusHelp(of: node) == nil ? 8 : 24)
    }
    .contentShape(.rect)
    .onTapGesture { choose(node) }
    #if os(macOS)
      .onHover { inside in
        if inside { hovered = node.id } else if hovered == node.id { hovered = nil }
      }
    #endif
    .contextMenu { menuItems(node) }
    .accessibilityAddTraits(isChosen ? [.isSelected] : [])
  }

  /// The «…» of a row, drawn only under the pointer and on the chosen row (an AppKit menu button
  /// draws its glyph whatever the label says). Otherwise a clear mark with the same words stays
  /// for VoiceOver, which opens the same items as the menu of the row.
  @ViewBuilder
  private func rowMenuButton(_ node: AccountsTree.Node, shown: Bool) -> some View {
    let label = SettingsRowMenu.label(node.name, environment)
    if shown {
      Menu {
        menuItems(node)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(Text(verbatim: label))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .disabled(Self.isPlace(node))
    } else if !Self.isPlace(node) {
      Color.clear
        .frame(width: 16, height: 16)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose(node) }
    }
  }

  /// «Без группы», the hidden ones and the archive gather rows; they are no thing of their own.
  private static func isPlace(_ node: AccountsTree.Node) -> Bool {
    switch node.kind {
    case .noGroup, .hidden, .archive: true
    default: false
    }
  }

  private func choose(_ node: AccountsTree.Node) {
    guard !Self.isPlace(node) else {
      if folded.contains(node.id) { folded.remove(node.id) } else { folded.insert(node.id) }
      return
    }
    chosen = node.id
    if isCompact, !editing { pushed = node.id }
  }

  /// «+ Добавить группу или банк…»: a group, a bank with its first account, or an account.
  private var addRow: some View {
    Menu {
      Button(t("accounts.newGroup")) { sheet = .group(nil) }
      Button(t("accounts.newBank")) { sheet = .bank(nil) }
        .accessibilityIdentifier("accounts.newBank")
      Button(t("accounts.newAccount")) { sheet = .account(nil) }
        .accessibilityIdentifier("accounts.newAccount")
    } label: {
      Label {
        Text(verbatim: w("tree.add"))
      } icon: {
        Image(systemName: "plus")
      }
      .labelStyle(.titleAndIcon)
      .appFont(.callout)
      .foregroundStyle(theme.accentContent)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .padding(.horizontal, AccountsTreeMetrics.rowPadding)
    .frame(height: AccountsTreeMetrics.rowHeight)
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .moveDisabled(true)
    .accessibilityIdentifier("accounts.tree.add")
  }

  /// «Выбрано 2 · В группу… · Скрыть · В архив».
  private var bulkBar: some View {
    let picked = accounts.filter { marked.contains($0.id) }
    let allHidden = !picked.isEmpty && picked.allSatisfy(\.hidden)
    return HStack(spacing: 6) {
      Text(
        verbatim: environment.format("tree.selected", table: EntryLinks.table, counts: marked.count)
      )
      .appFont(AppFont.callout.weight(.medium))
      .foregroundStyle(theme.contentPrimary)
      .frame(maxWidth: .infinity, alignment: .leading)
      Menu {
        ForEach(groups.filter { !$0.archived }, id: \.id) { group in
          Button(group.name) { perform(actions.moveToGroup(marked, group.id)) }
        }
        Divider()
        Button(w("tree.noGroup")) { perform(actions.moveToGroup(marked, nil)) }
      } label: {
        Text(verbatim: w("tree.toGroup"))
      }
      .menuStyle(.button)
      .buttonStyle(.rowAction)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityIdentifier("accounts.bulk.group")
      Button(w(allHidden ? "tree.show" : "tree.hide")) {
        perform(actions.setHidden(marked, !allHidden))
      }
      .buttonStyle(.rowAction)
      .accessibilityIdentifier("accounts.bulk.hide")
      Button(w("tree.toArchive")) { archiveMarked() }
        .buttonStyle(.rowAction)
        .accessibilityIdentifier("accounts.bulk.archive")
    }
    .disabled(store.isWritingInBackground)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(minHeight: AccountsTreeMetrics.barHeight)
    .background(theme.fillNeutral, in: .rect(cornerRadius: 8))
    .padding(.top, 2)
  }

  private func archiveMarked() {
    let ids = marked
    Task {
      guard let books = await actions.books() else {
        failed = true
        return
      }
      if perform(actions.archive(ids, books: books)) { marked = [] }
    }
  }

  // MARK: What a row says

  private func title(of node: AccountsTree.Node) -> String {
    switch node.kind {
    case .noGroup: w("tree.noGroup")
    case .hidden: w("tree.hidden")
    case .archive: w("tree.archive")
    default: node.name.isEmpty ? "—" : (node.card?.name ?? node.name)
    }
  }

  private func caption(of node: AccountsTree.Node) -> String? {
    switch node.kind {
    case .group(let group):
      // «часть скрыта»: the total holds money of a covered account; never how much.
      let words = w(group.inSummary ? "tree.inSummary" : "tree.notInSummary")
      return node.partHidden ? words + " · " + PartHiddenNote.text(environment.language) : words
    case .hidden:
      return environment.format(
        "tree.count.accounts", table: EntryLinks.table, counts: node.children.count)
    case .archive:
      return environment.format(
        "tree.count.items", table: EntryLinks.table, counts: node.children.count)
    case .account(let account):
      // The main account is told in words, never by the order alone.
      return account.isDefault && !account.archived ? t("accounts.main") : nil
    case .card(let card):
      let parts = card.aliases + (isMainCard(card) ? [w("tree.card.main")] : [])
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
    default:
      return nil
    }
  }

  private func badge(of node: AccountsTree.Node) -> (symbol: String, text: String)? {
    guard let account = node.account else { return nil }
    if account.isBorrowed { return ("person.2", w("tree.badge.borrowed")) }
    if account.credit != nil { return ("creditcard", w("tree.badge.credit")) }
    return nil
  }

  private func amount(of node: AccountsTree.Node) -> String? {
    guard let amount = node.amount else { return nil }
    if let account = node.account {
      guard !account.isBorrowed else { return nil }
      return environment.money.rounded(amount, currency: node.currency ?? account.mainCurrency)
    }
    return environment.money.rounded(amount)
  }

  private func currencyCode(of node: AccountsTree.Node) -> String? {
    guard let account = node.account, !account.archived, !account.isBorrowed, node.amount != nil
    else { return nil }
    return account.mainCurrency.code
  }

  private func plusHelp(of node: AccountsTree.Node) -> String? {
    switch node.kind {
    case .bank: w("tree.plus.account")
    case .account(let account)
    where !account.archived && !account.isBorrowed && account.kind != .cash:
      w("tree.plus.card")
    default: nil
    }
  }

  private func plus(_ node: AccountsTree.Node) {
    switch node.kind {
    case .bank(let bank, _): sheet = .accountInBank(bank.id)
    case .account(let account): sheet = .card(nil, accountId: account.id)
    default: break
    }
  }

  /// The mark of a row: an account's own; a group's, a bank's or a place's — all its accounts;
  /// none on a card and in the archive.
  private func mark(of node: AccountsTree.Node) -> Bool? {
    switch node.kind {
    case .card, .archive, .archivedGroup, .archivedBank: return nil
    case .account(let account): return account.archived ? nil : marked.contains(account.id)
    default:
      let ids = node.accounts.filter { !$0.archived }.map(\.id)
      return ids.isEmpty ? nil : ids.allSatisfy(marked.contains)
    }
  }

  private func toggleMark(_ node: AccountsTree.Node) {
    let ids = Set(node.accounts.filter { !$0.archived }.map(\.id))
    if ids.isSubset(of: marked) { marked.subtract(ids) } else { marked.formUnion(ids) }
  }

  private func isMainCard(_ card: PaymentCard) -> Bool {
    guard let account = accounts.first(where: { $0.id == card.accountId }) else { return false }
    return CardRules.validMainCard(of: account, cards: cards) == card.id
  }

  // MARK: The menus of the rows

  @ViewBuilder
  private func menuItems(_ node: AccountsTree.Node) -> some View {
    switch node.kind {
    case .group(let group): groupMenuItems(group)
    case .bank(let bank, _): bankMenuItems(bank)
    case .account(let account):
      if account.archived { archivedMenuItems(account) } else { accountMenuItems(account) }
    case .card(let card): cardMenuItems(card)
    case .archivedGroup(let group):
      Button(t("accounts.restore")) { perform(actions.restoreGroup(group.id)) }
      Button(t("accounts.delete"), role: .destructive) { askToDelete(group) }
    case .archivedBank(let bank):
      Button(t("accounts.restore")) { perform(actions.restoreBank(bank.id)) }
      Button(t("accounts.delete"), role: .destructive) { askToDelete(bank) }
    case .noGroup, .hidden, .archive:
      EmptyView()
    }
  }

  @ViewBuilder
  private func accountMenuItems(_ account: PaymentMethod) -> some View {
    Button(t("accounts.edit")) { sheet = .account(account) }
    if !account.isDefault {
      Button(t("accounts.makeMain")) { perform(actions.makeMain(account.id)) }
      // The order without a drag, for the keyboard and VoiceOver; nothing goes above the
      // main account.
      let live = actions.ordered(accounts)
      let index = live.firstIndex { $0.id == account.id }
      Button(t("accounts.moveUp")) { perform(actions.move(account.id, by: -1)) }
        .disabled(index.map { $0 == 0 || live[$0 - 1].isDefault } ?? true)
      Button(t("accounts.moveDown")) { perform(actions.move(account.id, by: 1)) }
        .disabled(index.map { $0 == live.count - 1 } ?? true)
    }
    Button(t("accounts.alphabetize")) { perform(actions.alphabetize()) }
      .disabled(!accounts.contains { !$0.archived && $0.sort != 0 })
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

  @ViewBuilder
  private func archivedMenuItems(_ account: PaymentMethod) -> some View {
    Button(t("accounts.restore")) { perform(actions.restore(account.id)) }
    Button(t("accounts.edit")) { sheet = .account(account) }
    Divider()
    Button(t("accounts.delete"), role: .destructive) { askToDelete([account.id]) }
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
    if card.archived {
      Button(environment.language("card.restore", table: CardText.table)) {
        perform(cardActions.restore(card.id))
      }
    } else {
      Button(environment.language("card.archive", table: CardText.table)) {
        perform(cardActions.archive(card.id))
      }
    }
    Button(environment.language("card.delete", table: CardText.table), role: .destructive) {
      deletingCard = card
    }
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

  @ViewBuilder
  private func groupMenuItems(_ group: AccountGroup) -> some View {
    Button(t("accounts.edit")) { sheet = .group(group) }
    Divider()
    Button(t("accounts.archive")) { perform(actions.archiveGroup(group.id)) }
    Button(t("accounts.delete"), role: .destructive) { askToDelete(group) }
  }

  // MARK: Under the tree

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

  // MARK: The panel

  private var chosenNode: AccountsTree.Node? {
    guard let chosen else { return nil }
    func find(_ nodes: [AccountsTree.Node]) -> AccountsTree.Node? {
      for node in nodes {
        if node.id == chosen { return node }
        if let found = find(node.children) { return found }
      }
      return nil
    }
    return find(tree)
  }

  private var panelCard: some View {
    ScrollView {
      panel
        .padding(AccountsTreeMetrics.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(theme.surfaceCard, in: .rect(cornerRadius: AccountsTreeMetrics.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: AccountsTreeMetrics.cardRadius)
        .strokeBorder(theme.borderCard, lineWidth: 1)
    }
    .accessibilityIdentifier("accounts.panel")
  }

  @ViewBuilder
  private var panel: some View {
    VStack(alignment: .leading, spacing: AccountsTreeMetrics.panelGap) {
      switch chosenNode?.kind {
      case .account(let account) where !account.archived: accountPanel(account)
      case .account(let account): archivedPanel(account)
      case .group(let group): groupPanel(group)
      case .bank(let bank, _): bankPanel(bank)
      case .card(let card): cardPanel(card)
      case .archivedGroup(let group):
        heading(group.name, caption: w("tree.archived"))
        Button(t("accounts.restore")) { perform(actions.restoreGroup(group.id)) }
          .buttonStyle(.rowAction)
      case .archivedBank(let bank):
        heading(bank.name, caption: w("tree.archived"))
        Button(t("accounts.restore")) { perform(actions.restoreBank(bank.id)) }
          .buttonStyle(.rowAction)
      default:
        emptyPanel
      }
    }
    .disabled(store.isWritingInBackground)
  }

  /// Nothing chosen: what to do, and the settings of the section as a whole.
  private var emptyPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: w(accounts.isEmpty ? "panel.start" : "panel.empty"))
        .appFont(.callout)
        .foregroundStyle(theme.contentSecondary)
        .fixedSize(horizontal: false, vertical: true)
      if accounts.isEmpty {
        // A book with no account yet: where to start, as buttons, not only the menu of the tree.
        VStack(alignment: .leading, spacing: 6) {
          Button(t("accounts.newBank")) { sheet = .bank(nil) }
            .accessibilityIdentifier("accounts.newBank")
          Button(t("accounts.newAccount")) { sheet = .account(nil) }
            .accessibilityIdentifier("accounts.newAccount")
          Button(t("accounts.newGroup")) { sheet = .group(nil) }
        }
        .buttonStyle(.rowAction)
      }
      ForgottenDaysSetting()
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: ImportText.t("import.settings.title", environment))
          .settingsHeaderStyle()
        StatementImportSettingsRows()
          .buttonStyle(.borderless)
      }
    }
  }

  private func heading(_ title: String, caption: String) -> some View {
    VStack(alignment: .leading, spacing: AccountsTreeMetrics.panelGap) {
      Text(verbatim: title)
        .appFont(AppFont.system(size: 14, weight: .semibold))
        .foregroundStyle(theme.contentPrimary)
        .lineLimit(2)
      Text(verbatim: caption)
        .appFont(.callout)
        .foregroundStyle(theme.contentSecondary)
    }
  }

  @ViewBuilder
  private func accountPanel(_ account: PaymentMethod) -> some View {
    let bank = account.bankId.flatMap { id in banks.first { $0.id == id } }
    let group = account.groupId.flatMap { id in groups.first { $0.id == id } }
    heading(
      account.name,
      caption: [t(AccountText.kindKey(account.kind)).lowercased(), bank?.name]
        .compactMap { $0 }.joined(separator: " · "))
    pickerRow("panel.bank", value: bank?.name ?? "—") {
      ForEach(BankRules.ordered(banks, locale: environment.language.locale), id: \.id) { choice in
        Button(choice.name) { saveAccount(account) { $0.bankId = choice.id } }
      }
    }
    pickerRow("panel.group", value: group?.name ?? w("tree.noGroup")) {
      ForEach(groups.filter { !$0.archived }, id: \.id) { choice in
        Button(choice.name) { saveAccount(account) { $0.groupId = choice.id } }
      }
      Divider()
      Button(w("tree.noGroup")) { saveAccount(account) { $0.groupId = nil } }
    }
    HStack(spacing: 6) {
      label("panel.name")
      TextField(text: $nameDraft) { Text(verbatim: w("panel.name")) }
        .labelsHidden()
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing)
        .appFont(AppFont.callout.weight(.medium))
        .focused($nameFocused)
        .onSubmit { commitName(account) }
        .onChange(of: nameFocused) { _, focused in if !focused { commitName(account) } }
        .accessibilityIdentifier("accounts.panel.name")
    }
    pickerRow("panel.currency", value: account.mainCurrency.code) {
      ForEach(actions.enabledCurrencies, id: \.code) { code in
        Button(code.code) {
          saveAccount(account) { changed in
            changed.otherCurrencies.removeAll { $0 == code }
            if changed.mainCurrency != code {
              changed.otherCurrencies.insert(changed.mainCurrency, at: 0)
            }
            changed.currency = code
          }
        }
      }
    }
    pickerRow(
      "panel.color",
      value: account.accountAccent.map {
        environment.language($0.nameKey, table: "Accounts")
      } ?? w("panel.none")
    ) {
      ForEach(AccountAccent.allCases, id: \.self) { accent in
        Button(environment.language(accent.nameKey, table: "Accounts")) {
          saveAccount(account) { $0.accent = accent.key }
        }
      }
      Divider()
      Button(w("panel.none")) { saveAccount(account) { $0.accent = nil } }
    }
    pickerRow("panel.cashback", value: w(cashbackKey(of: account))) {
      Button(w("panel.cashback.rules")) {
        sheet = .cashback(accountId: account.id, .account(account.id))
      }
    }
    let accountCards = liveCards(of: account.id)
    if !accountCards.isEmpty {
      let main = CardRules.validMainCard(of: account, cards: cards)
      pickerRow(
        "panel.mainCard", value: accountCards.first { $0.id == main }?.name ?? w("panel.none")
      ) {
        ForEach(accountCards, id: \.id) { card in
          Button(card.name) { saveAccount(account) { $0.mainCardId = card.id } }
        }
        Divider()
        Button(w("panel.none")) { saveAccount(account) { $0.mainCardId = nil } }
      }
    }
    switchRow(
      "panel.inSummary",
      isOn: Binding(
        get: { group?.inSummary ?? true },
        set: { on in if let group { perform(actions.setInSummary(group.id, on)) } }),
      note: group.map {
        environment.format("panel.inSummary.group", table: EntryLinks.table, $0.name)
      }
        ?? w("panel.inSummary.noGroup"),
      enabled: group != nil && !account.isDefault)
    switchRow(
      "panel.hide",
      isOn: Binding(
        get: { account.hidden }, set: { on in saveAccount(account) { $0.hidden = on } }),
      note: nil, enabled: true)
    Text(verbatim: w(Self.undoNoteKey))
      .appFont(.subheadline)
      .foregroundStyle(theme.contentSecondary)
      .fixedSize(horizontal: false, vertical: true)
    Button(w("panel.allFields")) { sheet = .account(account) }
      .buttonStyle(.plain)
      .appFont(.callout)
      .foregroundStyle(theme.accentContent)
      .accessibilityIdentifier("accounts.panel.allFields")
    Spacer(minLength: 12)
    dangerButton("panel.deleteAccount") { askToDelete([account.id]) }
      .accessibilityIdentifier("accounts.panel.delete")
  }

  /// «Правка применяется сразу, ⌘Z отменяет.» — on an iPhone and an iPad «… и отменяется»:
  /// there undo is the button «Отменить».
  static var undoNoteKey: String {
    #if os(macOS)
      "panel.note.mac"
    #else
      "panel.note.touch"
    #endif
  }

  private func archivedPanel(_ account: PaymentMethod) -> some View {
    VStack(alignment: .leading, spacing: AccountsTreeMetrics.panelGap) {
      heading(account.name, caption: w("tree.archived"))
      Button(t("accounts.restore")) { perform(actions.restore(account.id)) }
        .buttonStyle(.rowAction)
      dangerButton("panel.deleteAccount") { askToDelete([account.id]) }
    }
  }

  @ViewBuilder
  private func groupPanel(_ group: AccountGroup) -> some View {
    let members = accounts.filter { $0.groupId == group.id && !$0.archived }
    let holdsMain = members.contains(where: \.isDefault)
    heading(
      group.name,
      caption: environment.format(
        "tree.count.accounts", table: EntryLinks.table, counts: members.count))
    switchRow(
      "panel.inSummary",
      isOn: Binding(
        get: { group.inSummary }, set: { perform(actions.setInSummary(group.id, $0)) }),
      note: holdsMain ? t("account.group.holdsMain") : t("account.group.inSummaryHint"),
      enabled: !holdsMain)
    Text(verbatim: w(Self.undoNoteKey))
      .appFont(.subheadline)
      .foregroundStyle(theme.contentSecondary)
    Button(t("accounts.edit")) { sheet = .group(group) }
      .buttonStyle(.rowAction)
    Spacer(minLength: 12)
    dangerButton("panel.deleteGroup") { askToDelete(group) }
  }

  @ViewBuilder
  private func bankPanel(_ bank: Bank) -> some View {
    let live = accounts.filter { $0.bankId == bank.id && !$0.archived }
    heading(bank.name, caption: bankCaption(accounts: live.count, bank: bank))
    HStack(spacing: 6) {
      Button(t("accounts.edit")) { sheet = .bank(bank) }
        .buttonStyle(.rowAction)
      Button(t("bank.addAccount")) { sheet = .accountInBank(bank.id) }
        .buttonStyle(.rowAction)
    }
    Spacer(minLength: 12)
    dangerButton("panel.deleteBank") { askToDelete(bank) }
  }

  @ViewBuilder
  private func cardPanel(_ card: PaymentCard) -> some View {
    let account = accounts.first { $0.id == card.accountId }
    heading(
      card.name,
      caption: [
        w("panel.kind.card"), account?.name,
      ]
      .compactMap { $0 }.joined(separator: " · "))
    switchRow(
      "panel.mainCard",
      isOn: Binding(
        get: { isMainCard(card) },
        set: { on in
          if on {
            perform(cardActions.makeMain(card.id))
          } else if let account {
            saveAccount(account) { $0.mainCardId = nil }
          }
        }),
      note: nil, enabled: !card.archived)
    Text(verbatim: cardRulesCaption(card))
      .appFont(.callout)
      .foregroundStyle(theme.contentSecondary)
    HStack(spacing: 6) {
      Button(environment.language("action.edit")) { sheet = .card(card, accountId: card.accountId) }
        .buttonStyle(.rowAction)
      Button(environment.language("card.cashback", table: CardText.table)) {
        sheet = .cashback(accountId: card.accountId, .card(card.id))
      }
      .buttonStyle(.rowAction)
    }
    Spacer(minLength: 12)
    dangerButton("panel.deleteCard") { deletingCard = card }
  }

  /// «своих правил кэшбэка: 2», or «правила — как у счёта» for a card with none of its own.
  private func cardRulesCaption(_ card: PaymentCard) -> String {
    let own = rules.filter { $0.cardId == card.id }.count
    guard own > 0 else { return environment.language("card.captionFollows", table: CardText.table) }
    return environment.format("card.caption", table: CardText.table, counts: own)
  }

  /// «2 счёта · 3 карты»; «Нет счетов» for a bank all of whose accounts are gone or archived.
  private func bankCaption(accounts count: Int, bank: Bank) -> String {
    guard count > 0 else { return t("bank.caption.none") }
    let ids = Set(accounts.filter { $0.bankId == bank.id && !$0.archived }.map(\.id))
    let cardCount = cards.filter { !$0.archived && ids.contains($0.accountId) }.count
    return [
      environment.format("bank.caption.accounts", table: "Accounts", counts: count),
      environment.format("bank.caption.cards", table: "Accounts", counts: cardCount),
    ].joined(separator: " · ")
  }

  /// The cashback of an account as the design names it: «Нет», «Постоянные» — rules of its own
  /// or of its cards —, «Меняются каждый месяц» — the bank opens a choice of categories monthly.
  private func cashbackKey(of account: PaymentMethod) -> String {
    Self.cashbackKey(of: account, cards: cards, rules: rules)
  }

  static func cashbackKey(
    of account: PaymentMethod, cards: [PaymentCard], rules: [CashbackRule]
  ) -> String {
    if account.cashbackChoiceDay != nil { return "panel.cashback.monthly" }
    let own = Set(cards.filter { $0.accountId == account.id }.map(\.id))
    let ruled = rules.contains { rule in
      rule.accountId == account.id || rule.cardId.map(own.contains) == true
    }
    return ruled ? "panel.cashback.constant" : "panel.cashback.none"
  }

  private func label(_ key: String) -> some View {
    Text(verbatim: w(key))
      .appFont(.callout)
      .foregroundStyle(theme.contentSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// «Банк · Т-Банк ⌄»: the name of the setting, its value and a menu of the choices.
  private func pickerRow<Choices: View>(
    _ key: String, value: String, @ViewBuilder choices: () -> Choices
  ) -> some View {
    HStack(spacing: 6) {
      label(key)
      Menu {
        choices()
      } label: {
        HStack(spacing: 6) {
          Text(verbatim: value)
            .appFont(AppFont.callout.weight(.medium))
            .foregroundStyle(theme.contentPrimary)
            .lineLimit(1)
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))  // font-fixed: chevron in a 10 pt slot
            .foregroundStyle(theme.contentSecondary)
            .frame(width: 10, height: 10)
        }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel(Text(verbatim: w(key)))
      .accessibilityValue(Text(verbatim: value))
      .accessibilityIdentifier("accounts.\(key)")
    }
  }

  private func switchRow(
    _ key: String, isOn: Binding<Bool>, note: String?, enabled: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Toggle(isOn: isOn) {
        Text(verbatim: w(key))
          .appFont(.callout)
          .foregroundStyle(theme.contentPrimary)
      }
      .toggleStyle(.switch)
      .tint(theme.accentDefault)
      .disabled(!enabled)
      .accessibilityIdentifier("accounts.\(key)")
      if let note {
        Text(verbatim: note)
          .appFont(.footnote)
          .foregroundStyle(theme.contentSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// «Удалить счёт…»: the danger's tint, 11 pt, radius 8 — always asked before.
  private func dangerButton(_ key: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(verbatim: w(key))
        .appFont(.subheadline)
        .foregroundStyle(Color(theme.palette.statusNegative))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
          Color(theme.palette.statusNegativeTint), in: .rect(cornerRadius: 8))
    }
    .buttonStyle(.plain)
  }

  /// The name in the field follows the account chosen.
  private func takeTheName() {
    if case .account(let account)? = chosenNode?.kind { nameDraft = account.name }
  }

  private func commitName(_ account: PaymentMethod) {
    let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard name != account.name else { return }
    guard !name.isEmpty else {
      nameDraft = account.name
      return
    }
    saveAccount(account) { $0.name = name }
  }

  /// One change of the panel, written with the books of this moment: one step of ⌘Z.
  private func saveAccount(_ account: PaymentMethod, _ change: (inout PaymentMethod) -> Void) {
    var changed = account
    change(&changed)
    guard changed != account else { return }
    Task {
      guard let books = await actions.books() else {
        failed = true
        return
      }
      perform(actions.save(changed, previous: account, books: books))
      takeTheName()
    }
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
          marked = []
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
      case .delete(let ids, let held):
        // The choice of the new main account is also the confirmation of the deletion, so
        // the sheet says what goes with it.
        MainHandOverSheet(
          leaving: account, candidates: candidates, preselected: preselected,
          confirmTitle: t("accounts.delete"),
          note: AccountText.deleteMessage(count: ids.count, held: held, environment),
          confirm: { next in
            self.sheet = nil
            if perform(
              actions.delete(ids, newMain: next, losingMoney: !held.isEmpty), says: true)
            {
              marked = []
            }
          },
          cancel: { self.sheet = nil })
      }
    case .archiveMoney(let account, let newMain):
      ArchivedMoneySheet(archiving: account, newMain: newMain) { archived in
        self.sheet = nil
        if archived {
          refusal = nil
          marked = []
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
  /// step; a balance nobody knows keeps it out, and the note under the tree says so.
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
        deleteRefusal = refusal
        return
      }
    }
    guard let held = actions.heldMoney(on: ids) else {
      failed = true
      return
    }
    if let main = accounts.first(where: { ids.contains($0.id) && $0.isDefault && !$0.archived }) {
      Task {
        guard let books = await actions.books() else {
          failed = true
          return
        }
        let next = actions.successors(leaving: Set(ids), books: books)
        sheet = .handOver(
          main, .delete(ids, held), candidates: next.all, preselected: next.preselected)
      }
      return
    }
    let names = accounts.filter { ids.contains($0.id) }.map(\.name)
    deleting = Deletion(ids: ids, names: names, held: held)
  }

  private func delete(_ question: Deletion) {
    deleting = nil
    if perform(actions.delete(question.ids, losingMoney: !question.held.isEmpty), says: true) {
      marked.subtract(question.ids)
    }
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

  /// That nothing refers to the account — or to the accounts —, how much money leaves the
  /// totals with them, and that ⌘Z brings it back.
  private func deleteMessage(_ question: Deletion) -> String {
    AccountText.deleteMessage(count: question.ids.count, held: question.held, environment)
  }

  private func deleteTitle(_ question: Deletion) -> String {
    question.names.count == 1
      ? environment.format("accounts.delete.titleOne", table: "Accounts", question.names[0])
      : environment.format(
        "accounts.delete.titleMany", table: "Accounts", counts: question.names.count)
  }

  /// Says what came of an action and shows the tree as it is now. Returns whether it was done.
  @discardableResult
  private func perform(_ outcome: AccountActionOutcome, says alerts: Bool = false) -> Bool {
    switch outcome {
    case .done: refusal = nil
    case .refused(let reason):
      refusal = reason
      if alerts { deleteRefusal = reason }
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

  /// The live cards of an account, in the order of the lists.
  private func liveCards(of accountId: UUID) -> [PaymentCard] {
    CardRules.ordered(cards, of: accountId, locale: environment.language.locale)
  }

  private func reload() {
    accounts = actions.all
    groups = actions.groups
    banks = actions.banks
    cards = cardActions.cards
    rules = cardActions.rules
    marked = marked.filter { id in accounts.contains { $0.id == id && !$0.archived } }
    takeTheName()
  }
}

extension AccountsTree.Node {
  /// The card the node is, if it is one.
  var card: PaymentCard? {
    if case .card(let card) = kind { return card }
    return nil
  }
}
