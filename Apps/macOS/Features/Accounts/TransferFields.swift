import AppCore
import SwiftUI

/// A transfer being filled in — in its own sheet, in the ↓ panel or in the form at the side of
/// the window — and the walk of its save, one for all three: what is wrong is said first; a
/// transfer dated on the day of a count of a balance it moves, saved after that count, asks
/// whether it happened before it (`TransferActions.countStep`); money an edit would leave on an
/// account in the archive is moved to a live one by a transfer asked for first
/// (`ArchivedMoneySheet`); and the write is one step of ⌘Z with the fee
/// (`TransferActions.save`). The dialogs of the walk are `transferQuestions(_:)`.
@MainActor
@Observable
final class TransferEntry {
  var form: TransferForm
  /// Started by «перевод …» typed in the entry line.
  var fromTheLine: Bool
  /// The books the menus and the balances are read from, and the save worked out against.
  var books: AccountBooks?
  /// Why the last save wrote nothing, said under the fields.
  var refusal: TransferRefusal?
  /// The database did not take the write.
  var failed = false
  /// «Это было до сверки в 14:05?», waiting for the owner's answer.
  var question: CountQuestion?
  /// A save is under way: a second one is not started.
  var isSaving = false
  /// «Больше не спрашивать для этой сверки», ticked for the question on screen.
  var dontAsk = false
  /// What the edit would leave on an archived account, waiting for where it goes.
  var leftovers: Leftovers?
  /// The category of fees a new fee would bring back from the archive.
  var feeComingBack: FeeCategoryComingBack?

  /// The fee the terms of a credit card laid into the form last; a fee the owner typed over it
  /// is his and stays.
  @ObservationIgnored private(set) var laidFee: AmountE4?
  /// The laid fee is the ATM fee of a card abroad, not the fee of a credit card.
  @ObservationIgnored private(set) var laidFeeIsAtm = false

  /// «Банкомат за границей», as the owner set it; `nil` — as it is by default: on while the trip
  /// mode is on (`tripIsOn`).
  var atmAbroad: Bool?
  /// The trip mode is on: the default of the switch above. Told by whoever shows or saves the
  /// transfer, from the environment.
  @ObservationIgnored var tripIsOn = false
  /// Rubles per unit of a currency (`nil` — no rate): for the fixed part of an ATM fee that is
  /// in another currency than the withdrawal.
  @ObservationIgnored var rubPerUnit: (CurrencyCode) -> Decimal? = { _ in nil }

  /// Whether the switch is on.
  var atmIsOn: Bool { atmAbroad ?? tripIsOn }

  /// The cards of the books, for the ATM terms of the account the money leaves.
  var cards: [PaymentCard] { books?.dataset.cards ?? [] }

  /// Whether the account the money leaves has a card with ATM terms: only then the switch is
  /// offered.
  func offersAtm(accounts: [PaymentMethod], cards: [PaymentCard]? = nil) -> Bool {
    guard form.previous == nil,
      let from = accounts.first(where: { $0.id == form.fromAccountId }),
      Self.receivesCash(form, accounts: accounts)
    else { return false }
    return TravelFees.atmCard(of: from, cards: cards ?? self.cards) != nil
  }

  /// Whether the money lands in cash: only a withdrawal costs the ATM fee, not a transfer between
  /// the owner's own accounts or a payment of a credit card.
  static func receivesCash(_ form: TransferForm, accounts: [PaymentMethod]) -> Bool {
    accounts.first(where: { $0.id == form.toAccountId })?.kind == .cash
  }

  /// The bank's fee for withdrawing abroad: the ATM terms of the card of the account the money
  /// leaves (`TravelFees`), in the currency it leaves in; `nil` when the transfer is not new, is
  /// from a credit card (its terms are 0389), does not land in cash, moves nothing, or has no
  /// card with terms.
  static func atmFee(
    for form: TransferForm, accounts: [PaymentMethod], cards: [PaymentCard],
    convert: ((Money, CurrencyCode) -> AmountE4?)?
  ) -> AmountE4? {
    guard form.previous == nil, form.sent.raw > 0, let currency = form.fromCurrency,
      let from = accounts.first(where: { $0.id == form.fromAccountId }), from.credit == nil,
      receivesCash(form, accounts: accounts),
      form.toAccountId != form.fromAccountId || form.toCurrency != form.fromCurrency
    else { return nil }
    return TravelFees.atmFee(
      forWithdrawing: Money(amount: form.sent, currency: currency), from: from, cards: cards,
      convert: convert)
  }

  /// The save under way: the actions it writes with and what is told once it wrote.
  @ObservationIgnored private var saving: (actions: TransferActions, written: () -> Void)?

  /// The money an edit would leave on an archived account, and the write it waits for.
  struct Leftovers: Identifiable {
    let check: ArchivedMoneyCheck
    let occurredAt: Date
    let books: AccountBooks
    let id = UUID()
  }

  /// «Это было до сверки в 14:05?», asked before the transfer is written.
  struct CountQuestion: Identifiable {
    let questions: CountQuestions
    let books: AccountBooks
    var count: Date { questions.count }
    var id: Date { count }
  }

  init(form: TransferForm, fromTheLine: Bool = false) {
    self.form = form
    self.fromTheLine = fromTheLine
  }

  /// The books and the category of fees, read when the fields appear.
  func load(_ actions: TransferActions) async {
    books = await actions.books()
    feeComingBack = actions.feeCategoryComingBack()
  }

  // MARK: The fee of a credit card

  /// The fee the terms of the credit card the money leaves take for it — cash and transfers
  /// from a credit card cost the percent and the fixed sum of its terms —, or `nil`: not from a
  /// credit card, not in its main currency, nothing sent, or terms without a fee. Only a new
  /// transfer is given one: it is laid into the field and written with the transfer as its fee
  /// (`transfer:<id>:fee` in «Комиссии», one step of ⌘Z), unless the owner changed or removed
  /// it first.
  static func creditFee(for form: TransferForm, accounts: [PaymentMethod]) -> AmountE4? {
    guard form.previous == nil, form.sent.raw > 0,
      let from = accounts.first(where: { $0.id == form.fromAccountId }),
      let terms = from.credit, form.fromCurrency == from.mainCurrency,
      form.toAccountId != form.fromAccountId || form.toCurrency != form.fromCurrency
    else { return nil }
    let fee = CreditInterest.cashFee(amount: form.sent, terms: terms)
    return fee.isZero ? nil : fee
  }

  /// Lays the fee of the credit card into the form as the amount or the accounts change: the
  /// field follows the terms while it is empty and nothing was laid yet, or still holds what
  /// they laid in last; a fee the owner typed stays as he typed it, and one he removed — the
  /// field emptied after a fee was laid — stays removed.
  func layCreditFee(accounts: [PaymentMethod], cards: [PaymentCard]? = nil) {
    let credit = Self.creditFee(for: form, accounts: accounts)
    // The terms of a credit card come first; the ATM fee abroad is for the other accounts.
    let atm =
      credit == nil && atmIsOn
      ? Self.atmFee(
        for: form, accounts: accounts, cards: cards ?? self.cards,
        convert: TravelFees.converter(rubles: rubPerUnit))
      : nil
    let suggestion = credit ?? atm
    laidFeeIsAtm = credit == nil && atm != nil
    let followsTheTerms =
      (form.fee.isZero && laidFee == nil) || laidFee.map { form.fee == $0 } == true
    if followsTheTerms, form.fee != (suggestion ?? .zero) {
      form.fee = suggestion ?? .zero
    }
    laidFee = suggestion
  }

  /// What the line under the fee says of the fee of the credit card: laid and to be written
  /// with the transfer, or removed by the owner; `nil` when there is none or he typed his own.
  enum CreditFeeState: Equatable {
    case laid(AmountE4)
    case removed(AmountE4)
  }

  var creditFeeState: CreditFeeState? {
    guard let laid = laidFee else { return nil }
    if form.fee == laid { return .laid(laid) }
    if form.fee.isZero { return .removed(laid) }
    return nil
  }

  /// «Убрать»: the fee of the credit card is not written.
  func removeCreditFee() {
    guard laidFee != nil else { return }
    form.fee = .zero
  }

  /// «Вернуть»: the fee of the credit card is written after all.
  func restoreCreditFee() {
    guard let laidFee else { return }
    form.fee = laidFee
  }

  /// The money leaves a credit card whose cash and transfers have no grace period.
  func leavesACardWithoutGrace(accounts: [PaymentMethod]) -> Bool {
    guard let from = accounts.first(where: { $0.id == form.fromAccountId }) else { return false }
    return from.credit?.cashWithoutGrace == true && form.fromCurrency == from.mainCurrency
  }

  /// Whether saving writes a fee that is not there yet — the one that looks for its category.
  /// An edit keeps the category of the fee it has.
  var writesANewFee: Bool {
    guard form.fee.raw > 0 else { return false }
    guard let previous = form.previous else { return true }
    guard let books else { return false }
    return TransferActions.fee(of: previous.id, in: books.dataset.entries) == nil
  }

  /// The ids of the accounts of the transfer being edited: they stay in the menus even when they
  /// went to the archive since, so the form shows what was written.
  var kept: Set<UUID> {
    Set([form.previous?.fromAccountId, form.previous?.toAccountId].compactMap { $0 })
  }

  // MARK: Saving

  /// Saves the transfer as the form holds it, asking what has to be asked on the way; `written`
  /// is told once it is in the database. A refusal stays in `refusal`, a failed write in
  /// `failed`, and nothing is written then.
  func save(_ actions: TransferActions, written: @escaping () -> Void) {
    guard !isSaving else { return }
    isSaving = true
    refusal = nil
    saving = (actions, written)
    Task {
      guard let books = await actions.books() else {
        failed = true
        isSaving = false
        return
      }
      self.books = books
      // A transfer written straight from the line never showed its fields: the fee of a credit
      // card — and the ATM fee abroad, while the trip mode is on — is laid here too, as the
      // fields would have laid it.
      tripIsOn = actions.environment.tripEntryDefaults != nil
      rubPerUnit = actions.environment.rubPerUnitReader(on: form.day)
      layCreditFee(accounts: books.dataset.paymentMethods)
      let now = actions.environment.now()
      let occurredAt = form.occurredAt(now: now, calendar: actions.environment.calendar)
      // What is wrong is said before anything is asked.
      if case .failure(let reason) = actions.change(
        for: form, occurredAt: occurredAt, books: books)
      {
        refusal = reason
        isSaving = false
        return
      }
      switch actions.countStep(for: form, occurredAt: occurredAt, books: books, now: now) {
      case .none:
        proceed(occurredAt: occurredAt, books: books)
      case .answered(let stamp):
        proceed(occurredAt: stamp, books: books)
      case .ask(let questions):
        question = CountQuestion(questions: questions, books: books)
      }
    }
  }

  /// The owner's answer to «Это было до сверки?»: the moment, or the next count of the day.
  func answer(_ question: CountQuestion, wasBefore: Bool) {
    guard let actions = saving?.actions else { return }
    let remember = dontAsk
    dontAsk = false
    switch actions.answer(question.questions, wasBefore: wasBefore, remember: remember) {
    case .stamp(let moment):
      proceed(occurredAt: moment, books: question.books)
    case .ask(let next):
      // The next count is asked as a dialog of its own, once this one has gone; meanwhile
      // nothing can be saved.
      isSaving = true
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(300))
        self.question = CountQuestion(questions: next, books: question.books)
        self.isSaving = true
      }
    }
  }

  /// The question went without an answer — Esc, «Отменить»: nothing is written, and the
  /// transfer can be saved again.
  func dismissQuestion() {
    question = nil
    isSaving = false
  }

  /// The live account the money left on an archived one goes to: written with the transfer.
  func settle(_ settling: [Transfer]) {
    guard let asked = leftovers else { return }
    leftovers = nil
    write(occurredAt: asked.occurredAt, books: asked.books, settling: settling)
  }

  func cancelLeftovers() {
    leftovers = nil
    isSaving = false
  }

  /// The write, once the moment is known — after asking where money an edit leaves on an
  /// archived account goes, when it leaves some.
  private func proceed(occurredAt: Date, books: AccountBooks) {
    guard let actions = saving?.actions else { return }
    if case .success(let change) = actions.change(
      for: form, occurredAt: occurredAt, books: books)
    {
      let check = TransferActions.leftovers(of: change, books: books)
      if !check.leftovers.isEmpty {
        leftovers = Leftovers(check: check, occurredAt: occurredAt, books: books)
        return
      }
    }
    write(occurredAt: occurredAt, books: books)
  }

  private func write(occurredAt: Date, books: AccountBooks, settling: [Transfer] = []) {
    defer { isSaving = false }
    guard let saving else { return }
    switch saving.actions.save(form, occurredAt: occurredAt, books: books, settling: settling) {
    case .done:
      self.saving = nil
      saving.written()
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }
}

/// The fields of a transfer: from which account and currency, how much left; to which, and how
/// much came when the currency changes, with the rate that implies; the fee, the date and the
/// time, the comment — and why the last save wrote nothing. In the sheet they stand in sections
/// of a form; in the ↓ panel beside their labels; in the form at the side under them.
struct TransferFields: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Bindable var entry: TransferEntry
  var layout: Layout = .sheet
  /// The focus of the panel the fields stand in: Tab and Return of the panel reach them.
  var focus: FocusState<PanelFocus?>.Binding? = nil

  enum Layout {
    /// Sections of a grouped form: the sheet of a transfer.
    case sheet
    /// Labels beside the controls: the ↓ panel.
    case wide
    /// Labels above the controls, as wide as the column: the form at the side of the window.
    case column
  }

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  private var transfers: TransferActions { TransferActions(environment: environment, store: store) }

  private var form: TransferForm { entry.form }

  var body: some View {
    Group {
      switch layout {
      case .sheet: sheetBody
      case .wide, .column: panelBody
      }
    }
    .task(id: ObjectIdentifier(entry)) {
      entry.tripIsOn = environment.tripEntryDefaults != nil
      entry.rubPerUnit = environment.rubPerUnitReader(on: entry.form.day)
      await entry.load(transfers)
      entry.layCreditFee(accounts: accounts)
    }
    .onChange(of: entry.form) { _, _ in entry.refusal = nil }
    .onChange(of: CreditFeeKey(entry.form, atm: entry.atmIsOn)) { _, _ in
      entry.layCreditFee(accounts: accounts)
    }
  }

  // MARK: Layouts

  private var sheetBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      Form {
        Section {
          accountPicker(from: true)
          currencyPicker(from: true)
          amountRow(t("transfer.sheet.sent"), amount: $entry.form.sent, currency: form.fromCurrency)
          if let balance = balanceText(form.fromAccountId, form.fromCurrency) {
            caption(balance)
          }
        } header: {
          Text(verbatim: t("transfer.sheet.from"))
        }
        Section {
          accountPicker(from: false)
          currencyPicker(from: false)
          receivedRows
        } header: {
          Text(verbatim: t("transfer.sheet.to"))
        }
        Section {
          amountRow(t("transfer.sheet.fee"), amount: $entry.form.fee, currency: form.fromCurrency)
          feeCaptions
          datePicker
          noteField
        }
      }
      .formStyle(.grouped)
      refusalText
    }
  }

  private var panelBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      rows {
        row("transfer.sheet.from") { accountPicker(from: true) }
        if offersCurrency(from: true) {
          row("transfer.sheet.currency") { currencyPicker(from: true) }
        }
        row("transfer.sheet.sent") {
          amountControl(amount: $entry.form.sent, currency: form.fromCurrency)
            .modifier(TransferFocused(focus: focus, value: .transferSent))
            .accessibilityIdentifier("transfer.sent")
        }
        if let balance = balanceText(form.fromAccountId, form.fromCurrency) {
          row(nil) { caption(balance) }
        }
        row("transfer.sheet.to") { accountPicker(from: false) }
        if offersCurrency(from: false) {
          row("transfer.sheet.currency") { currencyPicker(from: false) }
        }
        if form.isExchange {
          row("transfer.sheet.received") {
            amountControl(amount: $entry.form.received, currency: form.toCurrency)
              .modifier(TransferFocused(focus: focus, value: .transferReceived))
              .accessibilityIdentifier("transfer.received")
          }
        }
        row(nil) { caption(rateCaption) }
        row("transfer.sheet.fee") {
          amountControl(amount: $entry.form.fee, currency: form.fromCurrency)
            .modifier(TransferFocused(focus: focus, value: .transferFee))
            .accessibilityIdentifier("transfer.fee")
        }
        row(nil) { feeCaptions }
        row("transfer.sheet.date") {
          momentPicker.modifier(TransferFocused(focus: focus, value: .transferDate))
        }
        row("transfer.sheet.note") {
          TextField(text: $entry.form.note) { Text(verbatim: t("transfer.sheet.note")) }
            .labelsHidden()
            .modifier(TransferFocused(focus: focus, value: .transferNote))
            .accessibilityIdentifier("transfer.note")
        }
      }
      refusalText
    }
  }

  /// A grid of labels and controls, or one column.
  @ViewBuilder
  private func rows<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    if layout == .wide {
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) { content() }
    } else {
      VStack(alignment: .leading, spacing: 12) { content() }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// One field: its label and its control, as the fields of an operation stand in the panel.
  @ViewBuilder
  private func row<Control: View>(
    _ key: String?, @ViewBuilder control: () -> Control
  )
    -> some View
  {
    if layout == .wide {
      GridRow {
        if let key { label(key) } else { Color.clear.frame(width: 1, height: 1) }
        control()
      }
    } else {
      VStack(alignment: .leading, spacing: 4) {
        if let key { label(key) }
        control()
          .buttonSizing(.flexible)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func label(_ key: String) -> some View {
    Text(verbatim: t(key))
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .gridColumnAlignment(.leading)
  }

  /// «Комиссия банка: 319.00 ₽ — запишется сама» with «Убрать», or, removed, «Комиссия банка
  /// 319.00 ₽ не запишется» with «Вернуть».
  private func creditFeeLine(_ state: TransferEntry.CreditFeeState) -> some View {
    let currency = form.fromCurrency ?? .rub
    return HStack(alignment: .firstTextBaseline, spacing: 6) {
      switch state {
      case .laid(let fee):
        caption(
          environment.format(
            entry.laidFeeIsAtm ? "transfer.sheet.atmFeeLaid" : "transfer.sheet.creditFeeLaid",
            table: AccountText.table,
            environment.money.exact(fee, currency: currency)))
        Spacer(minLength: 4)
        Button(t("transfer.sheet.creditFeeRemove")) { entry.removeCreditFee() }
          .buttonStyle(.link)
          .appFont(.caption)
          .accessibilityIdentifier("transfer.creditFee.remove")
      case .removed(let fee):
        caption(
          environment.format(
            "transfer.sheet.creditFeeRemoved", table: AccountText.table,
            environment.money.exact(fee, currency: currency)))
        Spacer(minLength: 4)
        Button(t("transfer.sheet.creditFeeRestore")) { entry.restoreCreditFee() }
          .buttonStyle(.link)
          .appFont(.caption)
          .accessibilityIdentifier("transfer.creditFee.restore")
      }
    }
    .accessibilityIdentifier("transfer.creditFee")
  }

  private func caption(_ text: String) -> some View {
    Text(verbatim: text)
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: Fields

  /// The live accounts in the order of every menu, and those of the transfer being edited.
  private var allAccounts: [PaymentMethod] {
    entry.books?.dataset.paymentMethods
      ?? AccountActions(environment: environment, store: store).all
  }

  private var accountItems: [AccountCardChoices.Item] {
    TransferSheet.accountItems(
      all: allAccounts,
      banks: entry.books?.dataset.banks
        ?? AccountActions(environment: environment, store: store).banks,
      keeping: entry.kept, locale: environment.language.locale)
  }

  private func account(_ id: UUID?) -> PaymentMethod? {
    allAccounts.first { $0.id == id && (!$0.archived || entry.kept.contains($0.id)) }
  }

  private func accountPicker(from: Bool) -> some View {
    let selection = from ? form.fromAccountId : form.toAccountId
    return Picker(
      selection: Binding(
        get: { selection },
        set: { id in
          guard let chosen = account(id) else { return }
          if from { entry.form.chooseFrom(chosen) } else { entry.form.chooseTo(chosen) }
        })
    ) {
      if selection == nil {
        Text(verbatim: "—").tag(UUID?.none)
      }
      ForEach(accountItems) { item in
        Text(verbatim: item.name).tag(UUID?.some(item.id))
      }
    } label: {
      Text(verbatim: t(layout == .sheet ? "transfer.sheet.account" : sideKey(from)))
    }
    .modifier(TransferFocused(focus: focus, value: from ? .transferFrom : .transferTo))
    .modifier(HiddenLabel(hidden: layout != .sheet))
    .accessibilityIdentifier(from ? "transfer.from" : "transfer.to")
  }

  private func sideKey(_ from: Bool) -> String {
    from ? "transfer.sheet.from" : "transfer.sheet.to"
  }

  /// One currency needs no choice; it is named next to the amount.
  private func offersCurrency(from: Bool) -> Bool {
    (account(from ? form.fromAccountId : form.toAccountId)?.currencies.count ?? 0) > 1
  }

  @ViewBuilder
  private func currencyPicker(from: Bool) -> some View {
    if let account = account(from ? form.fromAccountId : form.toAccountId),
      account.currencies.count > 1
    {
      Picker(selection: from ? $entry.form.fromCurrency : $entry.form.toCurrency) {
        ForEach(account.currencies, id: \.self) { currency in
          Text(verbatim: currency.code).tag(CurrencyCode?.some(currency))
        }
      } label: {
        Text(verbatim: t("transfer.sheet.currency"))
      }
      .pickerStyle(.segmented)
      .modifier(HiddenLabel(hidden: layout != .sheet))
    }
  }

  /// What came: typed for an exchange, with the rate it implies; else the same amount.
  @ViewBuilder
  private var receivedRows: some View {
    if form.isExchange {
      amountRow(
        t("transfer.sheet.received"), amount: $entry.form.received, currency: form.toCurrency)
    }
    caption(rateCaption)
  }

  private var rateCaption: String {
    form.isExchange ? rateLine ?? t("transfer.sheet.receivedHint") : t("transfer.sheet.sameAmount")
  }

  /// Every account, for the terms of a credit card the money leaves.
  private var accounts: [PaymentMethod] { entry.books?.dataset.paymentMethods ?? [] }

  @ViewBuilder
  private var feeCaptions: some View {
    caption(t("transfer.sheet.feeHint"))
    if entry.offersAtm(accounts: accounts) {
      Toggle(
        t("transfer.sheet.atmAbroad"),
        isOn: Binding(get: { entry.atmIsOn }, set: { entry.atmAbroad = $0 })
      )
      .appFont(.caption)
      .accessibilityIdentifier("transfer.atmAbroad")
    }
    if let state = entry.creditFeeState {
      creditFeeLine(state)
    }
    if entry.leavesACardWithoutGrace(accounts: accounts) {
      Label {
        Text(verbatim: t("transfer.sheet.creditNoGrace"))
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "percent")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("transfer.creditNoGrace")
    }
    if let feeComingBack = entry.feeComingBack, entry.writesANewFee {
      Label {
        Text(verbatim: TransferText.feeComingBack(feeComingBack, environment))
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "archivebox")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var datePicker: some View {
    // The date and the time in one line, as for an expense and an income.
    DatePicker(selection: momentBinding, displayedComponents: [.date, .hourAndMinute]) {
      Text(verbatim: t("transfer.sheet.date"))
    }
    .environment(\.locale, environment.language.locale)
  }

  private var momentPicker: some View {
    datePicker.labelsHidden().accessibilityIdentifier("transfer.date")
  }

  private var noteField: some View {
    TextField(text: $entry.form.note) {
      Text(verbatim: t("transfer.sheet.note"))
    }
  }

  private func amountRow(
    _ title: String, amount: Binding<AmountE4>, currency: CurrencyCode?
  ) -> some View {
    LabeledContent {
      amountControl(amount: amount, currency: currency)
    } label: {
      Text(verbatim: title)
    }
  }

  private func amountControl(amount: Binding<AmountE4>, currency: CurrencyCode?) -> some View {
    HStack(spacing: 4) {
      AmountField(amount: amount)
        .frame(maxWidth: 160)
      Text(verbatim: currency.map { environment.money.symbol(for: $0) } ?? "")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var refusalText: some View {
    if let refusal = entry.refusal {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        Text(verbatim: TransferText.message(refusal, environment))
          .fixedSize(horizontal: false, vertical: true)
      }
      .appFont(layout == .sheet ? .callout : .caption)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("transfer.refusal")
    }
  }

  /// The moment of the transfer: until the owner picks a time, the one it would get — now for
  /// today, noon for another day, its own for an edit that keeps the day. Picking another day
  /// alone chooses no time (`TransferForm.choose`).
  private var momentBinding: Binding<Date> {
    Binding(
      get: { entry.form.occurredAt(now: environment.now(), calendar: environment.calendar) },
      set: { picked in
        let shown = entry.form.occurredAt(now: environment.now(), calendar: environment.calendar)
        entry.form.choose(moment: picked, shown: shown, calendar: environment.calendar)
      })
  }

  /// «Курс обмена: 1 € = 98.5 ₽».
  private var rateLine: String? {
    guard let from = form.fromCurrency, let to = form.toCurrency,
      let rate = TransferText.rate(
        sent: form.sent, from: from, received: form.received, to: to, money: environment.money)
    else { return nil }
    return environment.format("transfer.sheet.rate", table: AccountText.table, rate)
  }

  /// «на счёте: 12,345.67 ₽» — what the key holds now, when it was ever counted.
  private func balanceText(_ accountId: UUID?, _ currency: CurrencyCode?) -> String? {
    guard let accountId, let currency, let books = entry.books,
      let amount = books.balances[BalanceKey(accountId: accountId, currency: currency)]?.amountE4
    else { return nil }
    return environment.format(
      "transfer.sheet.balance", table: AccountText.table,
      environment.money.exact(amount, currency: currency))
  }
}

/// The control takes the panel's focus under `value`, when the fields stand in a panel.
private struct TransferFocused: ViewModifier {
  let focus: FocusState<PanelFocus?>.Binding?
  let value: PanelFocus

  func body(content: Content) -> some View {
    if let focus {
      content.focused(focus, equals: value)
    } else {
      content
    }
  }
}

/// The label goes where the panel shows its own beside or above the control.
private struct HiddenLabel: ViewModifier {
  let hidden: Bool

  func body(content: Content) -> some View {
    if hidden { content.labelsHidden() } else { content }
  }
}

extension View {
  /// The dialogs of the save of `entry`, wherever its fields stand: «Это было до сверки в
  /// 14:05?» — with «Больше не спрашивать для этой сверки» where the answer is kept —, where
  /// money an edit leaves on an archived account goes, and a write the database refused.
  func transferQuestions(_ entry: TransferEntry?) -> some View {
    modifier(TransferQuestions(entry: entry))
  }
}

private struct TransferQuestions: ViewModifier {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let entry: TransferEntry?

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  func body(content: Content) -> some View {
    content
      // A count whose answer would not be kept (`CountQuestions.remembers`) is asked without
      // «Больше не спрашивать»; one whose answer would, with it.
      .background { countDialog(remembering: false) }
      .background {
        countDialog(remembering: true)
          .dialogSuppressionToggle(
            Text(verbatim: t("transfer.beforeCount.dontAsk")),
            isSuppressed: Binding(
              get: { entry?.dontAsk ?? false }, set: { entry?.dontAsk = $0 }))
      }
      .onChange(of: entry?.question?.id) { _, _ in entry?.dontAsk = false }
      .sheet(
        item: Binding(get: { entry?.leftovers }, set: { if $0 == nil { entry?.leftovers = nil } })
      ) { asked in
        ArchivedMoneySheet(
          check: asked.check,
          confirm: { settling in entry?.settle(settling) },
          cancel: { entry?.cancelLeftovers() }
        )
        .handingOver(dependencies)
      }
      .refusedWriteAlert(
        Binding(get: { entry?.failed ?? false }, set: { entry?.failed = $0 }), environment)
  }

  private func countDialog(remembering: Bool) -> some View {
    let question = entry?.question
    return Color.clear.confirmationDialog(
      question.map {
        environment.format(
          "transfer.beforeCount.title", table: AccountText.table,
          environment.dates.time($0.count))
      } ?? "",
      isPresented: Binding(
        get: { question.map { $0.questions.remembers == remembering } ?? false },
        set: { if !$0 { entry?.dismissQuestion() } }),
      titleVisibility: .visible, presenting: question
    ) { question in
      Button(t("transfer.beforeCount.yes")) { entry?.answer(question, wasBefore: true) }
      Button(t("transfer.beforeCount.no")) { entry?.answer(question, wasBefore: false) }
      Button(environment.language("action.cancel"), role: .cancel) { entry?.isSaving = false }
    } message: { _ in
      Text(verbatim: t("transfer.beforeCount.message"))
    }
  }
}

/// What the fee of a credit card follows: the account and currency the money leaves and the
/// amount sent.
private struct CreditFeeKey: Equatable {
  var from: UUID?
  var currency: CurrencyCode?
  var to: UUID?
  var sent: AmountE4
  /// «Банкомат за границей» is on.
  var atm: Bool

  init(_ form: TransferForm, atm: Bool) {
    self.atm = atm
    from = form.fromAccountId
    currency = form.fromCurrency
    to = form.toAccountId
    sent = form.sent
  }
}
