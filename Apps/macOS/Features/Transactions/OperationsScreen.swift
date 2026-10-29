import AppCore
import SwiftUI

/// What «Операции» keeps while the main window shows another screen: the filters, the search and
/// the operation in the editor beside the table. The main window holds it, so ⌘1 and back — or a
/// look at an account — finds the table as it was left.
@MainActor
@Observable
final class OperationsScreenState {
  var filters = TransactionFilters(today: CalendarContext.system.day(of: Date()))
  /// The operation in the editor beside the table. It stays there until «Save» or «Cancel»,
  /// whatever is selected meanwhile.
  var editor: TransactionEditorModel?
  /// Another operation asked for while the one in the editor has unsaved changes: the question
  /// is up.
  var switchingTo: TransactionEntry?
  /// The transfer in the column beside the table, in place of an operation's editor.
  var transferEditor: TransferEntry?

  init(editing: TransactionEditorModel? = nil) {
    editor = editing
  }
}

/// «Операции» of the main window (⌘4, ⌘⇧T): every operation of the history in a table — a
/// row per operation with its account and card, category, place, «на кого», quality, cashback
/// and comment in columns, splits as a row with a disclosure triangle — with the search and the
/// filters above it, the months shown newest first, and the operation being edited in a column
/// at its right.
///
/// The table is the whole history the pipeline holds (`ComputeStore`), filtered by
/// `EntryFilter` and turned into rows off the main thread, 150 ms after the last change of a
/// filter, of the search or of the data, the previous filtering cancelled. Until the first data
/// arrives the screen shows the state of the data step; after that it keeps the rows it has
/// while the data is read again.
///
/// Selecting many and changing them works as on every list of the window: the same
/// `OperationActions`, the same bulk menu and confirmations, and the selection bar the window
/// floats with the entry line. ↓ in the entry line comes onto the newest row, ↑ and ↓ move the
/// selection a row, ↑ on the newest row and Esc go back to the line.
///
/// A double click edits: with the entry line, in the column beside the table — a column of a
/// fixed width in the screen's own row, not an inspector, so nothing of the window is laid out
/// again or asked for its minimum (the loops of 0317, 0328 and 0348 were all a split view taking
/// a minimum back from what it held) — or in the edit sheet when the screen is too narrow for
/// both; with the form at the side (`EntryStyle.form`), in the form, which follows the selection.
struct OperationsScreen: View {
  let deps: AppDependencies
  let actions: OperationActions
  @Bindable var state: OperationsScreenState

  init(deps: AppDependencies, actions: OperationActions, state: OperationsScreenState) {
    self.deps = deps
    self.actions = actions
    self.state = state
  }

  private var environment: AppEnvironment { deps.environment }
  private var store: TransactionsStore { deps.store }
  private var compute: ComputeStore { deps.compute }

  @Environment(\.themeSurfaces) private var surfaces
  @State private var choices = FilterChoices()
  /// What the filters found and the newest months of it the table shows.
  @State private var pages = TransactionPages()
  /// What the window gives this screen. It decides whether a double click edits beside the
  /// table or in a sheet; it never decides a size.
  @State private var width: CGFloat = 0
  @State private var showsFilters = false
  @State private var showsColumns = false
  /// Between `onAppear` and `onDisappear`: a double click taken a turn late is not taken by a
  /// screen already gone.
  @State private var isShown = false
  @FocusState private var searchFocused: Bool
  /// The columns of the table (`OperationColumnLayout`): a setting of this Mac.
  @AppStorage(OperationColumnLayout.storageKey) private var columnsText = ""

  /// The narrowest screen that edits beside the table: the editor's column and a table that
  /// still shows the time, the description and the amount.
  static let widthForEditorColumn: CGFloat = OperationEditPlace.widthForEditorColumn

  private var editorColumnShown: Bool {
    environment.entryStyle == .line && (state.editor != nil || state.transferEditor != nil)
  }

  private var layout: OperationColumnLayout { OperationColumnLayout(storage: columnsText) }

  var body: some View {
    VStack(spacing: 0) {
      header
      HStack(spacing: 0) {
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          // The place of the table for the guide, whatever the table is showing now.
          .guideTarget(GuideTarget.operationsList)
        if editorColumnShown, let transfer = state.transferEditor {
          Divider()
          TransferEditorColumn(entry: transfer) { state.transferEditor = nil }
            .appDependencies(deps)
            .id(ObjectIdentifier(transfer))
            .frame(width: TransactionInspector.idealWidth)
            .frame(maxHeight: .infinity)
        } else if editorColumnShown, let editor = state.editor {
          Divider()
          TransactionInspector(deps: deps, editor: editor) { state.editor = nil }
            // The operation, not the object: `followData` makes a fresh model for the same
            // operation on every generation of the data, and identity by object would build
            // the whole column again on every pass.
            .id(editor.id)
            .frame(width: TransactionInspector.idealWidth)
            .frame(maxHeight: .infinity)
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: { width in
      self.width = width
    }
    .task {
      // `--present inspector`: the newest operation in the editor, as a double click does.
      guard await LaunchPresentation.due(.inspector) else { return }
      // The data may still be on its way three seconds after the window appears.
      for _ in 0..<50 where compute.snapshot == nil {
        try? await Task.sleep(for: .milliseconds(200))
      }
      if let newest = compute.snapshot?.dataset.entries
        .filter({ $0.transaction.deletedAt == nil })
        .max(by: { $0.transaction.occurredAt < $1.transaction.occurredAt })
      {
        if LaunchOptions.current.presents.contains(.selection) {
          actions.selection = [newest.id]
        }
        request(newest)
      }
    }
    .confirmationDialog(
      t("inspector.unsavedTitle"), isPresented: isAskingToSwitch, titleVisibility: .visible,
      presenting: state.switchingTo
    ) { next in
      // Offered only when «Save» of the editor could be pressed: a total of zero, parts that do
      // not add up or a large write landing leave «Don't Save» and «Cancel».
      if state.editor?.canSave(in: store) == true {
        Button(environment.language("action.save")) { saveAndSwitch(to: next) }
      }
      Button(t("inspector.discard"), role: .destructive) {
        state.switchingTo = nil
        open(next)
      }
      Button(environment.language("action.cancel"), role: .cancel) { state.switchingTo = nil }
    } message: { _ in
      Text(verbatim: t("inspector.unsavedMessage"))
    }
    .sheet(isPresented: $showsColumns) {
      OperationColumnsSheet(
        layout: Binding(get: { layout }, set: { columnsText = $0.storage }),
        resetEverything: resetEverything
      )
      .appDependencies(deps)
    }
    .onAppear {
      isShown = true
      claimTheEditing()
      followData()
      takeSearchFocus()
      takeRange()
      GuideStore.shared.report(GuideEvent.operationsOpened)
    }
    .onDisappear {
      isShown = false
      releaseTheEditing()
    }
    // The form at the side edits the selected operation itself; the line leaves it to this screen.
    .onChange(of: environment.entryStyle) { _, _ in claimTheEditing() }
    // Every change of the data: the dictionaries the filters and the bulk menu offer follow it,
    // and the editor follows the operation it holds (`TransactionEditorModel.follow`).
    .onChange(of: compute.generation) { _, _ in followData() }
    // ⌘F while the screen is already open; when it opens, `onAppear` takes the flag.
    .onChange(of: environment.pendingSearchFocus) { _, _ in takeSearchFocus() }
    .onChange(of: environment.pendingTransactionsRange) { _, _ in takeRange() }
    // Another filter or search starts from the newest months again.
    .onChange(of: state.filters.entryFilter(today: environment.today)) { _, _ in
      pages.startOver()
    }
    .onChange(of: state.filters.search) { _, text in
      if !text.trimmingCharacters(in: .whitespaces).isEmpty {
        GuideStore.shared.report(GuideEvent.searched)
      }
    }
    .task(
      id: FilterKey(
        filter: state.filters.entryFilter(today: environment.today),
        generation: compute.generation)
    ) {
      await refilter()
    }
  }

  // MARK: The search, the filters and the columns

  /// A screen narrower than this drops the title (the navigation bar has it) and lets the
  /// chips and buttons scroll sideways.
  static let widthForTitle: CGFloat = 560

  private var header: some View {
    let roomy = width == 0 || width >= Self.widthForTitle
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        if roomy {
          Text(verbatim: environment.language("section.operations"))
            .appFont(.title.bold())
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 8)
        }
        searchField
          .frame(maxWidth: roomy ? 260 : .infinity)
        #if !os(iOS)
          Button {
            NotificationCenter.default.post(name: .focusEntryLine, object: nil)
          } label: {
            Label {
              Text(verbatim: environment.language("action.add"))
            } icon: {
              Image(systemName: "plus")
            }
            .labelStyle(.iconOnly)
          }
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.circle)
          .help(environment.language("action.add"))
          .accessibilityIdentifier("operations.add")
        #endif
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          QuickFilterChips(
            chips: OperationsQuickFilter.allCases,
            isActive: { $0.isActive(in: state.filters, today: environment.today) },
            title: { t($0.titleKey) },
            choose: { chip in
              chip.apply(to: &state.filters, tree: choices.categories, today: environment.today)
            })
          Spacer(minLength: 8)
          controls
        }
        .frame(minWidth: 0, maxWidth: .infinity)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var searchField: some View {
    let field = TextField(
      text: $state.filters.search, prompt: Text(verbatim: t("operations.search.prompt"))
    ) {
      Text(verbatim: t("transactions.search"))
    }
    .labelsHidden()
    .focused($searchFocused)
    .accessibilityIdentifier("transactions.search")
    .guideTarget(GuideTarget.operationsSearch)
    .popoverTip(SpendingSearchTip())
    #if os(iOS)
      // The phone's search is a capsule with a magnifier, as the design draws it.
      return HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        field.textFieldStyle(.plain)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(surfaces.card, in: .capsule)
      .overlay { Capsule().strokeBorder(surfaces.cardBorder, lineWidth: 0.5) }
    #else
      return field.textFieldStyle(.roundedBorder)
    #endif
  }

  private var controls: some View {
    HStack(spacing: 8) {
      Button {
        showsFilters = true
      } label: {
        Label {
          Text(verbatim: filtersTitle)
        } icon: {
          Image(
            systemName: state.filters.activeCount > 0
              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
      }
      .accessibilityIdentifier("operations.filters")
      .popover(isPresented: $showsFilters, arrowEdge: .bottom) {
        // A popover is laid out in a host of its own: the dependencies go with it.
        TransactionFiltersForm(filters: $state.filters, choices: choices)
          .frame(width: 340, height: 560)
          .appDependencies(deps)
      }

      if state.filters.canReset {
        Button(t("filters.reset")) { state.filters.reset() }
          .accessibilityIdentifier("operations.filters.reset")
      }

      // The saved filters: apply one, save these, open the list.
      SavedFiltersMenu()

      Button {
        showsColumns = true
      } label: {
        Label {
          Text(verbatim: t("operations.columns"))
        } icon: {
          Image(systemName: "tablecells")
        }
      }
      .labelStyle(.iconOnly)
      .help(t("operations.columns"))
      .accessibilityIdentifier("operations.columns")
    }
  }

  /// «Фильтры», and how many narrow the table: «Фильтры · 2».
  private var filtersTitle: String {
    let count = state.filters.activeCount
    return count == 0 ? t("filters.title") : "\(t("filters.title")) · \(count)"
  }

  /// «Сбросить к настройкам по умолчанию» of the columns: the standard columns in their order
  /// and widths, and no filter and no search.
  private func resetEverything() {
    columnsText = ""
    state.filters.reset()
  }

  // MARK: The table and its states

  @ViewBuilder
  private var content: some View {
    if compute.snapshot == nil, let waiting = compute.states.data.waiting {
      ComputedBlock(waiting: waiting) { compute.retry(ComputeStep.data) }
        .padding(16)
    } else if compute.snapshot?.ledger.rows.isEmpty == true {
      ContentUnavailableView {
        Label {
          Text(verbatim: t("transactions.noneYet"))
        } icon: {
          Image(systemName: "list.bullet.rectangle")
        }
      } description: {
        Text(verbatim: t("transactions.noneYetHint"))
      }
    } else if let listing = pages.listing, let shown = pages.shown, !listing.isEmpty {
      #if os(iOS)
        // The phone's day cards are cards already: no second card around them.
        VStack(spacing: 0) {
          table(shown)
          if shown.operationCount < listing.operationCount {
            earlierMonths(hidden: listing.operationCount - shown.operationCount)
              .background(surfaces.card)
              .clipShape(.rect(cornerRadius: 12))
              .padding(.horizontal, 16)
              .padding(.bottom, 8)
          }
        }
      #else
        // The table stands on a rounded card of the theme, as the design draws it.
        // The footer is an inset of the table, not a sibling under it: the table keeps its edge at
        // the bottom of the window, so the room the floating bars take reaches its scroll view.
        table(shown)
          .scrollContentBackground(.hidden)
          .safeAreaInset(edge: .bottom, spacing: 0) {
            if shown.operationCount < listing.operationCount {
              earlierMonths(hidden: listing.operationCount - shown.operationCount)
            }
          }
          .background(surfaces.card)
          .clipShape(.rect(cornerRadius: 16))
          .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(surfaces.cardBorder, lineWidth: 0.5)
          }
          // With the editor column open the card runs up to its divider: the column's own width is
          // what the layout keeps, and nothing of it is spent on a margin beside the table.
          .padding(.leading, 16)
          .padding(.trailing, editorColumnShown ? 0 : 16)
      #endif
    } else if pages.listing != nil {
      nothingFound
    } else {
      ProgressView()
    }
  }

  private func table(_ shown: TransactionListing) -> some View {
    let rows = OperationsArrows.rows(of: shown)
    return TransactionsTable(
      deps: deps,
      listing: shown,
      selection: Bindable(actions).selection,
      layout: layout,
      menu: { ids in BulkMenuItems(ids: ids, actions: actions, offersEdit: true) },
      primaryAction: { ids in actions.edit(ids, store: store) },
      deleteAction: { ids in actions.requestDeletion(of: ids, store: store) }
    )
    // Esc clears the selection and hands the keyboard back to the entry line.
    .onExitCommand {
      actions.selection = []
      NotificationCenter.default.post(name: .returnToEntryLine, object: nil)
    }
    // ↓ in the entry line walks the table from its newest row; ↑ on that row goes back.
    .walkedFromTheEntryLine(firstRow: rows.first, selection: Bindable(actions).selection)
    // ↓ and ↑ move the selection a row, from the row the window says is selected: a row
    // selected by the window — ↓ from the entry line, the form at the side — is the one the
    // arrows go on from, whatever the table remembered.
    .onKeyPress(keys: [.downArrow, .upArrow]) { press in
      guard press.modifiers.isDisjoint(with: [.shift, .command, .option, .control]),
        let next = OperationsArrows.next(
          from: actions.selection, rows: rows, down: press.key == .downArrow)
      else { return .ignored }
      actions.selection = [next]
      return .handled
    }
  }

  /// The table shows the newest months of what was found; earlier ones come a few months at
  /// a time.
  private func earlierMonths(hidden: Int) -> some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 12) {
        Text(
          verbatim: environment.language.format(
            "transactions.olderHidden", table: "Transactions", counts: hidden)
        )
        .foregroundStyle(.secondary)
        .lineLimit(1)
        Spacer(minLength: 8)
        Button(t("transactions.showEarlier")) { showEarlier() }
          .buttonStyle(.link)
      }
      .appFont(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
  }

  /// A few more months, cut off the main thread from the listing already built.
  private func showEarlier() {
    guard let request = pages.showMore() else { return }
    Task { await cut(request) }
  }

  /// Cuts a page off the main thread and shows it — unless the listing or the months asked
  /// for changed while it was cut (`TransactionPages`).
  private func cut(_ request: TransactionPages.Request) async {
    guard let page = try? await compute.compute({ request.listing.latestMonths(request.months) }),
      pages.land(page, for: request)
    else { return }
    actions.keep(only: page.visibleIds)
  }

  /// The filters and the search found nothing. «Reset» brings back the whole history with
  /// nothing chosen.
  private var nothingFound: some View {
    ContentUnavailableView {
      Label {
        Text(verbatim: t("filters.nothingFound"))
      } icon: {
        Image(systemName: "line.3.horizontal.decrease.circle")
      }
    } description: {
      Text(verbatim: t("filters.empty"))
    } actions: {
      if state.filters.canReset {
        Button(t("filters.reset")) { state.filters.reset() }
      } else if state.filters.period != .allTime {
        Button(t("filters.allTime")) { state.filters.period = .allTime }
      }
    }
  }

  // MARK: Filtering

  /// Filters the whole history and builds the rows off the main thread. The first filtering
  /// after the data arrives goes at once; later ones wait 150 ms, so typing in the search box
  /// filters once.
  private func refilter() async {
    guard let ledger = compute.snapshot?.ledger else { return }
    if pages.listing != nil {
      try? await Task.sleep(for: ComputeStore.debounce)
      guard !Task.isCancelled else { return }
    }
    let (filter, months) = (state.filters.entryFilter(today: environment.today), pages.monthsShown)
    guard
      let result = try? await compute.compute({
        let found = TransactionListing.build(matching: filter, in: ledger)
        return (found: found, page: found.latestMonths(months))
      }),
      // A newer filter or newer data replaced this one while it ran: its result is stale.
      !Task.isCancelled
    else { return }
    let again = pages.land(found: result.found, page: result.page, cutFor: months)
    // Whatever the filters hide, the months not shown, and what a change takes away are no
    // longer selected.
    actions.keep(only: result.page.visibleIds)
    // «Show more» was pressed while this ran: the new listing is cut again for it.
    if let again { await cut(again) }
  }

  /// The dictionaries of the data the table shows, and the operation in the editor kept in
  /// step with it.
  private func followData() {
    guard let snapshot = compute.snapshot else { return }
    choices = FilterChoices(snapshot.dataset, locale: environment.language.locale)
    // A value archived since it was chosen is no longer offered: it stops filtering.
    var kept = state.filters
    kept.keep(within: choices)
    if kept != state.filters { state.filters = kept }
    actions.reloadDictionaries(from: snapshot.dataset)
    if let open = state.transferEditor?.form.previous,
      store.transfers(among: [open.id]).isEmpty
    {
      state.transferEditor = nil
    }
    guard let editor = state.editor else { return }
    // Deleted meanwhile — from the menu, or by ⌘Z of its creation — or changed elsewhere — a
    // bulk change, a part written off: with nothing typed here the editor closes, or shows the
    // operation as it is now, so a save cannot bring the old version back. With changes typed
    // it keeps them, and says so when the operation is gone.
    switch editor.follow(store.entry(id: editor.id)) {
    case .stay:
      break
    case .close:
      state.editor = nil
    case .reopen(let fresh):
      state.editor = TransactionEditorModel(
        entry: fresh, environment: environment, tree: snapshot.ledger.tree)
    }
  }

  // MARK: The editor

  /// With the entry line, a double click and «Edit» come here; with the form at the side, the
  /// form takes them (`EntryBar`), and an editor left open here goes.
  private func claimTheEditing() {
    switch environment.entryStyle {
    case .line:
      // A double click is an `NSTableView` delegate callback: the editor opens on the next
      // turn of the main queue, so the screen is not rearranged while the table is still
      // handling the click.
      let opens: @MainActor (TransactionEntry) -> Void = { entry in
        MainQueue.afterCallback { request(entry) }
      }
      actions.opensEditor = opens
      let opensTransfer: @MainActor (TransferEditing) -> Void = { editing in
        MainQueue.afterCallback { requestTransfer(editing) }
      }
      actions.opensTransferEditor = opensTransfer
      // The form at the side, going away as the line comes back, lets go of the double click
      // as it disappears — which may be after this: it is taken again a turn later.
      Task { @MainActor in
        if isShown, environment.entryStyle == .line {
          actions.opensEditor = opens
          actions.opensTransferEditor = opensTransfer
        }
      }
    case .form:
      state.editor = nil
      state.transferEditor = nil
    }
  }

  /// The other lists of the window edit in the sheet again; the form keeps what it set.
  private func releaseTheEditing() {
    if environment.entryStyle == .line {
      actions.opensEditor = nil
      actions.opensTransferEditor = nil
    }
  }

  /// The accounts' balances as the data on screen has them: a save that lands an operation on
  /// the day of a count, after it, asks first.
  private var balances: AccountBalances {
    compute.snapshot?.planning.accounts.balances ?? .empty
  }

  /// A double click or «Edit»: the operation goes into the editor beside the table — after
  /// asking, when the one there has unsaved changes —, or into the edit sheet when the screen
  /// has no room for the column.
  private func request(_ entry: TransactionEntry) {
    guard OperationEditPlace.choose(style: environment.entryStyle, width: width) == .column else {
      actions.editing = entry
      return
    }
    state.transferEditor = nil
    if let editor = state.editor, editor.id != entry.id, editor.hasChanges {
      state.switchingTo = entry
      return
    }
    guard state.editor?.id != entry.id else { return }
    open(entry)
  }

  /// A transfer goes where an operation goes: the column beside the table, or the sheet when
  /// the screen is too narrow for it.
  private func requestTransfer(_ editing: TransferEditing) {
    guard OperationEditPlace.choose(style: environment.entryStyle, width: width) == .column else {
      actions.editingTransfer = editing
      return
    }
    // Unsaved typing in the operation's editor is not thrown away for a transfer: the sheet
    // takes the transfer and the column keeps the typing.
    if state.editor?.hasChanges == true {
      actions.editingTransfer = editing
      return
    }
    guard state.transferEditor?.form.previous?.id != editing.id else { return }
    state.editor = nil
    state.transferEditor = TransferEntry(form: editing.form(calendar: environment.calendar))
  }

  private func open(_ entry: TransactionEntry) {
    state.transferEditor = nil
    state.editor = TransactionEditorModel(
      entry: entry, environment: environment,
      tree: compute.snapshot?.ledger.tree ?? CategoryTree())
  }

  /// «Save» in the question: the changes are saved first; if they cannot be, the editor keeps
  /// them and says why, and the other operation waits.
  private func saveAndSwitch(to next: TransactionEntry) {
    guard let editor = state.editor,
      editor.save(store: store, environment: environment, balances: balances)
    else { return }
    state.switchingTo = nil
    open(next)
  }

  private var isAskingToSwitch: Binding<Bool> {
    Binding(
      get: { state.switchingTo != nil },
      set: { isShown in
        if !isShown { state.switchingTo = nil }
      })
  }

  // MARK: Search focus and the range of a reconciliation

  /// The days a reconciliation asked to look through for missing operations.
  private func takeRange() {
    guard let range = environment.pendingTransactionsRange else { return }
    environment.pendingTransactionsRange = nil
    state.filters.customStart = range.start
    state.filters.customEnd = range.end
    state.filters.period = .custom
  }

  /// ⌘F from anywhere sets the flag and opens this screen; whichever of `onAppear` and
  /// `onChange` comes first takes it, so the very first ⌘F focuses the field too. The field
  /// may not be in the window yet when the screen appears: the focus is asked for again a
  /// moment later.
  private func takeSearchFocus() {
    guard environment.pendingSearchFocus else { return }
    environment.pendingSearchFocus = false
    searchFocused = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      searchFocused = true
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Transactions") }
}

/// What the filtering of the screen depends on.
private struct FilterKey: Hashable {
  let filter: EntryFilter
  let generation: Int
}

/// «Настроить столбцы…» of «Операции»: which columns the table shows, in which order and how
/// wide, and the way back to the standard table with no filter.
struct OperationColumnsSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  @Binding var layout: OperationColumnLayout
  let resetEverything: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("operations.columns.title"))
        .appFont(.headline)
      Text(verbatim: t("operations.columns.hint"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      List {
        ForEach(layout.order) { column in
          row(column)
        }
        .onMove { layout.move(fromOffsets: $0, toOffset: $1) }
      }
      .columnsListStyle()
      .frame(minHeight: 380)
      HStack {
        Button(t("operations.columns.reset")) { resetEverything() }
          .help(t("operations.columns.resetHint"))
          .accessibilityIdentifier("operations.columns.reset")
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 560)
  }

  private func row(_ column: OperationColumn) -> some View {
    let title = environment.language(column.titleKey, table: "Transactions")
    return HStack(spacing: 12) {
      Toggle(isOn: shown(column)) {
        Text(verbatim: title)
      }
      .disabled(!column.canBeHidden)
      Spacer(minLength: 8)
      Stepper(
        value: width(column), in: column.minimumWidth...column.maximumWidth, step: 10
      ) {
        Text(
          verbatim: environment.language.format(
            "operations.columns.width", table: "Transactions", "\(layout.width(of: column))")
        )
        .monospacedDigit()
        .foregroundStyle(.secondary)
      }
      Button {
        layout.move(column, by: -1)
      } label: {
        Label {
          Text(verbatim: t("operations.columns.up"))
        } icon: {
          Image(systemName: "chevron.up")
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .disabled(layout.order.first == column)
      Button {
        layout.move(column, by: 1)
      } label: {
        Label {
          Text(verbatim: t("operations.columns.down"))
        } icon: {
          Image(systemName: "chevron.down")
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .disabled(layout.order.last == column)
    }
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: Text(verbatim: t("operations.columns.up"))) {
      layout.move(column, by: -1)
    }
    .accessibilityAction(named: Text(verbatim: t("operations.columns.down"))) {
      layout.move(column, by: 1)
    }
  }

  private func shown(_ column: OperationColumn) -> Binding<Bool> {
    Binding(get: { layout.isShown(column) }, set: { layout.setShown($0, column) })
  }

  private func width(_ column: OperationColumn) -> Binding<Int> {
    Binding(get: { layout.width(of: column) }, set: { layout.setWidth($0, of: column) })
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Transactions") }
}

extension View {
  /// The bordered list of the column settings is a Mac list; a touch screen has the inset one.
  @ViewBuilder fileprivate func columnsListStyle() -> some View {
    #if os(macOS)
      listStyle(.bordered)
    #else
      listStyle(.insetGrouped)
    #endif
  }
}
