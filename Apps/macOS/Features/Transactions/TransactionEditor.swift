import AppCore
import Observation
import SwiftUI

/// One saved operation being edited: the ↓ panel's model bound to it, what it was when the
/// editing began, and what the editor has to say — an error, a deletion waiting for the
/// owner's word. The edit sheet of the main window and the inspector of the Transactions
/// window hold one each.
@MainActor
@Observable
final class TransactionEditorModel {
  /// The operation as it was when the editing began.
  let entry: TransactionEntry
  /// What names it in the table: the head of the inspector.
  let title: RowTitle
  let draft: EntryDraftModel
  /// The draft as the panel first showed it: anything else is an unsaved change.
  private let baseline: TransactionDraft
  var errorKey: String?
  /// Deleting asks first, the same question the list asks.
  var confirmation: BulkConfirmation?
  /// «Это было до сверки в 14:05?», waiting for the owner's answer before the save goes on.
  var countQuestion: BeforeTheCountQuestion?
  /// What the edit would leave on an account in the archive, waiting for where it goes: the
  /// save goes on with the transfers the owner picks (`save(…, settling:)`).
  var archivedLeftovers: ArchivedMoneyCheck?
  /// The balances of the accounts as the window showing this editor has them now, read by a
  /// save that is handed none: «Save» in the questions the Transactions window asks when
  /// another operation is opened or the inspector is folded away. Set while the editor is
  /// on screen, so those saves ask about a count as the button does.
  @ObservationIgnored var balancesNow: (@MainActor () -> AccountBalances)?
  /// «Выйдет за лимит карты» or «Остаток станет ниже минимума», waiting for «Записать всё
  /// равно» before an edit that makes either worse is saved (`save`, `answerSaveQuestion`).
  var saveQuestion: EntrySaveQuestions.Question?
  /// The cards and balances of the window showing this editor, read by a save that is handed
  /// none, the way `balancesNow` is. Nil for an editor no window shows: it asks nothing.
  @ObservationIgnored var moneyNow: (@MainActor () -> EntrySaveQuestions.Money)?

  /// The operation being edited.
  var id: UUID { entry.id }

  /// `tree` names the operation by its category when it has no description.
  convenience init(
    entry: TransactionEntry, environment: AppEnvironment, tree: CategoryTree = CategoryTree()
  ) {
    self.init(
      entry: entry, draft: EntryDraftModel(environment: environment, editsSavedOperation: true),
      tree: tree)
  }

  /// The editor over a panel made elsewhere — one that edits a saved operation
  /// (`editsSavedOperation`); it is loaded and set to the operation here.
  init(entry: TransactionEntry, draft: EntryDraftModel, tree: CategoryTree = CategoryTree()) {
    self.entry = entry
    self.title = RowTitle.of(entry, tree: tree)
    draft.reload()
    draft.draft = TransactionDraft(entry: entry)
    self.draft = draft
    self.baseline = draft.draft
    draft.rememberSaved(entry)
  }

  /// Something was changed and not saved yet: switching to another operation asks first.
  var hasChanges: Bool { draft.draft != baseline }

  /// What becomes of the editor when the data under it changes.
  enum Follow: Equatable {
    /// It stays as it is.
    case stay
    /// The operation is gone and nothing was typed: nothing is left to edit.
    case close
    /// Changed elsewhere while nothing was typed: an editor of the operation as it is now
    /// takes this one's place, so a save cannot bring the old version back.
    case reopen(TransactionEntry)
  }

  /// Follows the operation as the data has it now — `nil` once it is gone. An edit typed and
  /// not saved is never thrown away here: an operation deleted meanwhile (⌘Z of its creation,
  /// a bulk deletion) leaves the edit in place with the reason it cannot be saved, and the
  /// reason goes again when the operation comes back (⌘Z of the deletion). «Save» lays the
  /// edit over the operation as it is then (`TransactionsStore.saveEdit`).
  func follow(_ fresh: TransactionEntry?) -> Follow {
    guard hasChanges else {
      guard let fresh else { return .close }
      return fresh == entry ? .stay : .reopen(fresh)
    }
    if fresh == nil {
      errorKey = Self.goneKey
    } else if errorKey == Self.goneKey {
      errorKey = nil
    }
    return .stay
  }

  /// «The operation has been deleted, so the changes were not saved».
  private static let goneKey = "entry.error.gone"

  /// Whether «Save» can be pressed: the draft keeps the rules of the panel
  /// (`EntryDraftModel.saveRefusalKey`), and no large write is landing — it may be deleting
  /// this very operation, and a save queued in front of it would leave a step of ⌘Z above the
  /// deletion that brings the operation back («Delete…» waits for it too).
  func canSave(in store: TransactionsStore) -> Bool {
    draft.canSave && !store.isWritingInBackground
  }

  /// Saves the edit. The editor stays open when the change did not land: closing it would
  /// look exactly like saving, and the edit would be gone.
  ///
  /// Every way to save goes through here — the button, and «Save» in the question asked
  /// when another operation is opened — so the rule of the button is checked here as well.
  /// The edit is laid over the operation as it is now (`TransactionsStore.saveEdit`).
  ///
  /// An edit that moves the money to another day, account or currency and lands it on the day
  /// of the latest count of that account, after the count, asks first whether it was before
  /// the count (`countQuestion`, answered through `answerCount`); `balances` are the accounts'
  /// as the data has them — when none are handed in, those of the window showing the editor
  /// (`balancesNow`) — and `now` the moment of the save. Nothing is written until then. Money
  /// back asks too: its day and account can be edited, only its amount, type and currency
  /// stay.
  ///
  /// A refund taken back from a purchase keeps the purchase's rate, and the rubles it stores
  /// follow the purchase part (`RefundRules.rubles`): taking back the rest of the part stores
  /// the rest of its rubles exactly.
  ///
  /// Every count of that day is asked about in turn, oldest first; an answer kept with
  /// «Больше не спрашивать для этой сверки» answers its count without a question.
  ///
  /// An edit that would leave money on an account in the archive, or take it below its count,
  /// asks first where the money goes (`archivedLeftovers`); the save goes on with `settling`,
  /// the transfers that keep that account at zero, written with the edit in one step of ⌘Z.
  /// A comment, a category or any edit that moves no money is saved without asking.
  ///
  /// An edit that makes spending on a credit card pass its limit, or an account fall below the
  /// balance its bank asks to keep, asks the question a new operation asks (`saveQuestion`,
  /// `EntrySaveQuestions`) — only when the edit itself makes it worse than the saved operation
  /// was: a larger amount, another card, a later day that now counts. A description, a
  /// category, a smaller amount or an account already past the line asks nothing. `money` are
  /// the cards and balances as the data has them — none handed in, those of the window
  /// (`moneyNow`).
  func save(
    store: TransactionsStore, environment: AppEnvironment, balances: AccountBalances? = nil,
    money: EntrySaveQuestions.Money? = nil,
    now: Date = Date(), settling: [Transfer]? = nil
  ) -> Bool {
    if let refusal = draft.saveRefusalKey {
      errorKey = refusal
      return false
    }
    guard !store.isWritingInBackground else {
      errorKey = "entry.error.notSaved"
      return false
    }
    if let money = money ?? moneyNow?(),
      let question = EntrySaveQuestions.next(
        for: draft, environment: environment, money: money, now: now)
    {
      saveQuestion = question
      return false
    }
    let balances = balances ?? balancesNow?() ?? .empty
    if movesTheMoney(calendar: environment.calendar) {
      switch draft.countAsk(
        savedAt: now, balances: balances, remembered: environment.rememberedCountAnswers())
      {
      case .none:
        break
      case .answered(let stamp):
        draft.stampCount(stamp)
      case .ask(let questions):
        countQuestion = BeforeTheCountQuestion(
          count: questions.count, reconciliation: questions.reconciliation,
          questions: questions)
        return false
      }
    }
    let takesBack = RefundRules.takesBack(draft.draft)
    // A refund carries the purchase's rate, never one of its own day.
    if !takesBack { environment.applyRate(to: &draft.draft) }
    // «Списано со счёта» follows the rate the save has just laid.
    draft.refreshCharge()
    let rublesConverter: (AmountE4) throws -> AmountE4
    if takesBack,
      let rubles = Self.refundRubles(of: draft.draft, editing: entry, ledger: store.listing)
    {
      rublesConverter = { _ in rubles }
    } else {
      rublesConverter = environment.rublesConverter(for: draft.draft)
    }
    let updated: TransactionEntry
    do {
      updated = try Self.edited(
        entry, with: Self.cardAndCashbackOfItsKind(draft.draft, fields: draft.fields),
        rublesConverter: rublesConverter)
    } catch MoneyConversionError.rateMissing {
      errorKey = "entry.error.rateMissing"
      return false
    } catch {
      errorKey = "entry.error.notSaved"
      return false
    }
    if settling == nil {
      let check = store.archivedLeftovers(editing: entry, into: updated)
      if !check.leftovers.isEmpty {
        archivedLeftovers = check
        return false
      }
    }
    archivedLeftovers = nil
    switch store.saveEdit(updated, calendar: environment.calendar, settling: settling ?? []) {
    case .saved:
      errorKey = nil
      CategoryLearning.saved(
        updated, replacing: entry, choice: categoryChoice(), environment: environment)
      return true
    case .gone:
      // Deleted elsewhere meanwhile: the edit stays, with the reason, until «Cancel» — in
      // the sheet and in the inspector alike (`follow`).
      errorKey = Self.goneKey
      return false
    case .failed:
      errorKey = "entry.error.notSaved"
      return false
    case .declined(let refusal):
      errorKey = Self.errorKey(of: refusal)
      return false
    case .declinedByLink(let refusal):
      errorKey = Self.errorKey(of: refusal)
      return false
    case .refundRefused(let refusal):
      errorKey = Self.errorKey(of: refusal)
      return false
    case .chargeMissing:
      errorKey = "entry.error.chargeMissing"
      return false
    case .settlingRefused:
      errorKey = "transactions.error.settlingRefused"
      return false
    case .declinedDifference:
      errorKey = "editor.reconcileDifference.locked"
      return false
    case .refused:
      errorKey = "entry.error.noDependencies"
      return false
    }
  }

  /// The choice of a category made in this editing, if one was: a category left as it was
  /// saved is not chosen again by opening the operation.
  private func categoryChoice() -> CategoryFeedback? {
    guard let choice = draft.categoryChoice(),
      baseline.parts.first(where: { $0.id == choice.partId })?.categoryId
        != choice.chosenCategoryId
    else { return nil }
    return choice
  }

  /// «Записать всё равно»: the edit is saved with the worse position, and is not asked about it
  /// again; the caller saves once more.
  func answerSaveQuestion() {
    switch saveQuestion {
    case .overLimit: draft.overLimitAnswered = true
    case .minBalance: draft.minBalanceAnswered = true
    case .ahead, .repeated, nil: break
    }
    saveQuestion = nil
  }

  /// The owner's answer to «Это было до сверки?»: the operation is dated before or after the
  /// count, and the save that follows does not ask about that count again.
  func answerCount(_ count: Date, wasBefore: Bool) {
    draft.answerCount(count, wasBefore: wasBefore)
    draft.stampCount(draft.draft.occurredAt)
    countQuestion = nil
  }

  /// The moment the answers about the counts of the day gave: the operation is saved at it,
  /// and the save that follows asks nothing more.
  func stampCount(_ moment: Date) {
    draft.stampCount(moment)
    countQuestion = nil
  }

  /// Whether the edit moves the operation's money to another day, account or currency: only
  /// such an edit can land it on the day of a count it was not on before.
  private func movesTheMoney(calendar: CalendarContext) -> Bool {
    let old = entry.transaction
    let new = draft.draft
    return calendar.day(of: old.occurredAt) != calendar.day(of: new.occurredAt)
      || old.paymentMethodId != new.paymentMethodId || old.currency != new.currency
  }

  /// The rubles a refund taken back from a purchase stores after the edit: for each of its
  /// parts, what `RefundRules.rubles` gives against the purchase part, counting what the other
  /// refunds of that part took back — never this refund's own earlier figures. `nil` when the
  /// ledger does not know a purchase part the draft names: the save converts as any other.
  nonisolated static func refundRubles(
    of draft: TransactionDraft, editing original: TransactionEntry, ledger: Ledger?
  ) -> AmountE4? {
    guard let ledger else { return nil }
    let index = ledger.refundIndex
    let own = original.transaction.isDeleted ? [] : original.parts
    var total = AmountE4.zero
    for part in draft.parts {
      guard let target = part.refundOfPartId, let row = ledger.row(ofPart: target),
        let purchase = ledger.entry(row.transactionId)?.parts.first(where: { $0.id == target })
      else { return nil }
      // What this refund took back before the edit is not «before» it.
      let mine = own.filter { index.purchasePart(ofRefundPart: $0.id) == target }
      let before = (
        amount: index.refunded(part: target) - AmountE4.sum(mine.map(\.amountE4)),
        rub: index.refundedStoredRub(part: target) - AmountE4.sum(mine.map(\.amountRubE4))
      )
      total += RefundRules.rubles(refundAmount: part.amount, part: purchase, refundedBefore: before)
    }
    return total
  }

  /// The draft without the card and the cashback when its kind has no such field
  /// (`KindFields`): money back names no card, and only a purchase has a cashback. A purchase
  /// turned into money back in the editor would keep both out of sight otherwise — listed under
  /// the card, and holding it from being deleted. What else a kind hides is kept as stored:
  /// a place or an event income had before it lost them stays in the database.
  nonisolated static func cardAndCashbackOfItsKind(
    _ draft: TransactionDraft, fields: Set<OperationField>
  ) -> TransactionDraft {
    var draft = draft
    if !fields.contains(.card) { draft.cardId = nil }
    if !fields.contains(.cashback) { draft.cashback = nil }
    return draft
  }

  /// What the editor says when the store declines the edit.
  nonisolated static func errorKey(of refusal: EditRefusal) -> String {
    switch refusal {
    case .debtCurrency: "entry.error.debtCurrency"
    case .settledReimbursement: "entry.error.reimbursementEdit"
    case .closedPartRemoved: "entry.error.closedPartRemoved"
    case .closedPartChanged: "entry.error.closedPartChanged"
    }
  }

  /// What the editor says when a refund or money back that covered only some of a part leans
  /// on what the edit changes.
  nonisolated static func errorKey(of refusal: LinkedEditRefusal) -> String {
    switch refusal {
    case .refundedPartRemoved: "transactions.error.refundedPartRemoved"
    case .refundedPartReduced: "transactions.error.refundedPartReduced"
    case .refundedPartChanged: "transactions.error.refundedPartChanged"
    case .partlyReturnedPartChanged: "transactions.error.partlyReturnedPartChanged"
    case .linkedRefundChanged: "transactions.error.linkedRefundChanged"
    }
  }

  /// What the editor says when a refund taken back from a purchase may not become what the edit
  /// makes it.
  nonisolated static func errorKey(of refusal: RefundError) -> String {
    switch refusal {
    case .notRefundable: "transactions.error.refundNotRefundable"
    case .exceedsRemaining: "transactions.error.refundExceedsRemaining"
    case .notPositive: "transactions.error.refundNotPositive"
    case .purchaseHasRefunds: "transactions.error.purchaseHasRefunds"
    case .otherCurrency: "transactions.error.refundOtherCurrency"
    }
  }

  /// The String Catalog an error key of the editor is in: the refusals about refunds and money
  /// back, and the words about a count's difference the panel shows too, are the Transactions
  /// window's; the rest the panel's.
  nonisolated static func table(ofErrorKey key: String) -> String {
    key.hasPrefix("transactions.") || key.hasPrefix("editor.") ? "Transactions" : "Entry"
  }

  /// A purchase a live refund takes money back from stays, and the question says why.
  func requestDeletion(store: TransactionsStore) {
    let owed = store.deletionDebts()
    confirmation = BulkConfirmation.deletion(
      of: [entry], refunds: store.listing?.refundIndex ?? .empty, debts: store.debts,
      deletedDebts: owed.deleted, paidDebts: owed.paid,
      reopening: store.debtsClosedBy(deleting: [entry.id]))
  }

  /// The saved operation after the edit. Only what the panel edits changes: when the
  /// operation was created, which import it came from and how far its parts paid for others
  /// have come back stay as they were (`TransactionEntry.rebased(onto:)`); otherwise an
  /// edited bank row would lose the key that stops it from being imported twice.
  ///
  /// The formula goes back with its numbers written the way the app writes them: one saved
  /// when a lone comma was always decimal, «1,5+2», is saved again as «1.5+2».
  nonisolated static func edited(
    _ original: TransactionEntry, with draft: TransactionDraft,
    now: Date = Date(),
    rublesConverter: (AmountE4) throws -> AmountE4
  ) throws -> TransactionEntry {
    var draft = draft
    draft.amountExpression = draft.amountExpression.map {
      ExpressionEvaluator.canonical($0) ?? $0
    }
    return try draft.materialize(updating: original, now: now, rublesConverter: rublesConverter)
  }
}

/// The editing of one saved operation: the same ↓ panel the entry line uses, bound to it,
/// with «Delete…» on the left and «Cancel» and «Save» on the right. The main window shows it
/// in a sheet, the Transactions window in its inspector; content is never glass.
struct TransactionEditor: View {
  enum Style {
    /// The sheet of the main window: wide, with a title of its own.
    case sheet
    /// The inspector of the Transactions window: narrow, headed by the operation itself.
    case inspector
  }

  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  @Bindable var editor: TransactionEditorModel
  let style: Style
  /// Called when the editing is over: saved, cancelled, or the operation deleted.
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: style == .sheet ? 16 : 12) {
      header
      ScrollView {
        // Return in a text field saves, as «Save» does when it is on.
        DetailsPanel(
          model: editor.draft, submit: saveOnReturn, hasRoomForSegments: style == .sheet
        )
        .padding(.vertical, 2)
      }
      .frame(minWidth: style == .sheet ? 620 : nil, minHeight: style == .sheet ? 360 : nil)

      // Wraps in the width it is given, never fixed to its full height: the inspector is a
      // column of a split view, and a text fixed that way made the column's minimum the text
      // wrapped at a width of zero — a character a line, taller than the window — so a long
      // message («no rate yet», «deleted», a refusal) made the window loop until AppKit threw
      // (`testEveryMessageOfTheEditorLeavesTheInspectorSettled`).
      if let errorKey = editor.errorKey {
        Text(
          verbatim: environment.language(
            errorKey, table: TransactionEditorModel.table(ofErrorKey: errorKey))
        )
        .appFont(.caption)
        .foregroundStyle(.red)
      }

      // Named, not read by their captions: every confirmation of the Transactions window has
      // a «Cancel» of its own, and switching operations replaces the whole inspector
      // (`.id(ObjectIdentifier(editor))`), so two can stand there for one frame. A UI test
      // that asked for «Cancel» found several and refused to act (`make test-ui`, 21.09).
      HStack {
        Button(
          environment.language("selection.delete", table: "Transactions"), role: .destructive
        ) {
          editor.requestDeletion(store: store)
        }
        .disabled(store.isWritingInBackground)
        .accessibilityIdentifier("editor.delete")
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel, action: close)
          .accessibilityIdentifier("editor.cancel")
        Button(environment.language("action.save")) { save() }
          .buttonStyle(.borderedProminent)
          // The sheet is the window's own question, and Return answers it wherever the focus is —
          // a date, a menu. The inspector is a column beside the table, whose Return is the
          // table's: there only a text field's Return saves.
          .keyboardShortcut(style == .sheet ? .defaultAction : nil)
          .disabled(!editor.canSave(in: store))
          .accessibilityIdentifier("editor.save")
      }
    }
    .padding(style == .sheet ? 20 : 14)
    .bulkConfirmation($editor.confirmation) { landed in
      if landed {
        close()
      } else {
        editor.errorKey = "entry.error.notSaved"
      }
    }
    // The answers date the operation among the counts of its day, and the save goes on.
    .beforeTheCountQuestions($editor.countQuestion) { moment in
      editor.stampCount(moment)
      save()
    }
    // Money the edit would leave on an archived account goes to a live one, in the same step.
    .sheet(
      isPresented: Binding(
        get: { editor.archivedLeftovers != nil },
        set: { if !$0 { editor.archivedLeftovers = nil } })
    ) {
      if let check = editor.archivedLeftovers {
        ArchivedMoneySheet(
          check: check,
          confirm: { settling in
            editor.archivedLeftovers = nil
            save(settling: settling)
          },
          cancel: { editor.archivedLeftovers = nil }
        )
        .handingOver(dependencies)
      }
    }
    // While it is on screen, a save made from a question of the window asks about a count by
    // the balances the window has. Folded away, the editor asks nothing it could not show.
    .editSaveQuestions($editor.saveQuestion) {
      editor.answerSaveQuestion()
      save()
    }
    .onAppear {
      let compute = self.compute
      editor.balancesNow = { compute.snapshot?.planning.accounts.balances ?? .empty }
      editor.moneyNow = { .init(compute.snapshot) }
    }
    .onDisappear {
      editor.balancesNow = nil
      editor.moneyNow = nil
    }
  }

  /// Return in a text field of the panel: the save, when «Save» is on.
  private func saveOnReturn() {
    guard editor.canSave(in: store) else { return }
    save()
  }

  private func save(settling: [Transfer]? = nil) {
    let balances = compute.snapshot?.planning.accounts.balances ?? .empty
    if editor.save(
      store: store, environment: environment, balances: balances, settling: settling)
    {
      close()
    }
  }

  /// What a refund taken back from a purchase says here, as its row says it: on the purchase,
  /// what came back; on the refund, the purchase.
  private var refundMark: RefundMark? {
    guard let ledger = store.listing, let entry = ledger.entry(editor.id) else { return nil }
    return RefundMark.of(entry, ledger: ledger)
  }

  @ViewBuilder
  private var header: some View {
    switch style {
    case .sheet:
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: environment.language("action.edit"))
          .appFont(.headline)
        if let refundMark { RefundMarkLabel(mark: refundMark) }
      }
    case .inspector:
      // The operation as it is named in the table, and when it happened.
      VStack(alignment: .leading, spacing: 2) {
        RowTitleText(title: editor.title)
          .appFont(.headline)
          .lineLimit(2)
        Text(verbatim: environment.dates.moment(editor.entry.transaction.occurredAt))
          .appFont(.caption)
          .foregroundStyle(.secondary)
        if let refundMark { RefundMarkLabel(mark: refundMark) }
      }
    }
  }
}

/// The mark of a refund beside the description of a row. On a refund it leads to the purchase
/// when `open` is given: a click opens the purchase the refund takes money back from.
struct RefundMarkLabel: View {
  @Dependency(\.environment) private var environment
  let mark: RefundMark
  var open: ((UUID) -> Void)? = nil

  var body: some View {
    let words = RefundMarkText.text(mark, environment: environment)
    if case .refundOf(let purchaseId, _, _, _) = mark, let open {
      Button {
        open(purchaseId)
      } label: {
        label(words)
      }
      .buttonStyle(.link)
      .help(Text(verbatim: words))
      .accessibilityIdentifier("transactions.refund.purchase")
    } else {
      label(words)
        .foregroundStyle(.secondary)
        .help(Text(verbatim: words))
    }
  }

  private func label(_ words: String) -> some View {
    Label {
      Text(verbatim: words)
        .lineLimit(1)
    } icon: {
      Image(systemName: RefundMarkText.symbol)
    }
    .appFont(.caption)
    .accessibilityElement(children: .combine)
  }
}

/// The title of an operation in a list: its description, or — in the secondary style — its
/// category or kind.
struct RowTitleText: View {
  @Dependency(\.environment) private var environment
  let title: RowTitle

  var body: some View {
    switch title {
    case .note(let note):
      Text(verbatim: note)
    case .category(let path):
      Text(verbatim: CategoryPathText.text(path, language: environment.language))
        .foregroundStyle(.secondary)
    case .kind(let kind):
      Text(verbatim: environment.language("kind.\(kind.rawValue)"))
        .foregroundStyle(.secondary)
    }
  }
}

/// «Category › Subcategory», with «(archived)» after a retired one.
@MainActor
enum CategoryPathText {
  static func text(_ path: CategoryPath, language: AppLanguage) -> String {
    path.archived ? language.format("common.archivedName", path.text) : path.text
  }
}
