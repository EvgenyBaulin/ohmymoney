import AppCore
import SwiftUI
import TipKit

#if canImport(AppKit)
  import AppKit
#endif

/// The column the entry bar floats in. It is 560 to 720 pt wide but never wider
/// than 70% of the whole window, and never comes closer than 16 pt to the sides of the
/// column it floats over. Below an 800 pt window the share wins over the minimum, and with
/// the sidebar open the column can win over both, so the bar shrinks instead of spilling
/// over the edges.
enum EntryBarMetrics {
  static let minimumWidth: CGFloat = 560
  static let maximumWidth: CGFloat = 720
  static let widthShare: CGFloat = 0.7
  /// The tallest the ↓ panel stands before its fields scroll: the design's panel, label over
  /// control in three columns, is about 590 pt with its foot.
  static let panelMaxHeight: CGFloat = 620
  /// Room kept free between the bar and each side of the column it floats over.
  static let sideMargin: CGFloat = 16
  /// Distance between the capsule and the bottom edge of the window.
  static let bottomInset: CGFloat = 18
  /// Space between the elements stacked in the bar: the panel, the chips, the caption and
  /// the capsule.
  static let spacing: CGFloat = 10
  /// Space left between the last row of the content and the top of the bar.
  static let contentGap: CGFloat = 12

  static func columnWidth(windowWidth: CGFloat, detailWidth: CGFloat) -> CGFloat {
    // The very first layout pass can hand out a width of zero. The column stands in for the
    // window until the window is measured, and the bar starts at its minimum when neither is
    // known, instead of collapsing to nothing.
    let window = isUsable(windowWidth) ? windowWidth : detailWidth
    guard isUsable(window) else { return minimumWidth }
    // Clamp the share to 560…720, then cap it by the share again: the owner's rule is
    // «never wider than 70% of the window», and on a narrow window it beats the minimum.
    let share = window * widthShare
    let preferred = min(min(max(minimumWidth, share), maximumWidth), share)
    guard isUsable(detailWidth) else { return preferred }
    return max(0, min(preferred, detailWidth - 2 * sideMargin))
  }

  /// The room the list keeps under the bar is no longer counted here. It is the height of the
  /// bar itself, and the safe area takes it (`safeAreaInset`): a height
  /// measured off the screen and handed back to the window is what made the window of
  /// Transactions loop until AppKit gave up. What that count used to say —
  /// that the capsule, the chips and the selection bar are part of the room while the ↓ panel
  /// and the caption are not — is now the shape of the view, and `MainWindowLayoutTests`
  /// holds it.
  private static func isUsable(_ width: CGFloat) -> Bool { width.isFinite && width > 0 }
}

extension EnvironmentValues {
  /// Width of the whole window, measured once at the root of the scene. Views deep inside a
  /// split view only see their own column, and some sizes are defined by the window.
  @Entry var windowWidth: CGFloat = 0
}

/// The floating glass capsule that is always visible in the main window. Enter saves.
/// It keeps to a column of its own — centred above the content and bounded by
/// `EntryBarMetrics` — instead of stretching from one edge of the window to the other.
/// The ↓ panel grows out of the same `GlassEffectContainer`, so the two morph into one
/// another instead of stacking glass on glass.
///
/// `accessory` is another control of the same layer, shown just above the capsule — the
/// bar of a selection in the list. It lives in the same container for the same reason.
struct EntryBar<Accessory: View>: View {
  /// Width of the whole window: the bar takes a share of it.
  let windowWidth: CGFloat
  /// Width of the column the bar floats over: the bar never reaches its sides.
  let detailWidth: CGFloat
  /// How a new operation is filled in (`EntryStyle`): the floating line with the ↓ panel above
  /// it, or the form of every field in a column of its own — no line, no suggestions, the panel
  /// always open and saved with its own button.
  var style: EntryStyle = .line
  /// The ↓ panel is open from the start. A test opens it this way: a key press needs a key
  /// window, and a test host is not always given one.
  var opensDetails: Bool = false
  /// The selection of the window's lists, for the form at the side: an operation selected there
  /// opens in the form to be edited (`EntryFormEditor`). `nil`: the form only makes new ones.
  var operations: OperationActions? = nil
  /// On the phone and the tablet the line is not on screen until the round «+» shows it, and the
  /// keyboard comes only with it: the gate says when. `nil` (the Mac): always on screen.
  var phone: PhoneEntryAccess? = nil
  /// Glass of its own, or nothing. While it is shown it stands in the bar, so the safe area
  /// grows by its height and the last rows of the list can be scrolled out from under it. It
  /// morphs in and out of the capsule only inside an animated change; the screen that owns it
  /// animates its coming and going.
  @ViewBuilder var accessory: () -> Accessory

  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  /// Handed to the reimbursement sheet, which SwiftUI lays out in a host of its own.
  @Environment(\.dependencies) private var dependencies
  @Environment(\.themeSurfaces) private var surfaces
  @FocusState private var focused: Bool

  @State private var text = ""
  @State private var showsDetails = false
  /// A field of the form has the keyboard: «Save» answers Return then, and only then — the rest
  /// of the time Return belongs to whatever else in the window has the focus.
  @State private var formFocused = false
  /// The caption above the line: why it was not saved, or what the panel asks for.
  @State private var message: EntryLineMessage?
  /// One keystroke of Return saves once, however many ways AppKit hands it over.
  @State private var returnGate = EntrySaving.ReturnGate()
  @State private var model: EntryDraftModel?
  /// Money back from a person, waiting in its confirmation.
  @State private var moneyBack: MoneyBackPrefill?
  /// The payment form of a debt the money back repays in another currency than the debt's:
  /// waiting for the confirmation to close, then open.
  @State private var pendingRepayment: DebtSheet?
  @State private var repayment: DebtSheet?
  /// «Это было до сверки в 14:05?», waiting for the owner's answer before the save goes on.
  @State private var countQuestion: BeforeTheCountQuestion?
  /// The picker of purchases a refund takes money back from, while it is open.
  @State private var refundRequest: RefundPickerRequest?
  /// «Такая же операция уже записана — добавить ещё?», waiting for the owner's answer.
  @State private var repeatQuestion: RepeatQuestion?
  /// «Запись или план?» for an operation dated after today, waiting for the owner's answer.
  @State private var aheadQuestion: AheadQuestion?
  /// What the owner's rules and the tags typed say about the line, under it (`EntryLineRules`).
  @State private var ruleHint: String?
  /// The chips under the line.
  @State private var templates = TemplatesModel()
  /// The quick line of the form: whether «Будет записано» is up.
  @State private var quick = QuickEntryFlow()
  /// The form at the side: the kind of the next operation has been chosen, and its fields are
  /// shown. After a save the form starts again from the kinds.
  @State private var kindChosen = false
  /// The form at the side: the saved operation selected in a list, edited in the form.
  @State private var editing: TransactionEditorModel?
  /// «Сверх платежа X — уменьшить срок или платёж?», waiting for the owner's answer.
  @State private var prepayQuestion: PrepayQuestion?
  /// A thing bought in instalments, returned: the sheet that asks how the bank gives it back.
  @State private var instalmentReturn: InstalmentReturnRequest?
  /// «Распределить…» under the line, after an income.
  @State private var allocation: AllocationRequest?
  /// «Включить…» of the offer to count the tax of self-employment.
  @State private var settingUpSelfEmployment = false
  /// Quick entry: a pasted text of a bank, «ой, 350», places, the parts of a «;» line, drafts.
  @State private var fast = QuickEntryModel()
  /// The question mode of the line: Enter asks instead of writing (`QuestionLineModel`).
  @State private var questions = QuestionLineModel()
  @Namespace private var glass

  private var interpreter: any LineInterpreter {
    // The «#tags» of the line are taken out before it is read (`TaggingInterpreter`).
    TaggingInterpreter(
      base: CoreLineInterpreter(
        vocabulary: environment.vocabulary, calendar: environment.calendar,
        catalog: environment.currencyCatalog))
  }

  var body: some View {
    Group {
      switch style {
      case .line:
        if let phone, !phone.isShown {
          collapsedBody
        } else {
          lineBody
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      case .form: formBody
      }
    }
    .onAppear {
      // A screen appearing never opens the keyboard on the phone: only the owner's act does.
      focused = style == .line && phone == nil
      prepareModel()
      templates.attach(environment.references)
      fast.drafts.attach(SettingsDraftStore(settings: environment.settings))
      arrangeTheChips()
      if opensDetails || style == .form { showsDetails = true }
    }
    .onReceive(NotificationCenter.default.publisher(for: .focusEntryLine)) { _ in
      if let phone {
        // ⌘N on a hardware keyboard, or the palette: the line comes up and takes the keyboard.
        if phone.gate.send(.newEntryRequested), phone.isShown { focusTheLineSoon() }
        return
      }
      startNewOperation()
    }
    // ↑ on the newest row of the list, or Esc in it: the keyboard comes back to the line.
    .onReceive(NotificationCenter.default.publisher(for: .returnToEntryLine)) { _ in
      if let phone, !phone.isShown { return }
      focused = style == .line
    }
    // The line going away takes the keyboard and the open panel with it.
    .onChange(of: phone?.isShown) { _, shown in
      guard shown == false else { return }
      focused = false
      showsDetails = false
      message = nil
      #if os(iOS)
        UIApplication.shared.sendAction(
          #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
      #endif
    }
    // Goals and debts made in Planning or Debts belong in the pickers of the ↓ panel at once
    // (review of the app, 19.09): read again when the panel opens and after each write. The
    // defaults are laid as it opens too: an operation entered in the panel alone never passes
    // through the line, and is not saved without the default payment method.
    .onChange(of: showsDetails) { _, shown in
      guard shown else { return }
      model?.prepareForPanel(today: environment.today)
      readTheLineIntoThePanel()
    }
    // The open panel shows what the line says as it is typed, not only after Enter. The notice
    // that an operation became a plan has said what it had to: the next line starts clean.
    .onChange(of: text) { old, new in
      if message?.isNotice == true { message = nil }
      // A question is not read as an operation: no bank text, no panel, no rules.
      if questions.isActive {
        questions.textChanged()
        return
      }
      // A text of a bank pasted into the line is read; any other paste stays as it came.
      if let replaced = fast.lineChanged(
        old: old, new: new, environment: environment, compute: compute)
      {
        text = replaced
        return
      }
      readTheLineIntoThePanel()
      refreshRuleHint()
    }
    // The form at the side follows the selection of the window's lists: one operation selected
    // is edited in it, anything else brings the new operation back.
    .onChange(of: operations?.selection, initial: true) { _, selection in
      followTheSelection(selection ?? [])
    }
    .onAppear { offerTheFormForEditing() }
    .onDisappear { if style == .form { operations?.opensEditor = nil } }
    .onChange(of: compute.generation) { _, _ in
      followTheEditedOperation()
      if showsDetails { model?.reload() }
      // The chips too: a restore or an archive brought in replaces them.
      templates.reload()
      fast.drafts.reload()
      questions.askWaiting(compute: compute)
    }
    // Cancelled, the confirmation leaves the line as it was; recorded, it clears it like a
    // save. A person who owes nothing, or owes on a debt, sends the money back to the line as
    // income or as that debt's repayment.
    .sheet(
      item: $moneyBack,
      onDismiss: {
        // One sheet at a time: the payment form of the debt opens once the confirmation is gone.
        repayment = pendingRepayment
        pendingRepayment = nil
      }
    ) { prefill in
      MoneyBackConfirmSheet(
        prefill: prefill,
        recordAsIncome: { recordMoneyBack(.income, from: $0) },
        recordAsDebtRepayment: { recordMoneyBack(.debtRepayment($0), from: $1) },
        recorded: { if let model { finishSaving(model) } }
      )
      .handingOver(dependencies)
    }
    // Written there, the repayment clears the line like a save; cancelled, the line stays.
    .sheet(item: $repayment) { form in
      DebtSheetView(sheet: form, onDone: { if let model { finishSaving(model) } })
        .handingOver(dependencies)
    }
    // A thing bought in instalments, returned: written there, split as the owner says, the line
    // clears like a save; cancelled, the line stays.
    .sheet(item: $instalmentReturn) { request in
      InstalmentReturnSheet(refund: request.refund, debt: request.debt) { written in
        if written, let model { finishSaving(model) }
      }
      .handingOver(dependencies)
    }
    .sheet(item: $allocation) { request in
      AllocationSheetView(request: request)
        .handingOver(dependencies)
    }
    .sheet(isPresented: $settingUpSelfEmployment) {
      SelfEmploymentSetupSheet()
        .handingOver(dependencies)
    }
    .quickEntrySheets(fast, text: $text)
    // The ↓ panel asks for the picker through the model: read here, in the body, so the ask
    // is seen, and handed to the sheet.
    .onChange(of: model?.refundPicking) { _, request in
      guard let request else { return }
      model?.refundPicking = nil
      refundRequest = request
    }
    // A refund picks the purchase it takes money back from; asked by Enter, the save goes on
    // once one is picked — or «Без покупки».
    .sheet(item: $refundRequest) { request in
      if let model {
        RefundPicker(entry: model) {
          guard request.savesAfterChoice else { return }
          Task { @MainActor in commit(model) }
        }
        .handingOver(dependencies)
      }
    }
    // The answers date the operation before or after each count of its day, and the save
    // goes on at the moment they give.
    .beforeTheCountQuestions($countQuestion) { moment in
      guard let model else { return }
      model.stampCount(moment)
      commit(model)
    }
    // A transfer is written from the panel, as an operation is: its questions — the counts of
    // its day, money left on an archived account — are asked over the bar, open panel or not.
    .transferQuestions(model?.transfer)
    // A transfer the line wrote at once and was refused: the panel opens on the reason.
    .onChange(of: model?.transfer?.refusal) { _, refusal in
      guard refusal != nil, style == .line, !showsDetails else { return }
      withAnimation(.snappy) { showsDetails = true }
    }
    // Two questions before a new operation is written, each on a view of its own: a record or a
    // plan, for a date after today; and «такая же уже записана», for a repeat of the last minutes.
    .background {
      Color.clear.confirmationDialog(
        aheadQuestion.map { $0.title(environment) } ?? "",
        isPresented: Binding(
          get: { aheadQuestion != nil }, set: { if !$0 { aheadQuestion = nil } }),
        titleVisibility: .visible, presenting: aheadQuestion
      ) { question in
        Button(environment.language("entry.ahead.record", table: "Entry")) { recordAhead() }
        Button(environment.language(question.planKey, table: "Entry")) { makeAPlan(of: question) }
        Button(environment.language("action.cancel"), role: .cancel) {}
      } message: { _ in
        Text(verbatim: environment.language("entry.ahead.message", table: "Entry"))
      }
    }
    .background {
      Color.clear.confirmationDialog(
        environment.language("entry.repeat.title", table: "Entry"),
        isPresented: Binding(
          get: { repeatQuestion != nil }, set: { if !$0 { repeatQuestion = nil } }),
        titleVisibility: .visible, presenting: repeatQuestion
      ) { _ in
        Button(environment.language("entry.repeat.add", table: "Entry")) { addTheRepeat() }
        Button(environment.language("entry.repeat.skip", table: "Entry"), role: .cancel) {}
      } message: { question in
        Text(verbatim: question.message(environment))
      }
    }
    .background {
      Color.clear.confirmationDialog(
        prepayQuestion.map { $0.title(environment) } ?? "",
        isPresented: Binding(
          get: { prepayQuestion != nil }, set: { if !$0 { prepayQuestion = nil } }),
        titleVisibility: .visible, presenting: prepayQuestion
      ) { question in
        ForEach(question.choices, id: \.self) { choice in
          Button(environment.language(PrepayQuestion.key(of: choice), table: "Entry")) {
            answerPrepay(choice)
          }
        }
        Button(environment.language("action.cancel"), role: .cancel) {}
      } message: { _ in
        Text(verbatim: environment.language("entry.prepay.message", table: "Entry"))
      }
    }
  }

  /// «Уменьшить срок», «Уменьшить платёж» or «Это платёж вперёд»: the payment is written with
  /// the answer.
  private func answerPrepay(_ choice: PrepayChoice) {
    guard let model else { return }
    model.prepayChoice = choice
    continueSaving(model)
  }

  /// «Очистить» of the form: what was typed is dropped and the defaults are laid again.
  private func clearTheForm() {
    guard let model else { return }
    model.reset()
    model.reload()
    model.prepareForPanel(today: environment.today)
    message = nil
    kindChosen = false
    quick.dismiss()
    model.focusRequest = .control(.quick)
  }

  /// Double click and «Изменить» of a list open the operation in the form, not in a sheet.
  private func offerTheFormForEditing() {
    guard style == .form, let operations else { return }
    operations.opensEditor = { entry in operations.selection = [entry.id] }
  }

  /// One operation selected in a list of the window is edited in the form; nothing, several rows
  /// or a transfer bring the new operation back. An edit not saved goes with the selection, as
  /// it goes when the edit sheet is closed.
  private func followTheSelection(_ selection: Set<UUID>) {
    guard style == .form else { return }
    guard let entry = EntryFormSelection.operation(selection, find: findOperation) else {
      if editing != nil { editing = nil }
      return
    }
    guard editing?.id != entry.id else { return }
    editing = TransactionEditorModel(
      entry: entry, environment: environment, tree: compute.snapshot?.ledger.tree ?? CategoryTree())
    AppLog.info("entry.formEdits", .ui, "an operation selected in a list opened in the form")
  }

  private func findOperation(_ id: UUID) -> TransactionEntry? {
    store.entry(id: id) ?? compute.snapshot?.ledger.entry(id)
  }

  /// The data changed under the operation being edited: as the inspector follows it.
  private func followTheEditedOperation() {
    guard let current = editing else { return }
    switch current.follow(findOperation(current.id)) {
    case .stay: break
    case .close: stopEditing()
    case .reopen(let fresh):
      editing = TransactionEditorModel(
        entry: fresh, environment: environment,
        tree: compute.snapshot?.ledger.tree ?? CategoryTree())
    }
  }

  /// «Отмена», Esc or a save in the form's editing: the selection goes, and with it the editing;
  /// the form stands ready for a new operation.
  private func stopEditing() {
    editing = nil
    operations?.selection = []
    model?.focusRequest = .control(.quick)
  }

  /// The transfer the line named: its accounts, amount, day and note in the fields of a transfer
  /// (`TransferForm.fromTheLine`) — written at once when nothing is left to choose, else the
  /// panel opens on them, nothing written.
  private func startTransfer(fromTheLine reading: TransferReading, model: EntryDraftModel) {
    let form = TransferForm(
      fromTheLine: reading, draft: model.draft, accounts: model.paymentMethods,
      calendar: environment.calendar)
    let atOnce = form.savesAtOnce(reading)
    AppLog.info(
      "entry.transferFromLine", .ui, "the line named a transfer",
      [LogPair("complete", .flag(reading.isComplete)), LogPair("atOnce", .flag(atOnce))])
    message = nil
    let transfer = TransferEntry(form: form, fromTheLine: true)
    model.transfer = transfer
    if atOnce {
      saveTheTransfer(transfer, model)
      return
    }
    // Something is left to choose: the fields of the transfer, with what the line said.
    kindChosen = true
    if !showsDetails { withAnimation(.snappy) { showsDetails = true } }
  }

  /// The transfer of the panel written — the questions of its save asked on the way —; the line,
  /// the panel and the draft start over as after an operation. Refused, the reason stands under
  /// its fields and nothing is cleared.
  private func saveTheTransfer(_ transfer: TransferEntry, _ model: EntryDraftModel) {
    message = nil
    transfer.save(TransferActions(environment: environment, store: store)) {
      if transfer.fromTheLine { GuideStore.shared.report(GuideEvent.transferFromLine) }
      finishSaving(model)
    }
  }

  /// What the line says goes into the fields of the open transfer (`TransferForm.take`); false
  /// when its number is no amount.
  @discardableResult
  private func take(
    _ reading: InputLineReading, into transfer: TransferEntry, model: EntryDraftModel
  ) -> Bool {
    let parsed = reading.parsed
    var amount: AmountE4?
    if let typed = parsed.amount {
      guard let read = try? AmountE4(decimal: typed) else { return false }
      amount = read
    }
    transfer.form.take(
      line: parsed.transfer, amount: amount, currency: parsed.currency, day: parsed.date,
      accounts: model.paymentMethods)
    return true
  }

  /// Return with a transfer in the panel: the line, when it says something, goes into its fields
  /// first; then the transfer is saved.
  private func saveTheTransfer(
    _ transfer: TransferEntry, line trimmed: String, model: EntryDraftModel
  ) {
    if !trimmed.isEmpty {
      let reading = interpreter.read(trimmed, today: environment.today, kind: model.draft.kind)
      if let problem = reading.parsed.dateProblem {
        message = .date(problem)
        return
      }
      if let problem = reading.timeProblem {
        message = .time(problem)
        return
      }
      guard take(reading, into: transfer, model: model) else {
        message = .error("entry.error.amountTooLarge")
        return
      }
    }
    saveTheTransfer(transfer, model)
  }

  /// «Записать как есть»: the operation dated ahead is written on its date; the question is not
  /// asked again for it.
  private func recordAhead() {
    guard let model else { return }
    AppLog.info("entry.aheadRecorded", .ui, "an operation dated ahead was recorded as it is")
    model.aheadAnswered = true
    continueSaving(model)
  }

  /// The plan the question offered, written instead of the operation — one step of ⌘Z — and the
  /// line cleared; a plan that was not written leaves the line as it was.
  private func makeAPlan(of question: AheadQuestion) {
    guard let model, let dependencies else { return }
    let actions = PlanningActions(dependencies)
    let saved: Bool
    switch question.plan {
    case .payment:
      let name =
        model.planName ?? environment.language("entry.ahead.payment", table: "Entry")
      saved = actions.save(model.plannedPayment(named: name), previous: nil)
    case .income:
      let name =
        model.planName ?? environment.language("entry.ahead.income", table: "Entry")
      saved = actions.save(model.plannedIncome(named: name))
    }
    guard saved else {
      message = .error("entry.error.notSaved")
      return
    }
    AppLog.info(
      "entry.aheadPlanned", .ui, "an operation dated ahead became a plan",
      [LogPair("plan", .token("\(question.plan)"))])
    finishSaving(model, then: .planned(question.plan, question.day))
  }

  /// «Добавить»: the repeat is written; the question is not asked again for it.
  private func addTheRepeat() {
    guard let model else { return }
    AppLog.info("entry.repeatAdded", .ui, "a repeat of an operation just written was added")
    model.repeatConfirmed = true
    continueSaving(model)
  }

  /// The save goes on after the dialog that asked has gone: the next question it may ask — the
  /// counts of the day — is presented by a window that has just closed one, and a window takes
  /// the next only once the first is gone.
  private func continueSaving(_ model: EntryDraftModel) {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      commit(model)
    }
  }

  /// The phone with no line on screen: only what stands with it — the bar of a selection.
  private var collapsedBody: some View {
    GlassEffectContainer(spacing: 12) {
      accessory()
        .glassEffectID("accessory", in: glass)
    }
    .frame(
      width: EntryBarMetrics.columnWidth(windowWidth: windowWidth, detailWidth: detailWidth))
  }

  /// The line is up on the phone: it asks for the keyboard once it is in the view, and again a
  /// moment later (the field may not be in the window yet).
  private func focusTheLineSoon() {
    focused = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      if phone?.isShown == true { focused = true }
    }
  }

  /// The floating glass capsule with the chips above it and the ↓ panel over them.
  private var lineBody: some View {
    GlassEffectContainer(spacing: 12) {
      VStack(alignment: .leading, spacing: EntryBarMetrics.spacing) {
        TemplatesStrip(
          model: templates,
          currencyOf: { Templates.currency(of: $0, in: environment, model: model) }
        ) { template in
          // A chip with a blank («Такси до работы — ? ₽») puts its words in and waits for the sum.
          text = QuickSuggest.lineForBlank(template) ?? templateLine(for: template)
          focused = true
        }

        accessory()
          .glassEffectID("accessory", in: glass)

        GlassCapsule {
          HStack(spacing: 10) {
            // The accent circle with its plus, as the design draws the start of the line.
            Image(systemName: "plus")
              .font(.system(size: 12, weight: .bold))  // font-fixed: glyph in a fixed circle
              .foregroundStyle(surfaces.onAccent)
              .frame(width: 26, height: 26)
              .background(surfaces.accent, in: .circle)
              // The tip hangs on the symbol beside the line, not on the field: the field keeps
              // its keys — Tab into the panel — to itself.
              .popoverTip(EntryLineTip(), arrowEdge: .top)
            TextField(
              text: $text,
              prompt: Text(
                verbatim: questions.isActive
                  ? QuestionsText.t("questions.prompt", environment)
                  : environment.language("entry.placeholder", table: "Entry"))
            ) {
              Text(verbatim: environment.language("entry.amount", table: "Entry"))
            }
            .textFieldStyle(.plain)
            .focused($focused)
            // The line was shown by the owner's «+» (or ⌘N): the keyboard comes with it.
            .onAppear { if phone != nil { focusTheLineSoon() } }
            .accessibilityIdentifier("entry.line")
            .onSubmit(save)
            // ↓ walks the list of operations from the newest, and only while the line has
            // focus: a window-wide shortcut would swallow arrow keys meant for the list.
            // It opens nothing — the panel opens with Tab and the chevron.
            .onKeyPress(.downArrow) { press(.down) }
            .onKeyPress(.upArrow) { press(.up) }
            // Esc closes the panel and keeps the draft. With the panel closed it is not
            // ours, so it goes on to whatever else wants it.
            .onKeyPress(.escape) { press(.escape) }
            // Tab opens the panel and goes to the first field of the owner's order, and with the
            // panel open it goes there too, Shift-Tab to the last; with the panel closed
            // Shift-Tab is the window's.
            .onKeyPress(keys: [.tab, PanelTabOrder.backTab]) { key in tab(key) }
            // Last, over the field and its keys: where the guide frames the line.
            .guideTarget("entry.line")

            // «Вопрос»: the line asks about the data instead of writing; the mode is this button's,
            // never the text's.
            Button(action: toggleQuestionMode) {
              Image(
                systemName: questions.isActive ? "questionmark.bubble.fill" : "questionmark.bubble")
            }
            .buttonStyle(.glass)
            .help(QuestionsText.t("questions.mode.help", environment))
            .accessibilityLabel(
              Text(verbatim: QuestionsText.t("questions.mode.label", environment))
            )
            .accessibilityAddTraits(questions.isActive ? [.isSelected] : [])
            .accessibilityIdentifier("entry.question.toggle")

            Button(action: toggleDetails) {
              Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                // The closed panel still holds choices the next line will keep: a dot says
                // so, and the help and VoiceOver say what it means.
                .overlay(alignment: .topTrailing) {
                  if carriesChoices {
                    Circle()
                      .fill(.tint)
                      .frame(width: 6, height: 6)
                      .offset(x: 5, y: -3)
                      .accessibilityHidden(true)
                  }
                }
            }
            .buttonStyle(.glass)
            .help(
              environment.language(
                carriesChoices ? "entry.detailsCarried" : "entry.details", table: "Entry")
            )
            .accessibilityValue(
              Text(
                verbatim: carriesChoices
                  ? environment.language("entry.detailsCarried", table: "Entry") : "")
            )
            .disabled(questions.isActive)
            .accessibilityIdentifier("entry.details.toggle")
            .guideTarget("entry.details.toggle")

            Button(
              questions.isActive
                ? QuestionsText.t("questions.ask", environment)
                : environment.language("entry.save", table: "Entry"), action: save
            )
            .buttonStyle(.glassProminent)
            // While the panel is open Return saves wherever the focus is — a menu, the date,
            // a checkbox — as Enter in the line does. An open menu takes Return itself.
            .keyboardShortcut(showsDetails ? .defaultAction : nil)
            .disabled(
              questions.isActive
                ? text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                : !EntrySaving.isOffered(line: text, showsDetails: showsDetails))
          }
        }
        .glassEffectID("capsule", in: glass)
        // Above the capsule, not under it: the capsule keeps its place at the bottom of the
        // window while the result of a formula or an error comes and goes. It hangs over the
        // capsule instead of standing in the stack so that it adds nothing to the height —
        // otherwise the list would be nudged by every keystroke that changes what a formula
        // comes to.
        .overlay(alignment: .top) {
          standing(
            above: VStack(alignment: .leading, spacing: 6) {
              if questions.isActive {
                QuestionPanel(model: questions) { again in
                  text = again
                  askTheQuestion()
                }
              } else {
                if !showsDetails {
                  QuickEntryStrip(
                    model: fast, text: $text, applyCorrection: applyTheCorrection,
                    refocus: { focused = true })
                }
                questionNudge
              }
              caption
            })
        }
      }
      // The ↓ panel stands above the whole bar and adds nothing to its height either. The
      // room the list keeps under the bar is the safe area's, and the safe area takes it from
      // what stands in this stack — a panel counted in would shove the whole list down the
      // moment somebody pressed ↓. It stays inside the same `GlassEffectContainer`, so it
      // still morphs out of the capsule.
      .overlay(alignment: .top) {
        standing(above: Group { if showsDetails, let model { detailsPanel(model) } })
      }
    }
    // One width for the panel, the chips and the capsule together: bounding them
    // separately would make the morph jump as the panel opens.
    .frame(
      width: EntryBarMetrics.columnWidth(windowWidth: windowWidth, detailWidth: detailWidth)
    )
    // The space the last row of the list keeps above the bar, and the space the bar keeps
    // above the bottom of the window. Together with the bar itself they are the whole of the
    // safe area it asks for.
    .padding(.top, EntryBarMetrics.contentGap)
    .padding(.bottom, EntryBarMetrics.bottomInset)
  }

  /// The form at the side of the window (`EntryStyle.form`): every field of the panel, always
  /// open, with a button of its own to save and one to clear. No line, no chips, no suggestions.
  @ViewBuilder
  private var formBody: some View {
    if let editing {
      EntryFormEditor(editor: editing, close: stopEditing)
        // Another operation selected: a form of its own, not the last one's fields.
        .id(ObjectIdentifier(editing))
    } else if let model {
      EntryFormColumn(
        model: model, focusedInside: $formFocused, save: save, clear: clearTheForm,
        quickLine: { focus in AnyView(quickEntry(model, focus: focus)) },
        kindChosen: $kindChosen
      ) {
        caption
      }
    } else {
      Spacer()
    }
  }

  /// The line of quick entry of the form (`QuickEntryFlow`): it fills the fields below as it is
  /// typed, and the first Return only shows what will be written.
  @ViewBuilder
  private func quickEntry(
    _ model: EntryDraftModel, focus: FocusState<PanelFocus?>.Binding
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(
        text: $text,
        prompt: Text(verbatim: environment.language("entry.quick.prompt", table: "Entry"))
      ) {
        Text(verbatim: environment.language("entry.quick", table: "Entry"))
      }
      .textFieldStyle(.roundedBorder)
      .focused(focus, equals: .quick)
      .onSubmit { submitQuick() }
      // Return here is the quick line's alone: the panel around it saves on Return of its own
      // fields, and the first Return of this line writes nothing.
      .submitScope()
      .onExitCommand {
        quick.dismiss()
        text = ""
      }
      .onChange(of: text) { _, _ in quick.dismiss() }
      .accessibilityIdentifier("entry.quick")
      .guideTarget("entry.quick")
      if quick.confirming {
        VStack(alignment: .leading, spacing: 8) {
          Text(verbatim: environment.language("entry.quick.willWrite", table: "Entry"))
            .appFont(.caption)
            .foregroundStyle(.secondary)
          Text(verbatim: QuickEntrySummary.text(of: model, environment: environment))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("entry.quick.summary")
          HStack {
            Button(environment.language("entry.quick.change", table: "Entry")) {
              quick.dismiss()
              text = ""
              model.focusRequest = .first
            }
            .accessibilityIdentifier("entry.quick.change")
            Spacer()
            Button(environment.language("entry.quick.write", table: "Entry")) { submitQuick() }
              .buttonStyle(.borderedProminent)
              .accessibilityIdentifier("entry.quick.write")
          }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
      } else {
        quickSuggestions
      }
    }
  }

  /// The templates and the latest operations like the line: a click puts their line in the field.
  @ViewBuilder
  private var quickSuggestions: some View {
    let similar = QuickEntrySuggestions.lines(
      typed: text, entries: compute.snapshot?.dataset.entries ?? [], money: environment.money)
    let chips = Array(templates.templates.prefix(4))
    if !similar.isEmpty || !chips.isEmpty {
      FlowRow(spacing: 6, lineSpacing: 6) {
        ForEach(similar, id: \.self) { line in
          Button(line) {
            text = line
            model?.focusRequest = .control(.quick)
          }
        }
        ForEach(chips, id: \.id) { template in
          Button(template.text) {
            text = templateLine(for: template)
            templates.use(template)
            model?.focusRequest = .control(.quick)
          }
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  /// Return in the quick line, or «Записать»: the card first, the save on the second.
  private func submitQuick() {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let reading = interpreter.read(trimmed, today: environment.today, kind: model?.draft.kind)
    let parsed = reading.parsed
    let readable =
      !trimmed.isEmpty && parsed.dateProblem == nil && reading.timeProblem == nil
      && parsed.amount != nil
    switch quick.submit(lineIsReadable: readable) {
    case .refuse:
      if let problem = parsed.dateProblem {
        message = .date(problem)
      } else if let problem = reading.timeProblem {
        message = .time(problem)
      } else if !trimmed.isEmpty {
        message = .error(parsed.missingAmountErrorKey)
      }
    case .confirm:
      message = nil
      // What the line says stands in the fields below: the kind counts as chosen.
      kindChosen = true
      // A transfer the line names stands in the fields of a transfer, written by «Записать».
      if let named = parsed.transfer, let model, model.transfer == nil {
        let amount = parsed.amount.flatMap { try? AmountE4(decimal: $0) } ?? model.draft.amount
        model.apply(reading, amount: amount, today: environment.today, text: trimmed)
        model.transfer = TransferEntry(
          form: TransferForm(
            fromTheLine: named, draft: model.draft, accounts: model.paymentMethods,
            calendar: environment.calendar), fromTheLine: true)
      }
      readTheLineIntoThePanel()
    case .save:
      save()
    }
  }

  /// Money back of a person who owes nothing is income; of one who owes on a debt, that debt's
  /// repayment. The line saves it that way at once, as the confirmation held it: a repayment of
  /// a debt kept in another currency comes already in the debt's currency, at the rate the
  /// confirmation showed, with the money as the account received it — and like every repayment
  /// it closes the debt once covered, the rest income in «Доплаты» (`EntrySave`). Only money the
  /// confirmation could not convert — an account that holds the debt's currency — opens the
  /// payment form of the debt instead, on the account the money came to.
  private func recordMoneyBack(
    _ route: EntryDraftModel.MoneyBackInstead, from sheet: TransactionDraft
  ) {
    guard let model else { return }
    if case .debtRepayment(let debtId) = route,
      let form = MoneyBackConfirmation.repaymentForm(
        of: debtId, money: Money(amount: sheet.amount, currency: sheet.currency),
        account: sheet.paymentMethodId,
        among: (try? environment.references?.debts()) ?? model.debts)
    {
      pendingRepayment = form
      return
    }
    model.recordMoneyBackInstead(
      route, from: sheet,
      fromNote: { environment.language.format("moneyBack.fromNote", table: "Entry", $0) },
      today: environment.today)
    // The owner has just confirmed a form: nothing more is asked about the category.
    Task { @MainActor in commit(model, askingForGaps: false) }
  }

  /// Hangs a view over the top edge of whatever it is put on, one `spacing` clear of it, and
  /// takes none of its height. The alignment guide is what does it: an overlay aligned `.top`
  /// puts its own top guide on the content's top edge, so a top guide redefined to be the
  /// overlay's own bottom edge leaves the overlay standing above.
  private func standing(above view: some View) -> some View {
    view
      .frame(maxWidth: .infinity, alignment: .leading)
      // The overlay is proposed the height of what it hangs over; the panel is far taller and
      // must take the height it asks for instead of being squeezed into that proposal.
      .fixedSize(horizontal: false, vertical: true)
      .alignmentGuide(.top) { $0[.bottom] + EntryBarMetrics.spacing }
  }

  /// The ↓ panel: the same fields the edit sheet shows, on glass of its own above the capsule.
  private func detailsPanel(_ model: EntryDraftModel) -> some View {
    GlassPanel {
      VStack(alignment: .leading, spacing: 4) {
        ScrollView {
          // Return in a field of the panel saves, as Return in the line does. The close button
          // stands at the end of the row of the kinds, as the design draws it: it belongs to the
          // floating panel, not to `DetailsPanel`, whose edit sheet has buttons of its own.
          DetailsPanel(
            model: model, submit: save, offersTransfer: true,
            headerTrailing: AnyView(panelCloseCluster), showsSave: true
          )
          .padding(.trailing, 4)
        }
        .frame(maxHeight: EntryBarMetrics.panelMaxHeight)
      }
      // Esc while a control inside the panel has focus. Esc on the line itself is
      // handled by the line, so neither reaches the list behind.
      .onExitCommand(perform: closeDetails)
    }
    .glassEffectID("details", in: glass)
  }

  /// The caption under the line stands in from the capsule's rounded ends; the form has its own
  /// margin.
  private var captionInset: CGFloat { style == .form ? 0 : 14 }

  @ViewBuilder
  private var caption: some View {
    if let message, message.isError {
      Text(verbatim: message.text(environment))
        .appFont(.caption)
        .foregroundStyle(.red)
        .padding(.horizontal, captionInset)
        .accessibilityIdentifier("entry.caption")
    } else if let message {
      // A question, not an error: a symbol and words, in the secondary colour — and what it
      // offers to do, a button beside it.
      HStack(spacing: 8) {
        Label {
          Text(verbatim: message.text(environment))
        } icon: {
          Image(systemName: message.symbol)
        }
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("entry.caption")
        if let action = message.actionKey {
          Button(environment.language(action, table: "Entry")) { act(on: message) }
            .buttonStyle(.link)
            .accessibilityIdentifier("entry.caption.action")
        }
      }
      .appFont(.caption)
      .padding(.horizontal, captionInset)
    } else if preview != nil || ruleHint != nil {
      VStack(alignment: .leading, spacing: 2) {
        if let preview {
          // "Результат виден сразу": the amount a formula comes to, before Enter.
          Text(verbatim: preview)
            .appFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        // «По правилу «Пятёрочка»: Продукты · #еда»: nothing happens silently.
        if let ruleHint {
          Label(ruleHint, systemImage: "line.3.horizontal.decrease.circle")
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("entry.rule.hint")
        }
      }
      .padding(.horizontal, captionInset)
    }
  }

  /// The tags the entry carries — typed in the line or the panel, or named by a rule — go on
  /// the parts of the operation just written, as one step of ⌘Z of their own.
  private func attachTags(to entry: TransactionEntry, model: EntryDraftModel) {
    let state = model.ruleState
    let ruleTags = state.ruleTags.map(\.value)
    guard !state.typedTags.isEmpty || !ruleTags.isEmpty else { return }
    store.tag(
      parts: entry.parts.map(\.id), names: state.typedTags, ruleTagIds: ruleTags)
  }

  /// What the rules say about the line as typed, and the tags in it, for under the line.
  private func refreshRuleHint() {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let dataset = compute.snapshot?.dataset else {
      ruleHint = nil
      return
    }
    let tagged = TagText.extract(from: trimmed)
    let wording = RuleWording(environment: environment, names: RuleNames(dataset: dataset))
    var verdict = RuleVerdict()
    if showsDetails, let model, model.transfer == nil {
      // The open panel has read the line already: its verdict is the one that will be saved.
      verdict = model.ruleState.verdict
    } else if !dataset.rules.isEmpty, model?.editsSavedOperation != true {
      let reading = interpreter.read(trimmed, today: environment.today, kind: model?.draft.kind)
      guard reading.parsed.dateProblem == nil, reading.timeProblem == nil else {
        ruleHint = EntryLineRules.tagsCaption(tagged.tags)
        return
      }
      let tree = CategoryTree(dataset.categories)
      let subject = EntryLineRules.subject(
        reading: reading, noteWords: "",
        places: Dictionary(
          dataset.places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
        fallback: model?.draft, tree: tree, calendar: environment.calendar, now: Date())
      verdict = RuleEngine.evaluate(subject, rules: dataset.rules, tree: tree)
    }
    let sentence = EntryLineRules.hint(verdict, rules: dataset.rules, wording: wording)
    let parts = [EntryLineRules.tagsCaption(tagged.tags), sentence].compactMap { $0 }
    ruleHint = parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
  }

  /// The button of a notice under the line: the sheet it offers.
  private func act(on notice: EntryLineMessage) {
    switch notice {
    case .allocate(let incomeId, _):
      allocation = AllocationRequest(incomeId: incomeId)
      AppLog.info("entry.allocateOpened", .ui, "the allocation of an income was opened")
    case .offerSelfEmployment:
      settingUpSelfEmployment = true
    default:
      return
    }
    message = nil
  }

  /// «Esc» and the close button at the end of the row of the kinds.
  private var panelCloseCluster: some View {
    HStack(spacing: 8) {
      Text(verbatim: "Esc")
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      closeButton
    }
  }

  /// A plain button: the panel is glass already, and glass is never put on glass.
  private var closeButton: some View {
    Button(action: closeDetails) {
      Image(systemName: "xmark")
    }
    .buttonStyle(.borderless)
    .help(environment.language("action.close"))
    .accessibilityLabel(Text(verbatim: environment.language("action.close")))
    .accessibilityIdentifier("entry.details.close")
  }

  private func toggleDetails() {
    if showsDetails {
      closeDetails()
    } else {
      prepareModel()
      withAnimation(.snappy) { showsDetails = true }
    }
  }

  /// «+» in the toolbar and ⌘N: a new operation.
  ///
  /// Asking for the focus was all this used to do, and the line holds that focus already —
  /// the bar takes it the moment it appears, and a click on a toolbar button does not take
  /// it away. A `@FocusState` set to the value it already holds changes nothing, so «+» drew
  /// nothing at all and the owner reported a dead button (21.09). A new operation therefore
  /// opens the ↓ panel — the same whole form ↓ opens — which is something to see.
  ///
  /// Opened, never toggled: ⌘N twice in a row must not close the form it just opened.
  ///
  /// The focus is asked for twice, the way ⌘F asks for the search field
  /// (`OperationsScreen.takeSearchFocus`): a click on a toolbar can move the first
  /// responder on its way in, after the action has already run.
  private func startNewOperation() {
    message = nil
    prepareModel()
    // The form is always open: a new operation puts the keyboard on its first field.
    if style == .form {
      // An operation being edited in the form gives way to the new one.
      if editing != nil { stopEditing() }
      // The quick line over the fields, asked through the panel's own focus.
      model?.focusRequest = .control(.quick)
      return
    }
    if !showsDetails { withAnimation(.snappy) { showsDetails = true } }
    focused = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      focused = true
    }
  }

  /// Tab and Shift-Tab of the line: into the panel. Tab opens a closed panel on its first field;
  /// Shift-Tab with the panel closed is not ours.
  private func tab(_ key: KeyPress) -> KeyPress.Result {
    let backwards = key.key == PanelTabOrder.backTab || key.modifiers.contains(.shift)
    if !showsDetails {
      guard !backwards else { return .ignored }
      prepareModel()
      withAnimation(.snappy) { showsDetails = true }
    }
    guard let model else { return .ignored }
    model.focusRequest = backwards ? .last : .first
    return .handled
  }

  private func press(_ key: DetailsPanelKey) -> KeyPress.Result {
    // Esc on the phone's line, the panel closed: the line goes away with its keyboard.
    if key == .escape, let phone, !showsDetails {
      phone.gate.send(.escaped)
      return .handled
    }
    // While Enter's stop for a category stands, ↓ and ↑ choose in the menu it asked for: the
    // panel is open already, and without «Навигация с клавиатуры» the focus never reaches a menu.
    if showsDetails, key != .escape, let model,
      model.stepTheAskedMenu(by: key == .down ? 1 : -1, today: environment.today)
    {
      return .handled
    }
    // ↓ is the list's: it walks the operations from the newest and leaves the panel as it is.
    if key == .down {
      NotificationCenter.default.post(name: .walkOperationsList, object: nil)
      return .handled
    }
    let outcome = key.outcome(showing: showsDetails)
    guard outcome.handled else { return .ignored }
    if !outcome.showing { closeDetails() }
    return .handled
  }

  /// Closing only hides the panel: the draft stays for the next ↓, and typing goes on in
  /// the line.
  private func closeDetails() {
    // The form has no line to go back to, and nothing to close.
    guard style == .line else { return }
    withAnimation(.snappy) { showsDetails = false }
    focused = true
  }

  /// The panel is closed over a draft whose choices the next line will keep (Esc keeps the
  /// draft): the ↓ button shows a dot.
  private var carriesChoices: Bool {
    !showsDetails && (model?.carriesChoices ?? false)
  }

  /// What the line currently comes to, shown above the capsule while it is being typed.
  /// Only a formula is worth showing, a number not written the way the app writes numbers —
  /// «1500,5 = 1,500.50 ₽», «0,500 = 0.50 ₽» — and a point that may be taken for thousands,
  /// «1.500 = 1.50 ₽». A plain «250» or «1,500» already reads as itself.
  private var preview: String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let parsed = interpreter.interpret(trimmed, today: environment.today)
    if let transfer = parsed.transfer { return transferPreview(transfer, parsed) }
    // An amount in another currency: grey «≈ 1,240 ₽» at the last rate, before Enter.
    if parsed.amountToPreview == nil, let amount = parsed.amount, let currency = parsed.currency,
      let value = try? AmountE4(decimal: amount),
      let approximate = ApproximateText.of(
        amount: value, currency: currency, environment: environment, compute: compute)
    {
      return environment.money.exact(value, currency: currency) + " " + approximate
    }
    guard let expression = parsed.amountToPreview, let amount = parsed.amount,
      let value = try? AmountE4(decimal: amount)
    else { return nil }
    let currency = EntryPreview.currency(of: parsed, model: model, in: environment)
    return "\(expression) = \(environment.money.exact(value, currency: currency))"
  }

  /// «Перевод: Сбер → Т-Банк, 5,000 ₽» — a side no account answers to is «?».
  private func transferPreview(_ transfer: TransferReading, _ parsed: ParsedInput) -> String {
    Self.transferPreview(
      transfer, amount: parsed.amount.flatMap { try? AmountE4(decimal: $0) },
      currency: EntryPreview.currency(of: parsed, model: model, in: environment),
      accounts: model?.paymentMethods ?? [], environment: environment)
  }

  /// The words over the line for a transfer it names, from the accounts and the amount read.
  static func transferPreview(
    _ transfer: TransferReading, amount: AmountE4?, currency: CurrencyCode,
    accounts: [PaymentMethod], environment: AppEnvironment
  ) -> String {
    func name(_ id: UUID?) -> String {
      accounts.first { $0.id == id }?.name ?? "?"
    }
    var text =
      environment.language("entry.transfer.preview", table: "Entry") + " "
      + "\(name(transfer.fromAccountId)) → \(name(transfer.toAccountId))"
    if let amount {
      text += ", " + environment.money.exact(amount, currency: currency)
    }
    return text
  }

  /// The line read into the open panel at every change of it: the amount, the currency, the
  /// date, the place and the words show there, and the chips under «Категория» follow them —
  /// before Enter, which reads the line again and saves. What the owner chose in the panel
  /// itself stays over the line (`EntryDraftModel.apply`). A line that cannot be read yet — an
  /// unfinished formula, a day the calendar does not have — leaves the panel as it is: Enter says
  /// what is wrong with it.
  private func readTheLineIntoThePanel() {
    guard showsDetails, let model else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let reading = interpreter.read(trimmed, today: environment.today, kind: model.draft.kind)
    let parsed = reading.parsed
    guard parsed.dateProblem == nil, reading.timeProblem == nil else { return }
    // The panel holds a transfer: the line fills its fields.
    if let transfer = model.transfer {
      take(reading, into: transfer, model: model)
      return
    }
    var amount = model.draft.amount
    if let typed = parsed.amount {
      guard let read = try? AmountE4(decimal: typed) else { return }
      amount = read
    }
    // The quick line of the form reads as the entry line does: history and the category model
    // file what it says, while the fields typed by hand in the form stay the owner's alone.
    let assisted = model.assisted
    if style == .form { model.assisted = true }
    defer { model.assisted = assisted }
    model.retractRules()
    model.apply(
      reading, amount: amount, today: environment.today, text: trimmed, whileTyping: true)
    model.applyRules(
      compute.snapshot?.dataset.rules ?? [], lineTags: TagText.extract(from: trimmed).tags,
      calendar: environment.calendar)
  }

  private func prepareModel() {
    guard model == nil else { return }
    let model = EntryDraftModel(environment: environment)
    model.assisted = style.assists
    model.reload()
    self.model = model
  }

  private func save() {
    // Return may reach the save twice — the field's own action and the default button — and a
    // held Return repeats: one keystroke is one save.
    #if os(macOS)
      let event = NSApp.currentEvent
      let isRepeat = event?.type == .keyDown && event?.isARepeat == true
    #else
      let isRepeat = false
    #endif
    guard returnGate.admits(now: ProcessInfo.processInfo.systemUptime, isRepeat: isRepeat) else {
      return
    }
    // In the question mode Enter asks and never writes, whatever the line says.
    if QuestionLineGuard.action(for: questions.mode) == .askQuestion {
      askTheQuestion()
      return
    }
    saveTheLine()
  }

  /// The line is a question: it is answered from the data and stays in the line.
  private func askTheQuestion() {
    questions.ask(text, compute: compute)
  }

  /// The button of the question mode. Switched on, the ↓ panel closes and the next Enter asks.
  private func toggleQuestionMode() {
    questions.toggle()
    if questions.isActive {
      withAnimation(.snappy) { showsDetails = false }
      message = nil
    }
    focused = true
  }

  /// In the entry mode, a line that reads like a question offers the question mode. It only
  /// asks: the line is never taken for a question by its words.
  @ViewBuilder
  private var questionNudge: some View {
    if !showsDetails,
      QuestionLineGuard.offersQuestionMode(text: text, mode: questions.mode)
    {
      Button {
        toggleQuestionMode()
      } label: {
        Label {
          Text(verbatim: QuestionsText.t("questions.nudge", environment))
        } icon: {
          Image(systemName: "questionmark.bubble")
        }
      }
      .buttonStyle(.link)
      .appFont(.caption)
      .padding(.horizontal, captionInset)
      .accessibilityIdentifier("entry.question.nudge")
    }
  }

  /// The save of the line, past the gate of the keystroke: Return, a click, and the next part of
  /// a line with «;», which is no keystroke at all.
  private func saveTheLine() {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    prepareModel()
    guard let model else { return }

    // A correction («ой, 350»), «повторить вчера», a line of several operations («кофе 250;
    // метро 62») or a bill with a tip is answered by quick entry before the line is read.
    if !trimmed.isEmpty, model.transfer == nil {
      switch fast.intercept(trimmed, environment: environment, compute: compute) {
      case .handled:
        return
      case .proceed(let line, let replacesText):
        trimmed = line
        if replacesText { text = line }
      }
    }

    // A transfer left behind the closed panel of the line — Esc, a question not answered — goes:
    // the line is read afresh, «кофе 300» as an expense, «перевод …» as a transfer of its own.
    if model.transfer != nil, style == .line, !showsDetails {
      model.transfer = nil
    }
    // The panel holds a transfer: Return saves it, as it saves an operation.
    if let transfer = model.transfer {
      saveTheTransfer(transfer, line: trimmed, model: model)
      return
    }

    // An empty line with the panel open saves whatever the panel holds, or says why not.
    if trimmed.isEmpty {
      guard showsDetails else { return }
      if let refusal = model.saveRefusalKey {
        message = .error(refusal)
        return
      }
      commit(model)
      return
    }

    let reading = interpreter.read(trimmed, today: environment.today, kind: model.draft.kind)
    let parsed = reading.parsed
    // A day the calendar does not have, or a time no clock shows, is what was typed wrong: said
    // before anything else.
    if let problem = parsed.dateProblem {
      message = .date(problem)
      return
    }
    if let problem = reading.timeProblem {
      message = .time(problem)
      return
    }
    // A line of words alone, with the panel open over an amount, saves that amount: Return saves
    // what the panel shows. A number in the line that does not read is refused all the same.
    let takesThePanelAmount =
      parsed.amount == nil && parsed.amountProblem == nil && showsDetails
      && model.draft.amount.raw > 0
    guard parsed.amount != nil || takesThePanelAmount else {
      message = .error(parsed.missingAmountErrorKey)
      return
    }

    do {
      let amount = try parsed.amount.map { try AmountE4(decimal: $0) } ?? model.draft.amount
      model.retractRules()
      fast.collapseTip(on: model)
      model.apply(reading, amount: amount, today: environment.today, text: trimmed)
      model.applyRules(
        compute.snapshot?.dataset.rules ?? [], lineTags: TagText.extract(from: trimmed).tags,
        calendar: environment.calendar)
      fast.applyTip(to: model, environment: environment)
      // «перевод 5000 сбер т-банк» is a transfer, not an operation: written at once when both
      // accounts are known in one currency, else left in the fields of a transfer to finish.
      if let transfer = parsed.transfer {
        startTransfer(fromTheLine: transfer, model: model)
        return
      }
      if let refusal = model.saveRefusalKey {
        message = .error(refusal)
        return
      }
      commit(model)
    } catch CoreError.divisionByZero {
      message = .error("entry.error.divisionByZero")
    } catch CoreError.amountOutOfRange {
      message = .error("entry.error.amountTooLarge")
    } catch {
      message = .error("entry.error.badExpression")
    }
  }

  private func templateLine(for template: Template) -> String {
    prepareModel()
    return Templates.line(
      for: template, categories: (model?.categories ?? []) + (model?.archivedCategories ?? []),
      in: environment, model: model)
  }

  /// Nothing the owner typed is thrown away unless the operation really reached the
  /// database: a failed write used to look exactly like a successful one — the line cleared
  /// itself, the panel closed, and there was no operation.
  ///
  /// `askingForGaps`: a line that did not say the category — or whose subcategory the model
  /// left open — stops once and opens the panel on that field (`gapToAsk`); false where the
  /// owner has just confirmed a form.
  private func commit(_ model: EntryDraftModel, askingForGaps: Bool = true) {
    // A date nobody chose is now, not when the draft was made; first, so the
    // rate is the one of the day the operation lands on.
    model.takeTheMomentOfSaving()
    // Asked again on every way into the save — after the picker of purchases, after the
    // question about the count, after the confirmation of money back: what they changed may
    // stop it (a purchase whose account needs «Списано со счёта» typed). The panel opens on
    // a reason it shows.
    if let refusal = model.saveRefusalKey {
      message = .error(refusal)
      if model.shownRefusalKey != nil, !showsDetails {
        withAnimation(.snappy) { showsDetails = true }
      }
      return
    }
    // A refund first says which purchase it takes money back from — or that it has none.
    if model.needsRefundPurchase {
      message = nil
      refundRequest = RefundPickerRequest(savesAfterChoice: true)
      return
    }
    // The line did not say where the money goes: nothing is saved yet, the panel opens on the
    // field, marked, and the next Return saves the operation as it stands then.
    if askingForGaps, let gap = model.gapToAsk() {
      message = .gap(gap)
      model.focusRequest = .control(gap == .category ? .category : .subcategory)
      if !showsDetails { withAnimation(.snappy) { showsDetails = true } }
      kindChosen = true
      AppLog.info(
        "entry.gapAsked", .ui, "Enter asked for a field before saving",
        [LogPair("field", .token(gap.rawValue))])
      return
    }
    // A date after today: a record, or a plan of Planning's? Asked once.
    if askingForGaps, let plan = model.planAhead(today: environment.today) {
      aheadQuestion = AheadQuestion(
        plan: plan, day: environment.calendar.day(of: model.draft.occurredAt))
      AppLog.info(
        "entry.aheadAsked", .ui, "an operation dated ahead was asked about",
        [LogPair("plan", .token("\(plan)"))])
      return
    }
    // What was written a moment ago with the same amount is shown before it is written again.
    if askingForGaps, let same = model.repeatedOperation() {
      repeatQuestion = RepeatQuestion(entry: same)
      AppLog.info("entry.repeatAsked", .ui, "a repeat of an operation just written was asked about")
      return
    }
    // Dated on the day of counts of its balances and saved after them: whether its money was
    // already counted is asked about each count of the day, oldest first, before anything is
    // written. An answer remembered for a count («Больше не спрашивать для этой сверки») is used
    // without a question.
    switch model.countAsk(
      savedAt: Date(), balances: compute.snapshot?.planning.accounts.balances ?? .empty,
      remembered: environment.rememberedCountAnswers())
    {
    case .none:
      break
    case .answered(let stamp):
      model.stampCount(stamp)
    case .ask(let questions):
      countQuestion = BeforeTheCountQuestion(
        count: questions.count, reconciliation: questions.reconciliation, questions: questions)
      return
    }
    // A payment of a loan above what its due asks: the bank shortens the term or lowers the
    // payment, or it pays the next dues ahead, and the line says which (`DebtPrepayment`). Asked once; the answer of the last
    // time comes first.
    if askingForGaps, model.prepayChoice == nil, let question = prepayQuestion(for: model) {
      prepayQuestion = question
      AppLog.info("entry.prepayAsked", .ui, "a payment above its due was asked about")
      return
    }
    // A thing bought in instalments, returned: the bank lowers the debt or pays to the card —
    // the sheet asks, and writes it.
    if let plan = model.instalmentPlanOfTheRefund {
      do {
        instalmentReturn = InstalmentReturnRequest(
          refund: try EntrySave.refundEntry(model, environment: environment), debt: plan)
        message = nil
      } catch {
        message = .error(EntryCommit.errorKey(of: error))
      }
      return
    }
    // Money back from a person closes parts, and which ones the confirmation shows: nothing
    // is written here. Its rate and what the account received are worked out there.
    if model.recordsThroughReimbursementSheet {
      message = nil
      // Laid as a save lays it, which also asks the bank for the rate of the day when the cache
      // has none yet: the confirmation works it out again once it came.
      var money = model.draftForSaving
      environment.applyRate(to: &money)
      moneyBack = MoneyBackPrefill(draft: money)
      return
    }
    do {
      guard let written = try EntrySave.write(model, environment: environment, store: store)
      else {
        message = .error("entry.error.notSaved")
        return
      }
      CategoryLearning.saved(
        written.entry, choice: model.categoryChoice(), environment: environment)
      attachTags(to: written.entry, model: model)
      if written.openedCredit != nil || written.paidDebt != nil { model.reload() }
      // A debt opened by this purchase is a name the line should know next time.
      if written.openedCredit?.isNew == true { environment.refreshVocabulary() }
      templates.remember(model.draft, categories: model.categories + model.archivedCategories)
      let notice = EntryAfterSaving.notice(
        for: written.entry, saidSelfEmployed: model.lineSaysSelfEmployed,
        tree: model.categoryTree, selfEmployment: selfEmploymentSettings(),
        allocation: compute.snapshot?.dataset.allocationSettings ?? .standard,
        money: environment.money)
      if notice == .offerSelfEmployment { SelfEmploymentOfferSheet.markOffered(environment) }
      finishSaving(model, then: notice)
    } catch {
      message = .error(EntryCommit.errorKey(of: error))
    }
  }

  /// The question of a payment above its due, when there is one to ask (`DebtPrepayment`).
  private func prepayQuestion(for model: EntryDraftModel) -> PrepayQuestion? {
    guard let debt = model.debtBeingPaid, debt.currency == model.draft.currency else { return nil }
    let snapshot = compute.snapshot
    let dues = snapshot?.planning.debts.iOwe.first { $0.debt.id == debt.id }?.dues
    let journal =
      (try? environment.references?.debtEntries(debtId: debt.id))
      ?? snapshot?.dataset.planning.debtEntries.filter { $0.debtId == debt.id } ?? []
    guard
      let asked = DebtPrepayment.question(
        debt: debt, amount: model.draft.amount,
        day: environment.calendar.day(of: model.draft.occurredAt), dues: dues, journal: journal)
    else { return nil }
    return PrepayQuestion(excess: asked.excess, currency: debt.currency, suggested: asked.choice)
  }

  /// Self-employment as the database has it now: whether it is on and whether it was offered.
  private func selfEmploymentSettings() -> SelfEmploymentSettings {
    var values: [String: String] = [:]
    for key in [SelfEmploymentSettings.enabledKey, SelfEmploymentSettings.offeredKey] {
      if let value = (try? environment.settings?.string(key)) ?? nil { values[key] = value }
    }
    return SelfEmploymentSettings(storedValues: values)
  }

  /// The operation went in — here, or in the reimbursement sheet: the line, the panel and the
  /// draft start over.
  private func finishSaving(_ model: EntryDraftModel, then notice: EntryLineMessage? = nil) {
    // A date picker of the form that kept the keyboard gives it up before the draft starts over:
    // still editing, it would hand the last operation's moment back to the fresh draft as it
    // lets go.
    #if os(macOS)
      if style == .form, let window = NSApp.keyWindow, window.firstResponder is NSDatePicker {
        window.makeFirstResponder(nil)
      }
    #endif
    model.reset()
    // The draft this line was finished from is done; the next part of a «;» line is next.
    fast.drafts.lineWritten()
    fast.tip = nil
    if fast.bank?.reconcileAfter == true { fast.showsReconcile = true }
    fast.bank = nil
    // A rating just given by hand is history now (rule 2 of the qualities): the next
    // operation described the same way should find it.
    model.reload()
    text = ""
    message = notice
    // The form stays open over a fresh draft, with the defaults laid as they are when a panel
    // opens; the line's panel closes.
    if style == .form {
      model.prepareForPanel(today: environment.today)
      // The next operation starts from the kinds, the keyboard in the quick line.
      kindChosen = false
      quick.dismiss()
      model.focusRequest = .control(.quick)
    } else {
      withAnimation(.snappy) { showsDetails = false }
    }
    // The field of the panel that had the focus — Return in it, or «Save» clicked while it
    // was being typed in — goes with the panel: without this the window kept no first
    // responder and the next line was typed into nothing. `closeDetails` does the same.
    // On the phone the written line goes away (but for the next part of a «;» line).
    focused = phone == nil || fast.hasNextPart
    if let phone, !fast.hasNextPart { phone.gate.send(.saved) }
    // The next part of a line with «;» goes on where this one ended, once the bar has settled
    // (a run-loop timer, which a window under test serves like the app does).
    if let next = fast.nextPart() {
      text = next
      Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
        MainActor.assumeIsolated { saveTheLine() }
      }
    }
  }

  /// «Исправить» under «ой, 350»: the corrected operation is written, the line is cleared.
  private func applyTheCorrection() {
    if fast.applyCorrection(environment: environment, store: store) { text = "" }
    focused = true
  }

  /// The chips come in the order of the owner's habits: what he writes at this hour on this day
  /// of the week comes first, the pinned ones before all.
  private func arrangeTheChips() {
    templates.ordering = { [environment, compute] templates in
      guard let snapshot = compute.snapshot else { return templates }
      return HabitOrdering.ordered(
        templates, history: QuickSuggest.habits(of: snapshot.dataset.entries),
        now: environment.now(), calendar: environment.calendar)
    }
    templates.reload()
  }
}

extension Notification.Name {
  static let focusEntryLine = Notification.Name("io.github.EvgenyBaulin.ohmymoney.focusEntryLine")
}

/// The write of the entry line, once nothing is left to ask: the rate of the day, what the
/// account was charged, the operation and everything it moves — a debt opened for it, the line of
/// a debt it pays, the income over a debt owed to me, the link to an expected income — in one
/// write, so one ⌘Z takes all of it back.
@MainActor
enum EntrySave {
  /// What went in.
  struct Written {
    var entry: TransactionEntry
    /// The debt a purchase on credit opened or joined.
    var openedCredit: (debt: Debt, isNew: Bool)?
    /// The debt the operation pays or grows.
    var paidDebt: Debt?
  }

  /// Writes the draft of `model`. `nil` when the database did not take the write; a throw
  /// when the draft cannot be written as it is (`EntryCommit.errorKey` words it).
  static func write(
    _ model: EntryDraftModel, environment: AppEnvironment, store: TransactionsStore
  ) throws -> Written? {
    // A refund of a purchase keeps the purchase's rate: `applyRate` leaves it alone.
    environment.applyRate(to: &model.draft)
    // «Списано со счёта» follows the rate the save has just laid.
    model.refreshCharge()
    // The conversion is tried before anything is written, so a missing rate cannot leave
    // a debt behind that nothing bought. A refund of a purchase is in the purchase's rubles,
    // checked against what is left of it now.
    let convert =
      model.refundTarget == nil
      ? environment.rublesConverter(for: model.draft)
      : try model.refundRubles(index: model.refundIndexNow())
    _ = try convert(model.draft.amount)
    var credit = openCreditIfNeeded(model, environment: environment)
    // What the kind has no field for stays out of what is written.
    let entry = try model.draftForSaving.materialize(rublesConverter: convert)
    // «Рассрочка частями»: the plan is made from the purchase as written — the price and the
    // markup in its first line, the parts and their days in the debt (`InstalmentPlan.make`).
    var openingLine: DebtEntry?
    if let opened = credit, opened.isNew,
      let plan = model.instalmentPlan(
        for: entry, name: opened.debt.name, calendar: environment.calendar)
    {
      credit = (plan.debt, true)
      openingLine = plan.line
    }
    let paidDebt = model.debtPaid(by: entry)
    let repayment = repaymentSetting(of: paidDebt, by: entry, environment: environment)
    let saved: Bool
    if let change = try EntryCommit.change(
      entry: entry, openedCredit: credit?.debt, creditIsNew: credit?.isNew ?? false,
      paidDebt: paidDebt, expectedIncomeId: model.expectedIncomeId,
      day: environment.calendar.day(of: model.draft.occurredAt),
      paidDebtBalance: repayment?.balance, surplus: repayment?.surplus,
      closesTerm: model.closesDebtTerm, openingLine: openingLine)
    {
      // A payment of a loan that accrues interest writes the interest it pays as an operation of
      // its own in «Кредиты», in the same change; a payment of an instalment plan, its markup.
      var parted = DebtInterestPayment.parting(change, paying: paidDebt, environment: environment)
      // A payment above its due was answered: a shorter term, a smaller payment, or ahead.
      if let paidDebt {
        parted = DebtPrepayment.marking(parted, debt: paidDebt, choice: model.prepayChoice)
      }
      if openingLine != nil {
        AppLog.info(
          "debts.instalment.created", .db, "a purchase was bought in instalments",
          [LogPair("parts", .count(credit?.debt.parts ?? 0))])
      }
      saved = store.apply(parted)
    } else {
      saved = store.save(entry)
    }
    guard saved else { return nil }
    return Written(entry: entry, openedCredit: credit, paidDebt: paidDebt)
  }

  /// The refund the draft of `model` writes, as `write` would make it — the rate of the day,
  /// what the account received, the rubles of the purchase — without writing it: the sheet of a
  /// thing bought in instalments writes it, split as the owner says (`InstalmentReturnSheet`).
  static func refundEntry(
    _ model: EntryDraftModel, environment: AppEnvironment
  ) throws -> TransactionEntry {
    environment.applyRate(to: &model.draft)
    model.refreshCharge()
    let convert = try model.refundRubles(index: model.refundIndexNow())
    _ = try convert(model.draft.amount)
    return try model.draftForSaving.materialize(rublesConverter: convert)
  }

  /// Money given back on a debt owed to me follows the one rule of repayments
  /// (`DebtRules.repayment`), as the debt's own form and the money-back sheet do: the journal
  /// takes what is left of the debt as it is read now, the debt closes once it is covered, and
  /// what came back above it is income in «Доплаты» — without that category the save is refused.
  /// Only money back: an income that names such a debt is income already, all of it, and a
  /// surplus written beside it would count its money twice — it pays the debt as it always did.
  static func repaymentSetting(
    of debt: Debt?, by entry: TransactionEntry, environment: AppEnvironment
  ) -> (balance: AmountE4, surplus: EntryCommit.SurplusSetting)? {
    guard let debt, debt.direction == .owedToMe, entry.transaction.kind == .reimbursement,
      let references = environment.references,
      let journal = try? references.debtEntries(debtId: debt.id)
    else { return nil }
    let surcharges = (try? references.category(systemRole: .surcharges, kind: .income))?.id
    return (
      DebtRules.balance(entries: journal),
      EntryCommit.SurplusSetting(
        categoryId: surcharges,
        note: environment.language("reimbursement.surplus", table: "Entry"))
    )
  }

  /// "On credit" means the expense is recorded once, now, and the debt grows by the same
  /// amount; later payments only reduce the debt, so nothing is counted twice.
  ///
  /// Only a purchase has a plan to open with (`EntryDraftModel.offersCredit`). A plan left on
  /// an income or a refund is refused before this (`saveRefusalKey`), and is handed on all the
  /// same should it get here: `EntryCommit` refuses it with a reason rather than saving the
  /// operation without the debt the owner asked for, or with one nothing bought.
  private static func openCreditIfNeeded(
    _ model: EntryDraftModel, environment: AppEnvironment
  ) -> (debt: Debt, isNew: Bool)? {
    guard let plan = model.creditPlan else { return nil }

    if let chosen = plan.debtId, let existing = model.debts.first(where: { $0.id == chosen }) {
      model.draft.creditDebtId = existing.id
      return (existing, false)
    }

    // An instalment plan: the debt is made once the purchase is (`EntryDraftModel.instalmentPlan`),
    // under the id the purchase points at now.
    if plan.instalments {
      let debt = Debt(
        direction: .iOwe, type: .installment,
        name: model.draft.note ?? environment.language("entry.instalments.name", table: "Entry"),
        currency: model.draft.currency, paymentsAreExpenses: false, origin: .purchase,
        parts: plan.payments, termsReviewed: true)
      model.draft.creditDebtId = debt.id
      return (debt, true)
    }

    // A debt of its own for this purchase: its payments are not expenses, because the
    // expense is this very operation. It is written with the purchase, not before it.
    // The count of payments chosen is in the instalment: a debt is paid off in ⌈balance ÷
    // monthly payment⌉ months, and keeps no term of its own.
    let debt = Debt(
      direction: .iOwe,
      type: .installment,
      name: model.draft.note ?? environment.language("entry.onCredit", table: "Entry"),
      currency: model.draft.currency,
      monthlyPaymentE4: plan.monthlyAmount.isZero ? nil : plan.monthlyAmount,
      paymentsAreExpenses: false,
      origin: .purchase,
      // A debt made in 1.9 has nothing to be asked about later (`DebtReview`).
      termsReviewed: true)
    model.draft.creditDebtId = debt.id
    return (debt, true)
  }
}

/// What a key of the entry line does to the ↓ panel, apart from the view so a test reads it
/// without a window: ↓ is the list's — it walks the operations from the newest and leaves the
/// panel as it is —, ↑ and Esc close an open panel (the draft stays), and with the panel closed
/// ↑ and Esc are not ours and go on to whatever else wants them. The × of the panel and Esc
/// inside it close it the same way (`closeDetails`).
/// When the bar saves («Сохранение — Enter»): a line to read, or the ↓ panel open. «Save» is
/// active exactly then, and Return — in the line, or anywhere in the open panel — saves the
/// same way (`EntryBar.save`), with the save or with the reason there is none: a Return that
/// does nothing is what the owner reported.
enum EntrySaving {
  static func isOffered(line: String, showsDetails: Bool) -> Bool {
    showsDetails || !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// One keystroke, one save. AppKit may hand one Return both to a text field's action and to
  /// the default button, and a held Return repeats; a refused save must still be retried by the
  /// next Return, so a flag cannot do this.
  struct ReturnGate {
    /// Seconds within which a second request is the same keystroke handed over twice. A person
    /// presses Return again no sooner than a fifth of a second later.
    static let window: TimeInterval = 0.15
    private(set) var lastAdmitted: TimeInterval?

    /// `now`: `ProcessInfo.processInfo.systemUptime`; `isRepeat`: the key event is an
    /// auto-repeat of a held key (false for a click, or a save asked by code).
    mutating func admits(now: TimeInterval, isRepeat: Bool) -> Bool {
      guard !isRepeat else { return false }
      if let lastAdmitted, now - lastAdmitted < Self.window, now >= lastAdmitted { return false }
      lastAdmitted = now
      return true
    }
  }
}

enum DetailsPanelKey {
  case down, up, escape

  func outcome(showing: Bool) -> (showing: Bool, handled: Bool) {
    switch self {
    case .down: (showing, true)
    case .up, .escape: showing ? (false, true) : (false, false)
    }
  }
}

/// The preview above the entry line.
enum EntryPreview {
  /// The currency the save gives a line, for the preview above it. With the line's panel it is
  /// the panel's own answer (`EntryDraftModel.currencyOnSaving`), which follows the save step by
  /// step. Without one — before the line made its panel — a fresh draft would save: the one
  /// typed; else the main currency of the account the line names; else the one the line reads
  /// an amount without a code in — the currency of the account whose screen is open, or the
  /// default one.
  @MainActor static func currency(
    of parsed: ParsedInput, model: EntryDraftModel?, in environment: AppEnvironment
  ) -> CurrencyCode {
    if let model { return model.currencyOnSaving(parsed) }
    if let typed = parsed.currency { return typed }
    if let named = parsed.paymentMethodId,
      let account = ((try? environment.references?.paymentMethods()) ?? nil)?
        .first(where: { $0.id == named })
    {
      return account.mainCurrency
    }
    return Templates.lineCurrency(in: environment)
  }
}
