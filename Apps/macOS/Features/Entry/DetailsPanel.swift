import AppCore
import SwiftUI

/// The ↓ panel. Every field of an operation is here: type, category with suggestions,
/// quality, for whom, place, event, the account or its card and what it was charged, the
/// cashback, goal, debt, note, date, currency and rate — plus splitting, paying for somebody
/// else and buying on credit.
/// Only the fields the kind has are shown (`EntryDraftModel.fields`): income has no place,
/// event, «на кого», «за другого» or credit; money back has its person and its account; a
/// refund names the purchase it takes money back from.
///
/// The fields stand in the owner's order (Settings → «Ввод», `AppEnvironment.entryFieldOrder`),
/// and Tab walks them in it; the type stays on top — it decides which fields there are — and
/// the parts and the actions below them.
struct DetailsPanel: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  /// «Запомнить» of «Кэшбэк» writes its rule through the store: a step of ⌘Z.
  @Dependency(\.store) private var store
  @Environment(\.themeSurfaces) private var surfaces
  /// Handed to the sheet of «Add…», which SwiftUI lays out in a host of its own.
  @Environment(\.dependencies) private var dependencies
  @Bindable var model: EntryDraftModel
  /// «Хватит ли?» of a big expense is open.
  @State private var asksAfford = false
  /// Return in a text field of the panel («Сохранение — Enter»). The ↓ panel
  /// of the entry line saves with it; the editor of a saved operation has «Save» of its own.
  var submit: (() -> Void)? = nil
  /// The panel of a new operation offers «Перевод» among the kinds: the fields of a transfer
  /// stand in place of the fields of an operation, started with what the panel holds, and the
  /// panel saves the transfer (`EntryDraftModel.transfer`). The editor of a saved operation
  /// does not.
  var offersTransfer = false
  /// Told whether a field of the panel has the keyboard: the form at the side of the window
  /// answers Return with «Save» only while one does.
  var focusedInside: Binding<Bool>? = nil
  /// How the fields stand: beside their labels in a grid — the ↓ panel, 560–720 pt wide, and the
  /// editor — or under them in one column, for the form at the side of the window.
  var arrangement: Arrangement = .wide
  /// Whether the grid is wide enough for the kinds and «За кого» as segments side by side: the
  /// ↓ panel, 560–720 pt, is. The inspector of the Transactions window, a column of 300–440 pt,
  /// is not — there both are menus. Four kinds side by side want 390 pt in English and 524 in
  /// Russian, wider than the column can ever be, and SwiftUI does not always measure such a
  /// control squeezed: on some passes the content reported that natural width as its minimum,
  /// the split could not give a column more than its maximum, and the window looped until AppKit
  /// threw (`testTheInspectorNeverAsksForMoreThanItsColumnCanGive`).
  var hasRoomForSegments = true
  /// The line of quick entry the form at the side puts over its fields. It shares the panel's
  /// focus, so ⌘N asks for it the way Tab asks for a field (`PanelFocus.quick`) — one focus, never
  /// two that pull against each other.
  var quickLine: ((FocusState<PanelFocus?>.Binding) -> AnyView)? = nil
  /// Whether the kind of the operation has been chosen, in the form at the side: until it is, the
  /// form shows the quick line and the kinds alone, and a tile — or the quick line read into the
  /// fields — brings the fields. `nil`: the fields are always there (the ↓ panel, the editor).
  var kindChosen: Binding<Bool>? = nil
  /// What stands at the end of the row of the kinds: the ↓ panel's «Esc» and its close button.
  var headerTrailing: AnyView? = nil
  /// The panel has «Записать» of its own at its foot with a hint of the keys — the ↓ panel, which
  /// has no button of the editor's.
  var showsSave = false
  /// The control of the panel that has the keyboard focus, when it is one of the fields.
  @FocusState private var focus: PanelFocus?

  enum Arrangement {
    /// A label column and a control column: the ↓ panel and the editor.
    case wide
    /// Every label above its control, every control as wide as the column, the buttons wrapping:
    /// the form at the side of the window, about 380 pt wide.
    case column
  }

  /// The form at the side of the window, not the ↓ panel or the editor. Every field stands as
  /// the design draws it in all of them: its label above its control, the control as wide as its
  /// cell, the cells flowing in columns (`EntryFieldFlow`); only the number of columns differs.
  private var isSideForm: Bool { arrangement == .column }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let quickLine {
        quickLine($focus)
        Divider()
      }
      HStack(spacing: 12) {
        typeRow
        if let headerTrailing { headerTrailing }
      }
      if showsFields, let transfer = model.transfer {
        Divider()
        TransferFields(entry: transfer, layout: isSideForm ? .column : .wide, focus: $focus)
      } else if showsFields {
        Divider()
        fieldsAndActions
      } else {
        Text(verbatim: t("entry.form.chooseKind"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("entry.form.chooseKind")
      }
    }
    .frame(maxWidth: 720, alignment: .leading)
    .onSubmit { submit?() }
    // The quick line answers Return itself: the form's «Save» is not its default button.
    .onChange(of: focus) { _, field in focusedInside?.wrappedValue = field != nil && field != .quick
    }
    // The panel is asked to put the focus somewhere: the first or the last field of the order —
    // Tab and Shift-Tab in the line — or the field Enter asks for. Asked on the next turn: the
    // panel may be appearing just now.
    .task(id: model.focusRequest) {
      guard let request = model.focusRequest else { return }
      try? await Task.sleep(for: .milliseconds(30))
      focus =
        model.transfer == nil
        ? PanelTabOrder.resolve(
          request, order: environment.entryFieldOrder, shown: shownControls,
          fullKeyboardAccess: PanelTabOrder.fullKeyboardAccess)
        : PanelTabOrder.resolveTransfer(
          request, shown: shownControls, fullKeyboardAccess: PanelTabOrder.fullKeyboardAccess)
      model.focusRequest = nil
    }
    // The data was computed again — the bank's rates among it: «Списано со счёта» reads them
    // afresh the next time it is worked out.
    .onChange(of: compute.generation) { _, _ in model.ratesMayHaveChanged() }
    // The shares of «Пополам» and «Поровну» follow the total.
    .onChange(of: model.draft.amount) { _, _ in model.relayPayingFor() }
    // A saved operation shows «За кого» as its parts say it.
    .onAppear { if model.editsSavedOperation { model.readPayingFor() } }
    // «Add…» of a menu: a record of its kind, chosen in that menu once it is saved.
    .sheet(item: $model.adding) { kind in
      AddRecordSheet(kind: kind, model: model, today: environment.today) {
        model.adding = nil
      }
      .handingOver(dependencies)
    }
  }

  /// The fields are on screen: always, but in the form at the side before a kind is chosen.
  private var showsFields: Bool { kindChosen?.wrappedValue ?? true }

  /// Everything under the kinds: the fields, the parts, the actions and what stops the save.
  @ViewBuilder
  private var fieldsAndActions: some View {
    mainFields
    // The difference of a count: why its money cannot be changed here.
    if model.isReconcileDifference {
      Label {
        Text(
          verbatim: environment.language(
            "editor.reconcileDifference.locked", table: "Transactions"))
      } icon: {
        Image(systemName: "lock")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("entry.reconcileDifference.locked")
    }
    // Money back is never split: a split held before the kind changed stays out of sight,
    // and out of what is written.
    if model.isSplit && model.has(.split) {
      Divider()
      splitEditor
    }
    Divider()
    footer
    // «Save» is inactive for these, and nothing else in the panel says why. Wraps in the
    // width it is given: the panel is also the inspector, a column of a split view.
    if let refusal = model.shownRefusalKey {
      Text(verbatim: t(refusal))
        .appFont(.caption)
        .foregroundStyle(.red)
        .accessibilityIdentifier("entry.refusal")
    }
    // A record «Add…» asked for that the database refused: nothing was chosen.
    if let failure = model.creationFailureKey {
      Text(verbatim: t(failure))
        .appFont(.caption)
        .foregroundStyle(.red)
    }
  }

  // MARK: Type

  /// Four kinds side by side want about 450 pt, more than the column has: there every choice is
  /// a tile, two to a row, the transfer among them, so none hides in a menu
  /// (`EntryKindTiles`).
  @ViewBuilder
  private var typeRow: some View {
    switch arrangement {
    case .wide:
      if hasRoomForSegments {
        kindTabs
      } else {
        kindPicker.pickerStyle(.menu)
      }
    case .column: kindTiles
    }
  }

  /// The kinds in one capsule track, «Перевод» last where the panel offers a transfer.
  private var kindTabs: some View {
    EntryKindTabs(
      tiles: EntryKindTiles.all.filter { $0 != .transfer || offersTransfer },
      chosen: model.transfer == nil ? .kind(model.draft.kind) : .transfer,
      title: { tile in
        switch tile {
        case .kind(let kind): environment.language("kind.\(kind.rawValue)")
        case .transfer: t("entry.kind.transfer")
        }
      },
      locked: model.hasClosedPart || model.isReconcileDifference,
      choose: { chooseKind($0) }
    )
    // The defaults also drop a category of the other kind from every part, so switching an
    // expense to income never leaves an expense category behind.
    .onChange(of: model.draft.kind) { _, _ in
      model.applyDefaults(today: environment.today)
    }
  }

  /// The tiles of the column: the kinds, and the transfer where the panel offers one.
  private var kindTiles: some View {
    let tiles = EntryKindTiles.all.filter { $0 != .transfer || offersTransfer }
    let rows = EntryKindTiles.rows(of: tiles, mostUsed: model.mostUsedKindTile)
    let locked = model.hasClosedPart || model.isReconcileDifference
    return VStack(spacing: 6) {
      ForEach(rows, id: \.self) { row in
        HStack(spacing: 6) {
          ForEach(row, id: \.self) { tile in
            kindTile(tile, locked: locked)
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: t("entry.kind.tiles")))
  }

  @ViewBuilder
  private func kindTile(_ tile: EntryKindTile, locked: Bool) -> some View {
    switch tile {
    case .kind(let kind):
      // Before a kind is chosen in the form, none of the tiles is lit.
      let chosen = showsFields && model.transfer == nil && model.draft.kind == kind
      Button {
        let fieldsWereHidden = !showsFields
        kindChosen?.wrappedValue = true
        chooseKind(.kind(kind))
        // The fields have just come: the keyboard goes to the first of them.
        if fieldsWereHidden { model.focusRequest = .first }
      } label: {
        Label {
          Text(verbatim: environment.language("kind.\(kind.rawValue)"))
        } icon: {
          Image(systemName: Self.symbol(of: kind))
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .tint(chosen ? Color.accentColor : nil)
      .fontWeight(chosen ? .semibold : .regular)
      .disabled(locked && !chosen)
      .accessibilityAddTraits(chosen ? .isSelected : [])
      .accessibilityIdentifier("entry.kind.\(kind.rawValue)")
    case .transfer:
      let chosen = showsFields && model.transfer != nil
      Button {
        let fieldsWereHidden = !showsFields
        kindChosen?.wrappedValue = true
        chooseKind(.transfer)
        if fieldsWereHidden { model.focusRequest = .first }
      } label: {
        Label {
          Text(verbatim: t("entry.kind.transfer"))
        } icon: {
          Image(systemName: "arrow.left.arrow.right.circle")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .tint(chosen ? Color.accentColor : nil)
      .fontWeight(chosen ? .semibold : .regular)
      .disabled(locked)
      .accessibilityAddTraits(chosen ? .isSelected : [])
      .accessibilityIdentifier("entry.kind.transfer")
    }
  }

  /// A kind chosen — a tile, a segment, «Перевести…»: an operation of that kind, its defaults
  /// laid, or the transfer, started with what the panel holds. The draft of the operation stays
  /// beside a transfer, and comes back as it was.
  private func chooseKind(_ tile: EntryKindTile) {
    switch tile {
    case .kind(let kind):
      model.transfer = nil
      guard model.draft.kind != kind else { return }
      model.draft.kind = kind
      // The segments lay the defaults when the kind changes (`kindPicker`); the tiles here.
      if isSideForm { model.applyDefaults(today: environment.today) }
    case .transfer:
      model.chooseTransfer(calendar: environment.calendar)
    }
  }

  private static func symbol(of kind: TransactionKind) -> String {
    switch kind {
    case .expense: "arrow.down.circle"
    case .income: "arrow.up.circle"
    case .refund: "arrow.uturn.left.circle"
    case .reimbursement: "person.crop.circle.badge.checkmark"
    }
  }

  /// The kinds, and «Перевод» last where the panel offers a transfer.
  private var kindPicker: some View {
    Picker(
      selection: Binding<EntryKindTile>(
        get: { model.transfer == nil ? .kind(model.draft.kind) : .transfer },
        set: { chooseKind($0) })
    ) {
      ForEach(TransactionKind.allCases, id: \.self) { kind in
        Text(verbatim: environment.language("kind.\(kind.rawValue)"))
          .tag(EntryKindTile.kind(kind))
      }
      if offersTransfer {
        Text(verbatim: t("entry.kind.transfer")).tag(EntryKindTile.transfer)
      }
    } label: {
      Text(verbatim: t("entry.category"))
    }
    .labelsHidden()
    // Money came back for a part: what the operation is stays as the reimbursement found it.
    // The difference of a count is what the count found.
    .disabled(model.hasClosedPart || model.isReconcileDifference)
    // The defaults also drop a category of the other kind from every part, so switching an
    // expense to income never leaves an expense category behind.
    .onChange(of: model.draft.kind) { _, _ in
      model.applyDefaults(today: environment.today)
    }
  }

  // MARK: Main fields

  /// The fields in the owner's order. A field the kind does not have is not shown, wherever it
  /// stands in the order.
  private var mainFields: some View {
    fields {
      ForEach(environment.entryFieldOrder, id: \.self) { field in
        rows(for: field)
      }
      // «За кого» after the fields of the order: Tab from the line reaches the first of them.
      if model.offersPayingFor || model.payingForWay != nil {
        payingForRows
      }
    }
  }

  // MARK: За кого

  /// «За кого»: Себе, За другого, Пополам, Поровну — the people, «Вернёт?», and under them what
  /// comes of it in plain words (`PayingForRules`).
  @ViewBuilder
  private var payingForRows: some View {
    let way = model.shownPayingForWay
    fieldRow("entry.payingFor") {
      Picker(
        selection: Binding(
          get: { model.shownPayingForWay }, set: { model.choosePayingForWay($0) })
      ) {
        ForEach(EntryDraftModel.PayingForWay.allCases, id: \.self) { way in
          Text(verbatim: t("entry.payingFor.\(way.rawValue)")).tag(way)
        }
      } label: {
        Text(verbatim: t("entry.payingFor"))
      }
      .labelsHidden()
      .modifier(
        PayingForStyle(arrangement: arrangement, hasRoomForSegments: hasRoomForSegments)
      )
      .accessibilityIdentifier("entry.payingFor")
      .guideTarget("entry.forWhom")
    }
    if way != .me {
      fieldRow(way == .evenly ? "entry.payingFor.people" : "entry.payingFor.person") {
        payingForPeople(way)
      }
    }
    if way == .somebody {
      fieldRow("entry.payingFor.paysBack") {
        Picker(
          selection: Binding(
            get: { model.payingForPaysBack }, set: { model.setPaysBack($0) })
        ) {
          Text(verbatim: t("entry.payingFor.paysBack.yes")).tag(true)
          Text(verbatim: t("entry.payingFor.paysBack.no")).tag(false)
        } label: {
          Text(verbatim: t("entry.payingFor.paysBack"))
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(model.payingForPeople.isEmpty)
        .accessibilityIdentifier("entry.payingFor.paysBack")
      }
    }
    if let sentence = payingForSentence {
      fieldRow(nil) {
        Text(verbatim: sentence)
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("entry.payingFor.outcome")
      }
    }
  }

  @ViewBuilder
  private func payingForPeople(_ way: EntryDraftModel.PayingForWay) -> some View {
    let people = model.payingForPeople
    let options = model.people.filter { !$0.archived }.map { ($0.id, $0.name) }
    let slots = way == .evenly ? people.count + 1 : 1
    buttonRow(spacing: 8).callAsFunction {
      ForEach(0..<slots, id: \.self) { slot in
        referencePicker(
          selection: Binding(
            get: { slot < people.count ? people[slot] : nil },
            set: { model.setPayingForPerson($0, slot: slot) }),
          options: options, adding: .payingFor(slot: slot)
        )
        .frame(maxWidth: 160)
        .accessibilityIdentifier("entry.payingFor.person.\(slot)")
      }
    }
  }

  /// Four ways side by side want about 340 pt in Russian, more than the column has: there they
  /// are a menu as wide as the column, and in the inspector a menu.
  private struct PayingForStyle: ViewModifier {
    let arrangement: Arrangement
    let hasRoomForSegments: Bool

    func body(content: Content) -> some View {
      switch arrangement {
      case .wide where hasRoomForSegments: content.pickerStyle(.segmented)
      case .wide: content.pickerStyle(.menu)
      case .column:
        content.pickerStyle(.menu).buttonSizing(.flexible)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// What «За кого» comes to, under its fields (`PayingForSentence`).
  private var payingForSentence: String? {
    PayingForSentence.text(of: model, environment: environment)
  }

  /// The rows of fields: cells flowing in columns — three in the ↓ panel, two in the form at the
  /// side — each a label over its control.
  private func fields<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    EntryFieldFlow(
      maxColumns: isSideForm
        ? EntryFieldFlowMetrics.sideColumns : EntryFieldFlowMetrics.panelColumns
    ) { content() }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// One field: its label above its control, the control as wide as its cell. `alone`: the field
  /// takes a row of its own — the amount, a note, a choice of a few options. No `key`: a line
  /// under the control above, always on a row of its own.
  @ViewBuilder
  private func fieldRow<Control: View>(
    _ key: String?, marked: Bool = false, alone: Bool = false, @ViewBuilder control: () -> Control
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let key { fieldLabel(key, marked: marked) }
      control()
        .buttonSizing(.flexible)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .layoutValue(key: EntryFieldFlow.Alone.self, value: alone || key == nil)
  }

  /// A control with what goes beside it: one under the other, where a cell is too narrow for
  /// the two in a line.
  private var beside: AnyLayout {
    AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
  }

  /// A row of small buttons: they wrap where the width ends.
  private func buttonRow(spacing: CGFloat) -> AnyLayout {
    AnyLayout(FlowRow(spacing: spacing, lineSpacing: 8))
  }

  /// A fixed width: none, the control is as wide as its cell.
  private func gridWidth(_ width: CGFloat) -> CGFloat? { nil }

  @ViewBuilder
  private func rows(for field: EntryField) -> some View {
    switch field {
    case .amount: amountRows
    case .category: categoryRows
    case .quality: qualityRow
    case .forWhom: forWhomRow
    case .place: placeRow
    case .event: eventRow
    case .account: accountRows
    case .cashback: cashbackRow
    case .goal: goalRow
    case .debt: debtRow
    case .note:
      noteRow
      oneOffRow
    case .date: dateRow
    case .incomeMonth: incomeMonthRows
    case .currency: currencyRows
    }
  }

  /// Which controls are on screen, for Tab: by the same conditions the rows are laid by.
  private var shownControls: Set<PanelFocus> {
    // Before a kind is chosen only the quick line is there.
    guard showsFields else { return quickLine == nil ? [] : [.quick] }
    if model.transfer != nil {
      var shown = Set(PanelTabOrder.transferControls)
      if model.transfer?.form.isExchange != true { shown.remove(.transferReceived) }
      if quickLine != nil { shown.insert(.quick) }
      return shown
    }
    var shown: Set<PanelFocus> = [.amount, .account, .note, .date, .currency]
    if quickLine != nil { shown.insert(.quick) }
    if model.has(.category) { shown.formUnion([.category, .subcategory]) }
    if model.hasQuality && model.has(.quality) { shown.insert(.quality) }
    if model.has(.fromPerson) {
      shown.insert(.forPerson)
    } else if model.has(.forWhom) && !forWhomIsSaidByPayingFor {
      shown.insert(.forWhom)
    }
    if model.has(.place) { shown.insert(.place) }
    if model.has(.event) { shown.insert(.event) }
    if model.needsCharge { shown.insert(.charge) }
    if model.showsCashback { shown.insert(.cashback) }
    if showsGoal { shown.insert(.goal) }
    if showsDebt { shown.insert(.debt) }
    if model.draft.kind == .income {
      shown.insert(.incomeMonth)
      if !openExpectations.isEmpty, model.linksExpectedIncome { shown.insert(.expected) }
    }
    if model.draft.currency != .rub { shown.insert(.rate) }
    return shown
  }

  /// The money of the difference of a count follows the books: it is not changed here.
  private var moneyLocked: Bool { model.isReconcileDifference }

  @ViewBuilder
  private var amountRows: some View {
    fieldRow("entry.amount", alone: true) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        AmountField(
          amount: totalBinding,
          // The text goes along: a formula typed here is kept in `amount_expr`.
          onTyped: { model.setTotal($0, typed: $1) },
          prominent: true
        )
        .frame(width: 180)
        .focused($focus, equals: .amount)
        // One part is the whole operation: its amount is the total.
        .disabled((!model.isSplit && model.hasClosedPart) || moneyLocked)
        // The formula the amount was worked out from, its numbers written the way the app
        // writes them.
        if let expression = model.draft.amountExpression {
          Text(verbatim: ExpressionEvaluator.canonical(expression) ?? expression)
            .appFont(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        // Another currency than the default one: grey «≈ 1,240 ₽», display only.
        if let approximate = ApproximateText.of(
          amount: model.draft.amount, currency: model.draft.currency, environment: environment,
          compute: compute)
        {
          Text(verbatim: approximate)
            .appFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("entry.approximate")
        }
      }
    }
    // An income in a category with a tax: grey «налог ≈ 240 ₽ (4 %)», never money.
    if let tax = taxEstimateText {
      fieldRow(nil) {
        Text(verbatim: tax)
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("entry.taxEstimate")
      }
    }
    if let affordAmount = affordLinkAmount {
      fieldRow(nil) {
        Button(environment.language("afford.title", table: "WhatIf")) { asksAfford = true }
          .buttonStyle(.link)
          .accessibilityIdentifier("entry.afford")
          .sheet(isPresented: $asksAfford) {
            AffordSheet(amount: affordAmount).handingOver(dependencies)
          }
      }
    }
    if !model.isSplit && model.hasClosedPart {
      fieldRow(nil) { closedPartCaption }
    }
    if model.offersRefundPurchase {
      fieldRow("entry.refund.purchase", alone: true) { refundPurchaseRow }
    }
  }

  @ViewBuilder
  private var categoryRows: some View {
    if model.has(.category) {
      fieldRow("entry.category", marked: model.markedGap == .category) {
        HStack(spacing: 8) {
          categoryPicker(forPartAt: 0)
            .focused($focus, equals: .category)
          if model.markedGap == .category { gapMark(.category) }
        }
      }
      fieldRow("entry.subcategory", marked: model.markedGap == .subcategory) {
        HStack(spacing: 8) {
          subcategoryPicker(forPartAt: 0)
            .focused($focus, equals: .subcategory)
          if model.markedGap == .subcategory { gapMark(.subcategory) }
        }
      }
      if !model.categorySuggestions.isEmpty {
        fieldRow(nil) { suggestionChips }
      }
    }
  }

  /// What the line did not say, beside the picker Enter asks for: a symbol and words, never the
  /// colour alone.
  private func gapMark(_ gap: EntryGap) -> some View {
    Label {
      Text(verbatim: EntryLineMessage.mark(gap, environment))
    } icon: {
      Image(systemName: "exclamationmark.circle")
    }
    .appFont(.caption)
    .foregroundStyle(.tint)
    .fixedSize()
    .accessibilityIdentifier("entry.gap.mark")
  }

  @ViewBuilder
  private var qualityRow: some View {
    if model.hasQuality && model.has(.quality) {
      fieldRow("entry.quality", alone: true) {
        // A menu like every other field: chosen by a click, and from the keyboard with Space,
        // the arrows and Return — a segmented control took Return for nothing.
        qualityMenu(for: partBinding(0))
          .focused($focus, equals: .quality)
      }
    }
  }

  @ViewBuilder
  private var forWhomRow: some View {
    if model.has(.fromPerson) {
      // Money back names the person it came from, and nothing else about them.
      fieldRow("entry.fromWhom") {
        referencePicker(
          selection: partBinding(0).forPersonId,
          options: model.people.map { ($0.id, $0.name) }, adding: .person(part: 0)
        )
        .focused($focus, equals: .forPerson)
      }
    } else if model.has(.forWhom) && !forWhomIsSaidByPayingFor {
      fieldRow(forWhomKey) {
        forWhomPicker(forPartAt: 0, focusing: true)
      }
    }
  }

  /// «За кого» above already names the people when the expense is paid for somebody: a second
  /// «На кого» under it would say the same thing twice. For «Себе» it stays, to tell which of
  /// my own groups the money went to.
  private var forWhomIsSaidByPayingFor: Bool {
    model.offersPayingFor && model.shownPayingForWay != .me
  }

  @ViewBuilder
  private var placeRow: some View {
    if model.has(.place) {
      fieldRow("entry.place") {
        // Through the model, like a place the line names: it brings its category and its
        // payment method. A place not been to yet is added from the menu, and the name the
        // line could not match is where its sheet starts. A place archived since is shown only
        // for the operation already at it.
        referencePicker(
          selection: Binding(
            get: { model.draft.placeId },
            set: { model.setPlace($0, today: environment.today) }),
          options: model.placeChoices.map { choice in
            (
              choice.id,
              choice.archived ? environment.format("common.archivedName", choice.name) : choice.name
            )
          },
          adding: .place
        )
        .focused($focus, equals: .place)
      }
    }
  }

  @ViewBuilder
  private var eventRow: some View {
    if model.has(.event) {
      fieldRow("entry.event") {
        beside {
          referencePicker(
            selection: partBinding(0).eventId,
            options: model.events.map { ($0.id, $0.name) }, adding: .event(part: 0)
          )
          .focused($focus, equals: .event)
          if let suggested = model.suggestedEvent, model.draft.parts.first?.eventId == nil {
            Button {
              model.draft.parts[0].eventId = suggested.id
            } label: {
              Label {
                Text(verbatim: suggested.name)
              } icon: {
                Image(systemName: "calendar.badge.plus")
              }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(t("entry.eventSuggested"))
          }
        }
      }
    }
  }

  @ViewBuilder
  private var accountRows: some View {
    // «Со счёта» for spending, «На счёт» for money that comes in, «Счёт» for a goal.
    fieldRow(model.accountFieldKey, alone: true) {
      // An account chosen here is the owner's: no place chosen after it replaces it. The
      // main account first, the rest in the owner's order, each followed by its live cards
      // («Т-Банк · Black»): a card brings its account, an account picked names no card. No
      // «none»: an operation that names no account is on the main one, and the picker says so.
      // Only a database with no account yet shows «—», with «Add…» to make one.
      referencePicker(
        selection: Binding(
          get: { model.accountOrCardSelection }, set: { model.setAccountOrCard($0) }),
        options: model.accountCardChoices(locale: environment.language.locale).map { choice in
          (
            choice.id,
            choice.archived ? environment.format("common.archivedName", choice.name) : choice.name
          )
        },
        adding: .paymentMethod, offersNone: model.selectedAccount == nil
      )
      .focused($focus, equals: .account)
      .disabled(moneyLocked)
      .accessibilityIdentifier("entry.account")
    }
    // «Карта · Счёт»: a purchase is made with a card — the one the line named, the one of the
    // place, the main card of the account —, unless it is said to leave the account itself.
    if model.offersCardOrAccount {
      fieldRow(nil) {
        Picker(
          selection: Binding(
            get: { model.paysWithCard }, set: { model.setPaysFromAccount(!$0) })
        ) {
          Text(verbatim: t("entry.payWith.card")).tag(true)
          Text(verbatim: t("entry.payWith.account")).tag(false)
        } label: {
          EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .help(t("entry.payWith.help"))
        .disabled(moneyLocked)
        .accessibilityIdentifier("entry.payWith")
      }
    }
    if model.needsCharge {
      fieldRow("entry.accountCharge", alone: true) {
        AccountChargeField(model: model, stacked: true)
          .focused($focus, equals: .charge)
          .disabled(moneyLocked)
      }
    }
  }

  /// «Кэшбэк» of a purchase that moves money on its account: what its rules expect, or a figure
  /// or a percent typed for this operation alone. «Запомнить» writes a typed percent as a rule
  /// of the card at once — a step of ⌘Z of its own. An empty or unreadable field never stops
  /// the save.
  @ViewBuilder
  private var cashbackRow: some View {
    if model.showsCashback {
      fieldRow("entry.cashback", alone: true) {
        CashbackField(
          state: $model.cashbackField, draft: model.draft,
          expectation: model.cashbackExpectation, context: model.cashbackContext,
          leading: true,
          remember: { rule in
            model.rememberCashback(rule) {
              CardActions(environment: environment, store: store).remember($0)
            }
          }
        )
        .focused($focus, equals: .cashback)
      }
    }
  }

  /// The goal row: for a part that goes to a goal («цель — если выбрана категория Goals»).
  private var showsGoal: Bool {
    model.has(.goal) && model.isGoalContribution(model.part(at: 0))
  }

  @ViewBuilder
  private var goalRow: some View {
    if showsGoal {
      fieldRow("entry.goal") {
        referencePicker(
          selection: Binding(
            get: { model.part(at: 0).goalId },
            set: {
              model.setGoal($0, forPartAt: 0)
              model.applyDefaults(today: environment.today)
            }),
          options: model.goals.map { ($0.id, $0.name) }
        )
        .focused($focus, equals: .goal)
      }
    }
  }

  /// The debt row: a purchase may pay one, and any operation keeps the debt it pays.
  private var showsDebt: Bool {
    model.has(.debt) && (model.draft.kind == .expense || model.draft.debtId != nil)
  }

  @ViewBuilder
  private var debtRow: some View {
    if showsDebt {
      fieldRow("entry.debt") {
        // A debt closed or deleted since stays in the menu of the payment that names it, and
        // says so; the payment keeps it unless another is picked. The difference of a count pays
        // no debt: its amount follows every recount, and a debt's balance would follow it.
        referencePicker(
          selection: $model.draft.debtId,
          options: model.debtChoices.map { choice in
            switch choice.state {
            case .open: (choice.id, choice.name)
            case .closed:
              (
                choice.id,
                environment.language.format("entry.debt.closed", table: "Entry", choice.name)
              )
            case .deleted:
              (
                choice.id,
                environment.language.format("entry.debt.gone", table: "Entry", choice.name)
              )
            }
          }
        )
        .focused($focus, equals: .debt)
        .disabled(moneyLocked)
        .accessibilityIdentifier("entry.debt")
      }
      // Money that comes onto a debt owed to me is the debt paid back, not income.
      if model.incomeIsMoneyBack {
        fieldRow(nil) {
          caption("entry.debt.moneyBack")
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("entry.debt.moneyBack")
        }
      }
    }
  }

  private var noteRow: some View {
    fieldRow("entry.note", alone: true) {
      // Several lines: ⌥Return starts a new one, Return saves as in every field.
      TextField(text: Binding($model.draft.note, replacingNilWith: ""), axis: .vertical) {
        Text(verbatim: t("entry.note"))
      }
      .lineLimit(1...6)
      .labelsHidden()
      .focused($focus, equals: .note)
      .help(t("entry.note.lines"))
    }
  }

  /// «Разовое»: the operation stays in the totals and the limits, and is left out of the
  /// averages and forecasts. Only an expense can be marked; a split says the mark is of the whole
  /// receipt.
  @ViewBuilder
  private var oneOffRow: some View {
    if model.draft.kind == .expense {
      fieldRow(nil, alone: true) {
        VStack(alignment: .leading, spacing: 2) {
          Toggle(isOn: $model.draft.isOneOff) {
            Text(verbatim: SpendingText.t("spending.oneOff", environment))
          }
          .accessibilityIdentifier("entry.oneOff")
          Text(verbatim: SpendingText.t("spending.oneOff.hint", environment))
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if model.isSplit {
            Text(verbatim: SpendingText.t("spending.oneOff.splitHint", environment))
              .appFont(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("entry.oneOff.splitHint")
          }
        }
      }
    }
  }

  private var dateRow: some View {
    fieldRow("entry.date") {
      // A new day offers the event covering it instead of the old day's.
      DatePicker(
        selection: Binding(
          get: { model.draft.occurredAt },
          set: { model.setDate($0, today: environment.today) }),
        displayedComponents: [.date, .hourAndMinute]
      ) {
        Text(verbatim: t("entry.date"))
      }
      .labelsHidden()
      .environment(\.locale, environment.language.locale)
      .focused($focus, equals: .date)
      .disabled(moneyLocked)
    }
  }

  @ViewBuilder
  private var incomeMonthRows: some View {
    if model.draft.kind == .income {
      fieldRow("entry.periodMonth") {
        periodMonthPicker
          .focused($focus, equals: .incomeMonth)
      }
      // Cashback the bank pays by a day of the next month is the month before's: said in words,
      // so the month the picker shows is not taken for a slip.
      if model.periodMonthIsCashbackOfTheMonthBefore {
        fieldRow(nil) {
          Text(
            verbatim: environment.language.format(
              "entry.periodMonth.cashback", table: "Entry",
              environment.dates.monthTitle(model.shownPeriodMonth))
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("entry.periodMonth.cashback")
        }
      }
      if !openExpectations.isEmpty {
        fieldRow("entry.expected") {
          if model.linksExpectedIncome {
            // Two of one name are told apart by amount and date.
            let titles = ExpectedIncomeLabels.titles(openExpectations, environment)
            Picker(selection: $model.expectedIncomeId) {
              Text(verbatim: "—").tag(UUID?.none)
              ForEach(openExpectations) { status in
                Text(verbatim: titles[status.id] ?? status.income.name).tag(Optional(status.id))
              }
            } label: {
              EmptyView()
            }
            .labelsHidden()
            .focused($focus, equals: .expected)
          } else {
            // The editor writes no link: a saved income is tied in Planning.
            caption("entry.expectedInPlanning")
          }
        }
      }
    }
  }

  @ViewBuilder
  private var currencyRows: some View {
    fieldRow("entry.currency") {
      currencyPicker
        .focused($focus, equals: .currency)
    }
    if model.draft.currency != .rub {
      fieldRow("entry.rate") {
        rateField
          .focused($focus, equals: .rate)
      }
    }
  }

  private var suggestionChips: some View {
    buttonRow(spacing: 6).callAsFunction {
      ForEach(model.categorySuggestions, id: \.id) { category in
        // History remembers the most specific category, so a chip fills both pickers and
        // shows the whole path — otherwise two chips could read the same.
        Button(title(for: category)) {
          model.applySuggestion(category)
          model.applyDefaults(today: environment.today)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }

  // MARK: Split, paid for someone, on credit

  private var splitEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Two lines per part, not one. A part carries everything an operation does («У
      // каждой части свои категория, подкатегория, оценка, сумма (тоже выражением), «для
      // кого», событие и признак «за другого»»), and all of it in one row came to about 790 pt
      // against a panel of 720 — the «−» would have fallen off the right edge, and in the
      // inspector, which is 360 pt wide, most of the row with it.
      ForEach(Array(model.draft.parts.enumerated()), id: \.element.id) { index, part in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 10) {
            // Stacked rather than side by side: a split row has to fit the panel as well.
            if model.has(.category) {
              VStack(alignment: .leading, spacing: 4) {
                categoryPicker(forPartAt: index)
                subcategoryPicker(forPartAt: index)
              }
              .frame(maxWidth: .infinity)
            }
            // Each part has a quality of its own, so it sits next to the amount.
            VStack(alignment: .leading, spacing: 4) {
              AmountField(amount: partBinding(index).amount)
                .frame(width: 104)
                .disabled(model.isClosedPart(id: part.id))
              if model.hasQuality {
                qualityMenu(for: partBinding(index))
              }
            }
            Spacer(minLength: 0)
            Button {
              model.removePart(id: part.id)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            // A part someone gave the money back for stays.
            .disabled(!model.canRemovePart(id: part.id))
          }
          // The second line: «для кого» with its person, the event, and «за другого» with the
          // debtor. Until 21.09 the first two were offered for part one only, and the only way
          // to set them on part two was the bulk menu of the table. One line in the panel;
          // in the inspector, 360 pt, it did not fit — about 400 pt in English — and the column
          // showed the middle of the whole editor, «mount» and «ategory» cut at the left
          // (24.09, `testTheEditorFitsTheInspectorBesideTheSidebar`), so there the three groups
          // go one under another.
          // Income has none of the three: its parts are an amount and a category.
          if model.has(.forWhom) || model.has(.event) || model.has(.reimbursable) {
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 10) {
                partForWhom(index)
                partEvent(index)
                partPaidForSomeone(index, part)
                Spacer(minLength: 0)
              }
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) { partForWhom(index) }
                HStack(spacing: 10) { partEvent(index) }
                HStack(spacing: 10) { partPaidForSomeone(index, part) }
              }
            }
            .appFont(.caption)
          }
          if model.isClosedPart(id: part.id) {
            closedPartCaption
          }
          if index < model.draft.parts.count - 1 { Divider() }
        }
      }
      HStack {
        Text(verbatim: t("entry.unallocated"))
          .foregroundStyle(model.draft.isBalanced ? Color.secondary : Color.red)
        Text(
          verbatim: environment.money.exact(model.draft.unallocated, currency: model.draft.currency)
        )
        .appFont(.body.monospacedDigit())
        .foregroundStyle(model.draft.isBalanced ? Color.secondary : Color.red)
      }
      .appFont(.caption)
    }
  }

  @ViewBuilder
  private func partForWhom(_ index: Int) -> some View {
    if model.has(.forWhom) {
      partLabel(forWhomKey)
      forWhomPicker(forPartAt: index)
    }
  }

  @ViewBuilder
  private func partEvent(_ index: Int) -> some View {
    if model.has(.event) {
      partEventPicker(index)
    }
  }

  @ViewBuilder
  private func partEventPicker(_ index: Int) -> some View {
    partLabel("entry.event")
    referencePicker(
      selection: partBinding(index).eventId,
      options: model.events.map { ($0.id, $0.name) }, adding: .event(part: index)
    )
    .frame(maxWidth: 140)
  }

  @ViewBuilder
  private func partPaidForSomeone(_ index: Int, _ part: PartDraft) -> some View {
    if model.has(.reimbursable) {
      partPaidForSomeonePicker(index, part)
    }
  }

  @ViewBuilder
  private func partPaidForSomeonePicker(_ index: Int, _ part: PartDraft) -> some View {
    Toggle(isOn: partBinding(index).reimbursable) {
      Text(verbatim: t("entry.paidForSomeone"))
    }
    .toggleStyle(.checkbox)
    // Its money came back: the part stays paid for them.
    .disabled(model.isClosedPart(id: part.id))
    if part.reimbursable {
      // Who pays it back is added from the menu, like the person of «для кого».
      referencePicker(
        selection: partBinding(index).debtorPersonId,
        options: model.people.map { ($0.id, $0.name) }, adding: .debtor(part: index)
      )
      .frame(maxWidth: 140)
      .disabled(model.isClosedPart(id: part.id))
    }
  }

  /// The foot of the ↓ panel: the keys that save and close, and «Записать» in the theme's accent.
  private var saveRow: some View {
    HStack(spacing: 12) {
      Text(verbatim: t("entry.panel.hint"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      Button {
        submit?()
      } label: {
        Text(verbatim: t("entry.save"))
          .fontWeight(.semibold)
          .padding(.horizontal, 14)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .controlSize(.large)
      .tint(surfaces.accent)
      .accessibilityIdentifier("entry.panel.save")
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 12) {
      // The column is too narrow for the four in a line: there they wrap.
      buttonRow(spacing: 8).callAsFunction {
        // A refund of a purchase takes back one amount of one part: it is neither split nor
        // paid for somebody else.
        if model.canSplit {
          Button(t("entry.split")) {
            model.addPart()
          }
          .buttonStyle(.bordered)
        }

        if model.canMarkPaidForSomeone && !model.offersPayingFor {
          Button(t("entry.paidForSomeone")) {
            model.markLastPartPaidForSomeone()
          }
          .buttonStyle(.bordered)
        }

        // In the editor the box only says what the purchase is: a saved purchase is put on
        // credit or taken off it in Debts, never by a plan the editor would not write. A plain
        // one does not show it at all, and neither does an income or a refund: only a purchase
        // is bought on credit.
        if model.offersCredit || model.isOnCredit {
          Toggle(isOn: onCreditBinding) {
            Text(verbatim: t("entry.onCredit"))
          }
          .toggleStyle(.checkbox)
          .disabled(!model.canChangeCredit)
        }

        if offersTransfer {
          Button(t("entry.transfer")) { chooseKind(.transfer) }
            .buttonStyle(.bordered)
            .help(t("entry.transfer.help"))
            .accessibilityIdentifier("entry.transfer")
        }

      }

      if !model.canChangeCredit && model.isOnCredit {
        caption("entry.creditInDebts")
      }

      if showsSave { saveRow }

      // A payment smaller than the due of its debt may say that no more comes this month.
      if offersClosingTerm {
        Toggle(isOn: $model.closesDebtTerm) {
          Text(verbatim: t("entry.closesTerm"))
            .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
        .help(t("entry.closesTerm.help"))
        .accessibilityIdentifier("entry.closesTerm")
      }

      if model.creditPlan != nil {
        creditFields
      }
    }
    // The box goes with the offer: a payment made whole, or another debt, says nothing.
    .onChange(of: offersClosingTerm) { _, offered in
      if !offered { model.closesDebtTerm = false }
    }
  }

  /// The state of the dues of the debt the operation pays, as the planning last worked them out.
  private var duesOfTheDebtPaid: DebtDueState? {
    guard let id = model.debtBeingPaid?.id else { return nil }
    return compute.snapshot?.planning.debts.iOwe.first { $0.debt.id == id }?.dues
  }

  private var offersClosingTerm: Bool { model.offersClosingTerm(dues: duesOfTheDebtPaid) }

  /// Which debt the purchase joins — an existing one or a new one — and how it is repaid.
  @ViewBuilder
  private var creditFields: some View {
    let plan = Binding(
      get: { model.creditPlan ?? EntryDraftModel.CreditPlan() },
      set: { model.creditPlan = $0 })

    fields {
      fieldRow("entry.debt") {
        Picker(selection: plan.debtId) {
          Text(verbatim: t("entry.newDebt")).tag(UUID?.none)
          ForEach(model.debts, id: \.id) { debt in
            Text(verbatim: debt.name).tag(UUID?.some(debt.id))
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
      }
      // A new debt may be an instalment plan: equal parts, the first today, a markup on top.
      if plan.wrappedValue.debtId == nil {
        fieldRow(nil) {
          Toggle(
            isOn: Binding(
              get: { plan.wrappedValue.instalments }, set: { model.setInstalments($0) })
          ) {
            Text(verbatim: t("entry.instalments"))
          }
          .toggleStyle(.checkbox)
          .accessibilityIdentifier("entry.instalments")
        }
      }
      if plan.wrappedValue.debtId == nil, plan.wrappedValue.instalments {
        instalmentFields(plan.wrappedValue)
      }
      // The count and the instalment move together, and only a new debt takes them: an
      // existing one keeps its own payment.
      if plan.wrappedValue.debtId == nil, !plan.wrappedValue.instalments {
        fieldRow("entry.payments") {
          Stepper(
            value: Binding(
              get: { plan.wrappedValue.payments }, set: { model.setCreditPayments($0) }),
            in: EntryDraftModel.creditPaymentsRange
          ) {
            Text(verbatim: "\(plan.wrappedValue.payments)")
              .appFont(.body.monospacedDigit())
          }
          .fixedSize()
        }
        fieldRow("entry.monthlyPayment") {
          AmountField(
            amount: Binding(
              get: { plan.wrappedValue.monthlyAmount }, set: { model.setCreditMonthly($0) })
          )
          .frame(width: gridWidth(120))
        }
      }
    }
  }

  /// The parts of an instalment plan: how many, how often, the markup, and what one part is.
  @ViewBuilder
  private func instalmentFields(_ plan: EntryDraftModel.CreditPlan) -> some View {
    fieldRow("entry.instalments.parts") {
      Stepper(
        value: Binding(get: { plan.payments }, set: { model.setCreditPayments($0) }),
        in: EntryDraftModel.instalmentPartsRange
      ) {
        Text(verbatim: "\(plan.payments)")
          .appFont(.body.monospacedDigit())
      }
      .fixedSize()
      .accessibilityIdentifier("entry.instalments.parts")
    }
    fieldRow("entry.instalments.step") {
      Picker(
        selection: Binding(get: { plan.everyDays }, set: { model.setInstalmentStep($0) })
      ) {
        Text(verbatim: t("entry.instalments.step.week")).tag(Int?.some(7))
        Text(verbatim: t("entry.instalments.step.twoWeeks")).tag(Int?.some(14))
        Text(verbatim: t("entry.instalments.step.month")).tag(Int?.none)
        if let days = plan.everyDays, ![7, 14].contains(days) {
          Text(
            verbatim: environment.language.format(
              "entry.instalments.step.days", table: "Entry", days)
          )
          .tag(Int?.some(days))
        }
      } label: {
        EmptyView()
      }
      .labelsHidden()
      .fixedSize()
      .accessibilityIdentifier("entry.instalments.step")
    }
    fieldRow("entry.instalments.markup") {
      AmountField(
        amount: Binding(get: { plan.markup }, set: { model.setInstalmentMarkup($0) })
      )
      .frame(width: gridWidth(120))
      .accessibilityIdentifier("entry.instalments.markup")
    }
    fieldRow(nil) {
      Text(
        verbatim: environment.language.format(
          plan.everyDays == nil ? "entry.instalments.summary.month" : "entry.instalments.summary",
          table: "Entry",
          environment.money.exact(plan.monthlyAmount, currency: model.draft.currency))
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("entry.instalments.summary")
    }
  }

  // MARK: Pieces

  /// `marked`: the field Enter asks for — its name stands out.
  private func fieldLabel(_ key: String, marked: Bool = false) -> some View {
    Text(verbatim: t(key))
      .appFont(.caption)
      .fontWeight(marked ? .semibold : .regular)
      .foregroundStyle(marked ? Color.primary : Color.secondary)
  }

  /// The category of a part. Choosing one drops whatever subcategory was under the
  /// previous category, so the pair can never end up mismatched.
  private func categoryPicker(forPartAt index: Int) -> some View {
    // The source is set inside the binding rather than in `onChange`: only a choice made
    // here is `manual`, while a category that history or a template filled in keeps its
    // own source.
    let selection = Binding<UUID?>(
      get: { model.categoryOfPart(model.part(at: index)) },
      set: { newValue in
        model.setCategory(newValue, forPartAt: index)
        model.applyDefaults(today: environment.today)
      })

    return Picker(selection: addingSelection(selection, .category(part: index))) {
      Text(verbatim: "—").tag(UUID?.none)
      ForEach(model.categoryOptions(forPartAt: index), id: \.id) { category in
        Text(verbatim: optionTitle(category)).tag(UUID?.some(category.id))
      }
      addItem
    } label: {
      Text(verbatim: t("entry.category"))
    }
    .labelsHidden()
    .accessibilityIdentifier("entry.category")
  }

  /// The subcategory of a part: only children of the chosen category, plus the dash, which
  /// leaves the operation on the category itself. «Add…» files a new one under that category
  /// — only one of the owner's (`canAddSubcategory`) — so the menu is off only when there is
  /// neither a child to choose nor a category to add one under.
  private func subcategoryPicker(forPartAt index: Int) -> some View {
    let children = model.subcategoryOptions(forPartAt: index)
    let canAdd = model.canAddSubcategory(forPartAt: index)
    let selection = Binding<UUID?>(
      get: { model.subcategoryOfPart(model.part(at: index)) },
      set: { newValue in
        model.setSubcategory(newValue, forPartAt: index)
        model.applyDefaults(today: environment.today)
      })

    return Picker(
      selection: canAdd ? addingSelection(selection, .subcategory(part: index)) : selection
    ) {
      Text(verbatim: "—").tag(UUID?.none)
      ForEach(children, id: \.id) { category in
        Text(verbatim: optionTitle(category)).tag(UUID?.some(category.id))
      }
      if canAdd { addItem }
    } label: {
      Text(verbatim: t("entry.subcategory"))
    }
    .labelsHidden()
    .disabled(children.isEmpty && !canAdd)
  }

  /// The quality as a menu — of the first part and of every part of a split. Every value
  /// carries its symbol and its name, never a colour alone.
  private func qualityMenu(for part: Binding<PartDraft>) -> some View {
    Picker(selection: qualitySelection(for: part)) {
      ForEach(Quality.allCases, id: \.self) { quality in
        Label {
          Text(verbatim: environment.language(Palette.qualityKey(quality)))
        } icon: {
          Image(systemName: Palette.qualitySymbol(quality))
        }
        .tag(Quality?.some(quality))
      }
    } label: {
      Text(verbatim: t("entry.quality"))
    }
    .pickerStyle(.menu)
    .labelsHidden()
    // As wide as the column in the form; in the grid and in a part of a split, as its value.
    .help(t("entry.quality"))
    .disabled(!model.canRateByHand(part.wrappedValue))
  }

  /// Same reasoning as the category picker: only a choice made here is `manual`, and a
  /// contribution to a goal cannot be re-rated at all.
  private func qualitySelection(for part: Binding<PartDraft>) -> Binding<Quality?> {
    Binding(
      get: { part.wrappedValue.quality },
      set: { newValue in
        part.wrappedValue.quality = newValue
        part.wrappedValue.qualitySource = .manual
      })
  }

  /// `focusing`: the pickers of the first part, which Tab reaches as fields of the panel.
  private func forWhomPicker(forPartAt index: Int, focusing: Bool = false) -> some View {
    let part = partBinding(index)
    return Picker(selection: forWhomChoice(for: part, at: index)) {
      ForEach(ForWhom.allCases, id: \.self) { value in
        Text(verbatim: environment.label(for: value)).tag(ForWhomChoice.group(value))
      }
      let people = model.people
      if !people.isEmpty {
        Divider()
        ForEach(people, id: \.id) { person in
          Text(verbatim: person.name).tag(ForWhomChoice.person(person.id))
        }
      }
      Divider()
      Text(verbatim: t("entry.add")).tag(ForWhomChoice.add)
    } label: {
      Text(verbatim: t("entry.forWhom"))
    }
    .labelsHidden()
    .modifier(PanelFocused(focus: $focus, control: focusing ? .forWhom : nil))
  }

  /// One menu for «На кого»: my own groups first, then the people of the dictionary, then
  /// «Add…». A person set on the part beats the group everywhere the app renders it
  /// (`TransactionRows`), so choosing a group lets the person go and choosing a person
  /// stands the part as «Другое» (`PayingForRules.reading`).
  private enum ForWhomChoice: Hashable {
    case group(ForWhom)
    case person(UUID)
    case add
  }

  private func forWhomChoice(for part: Binding<PartDraft>, at index: Int) -> Binding<ForWhomChoice>
  {
    Binding(
      get: {
        if let id = part.wrappedValue.forPersonId { return .person(id) }
        return .group(part.wrappedValue.forWhom)
      },
      set: { choice in
        switch choice {
        case .group(let value):
          guard value != part.wrappedValue.forWhom || part.wrappedValue.forPersonId != nil
          else { return }
          part.wrappedValue.forWhom = value
          part.wrappedValue.forPersonId = nil
        case .person(let id):
          part.wrappedValue.forWhom = .other
          part.wrappedValue.forPersonId = id
        case .add:
          model.adding = .person(part: index)
        }
      })
  }

  /// A short caption beside a control of a split row: the field grid has a label column and
  /// a row of the split editor does not, and a disabled empty picker with nothing beside it
  /// is indistinguishable from a broken one.
  private func partLabel(_ key: String) -> some View {
    Text(verbatim: t(key))
      .foregroundStyle(.secondary)
      .fixedSize()
  }

  /// A menu of a dictionary. Given `adding`, «Add…» ends it and opens the sheet of that kind,
  /// and the menu is never off for want of rows: «Add…» is always there to choose. The goal and
  /// the debt have no «Add…» and are off while there is nothing to choose.
  /// `offersNone` false leaves out «—»: the account, which every operation has once there is
  /// one.
  private func referencePicker(
    selection: Binding<UUID?>, options: [(UUID, String)], adding kind: AddFromPicker.Kind? = nil,
    offersNone: Bool = true
  ) -> some View {
    Picker(selection: kind.map { addingSelection(selection, $0) } ?? selection) {
      if offersNone {
        Text(verbatim: "—").tag(UUID?.none)
      }
      ForEach(options, id: \.0) { option in
        Text(verbatim: option.1).tag(UUID?.some(option.0))
      }
      if kind != nil { addItem }
    } label: {
      EmptyView()
    }
    .labelsHidden()
    .disabled(kind == nil && options.isEmpty)
  }

  /// The last item of a menu of a dictionary, after a line.
  @ViewBuilder
  private var addItem: some View {
    Divider()
    Text(verbatim: t("entry.add")).tag(UUID?.some(AddFromPicker.tag))
  }

  /// The choice of a menu that ends with «Add…»: that item opens the sheet of `kind` and
  /// leaves the choice as it was.
  private func addingSelection(
    _ selection: Binding<UUID?>, _ kind: AddFromPicker.Kind
  ) -> Binding<UUID?> {
    AddFromPicker.selection(selection) { model.adding = kind }
  }

  /// Expectations not fulfilled yet, from the planning the pipeline counted.
  private var openExpectations: [ExpectedIncomeStatus] {
    (compute.snapshot?.planning.expected ?? []).filter { !$0.isFulfilled && !$0.income.closed }
  }

  /// Income says which month it is for; by default that is the month of its date.
  private var periodMonthPicker: some View {
    Picker(
      selection: Binding(
        get: { model.shownPeriodMonth },
        set: { model.choosePeriodMonth($0) })
    ) {
      ForEach(model.periodMonthOptions, id: \.iso) { month in
        Text(verbatim: month.iso).tag(month)
      }
    } label: {
      EmptyView()
    }
    .labelsHidden()
  }

  /// The amount «Хватит ли?» starts with, in rubles, while the panel holds a new expense above
  /// the threshold; `nil` otherwise (and when the rate of the currency is unknown).
  private var affordLinkAmount: AmountE4? {
    guard !model.editsSavedOperation,
      AffordModel.offersEntryLink(
        isExpense: model.draft.kind == .expense, amount: model.draft.amount,
        currency: model.draft.currency, defaultCurrency: environment.defaultCurrency)
    else { return nil }
    return AffordModel.rubles(
      of: model.draft.amount, currency: model.draft.currency,
      rubPerUnit: compute.snapshot?.planning.rubPerUnit ?? [:])
  }

  /// The tax of the income being entered, as the panel shows it; `nil` when there is none.
  private var taxEstimateText: String? {
    guard model.draft.kind == .income, let snapshot = compute.snapshot,
      let tax = model.taxEstimate(
        settings: snapshot.dataset.selfEmployment, dayRates: snapshot.context.dayRates,
        deductionLeft: snapshot.planning.npd?.deductionLeftE4)
    else { return nil }
    return Self.taxText(tax.taxE4, rate: tax.rate, environment: environment)
  }

  /// «налог ≈ 240 ₽ (4 %)»: the rate with as many digits as it has, up to two.
  static func taxText(_ tax: AmountE4, rate: Decimal, environment: AppEnvironment) -> String {
    let digits =
      DecimalMath.round(rate, scale: 0) == rate
      ? 0
      : DecimalMath.round(rate, scale: 1) == rate
        ? 1 : 2
    let basisPoints = NSDecimalNumber(decimal: DecimalMath.round(rate * 100, scale: 0)).intValue
    return environment.language.format(
      "entry.tax.estimate", table: "Entry", environment.money.exact(tax, currency: .rub),
      environment.money.percent(basisPoints: basisPoints, fractionDigits: digits))
  }

  /// The currencies the picker offers: the enabled ones of the bank, then the owner's own, and the
  /// operation's own currency should it be neither.
  private var currencyChoices: [CurrencyCode] {
    let catalog = environment.currencyCatalog
    var choices = catalog.choices(enabled: environment.vocabulary.enabledCurrencies)
    if !choices.contains(model.draft.currency) { choices.append(model.draft.currency) }
    return choices
  }

  /// «ZZT · Звёзды» for a currency of the owner's own, the code for the bank's.
  private func currencyTitle(_ currency: CurrencyCode) -> String {
    let catalog = environment.currencyCatalog
    guard catalog.isCustom(currency),
      let name = catalog.name(currency, language: environment.language.locale.identifier)
    else { return currency.code }
    return "\(currency.code) · \(name)"
  }

  /// A currency picked here is the owner's: the account chosen after it does not replace it.
  private var currencyPicker: some View {
    Picker(
      selection: Binding(get: { model.draft.currency }, set: { model.setCurrency($0) })
    ) {
      ForEach(currencyChoices, id: \.code) { currency in
        Text(verbatim: currencyTitle(currency)).tag(currency)
      }
    } label: {
      EmptyView()
    }
    .labelsHidden()
    // A refund of a purchase is in the purchase's currency; a difference of a count in the
    // currency counted.
    .disabled(model.hasClosedPart || model.refundTarget != nil || moneyLocked)
  }

  /// The purchase a refund takes money back from: picked, «без покупки», or still to pick.
  private var refundPurchaseRow: some View {
    beside {
      if let target = model.refundTarget {
        Label {
          Text(verbatim: purchaseTitle(target))
        } icon: {
          Image(systemName: "arrow.uturn.left.circle")
        }
        .accessibilityIdentifier("entry.refund.purchase")
      } else if model.refundWithoutPurchase {
        Text(verbatim: t("entry.refund.none"))
          .foregroundStyle(.secondary)
      }
      Button(t(model.refundTarget == nil ? "entry.refund.pick" : "entry.refund.change")) {
        model.refundPicking = RefundPickerRequest(savesAfterChoice: false)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  /// «кроссовки · 12 September 2026 · 7,000.00 ₽».
  private func purchaseTitle(_ target: EntryDraftModel.RefundTarget) -> String {
    let transaction = target.purchase.transaction
    let day = environment.dates.longDay(environment.calendar.day(of: transaction.occurredAt))
    let amount = environment.money.exact(target.part.amountE4, currency: transaction.currency)
    return [target.part.note ?? transaction.note, day, amount].compactMap { $0 }
      .joined(separator: " · ")
  }

  /// Why the money of a part cannot be changed: someone gave it back.
  private var closedPartCaption: some View { caption("entry.closedPart") }

  /// Why a field cannot be changed here, or where it is changed instead.
  private func caption(_ key: String) -> some View {
    Text(verbatim: t(key))
      .appFont(.caption)
      .foregroundStyle(.secondary)
  }

  private var rateField: some View {
    HStack(spacing: 8) {
      RateField(model: model, title: t("entry.rate"), width: gridWidth(120))
        .labelsHidden()
        // A refund of a purchase is at the purchase's rate.
        .disabled(!model.canTypeRate || moneyLocked)
      if model.draft.rateSource == .manual {
        Text(verbatim: t("entry.rateManual"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Helpers

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }

  /// Money back names the person it came from; everything else, whom it was spent on.
  private var forWhomKey: String { Self.forWhomKey(of: model.draft.kind) }

  static func forWhomKey(of kind: TransactionKind) -> String {
    kind == .reimbursement ? "entry.fromWhom" : "entry.forWhom"
  }

  /// A retired category is only ever shown for what is already filed under it, and says so.
  private func optionTitle(_ category: CoreKit.Category) -> String {
    category.archived ? environment.format("common.archivedName", category.name) : category.name
  }

  private func title(for category: CoreKit.Category) -> String {
    guard let parentId = category.parentId,
      let parent = model.categories.first(where: { $0.id == parentId })
    else { return category.name }
    return "\(parent.name) › \(category.name)"
  }

  private var onCreditBinding: Binding<Bool> {
    Binding(
      get: { model.isOnCredit },
      set: { isOn in
        if isOn {
          model.startCreditPlan()
        } else {
          model.stopCreditPlan()
        }
      })
  }

  /// The total of the operation. A draft with a single part keeps that part in step, so
  /// correcting the amount of an ordinary operation just works; a split keeps its parts
  /// and shows what is left unallocated.
  private var totalBinding: Binding<AmountE4> {
    Binding(get: { model.draft.amount }, set: { model.setTotal($0) })
  }

  private func partBinding(_ index: Int) -> Binding<PartDraft> {
    Binding(
      get: { model.draft.parts.indices.contains(index) ? model.draft.parts[index] : PartDraft() },
      set: { newValue in
        guard model.draft.parts.indices.contains(index) else { return }
        model.draft.parts[index] = newValue
      })
  }
}

/// What an amount field tells of its text: every change the owner makes, once — never the text
/// it writes back itself when the owner is done with it. Told again, that amount would land a
/// second time: Enter writes «1500,5» back as «1,500.50» while the same Enter saves the form and
/// empties it for the next operation, and the echo would put 1,500.50 into the empty form.
@MainActor
struct AmountFieldEcho {
  private(set) var writtenBack: String?

  /// Enter, Tab or leaving the field: the text to write back — the amount written the one way
  /// the app writes amounts —, or nil when the text stays as it is.
  mutating func settle(_ text: String) -> String? {
    guard let settled = AmountField.settledText(text), settled != text else { return nil }
    writtenBack = settled
    return settled
  }

  /// Whether a change of the text is the owner's, to be told: not the text just written back.
  mutating func tells(_ text: String) -> Bool {
    let isWrittenBack = text == writtenBack
    writtenBack = nil
    return !isWrittenBack
  }
}

/// An amount that can be typed as an expression: "1500×3−2000" is evaluated as you type.
/// The field also follows the amount when something else changes it — splitting evenly,
/// for example — so what is shown is always what will be saved.
///
/// The text stays exactly as typed while the owner types: rewritten on every keystroke, it
/// would move under the cursor. Enter, Tab and leaving the field write it back the one way the
/// app writes amounts — «1500,5» becomes «1,500.50», a formula becomes what it comes to (the
/// total of an operation keeps the formula itself beside the field). What the field writes it
/// also reads back as the same amount: an equal split of 37 in eight is «4.625», never a text
/// that reads as 4 625.
///
/// Text that does not read — «1700+», «abc» — leaves the amount as it was. A form that must not
/// save that amount under such text passes `reads`: false while the text does not read.
struct AmountField: View {
  @Binding var amount: AmountE4
  /// Given, it is told every amount typed together with the text behind it, and writes the
  /// amount itself: the total of an operation keeps a formula typed in it (`amount_expr`).
  var onTyped: ((AmountE4, String) -> Void)?
  private var reads: Binding<Bool>?
  /// The amount of an operation, large as the design draws it: the number the form is about.
  private let prominent: Bool
  @State private var text: String = ""
  @State private var lastShown: AmountE4 = .zero
  /// The text the field has just written back itself: its amount was told when it was typed.
  @State private var echo = AmountFieldEcho()
  @FocusState private var isFocused: Bool

  /// `locale` is accepted and not needed: amounts are written the same way in every language.
  init(
    amount: Binding<AmountE4>, locale _: Locale? = nil, reads: Binding<Bool>? = nil,
    onTyped: ((AmountE4, String) -> Void)? = nil, prominent: Bool = false
  ) {
    self.prominent = prominent
    self._amount = amount
    self.reads = reads
    self.onTyped = onTyped
  }

  var body: some View {
    TextField(text: $text) {
      Text(verbatim: "0")
    }
    .labelsHidden()
    .appFont(prominent ? .title.monospacedDigit().bold() : .body.monospacedDigit())
    .focused($isFocused)
    .onAppear { show(amount) }
    .onChange(of: amount) { _, newValue in
      guard newValue != lastShown else { return }
      show(newValue)
    }
    .onChange(of: text) { _, newValue in
      guard echo.tells(newValue) else { return }
      let parsed = Self.amount(from: newValue)
      if let reads, reads.wrappedValue != (parsed != nil) { reads.wrappedValue = parsed != nil }
      guard let parsed else { return }
      lastShown = parsed
      if let onTyped { onTyped(parsed, newValue) } else { amount = parsed }
    }
    // Submit actions add up along the hierarchy: Enter still reaches the form around the field.
    .onSubmit { settle() }
    .onChange(of: isFocused) { _, focused in
      if !focused { settle() }
    }
  }

  /// What the text says: zero when it is empty — a field cleared by hand, not the last digit
  /// left in it (fourth review, 19.09) — the value of an expression that reads, and nothing
  /// while it is half typed, so the amount stays as it was.
  static func amount(from text: String) -> AmountE4? {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .zero }
    guard let value = try? ExpressionEvaluator.evaluate(text) else { return nil }
    return try? AmountE4(decimal: value)
  }

  /// The text once the owner is done with the field: the amount it reads as, written the way
  /// the app writes amounts. Nil leaves the text alone — nothing typed, or text that does not
  /// read yet and is left for the owner to finish.
  static func settledText(_ text: String) -> String? {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
      let value = amount(from: text)
    else { return nil }
    return Self.text(for: value)
  }

  private func settle() {
    guard let settled = echo.settle(text) else { return }
    text = settled
  }

  private func show(_ value: AmountE4) {
    lastShown = value
    text = Self.text(for: value)
  }

  /// What the field shows for an amount: nothing for zero, otherwise the amount the way the
  /// app writes amounts — «1,500.50», «4.625» — which reads back as the same amount.
  static func text(for value: AmountE4) -> String {
    value.isZero ? "" : FieldNumber.text(value)
  }
}

/// The rate typed by hand. The text stays as it is typed — «81,» is 81 half-typed, «81,40»
/// is 81.4 — and is rewritten only when the rate becomes one the text does not read: cleared,
/// or put there by something else, and once the owner is done with the field (Enter, Tab,
/// leaving it), when it is written back the way the app writes rates: «81,40» becomes «81.4».
/// Bound straight to the rate, the field showed every keystroke back as the number it made, so
/// the separator vanished under the cursor and «81,43» came out as 8143. `AmountField` keeps its
/// text the same way.
///
/// A rate keeps the rule of rates: a lone separator is the decimal one, «83,125» is 83.125. It
/// can be a formula, like an amount — «95,5/1,02», «(90+92)/2» (`RateText`) —: beside the field
/// stands what it comes to while the text is a formula, and Enter writes that rate in its place.
struct RateField: View {
  let model: EntryDraftModel
  let title: String
  /// The width of the text field itself — `nil` fills the row, as in the form column; what a
  /// formula comes to stands beside it.
  var width: CGFloat? = 120
  @State private var text = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      TextField(text: $text) {
        Text(verbatim: title)
      }
      .frame(width: width)
      .focused($isFocused)
      if let result = Self.formulaResult(text) {
        RateFormulaResult(rate: result)
      }
    }
    .onAppear { text = Self.text(afterTyping: text, rate: model.draft.rate) }
    // Half-typed text must not clear the rate and claim the owner chose it: that combination
    // is what converts a foreign amount one to one (see the model). Text that already reads as
    // the rate is the rate being shown, not typed: passed on, it would make a bank rate manual.
    .onChange(of: text) { _, typed in
      guard !Self.reads(typed, as: model.draft.rate) else { return }
      model.setManualRate(typed)
    }
    .onChange(of: model.draft.rate) { _, rate in
      text = Self.text(afterTyping: text, rate: rate)
    }
    .onSubmit { settle() }
    .onChange(of: isFocused) { _, focused in
      if !focused { settle() }
    }
  }

  /// What a formula in the field comes to, while it is one that reads; nil for a plain number,
  /// which says itself, and for a formula still being typed.
  static func formulaResult(_ text: String) -> Decimal? {
    RateTextField.formulaResult(text)
  }

  private func settle() {
    let settled = Self.settledText(text, rate: model.draft.rate)
    if settled != text { text = settled }
  }

  /// What the field shows once the model has taken `typed`: the text as typed while it reads
  /// as the rate, otherwise the rate itself.
  static func text(afterTyping typed: String, rate: Decimal?) -> String {
    reads(typed, as: rate) ? typed : (rate.map { FieldNumber.text($0) } ?? "")
  }

  /// The text once the owner is done with the field: the rate the way the app writes rates,
  /// or nothing for no rate. Text that does not read as the rate stays as it is.
  static func settledText(_ typed: String, rate: Decimal?) -> String {
    guard reads(typed, as: rate) else { return typed }
    return rate.map { FieldNumber.text($0) } ?? ""
  }

  /// Whether `text` says `rate`: the same number however it is typed, or nothing for no rate.
  static func reads(_ text: String, as rate: Decimal?) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard let rate else { return trimmed.isEmpty }
    return RateText.value(trimmed) == rate
  }
}

/// A number put into a text field for editing, written the one way the app writes numbers, in
/// every language, so that it reads back as the same number.
enum FieldNumber {
  /// An amount: thousands grouped by commas, a point before at least two decimals — «1,500.50»,
  /// «4.625», «250». Amounts typed by hand read a lone comma before three digits as thousands,
  /// so a fraction is never written with a comma.
  static func text(_ value: AmountE4) -> String {
    NumberText.amount(value, minus: "-")
  }

  /// A rate: every digit it has, a point, no grouping — «81.4321». Rates read a lone separator
  /// as the decimal one, so a comma between thousands would turn 1,234 into 1.234.
  static func text(_ value: Decimal) -> String {
    NumberText.plain(value)
  }
}

extension Binding<String> {
  /// Lets a `TextField` edit an optional note without inventing an empty string in the model.
  init(_ source: Binding<String?>, replacingNilWith placeholder: String) {
    self.init(
      get: { source.wrappedValue ?? placeholder },
      set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
  }
}

/// A control of the ↓ panel Tab reaches as a field: bound to the panel's focus when it has a
/// place in the order, left alone otherwise — a picker of the second part of a split.
private struct PanelFocused: ViewModifier {
  var focus: FocusState<PanelFocus?>.Binding
  let control: PanelFocus?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let control {
      content.focused(focus, equals: control)
    } else {
      content
    }
  }
}
