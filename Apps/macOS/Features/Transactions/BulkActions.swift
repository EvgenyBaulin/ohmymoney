import AppCore
import AppDatabase
import SwiftUI

/// A bulk change or a deletion waiting for the owner's word, with the plan its text is
/// written from.
enum BulkConfirmation {
  case edit(BulkEdit, ids: [UUID], plan: BulkEditPlan)
  /// `ids` are the operations and transfers that will go; `totals` is what the operations come
  /// to; `transfers` counts the transfers among `ids` and what their fees come to.
  ///
  /// `reopening` are the closed debts the deletion leaves owed again — the payment that closed
  /// them is among the operations that go: the question offers «Удалить и открыть долг».
  case delete(
    ids: [UUID], plan: BulkEditPlan, totals: RowTotals, transfers: TransferDeletion = .none,
    reopening: [Debt] = [])

  /// Deleting always asks first, one operation or many, from the menu or from the edit
  /// sheet: the same question with the same numbers. Transfers go with the operations, in the
  /// same step of ⌘Z; they add up to nothing, and their fees are named apart.
  ///
  /// `refunds` are the refunds of the whole ledger (`Ledger.refundIndex`): a purchase a live
  /// refund takes money back from stays, as the deletion itself leaves it, and what the rest
  /// comes to counts a refund in its purchase — the numbers of the day it is deleted from.
  ///
  /// `deletedDebts` and `paidDebts` are the store's (`TransactionsStore.deletionDebts()`): a
  /// purchase on credit of a deleted debt goes like any other, unless something ever paid that
  /// debt — the question offers what the store will delete.
  static func deletion(
    of entries: [TransactionEntry], transfers: [UUID] = [],
    transferSummary: TransferDeletion = .none, refunds: RefundIndex = .empty,
    debts: [UUID: Debt], deletedDebts: Set<UUID> = [], paidDebts: Set<UUID> = [],
    reopening: [Debt] = []
  ) -> BulkConfirmation? {
    let plan = BulkEditRule.deletion(
      of: entries, refunds: refunds, deletedDebts: deletedDebts, paidDebts: paidDebts)
    // A transfer the rules keep is said too: the owner hears why it stays.
    guard
      !plan.changed.isEmpty || !plan.skipped.isEmpty || !transfers.isEmpty
        || !transferSummary.kept.isEmpty
    else {
      return nil
    }
    return .delete(
      ids: plan.changedIds + transfers, plan: plan,
      totals: RowTotals(entries: plan.changed, debts: debts, refunds: refunds),
      transfers: transferSummary, reopening: plan.changed.isEmpty ? [] : reopening)
  }
}

/// The bank's rates by day, for one unit, as the cache holds them now. A bulk change of the
/// account works out from them what an account that does not hold an operation's currency is
/// charged for it; read when the change is planned and again when it is made. No other change
/// reads them: the whole cache is read from the database where the window draws.
@MainActor
enum BulkRates {
  /// Whether `edit` works out a charge: only a change of the account does.
  static func needed(for edit: BulkEdit) -> Bool {
    if case .paymentMethod = edit { return true }
    return false
  }

  /// The rates `edit` needs: the cache for a change of the account, nothing otherwise.
  static func now(for edit: BulkEdit, _ environment: AppEnvironment) -> DayRates {
    needed(for: edit) ? now(environment) : .empty
  }

  static func now(_ environment: AppEnvironment) -> DayRates {
    guard let table = try? environment.rates?.table() else { return .empty }
    var series: [CurrencyCode: [DayRate]] = [:]
    for rate in table.rates {
      series[rate.currency, default: []].append(DayRate(day: rate.date, perUnit: rate.perUnit))
    }
    return DayRates(series: series)
  }
}

/// What a popover of the bulk menu is about to change.
enum BulkPopover: Identifiable, Hashable {
  case category(Set<UUID>)
  case place(Set<UUID>)
  case person(Set<UUID>)

  var id: Self { self }

  var ids: Set<UUID> {
    switch self {
    case .category(let ids), .place(let ids), .person(let ids): ids
    }
  }
}

/// The dictionaries the bulk menu offers. Taken when the screen appears and after every
/// change of the data, not on every redraw of a menu. Categories are not among them: the
/// category popover reads them from the store when it opens, the same source the rule of
/// the change judges by (`TransactionsStore.categories()`).
struct BulkDictionaries {
  var people: [Person] = []
  var places: [Place] = []
  var events: [Event] = []
  var paymentMethods: [PaymentMethod] = []
  /// Every bank, so an account is named in a menu as in every list of accounts.
  var banks: [Bank] = []
}

/// The selection of a screen and everything that is opened from it: the edit sheet, the
/// popovers of the bulk menu and the confirmations.
///
/// Everything here is presented from the root of the screen, never from a row: rows are
/// redrawn on every change of the data, and a sheet hung on one would vanish with it.
@MainActor
@Observable
final class OperationActions {
  /// The coordinate space of the screen root. The selection bar reports its frame in it,
  /// and the popovers of the bulk menu point at the bar from there.
  nonisolated static let coordinateSpace = "operations"

  var selection: Set<UUID> = []
  var editing: TransactionEntry?
  /// A transfer opened from a list of days: its own sheet, not the editor of an operation.
  var editingTransfer: TransferEditing?
  var popover: BulkPopover?
  var confirmation: BulkConfirmation?
  var recordingReimbursement = false
  /// Where the selection bar is, in `coordinateSpace`; empty while it is not shown.
  ///
  /// **Deliberately not observed.** The bar measures itself inside the very column the
  /// popovers hang on, and `OperationPresentations.anchor` reads this property inside the
  /// modifier applied to that same column. Observed, the two make a forbidden edge —
  /// a size taken off the screen coming back into the layout of its own branch — with one
  /// more hop through an object, which is why `scripts/check-geometry.sh` never saw it. The
  /// bar's entrance animation moves this rect on every frame, and every frame asked the
  /// column to lay out again; with the inspector's column being added at the same moment,
  /// the window never converged and AppKit threw (the owner's crash of 21.09).
  ///
  /// Nothing is lost: the anchor is read when a popover is presented, and it is read then —
  /// the bar is on screen for exactly as long as the popover is (`present(_:)` selects first).
  @ObservationIgnored var barFrame: CGRect = .zero
  private(set) var dictionaries = BulkDictionaries()

  /// The live values of the dictionaries, from the data the list shows: no read of the
  /// database on the main thread.
  func reloadDictionaries(from dataset: Dataset) {
    dictionaries = BulkDictionaries(
      people: dataset.people.filter { !$0.archived },
      places: dataset.places.filter { !$0.archived },
      events: dataset.events.filter { !$0.archived },
      paymentMethods: dataset.paymentMethods.filter { !$0.archived },
      banks: dataset.banks)
  }

  /// The selection is only ever what can be seen: whatever leaves the list — deleted, or
  /// no longer among the rows shown — leaves the selection too, so a count, a sum or a
  /// change never reaches something out of sight.
  func keep(only listed: Set<UUID>) {
    let kept = selection.intersection(listed)
    if kept != selection { selection = kept }
  }

  /// Where «Edit» leads: the edit sheet unless a screen takes it — the Transactions window
  /// opens the operation in its inspector instead.
  @ObservationIgnored var opensEditor: (@MainActor (TransactionEntry) -> Void)?

  /// A double click, or «Edit» in the menu of one row. A transfer opens its own sheet, with
  /// the fee it has now.
  func edit(_ ids: Set<UUID>, store: TransactionsStore) {
    guard ids.count == 1, let id = ids.first else { return }
    guard let entry = store.entry(id: id) else {
      guard let transfer = store.transfers(among: [id]).first else { return }
      let fee = TransferActions.fee(of: transfer.id, in: store.listing?.dataset.entries ?? [])
      editingTransfer = TransferEditing(transfer: transfer, fee: fee?.transaction.amountE4)
      return
    }
    if let opensEditor {
      opensEditor(entry)
    } else {
      editing = entry
    }
  }

  /// A popover points at the selection bar, so the bar must show what the popover will
  /// change — also when it was opened from the menu of a row outside the selection.
  ///
  /// One known cost of the crash fix: the anchor is `barFrame` and `barFrame`
  /// is no longer observed, so when this is called with **nothing** selected — the bulk menu
  /// of a row outside the selection — the bar goes up in the same update and has not measured
  /// itself yet. The anchor falls back to `.point(.bottom)`, which is where the bar is
  /// anyway, and it is right again from the second time on.
  ///
  /// Waiting a turn of the main queue was tried and is worse: the bar enters animated, so one
  /// turn in it is mid-slide, and an unobserved frame read then stays frozen there. A real
  /// answer is to hang the popover on the bar itself; that is left for later rather than done
  /// in a hurry.
  func present(_ popover: BulkPopover) {
    selection = popover.ids
    self.popover = popover
  }

  /// A change is made straight away when nothing about it needs saying; otherwise the
  /// confirmation says that it reaches every part of a split, or what it leaves alone.
  /// Nothing is asked while a bulk write is still landing in the background: the store would
  /// refuse the change after the owner had confirmed it.
  ///
  /// `environment` gives the rates and the calendar that work out what an account is charged
  /// for an operation in a currency it does not hold, when the change moves it there.
  func request(
    _ edit: BulkEdit, on ids: Set<UUID>, store: TransactionsStore, environment: AppEnvironment
  ) {
    guard !store.isWritingInBackground else { return }
    let rates = BulkRates.now(for: edit, environment)
    let plan = store.plan(edit, ids: ids, rates: rates, calendar: environment.calendar)
    guard !plan.changed.isEmpty || !plan.skipped.isEmpty else { return }
    // A change that moves money on an account in the archive is confirmed first: the
    // confirmation then asks where that money goes (`BulkConfirmationDialog`).
    let movesArchivedMoney =
      !store.archivedLeftovers(
        of: edit, ids: ids, rates: rates, calendar: environment.calendar
      ).leftovers.isEmpty
    if plan.touchesSplit || !plan.skipped.isEmpty || movesArchivedMoney {
      confirmation = .edit(edit, ids: Array(ids), plan: plan)
    } else {
      store.apply(edit, to: Array(ids), rates: rates, calendar: environment.calendar)
    }
  }

  /// Transfers among `ids` go with the operations, but for those the rules keep — with a fee
  /// something came back for; a purchase a live refund takes money back from stays, unless the
  /// refund goes too. Money the deletion would leave on an account in the archive is asked
  /// about once it is confirmed.
  func requestDeletion(of ids: Set<UUID>, store: TransactionsStore) {
    guard !store.isWritingInBackground else { return }
    let owed = store.deletionDebts()
    confirmation = BulkConfirmation.deletion(
      of: store.entries(ids: ids), transfers: store.transferIds(in: ids),
      transferSummary: store.transferDeletion(in: ids),
      refunds: store.listing?.refundIndex ?? .empty, debts: store.debts,
      deletedDebts: owed.deleted, paidDebts: owed.paid,
      reopening: store.debtsClosedBy(deleting: ids))
  }
}

// MARK: - The menu

/// The bulk menu: «Change ▾» on the selection bar, and the context menu of the selection.
struct BulkMenuItems: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  let ids: Set<UUID>
  let actions: OperationActions
  /// The context menu of a single row also offers the edit sheet.
  var offersEdit = false

  var body: some View {
    // A click on a day's heading or on the cards hands the menu nothing: no menu then.
    if !ids.isEmpty {
      items
        // A bulk write still landing in the background: nothing else is changed until then.
        .disabled(store.isWritingInBackground)
    }
  }

  @ViewBuilder
  private var items: some View {
    if offersEdit, ids.count == 1 {
      Button(environment.language("action.edit")) { actions.edit(ids, store: store) }
      Divider()
    }
    Button(t("bulk.category")) { actions.present(.category(ids)) }
    Menu(t("bulk.quality")) {
      ForEach(Quality.allCases, id: \.self) { quality in
        Button {
          request(.quality(quality))
        } label: {
          Label {
            Text(verbatim: environment.language(Palette.qualityKey(quality)))
          } icon: {
            Image(systemName: Palette.qualitySymbol(quality))
          }
        }
      }
    }
    Menu(t("bulk.forWhom")) {
      ForEach(ForWhom.allCases, id: \.self) { value in
        Button(environment.label(for: value)) { request(.forWhom(value)) }
      }
      Divider()
      Button(t("bulk.person")) { actions.present(.person(ids)) }
        .disabled(actions.dictionaries.people.isEmpty)
    }
    Button(t("bulk.place")) { actions.present(.place(ids)) }
    Menu(t("bulk.event")) {
      Button(t("bulk.none")) { request(.event(nil)) }
      ForEach(actions.dictionaries.events, id: \.id) { event in
        Button(event.name) { request(.event(event.id)) }
      }
    }
    // Every operation keeps an account: a bulk change moves operations to another one, never
    // to none. The main account comes first, as in every menu of accounts.
    Menu(t("bulk.paymentMethod")) {
      ForEach(
        Self.accountItems(
          actions.dictionaries.paymentMethods, banks: actions.dictionaries.banks,
          locale: environment.language.locale),
        id: \.id
      ) { item in
        Button(item.name) { request(.paymentMethod(item.id)) }
      }
    }
    oneOffItem
    Divider()
    Button(t("selection.delete"), role: .destructive) {
      actions.requestDeletion(of: ids, store: store)
    }
  }

  private func request(_ edit: BulkEdit) {
    actions.request(edit, on: ids, store: store, environment: environment)
  }

  /// «Отметить как разовое» / «Снять отметку»: one write and one step of ⌘Z for the whole
  /// selection (`TransactionsStore.setOneOff`). Offered when the selection holds an expense.
  @ViewBuilder
  private var oneOffItem: some View {
    let entries = store.entries(ids: ids)
    if let action = OneOffMenu.action(for: entries) {
      Button(
        SpendingText.t(action == .mark ? "spending.oneOff.mark" : "spending.oneOff.unmark", environment)
      ) {
        store.setOneOff(action == .mark, ids: OneOffMenu.targets(in: entries))
      }
      .accessibilityIdentifier("bulk.oneOff")
    }
  }

  /// The accounts the account menu offers: each live one, the main one first.
  static func accountChoices(_ accounts: [PaymentMethod], locale: Locale) -> [PaymentMethod] {
    AccountRules.ordered(accounts, locale: locale)
  }

  /// The account menu's items: `accountChoices` named as every list of accounts names them —
  /// the bank alone for a bank with one live account, «Банк › Счёт» for one with several.
  static func accountItems(
    _ accounts: [PaymentMethod], banks: [Bank], locale: Locale
  ) -> [AccountCardChoices.Item] {
    AccountCardChoices.accountItems(
      accounts: accountChoices(accounts, locale: locale), banks: banks, among: accounts,
      locale: locale)
  }

  /// What the account menu does: a move to one of `accountChoices`, never to none — every
  /// operation keeps an account.
  static func accountEdits(_ accounts: [PaymentMethod], locale: Locale) -> [BulkEdit] {
    accountChoices(accounts, locale: locale).map { .paymentMethod($0.id) }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Transactions") }
}

// MARK: - Popovers

/// Category and subcategory for the selection: the same pair of pickers as the ↓ panel,
/// offering live categories of the selection's kind and never a system one.
struct BulkCategoryPopover: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  let ids: Set<UUID>
  let actions: OperationActions
  @State private var kind: CategoryKind = .expense
  @State private var categoryId: UUID?
  @State private var subcategoryId: UUID?
  /// The dictionary as it is when the popover opens, archived categories included: a
  /// category added in Settings a moment ago is offered, one archived is not. Should it be
  /// archived while the popover is open, the rule refuses it and the dialog says so.
  @State private var categories: [CoreKit.Category] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: environment.language("bulk.category", table: "Transactions"))
        .appFont(.headline)
      if kinds.count > 1 {
        Picker(selection: $kind) {
          ForEach(kinds, id: \.self) { kind in
            Text(verbatim: environment.language("kind.\(kind.rawValue)")).tag(kind)
          }
        } label: {
          EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      Picker(selection: categoryBinding) {
        Text(verbatim: "—").tag(UUID?.none)
        ForEach(topLevel, id: \.id) { category in
          Text(verbatim: category.name).tag(UUID?.some(category.id))
        }
      } label: {
        Text(verbatim: environment.language("entry.category", table: "Entry"))
      }
      .accessibilityIdentifier("bulk.category.picker")
      Picker(selection: $subcategoryId) {
        Text(verbatim: "—").tag(UUID?.none)
        ForEach(children, id: \.id) { category in
          Text(verbatim: category.name).tag(UUID?.some(category.id))
        }
      } label: {
        Text(verbatim: environment.language("entry.subcategory", table: "Entry"))
      }
      .disabled(children.isEmpty)
      HStack {
        Spacer()
        Button(environment.language("bulk.apply", table: "Transactions"), action: apply)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(categoryId == nil)
          .accessibilityIdentifier("bulk.category.apply")
      }
    }
    .padding(14)
    .frame(width: 320)
    .onAppear {
      categories = store.categories()
      kind = kinds.first ?? .expense
    }
    .onChange(of: kind) { _, _ in
      categoryId = nil
      subcategoryId = nil
    }
  }

  /// The kinds of category the selection can take: spending ones for expenses and refunds,
  /// income ones for income. Money given back takes none.
  private var kinds: [CategoryKind] {
    let present = Set(
      store.entries(ids: ids).map(\.transaction.kind).filter { $0 != .reimbursement }
        .map(\.categoryKind))
    return CategoryKind.allCases.filter(present.contains)
  }

  private var tree: CategoryTree { CategoryTree(categories) }

  /// Live categories of the kind, without the ones that belong to the app.
  private var topLevel: [CoreKit.Category] {
    let tree = tree
    return categories.filter {
      $0.parentId == nil && !$0.archived && $0.kind == kind && tree.systemRole(of: $0.id) == nil
    }
  }

  private var children: [CoreKit.Category] {
    guard let categoryId else { return [] }
    let tree = tree
    return categories.filter {
      $0.parentId == categoryId && !$0.archived && tree.systemRole(of: $0.id) == nil
    }
  }

  /// Choosing another category drops the subcategory, exactly as the ↓ panel does.
  private var categoryBinding: Binding<UUID?> {
    Binding(
      get: { categoryId },
      set: { newValue in
        guard newValue != categoryId else { return }
        categoryId = newValue
        subcategoryId = nil
      })
  }

  private func apply() {
    guard let chosen = subcategoryId ?? categoryId else { return }
    actions.popover = nil
    actions.request(.category(chosen), on: ids, store: store, environment: environment)
  }
}

/// A searchable list of places or people for the selection.
struct ReferencePickerPopover: View {
  @Dependency(\.environment) private var environment

  let title: String
  let options: [(id: UUID, name: String)]
  /// Whether «—» is offered: a place can be taken away, a person cannot be «nobody».
  let allowsNone: Bool
  let pick: (UUID?) -> Void
  @State private var search = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: title)
        .appFont(.headline)
      TextField(text: $search) {
        Text(verbatim: environment.language("bulk.search", table: "Transactions"))
      }
      .textFieldStyle(.roundedBorder)
      List {
        if allowsNone, search.isEmpty {
          Button {
            pick(nil)
          } label: {
            Text(verbatim: "—")
          }
          .buttonStyle(.plain)
        }
        ForEach(filtered, id: \.id) { option in
          Button(option.name) { pick(option.id) }
            .buttonStyle(.plain)
        }
      }
      .listStyle(.plain)
      .frame(height: 220)
    }
    .padding(12)
    .frame(width: 280)
  }

  private var filtered: [(id: UUID, name: String)] {
    let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return options }
    return options.filter { $0.name.lowercased().contains(needle) }
  }
}

/// A transfer a list opened for editing, with its fee as the list had it then.
struct TransferEditing: Identifiable {
  let transfer: Transfer
  let fee: AmountE4?

  var id: UUID { transfer.id }

  /// The form of the transfer's sheet: the transfer as it was written, on its day.
  func form(calendar: CalendarContext) -> TransferForm {
    TransferForm(editing: transfer, fee: fee, calendar: calendar)
  }
}

// MARK: - Presenting from the root of a screen

extension View {
  /// Hangs everything `actions` opens on this view: meant for the root of a screen.
  /// Popovers point at the selection bar when it is shown.
  func operationPresentations(_ actions: OperationActions) -> some View {
    modifier(OperationPresentations(actions: actions))
  }

  /// The confirmation of a bulk change or of a deletion. `finished` hears whether the
  /// deletion landed, for a sheet that closes itself after it.
  func bulkConfirmation(
    _ confirmation: Binding<BulkConfirmation?>, finished: ((Bool) -> Void)? = nil
  ) -> some View {
    modifier(BulkConfirmationDialog(confirmation: confirmation, finished: finished))
  }
}

private struct OperationPresentations: ViewModifier {
  /// Sheets and popovers are laid out by hosts of their own: they get the dependencies of
  /// the screen handed over, never trusting the environment to reach them.
  @Environment(\.dependencies) private var dependencies
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Bindable var actions: OperationActions

  func body(content: Content) -> some View {
    content
      .sheet(item: $actions.editing) { entry in
        EditTransactionSheet(entry: entry)
          .handingOver(dependencies)
      }
      .sheet(item: $actions.editingTransfer) { editing in
        TransferSheet(form: editing.form(calendar: environment.calendar)) { _ in
          actions.editingTransfer = nil
        }
        .handingOver(dependencies)
      }
      .sheet(isPresented: $actions.recordingReimbursement) {
        ReimbursementSheet()
          .handingOver(dependencies)
      }
      .popover(item: $actions.popover, attachmentAnchor: anchor, arrowEdge: .top) { popover in
        popoverContent(popover)
          .handingOver(dependencies)
      }
      .bulkConfirmation($actions.confirmation)
      // A write refused because the view has no dependencies must never be silent.
      .alert(
        Text(verbatim: environment.language("entry.error.noDependencies", table: "Entry")),
        isPresented: Binding(
          get: { store.refusal != nil }, set: { if !$0 { store.forgetRefusal() } })
      ) {
        Button(environment.language("action.ok")) { store.forgetRefusal() }
      } message: {
        Text(verbatim: store.refusal ?? "")
      }
      // A write that failed where nobody else can say so — ⌘Z, a bulk change, a deletion
      // that landed off the main thread — is never silent either.
      .alert(
        Text(verbatim: store.failure.map { StoreFailureText.title($0, language: language) } ?? ""),
        isPresented: Binding(
          get: { store.failure != nil }, set: { if !$0 { store.forgetFailure() } })
      ) {
        Button(environment.language("action.ok")) { store.forgetFailure() }
      } message: {
        Text(verbatim: store.failure.map { StoreFailureText.message($0, language: language) } ?? "")
      }
  }

  private var language: AppLanguage { environment.language }

  /// The selection bar when it is shown; the bottom of the screen, where it appears,
  /// before its first frame is known.
  private var anchor: PopoverAttachmentAnchor {
    actions.barFrame.isEmpty ? .point(.bottom) : .rect(.rect(actions.barFrame))
  }

  @ViewBuilder
  private func popoverContent(_ popover: BulkPopover) -> some View {
    switch popover {
    case .category(let ids):
      BulkCategoryPopover(ids: ids, actions: actions)
    case .place(let ids):
      ReferencePickerPopover(
        title: environment.language("bulk.place", table: "Transactions"),
        options: actions.dictionaries.places.map { ($0.id, $0.name) },
        allowsNone: true
      ) { placeId in
        actions.popover = nil
        actions.request(.place(placeId), on: ids, store: store, environment: environment)
      }
    case .person(let ids):
      ReferencePickerPopover(
        title: environment.language("bulk.person", table: "Transactions"),
        options: actions.dictionaries.people.map { ($0.id, $0.name) },
        allowsNone: false
      ) { personId in
        actions.popover = nil
        guard let personId else { return }
        actions.request(.forPerson(personId), on: ids, store: store, environment: environment)
      }
    }
  }
}

/// A confirmed change or deletion that would leave money on an account in the archive, waiting
/// for where that money goes.
struct ArchivedSettling: Identifiable {
  enum Write {
    /// `planned` are the operations the change was to change — or the deletion to take — when
    /// the money was worked out: the transfers the owner picks count theirs, and are written
    /// only with a write that still lands on exactly those.
    case edit(BulkEdit, ids: [UUID], rates: DayRates, planned: Set<UUID>? = nil)
    case delete([UUID], planned: Set<UUID>? = nil, reopening: Set<UUID> = [])
  }

  let check: ArchivedMoneyCheck
  let write: Write
  let id = UUID()
}

private struct BulkConfirmationDialog: ViewModifier {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dependencies) private var dependencies
  @Binding var confirmation: BulkConfirmation?
  let finished: ((Bool) -> Void)?
  /// The money a confirmed write would leave on an archived account: asked about in a sheet,
  /// and the write made with the transfers the owner picks, in one step of ⌘Z.
  @State private var settling: ArchivedSettling?

  func body(content: Content) -> some View {
    dialog(content)
      .sheet(item: $settling) { asked in
        ArchivedMoneySheet(
          check: asked.check,
          confirm: { transfers in
            settling = nil
            write(asked.write, settling: transfers)
          },
          cancel: {
            settling = nil
            if case .delete = asked.write { finished?(false) }
          }
        )
        .handingOver(dependencies)
      }
  }

  /// The write once confirmed: asked about first when it would leave money on an archived
  /// account.
  private func confirmed(_ write: ArchivedSettling.Write) {
    let check: ArchivedMoneyCheck
    var write = write
    switch write {
    case .edit(let edit, let ids, let rates, _):
      let calendar = environment.calendar
      check = store.archivedLeftovers(of: edit, ids: Set(ids), rates: rates, calendar: calendar)
      let planned = store.plan(edit, ids: Set(ids), rates: rates, calendar: calendar).changed
      write = .edit(edit, ids: ids, rates: rates, planned: Set(planned.map(\.id)))
    case .delete(let ids, _, let reopening):
      check = store.archivedLeftovers(ofDeleting: ids)
      write = .delete(ids, planned: store.deletionPlanned(of: ids), reopening: reopening)
    }
    guard !check.leftovers.isEmpty else {
      self.write(write, settling: [])
      return
    }
    // The sheet waits for the dialog to go: presented at once, it would go with it.
    let asked = ArchivedSettling(check: check, write: write)
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      settling = asked
    }
  }

  private func write(_ write: ArchivedSettling.Write, settling: [Transfer]) {
    switch write {
    case .edit(let edit, let ids, let rates, let planned):
      store.apply(
        edit, to: ids, rates: rates, calendar: environment.calendar, settling: settling,
        planned: planned)
    case .delete(let ids, let planned, let reopening):
      let landed = store.delete(
        ids: ids, settling: settling, planned: planned, reopening: reopening)
      finished?(landed)
    }
  }

  private func dialog(_ content: Content) -> some View {
    content.confirmationDialog(
      title, isPresented: isPresented, titleVisibility: .visible, presenting: confirmation
    ) { confirmation in
      switch confirmation {
      case .edit(let edit, let ids, let plan):
        if !plan.changed.isEmpty {
          Button(t("bulk.apply")) {
            confirmed(.edit(edit, ids: ids, rates: BulkRates.now(for: edit, environment)))
          }
          Button(environment.language("action.cancel"), role: .cancel) {}
        } else {
          Button(environment.language("action.ok"), role: .cancel) {}
        }
      case .delete(let ids, _, _, _, let reopening):
        if !ids.isEmpty {
          Button(environment.language("action.delete"), role: .destructive) {
            confirmed(.delete(ids))
          }
          // An income allocated: its contributions and transfers can go with it, in the same
          // step (`TransactionsStore.allocation(ofDeleting:)`).
          let allocation = store.allocation(ofDeleting: ids)
          if !allocation.contributions.isEmpty || !allocation.transfers.isEmpty {
            Button(
              environment.format(
                "allocation.deleteWith", table: "Allocation", allocation.contributions.count,
                allocation.transfers.count), role: .destructive
            ) {
              confirmed(.delete(ids + allocation.contributions + allocation.transfers))
            }
          }
          // A debt this payment had closed: deleted with it, it can be opened in the same step.
          if !reopening.isEmpty {
            Button(
              environment.language.format(
                "bulk.deleteAndReopen", table: "Transactions",
                reopening.map(\.name).joined(separator: ", ")), role: .destructive
            ) {
              confirmed(.delete(ids, reopening: Set(reopening.map(\.id))))
            }
          }
          Button(environment.language("action.cancel"), role: .cancel) {}
        } else {
          Button(environment.language("action.ok"), role: .cancel) {}
        }
      }
    } message: { confirmation in
      Text(verbatim: BulkConfirmationText.message(confirmation, environment: environment))
    }
  }

  private var isPresented: Binding<Bool> {
    Binding(
      get: { confirmation != nil },
      set: { isShown in
        if !isShown { confirmation = nil }
      })
  }

  private var title: String {
    guard let confirmation else { return "" }
    return BulkConfirmationText.title(confirmation, environment: environment)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Transactions") }
}

/// The words of a write of the store that did not land (`TransactionsStore.failure`).
@MainActor
enum StoreFailureText {
  static func title(_ failure: StoreFailure, language: AppLanguage) -> String {
    switch failure.action {
    case .undo: language("store.failure.undo", table: table)
    case .delete: language("store.failure.delete", table: table)
    case .change, .save, .planning, .edit: language("store.failure.change", table: table)
    }
  }

  static func message(_ failure: StoreFailure, language: AppLanguage) -> String {
    switch (failure.action, failure.cause) {
    case (.undo, .tiedToOtherRows): language("store.failure.undoTied", table: table)
    case (.undo, .other): language("store.failure.undoOther", table: table)
    case (_, .planOutdated): language("store.failure.planOutdated", table: table)
    default: language("store.failure.other", table: table)
    }
  }

  private static let table = "Transactions"
}

/// The words of the confirmations, kept apart from the dialog so they can be read in a test.
@MainActor
enum BulkConfirmationText {
  static func title(_ confirmation: BulkConfirmation, environment: AppEnvironment) -> String {
    let language = environment.language
    switch confirmation {
    case .edit(_, _, let plan):
      guard !plan.changed.isEmpty else { return language("bulk.nothingToChange", table: table) }
      return language.format("bulk.confirmEdit", table: table, counts: plan.changed.count)
    case .delete(let ids, let plan, _, let transfers, _):
      guard !ids.isEmpty else { return language("bulk.nothingToDelete", table: table) }
      // A transfer is not an operation: transfers alone are asked about as transfers.
      if let title = TransferDeletionText.title(
        operations: plan.changed.count, transfers, language: language)
      {
        return title
      }
      return language.format("bulk.confirmDelete", table: table, counts: plan.changed.count)
    }
  }

  static func message(_ confirmation: BulkConfirmation, environment: AppEnvironment) -> String {
    let language = environment.language
    var lines: [String] = []
    switch confirmation {
    case .edit(_, _, let plan):
      if plan.splitCount > 0 {
        lines.append(language.format("bulk.splitWarning", table: table, counts: plan.splitCount))
      }
      lines += skipLines(plan, language: language)
    case .delete(let ids, let plan, let totals, let transfers, let reopening):
      if !totals.isEmpty { lines.append(RowTotalsText.line(totals, environment: environment)) }
      // The transfers besides the operations, and the fees that go with them.
      lines += TransferDeletionText.lines(
        operations: plan.changed.count, transfers, environment: environment)
      // Money given back for a purchase takes its surplus or shortfall along and reopens the
      // parts it closed. Money given back on a debt owed to me is a reimbursement too, but it
      // closes nothing: the line about debts is the one that applies to it.
      if plan.changed.contains(where: {
        $0.transaction.kind == .reimbursement && $0.transaction.debtId == nil
      }) {
        lines.append(language("bulk.deleteReimbursement", table: table))
      }
      if plan.changed.contains(where: { $0.transaction.debtId != nil }) {
        lines.append(language("bulk.deleteDebtPayment", table: table))
      }
      // The payment closed a debt: without it the debt is owed again, and stays closed unless
      // the owner opens it.
      if !reopening.isEmpty {
        lines.append(
          language.format(
            "bulk.deleteClosedDebt", table: table, reopening.map(\.name).joined(separator: ", ")))
      }
      lines += skipLines(plan, language: language)
      if !ids.isEmpty { lines.append(language("bulk.undoHint", table: table)) }
    }
    return lines.joined(separator: "\n")
  }

  private static let table = "Transactions"

  private static func skipLines(_ plan: BulkEditPlan, language: AppLanguage) -> [String] {
    var lines: [String] = []
    let whole = plan.fullySkipped
    if !whole.isEmpty {
      lines.append(
        language.format("bulk.skipped", table: table, counts: whole.count) + " "
          + reasons(whole, language: language))
    }
    let partly = plan.partlySkipped
    if !partly.isEmpty {
      lines.append(
        language.format("bulk.partlySkipped", table: table, counts: partly.count) + " "
          + reasons(partly, language: language))
    }
    return lines
  }

  private static func reasons(_ skips: [BulkSkip], language: AppLanguage) -> String {
    BulkEditPlan.reasons(of: skips)
      .map { language("bulk.reason.\($0.rawValue)", table: table) }
      .joined(separator: "; ") + "."
  }
}
