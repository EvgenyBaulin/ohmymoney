import AppCore
import AppDatabase
import Foundation

/// A transfer as its fields hold it while the owner fills it in: where the money leaves, where
/// it arrives, how much went and came, the fee, the day and the note. Nothing here is written.
struct TransferForm: Hashable, Sendable {
  var fromAccountId: UUID?
  var fromCurrency: CurrencyCode?
  var toAccountId: UUID?
  var toCurrency: CurrencyCode?
  /// What left the account, in its currency.
  var sent: AmountE4 = .zero
  /// What arrived, in the currency of the other side; the same as `sent` in one currency.
  var received: AmountE4 = .zero
  /// What the bank took for it, in the currency the money left in; zero means no fee.
  var fee: AmountE4 = .zero
  var day: DateOnly
  /// The time the owner chose on the clock; `nil` while he has not, and the moment is the
  /// default one (`occurredAt(now:calendar:)`).
  var time: TimeOfDay?
  var note: String = ""
  /// The transfer being edited; `nil` for a new one.
  var previous: Transfer?

  /// A new transfer from `account` in its main currency, on `day`. The other side is the main
  /// account when the money leaves another one, and nothing otherwise.
  init(from account: PaymentMethod?, accounts: [PaymentMethod], day: DateOnly) {
    self.day = day
    fromAccountId = account?.id
    fromCurrency = account?.mainCurrency
    if let main = accounts.first(where: { $0.isDefault && !$0.archived }), main.id != account?.id {
      toAccountId = main.id
      toCurrency = Self.currency(on: main, preferring: fromCurrency)
    }
  }

  /// «Перевести остаток…»: the money of `account` moved away whole — from the first of its
  /// currencies that holds money, the whole of it, to the main account as a new transfer goes.
  /// A balance below zero — a credit card — is covered instead: the whole of it from the main
  /// account to this one. When the main account does not hold the card's currency, the money
  /// leaves in the main account's own and what it came to there is the bank's to say: the
  /// amount received is the debt, the amount sent is left for the owner to type. With nothing
  /// known on it, the form of a new transfer from it.
  init(
    movingBalanceOf account: PaymentMethod, balances: AccountBalances, accounts: [PaymentMethod],
    day: DateOnly
  ) {
    self.init(from: account, accounts: accounts, day: day)
    let known = account.currencies.compactMap { currency -> (CurrencyCode, AmountE4)? in
      guard
        let amount = balances[BalanceKey(accountId: account.id, currency: currency)]?.amountE4,
        !amount.isZero
      else { return nil }
      return (currency, amount)
    }
    if let (currency, amount) = known.first(where: { $0.1.raw > 0 }) {
      fromCurrency = currency
      sent = amount
      if let toAccountId, let main = accounts.first(where: { $0.id == toAccountId }) {
        toCurrency = Self.currency(on: main, preferring: currency)
      }
      return
    }
    guard let (currency, owed) = known.first,
      let main = accounts.first(where: { $0.isDefault && !$0.archived }), main.id != account.id
    else { return }
    fromAccountId = main.id
    let leaving = Self.currency(on: main, preferring: currency)
    fromCurrency = leaving
    toAccountId = account.id
    toCurrency = currency
    // An exchange is never prefilled one to one: 500 $ owed are not 500 ₽ sent.
    sent = leaving == currency ? owed.magnitude : .zero
    received = owed.magnitude
  }

  /// «Перевести…» in the ↓ panel: what the panel holds starts a new transfer — the amount is
  /// what leaves, in the panel's currency when the account holds it (else in the account's own),
  /// from the account the panel names, on the day of its date, with its note as the comment. The
  /// other side is the main account, as in every new transfer. No time is chosen.
  init(
    fromThePanel draft: TransactionDraft, account: PaymentMethod?, accounts: [PaymentMethod],
    calendar: CalendarContext
  ) {
    self.init(from: account, accounts: accounts, day: calendar.day(of: draft.occurredAt))
    fromCurrency = draft.currency
    if let account { chooseFrom(account) }
    if let toAccountId, let target = accounts.first(where: { $0.id == toAccountId }) {
      chooseTo(target)
    }
    if draft.amount > .zero { sent = draft.amount }
    note = (draft.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// «перевод 5000 сбер т-банк»: the accounts the line named, then what the draft holds — the
  /// amount, its currency, the day and the note — as «Перевести…» takes them. A side the line
  /// did not name stays empty for the owner to choose: the main account is never put there by
  /// itself.
  init(
    fromTheLine reading: TransferReading, draft: TransactionDraft, accounts: [PaymentMethod],
    calendar: CalendarContext
  ) {
    let from = accounts.first { $0.id == reading.fromAccountId }
    self.init(fromThePanel: draft, account: from, accounts: accounts, calendar: calendar)
    if from == nil {
      fromAccountId = nil
    }
    if let to = accounts.first(where: { $0.id == reading.toAccountId }) {
      chooseTo(to)
    } else {
      toAccountId = nil
      toCurrency = nil
    }
  }

  /// The entry line typed while the fields of a transfer are open: the accounts it names, the
  /// amount, its currency and the day go over what the fields hold; what it does not name stays
  /// as the owner chose it.
  mutating func take(
    line reading: TransferReading?, amount: AmountE4?, currency: CurrencyCode?, day: DateOnly?,
    accounts: [PaymentMethod]
  ) {
    func account(_ id: UUID?) -> PaymentMethod? { accounts.first { $0.id == id } }
    if let from = account(reading?.fromAccountId) { chooseFrom(from) }
    if let currency, let from = account(fromAccountId), from.holds(currency) {
      fromCurrency = currency
      if reading?.toAccountId == nil, let to = account(toAccountId) { chooseTo(to) }
    }
    if let to = account(reading?.toAccountId) { chooseTo(to) }
    if let amount, amount.raw > 0 { sent = amount }
    if let day { self.day = day }
  }

  /// Whether the line may write the transfer it named without a word: both accounts known and
  /// different, one currency, and an amount.
  func savesAtOnce(_ reading: TransferReading) -> Bool {
    reading.isComplete && fromAccountId != nil && toAccountId != nil && !isExchange
      && sent.raw > 0
  }

  /// The form of a saved transfer and its fee.
  init(editing transfer: Transfer, fee: AmountE4?, calendar: CalendarContext) {
    previous = transfer
    fromAccountId = transfer.fromAccountId
    fromCurrency = transfer.fromCurrency
    toAccountId = transfer.toAccountId
    toCurrency = transfer.toCurrency
    sent = transfer.fromAmountE4
    received = transfer.toAmountE4
    self.fee = fee ?? .zero
    day = calendar.day(of: transfer.occurredAt)
    note = transfer.note ?? ""
  }

  /// Money changes currency: both amounts are asked, as the bank shows them.
  var isExchange: Bool {
    guard let fromCurrency, let toCurrency else { return false }
    return fromCurrency != toCurrency
  }

  /// What arrived: typed for an exchange, the money sent otherwise.
  var receivedAmount: AmountE4 { isExchange ? received : sent }

  /// Units received for one unit sent, as the two amounts imply; for showing only.
  var impliedRate: Decimal? {
    guard isExchange, sent.raw > 0, received.raw > 0 else { return nil }
    return received.decimal / sent.decimal
  }

  /// The side the money leaves from moved to another account: its currency follows the
  /// account unless the account holds the one chosen.
  mutating func chooseFrom(_ account: PaymentMethod) {
    fromAccountId = account.id
    fromCurrency = Self.currency(on: account, preferring: fromCurrency)
  }

  /// The side the money arrives at moved to another account: the currency the money leaves in
  /// when the account holds it — a plain transfer —, else the account's main currency.
  mutating func chooseTo(_ account: PaymentMethod) {
    toAccountId = account.id
    toCurrency = Self.currency(on: account, preferring: fromCurrency ?? toCurrency)
  }

  static func currency(
    on account: PaymentMethod, preferring currency: CurrencyCode?
  )
    -> CurrencyCode
  {
    if let currency, account.holds(currency) { return currency }
    return account.mainCurrency
  }

  /// The transfer to write, at `occurredAt`; `nil` while a side is not chosen.
  func transfer(id: UUID, occurredAt: Date, now: Date) -> Transfer? {
    guard let fromAccountId, let fromCurrency, let toAccountId, let toCurrency else {
      return nil
    }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return Transfer(
      id: id, occurredAt: occurredAt, fromAccountId: fromAccountId, fromCurrency: fromCurrency,
      fromAmountE4: sent, toAccountId: toAccountId, toCurrency: toCurrency,
      toAmountE4: receivedAmount, note: trimmed.isEmpty ? nil : trimmed,
      createdAt: previous?.createdAt ?? now, updatedAt: now)
  }

  /// The one field of date and time gives back the moment `picked`, where `shown` is the moment
  /// it showed (`occurredAt`): the day is the one picked, and the time is chosen only when the
  /// clock part of `picked` is not the one `shown` had — moving to another day alone chooses no
  /// time, and the transfer is still asked about the counts of its day (`asksAboutTheCount`).
  mutating func choose(moment picked: Date, shown: Date, calendar: CalendarContext) {
    day = calendar.day(of: picked)
    let clock = calendar.timeOfDay(picked)
    if clock != calendar.timeOfDay(shown) { time = clock }
  }

  /// The moment of the transfer before the question about a count: the time the owner chose
  /// on its day; else a transfer of today happened now, one of another day at its noon — the
  /// same moments the entry line gives —, and an edit that keeps the day keeps the moment it
  /// had.
  func occurredAt(now: Date, calendar: CalendarContext) -> Date {
    if let time { return calendar.moment(day, hour: time.hour, minute: time.minute) }
    if let previous, calendar.day(of: previous.occurredAt) == day { return previous.occurredAt }
    return calendar.day(of: now) == day ? now : calendar.noon(of: day)
  }

  /// Whether saving has to ask «Это было до сверки?»: never with a time the owner chose — it
  /// says itself whether it was before a count of that day —; otherwise a new transfer does,
  /// and an edit only when its day or its accounts and currencies moved.
  func asksAboutTheCount(_ transfer: Transfer, calendar: CalendarContext) -> Bool {
    guard time == nil else { return false }
    guard let previous else { return true }
    return calendar.day(of: previous.occurredAt) != calendar.day(of: transfer.occurredAt)
      || previous.from != transfer.from || previous.to != transfer.to
  }
}

/// Why a transfer was not saved. Nothing is written then.
enum TransferRefusal: Error, Hashable, Sendable {
  /// No account or currency on the side the money leaves.
  case noFrom
  /// No account or currency on the side it arrives.
  case noTo
  case issue(TransferIssue)
  /// A fee below zero.
  case negativeFee
  /// The fee is in a currency whose rate is not known for the day: its rubles cannot be told.
  case rateMissing(CurrencyCode)
  /// The transfer is not there any more.
  case notFound
  /// A refund was recorded against the fee: it is not taken off, made smaller than what came
  /// back or moved to another currency, and the transfer is not deleted with it.
  case feeRefunded
  /// Money a person gave back was linked to the fee: its amount and currency stay, and a fee
  /// it closed is not taken off.
  case feeMoneyBack
}

/// The category of fees a new fee brings back from the archive, as the sheet names it under
/// the fee: «Комиссия пойдёт в «Комиссии» — она вернётся из архива вместе с «Банк».»
struct FeeCategoryComingBack: Hashable, Sendable {
  /// The name of the category of fees.
  let category: String
  /// The name of its parent when the parent comes back from the archive too.
  let parent: String?
}

/// What came of saving or deleting a transfer.
enum TransferOutcome: Hashable, Sendable {
  case done
  case refused(TransferRefusal)
  /// The database did not take the write; the journal says why.
  case failed
}

/// What deleting a transfer from a list of days comes to before the owner is asked anything.
enum TransferDeletionStep {
  /// Written, refused or failed: nothing is left to ask.
  case finished(TransferOutcome)
  /// The deletion would leave money on an account in the archive: nothing is written until
  /// the owner says where it goes; `books` are the books the question was worked out from.
  case ask(ArchivedMoneyCheck, books: AccountBooks)
}

/// Transfers between accounts and between the currencies of one account: a new one, an edit,
/// a deletion — each one write with its fee and one step of ⌘Z.
///
/// A transfer is neither income nor spending. Its fee is an ordinary expense from the account
/// the money left, in the category the fees go to («Комиссии»), which points back at the
/// transfer by its key; the category is found or made at the first fee and remembered.
@MainActor
struct TransferActions {
  let environment: AppEnvironment
  let store: TransactionsStore

  init(environment: AppEnvironment, store: TransactionsStore) {
    self.environment = environment
    self.store = store
  }

  /// The books as the database has them now: the accounts, the transfers, the fees and the
  /// balances the question about a count is asked from.
  func books() async -> AccountBooks? {
    await AccountActions(environment: environment, store: store).books()
  }

  // MARK: Before the count

  /// What saving `form` at `occurredAt`, at the moment `now`, asks about the counts of its day:
  /// nothing for a time the owner chose or an edit that keeps its day and its sides
  /// (`TransferForm.asksAboutTheCount`); otherwise every count of a balance it moves made on
  /// its day before the save, oldest first (`AccountReconciliation.countToAsk`). An answer
  /// kept with «Больше не спрашивать для этой сверки» answers its count without a question,
  /// and when the kept answers settle every count the moment itself comes back. `remembered`
  /// are those answers — reconciliation → «было до сверки» —, read from the database when not
  /// given.
  func countStep(
    for form: TransferForm, occurredAt: Date, books: AccountBooks, now: Date,
    remembered: [UUID: Bool]? = nil
  ) -> CountAsk {
    let calendar = environment.calendar
    guard
      let transfer = form.transfer(
        id: form.previous?.id ?? UUID(), occurredAt: occurredAt, now: now),
      form.asksAboutTheCount(transfer, calendar: calendar)
    else { return .none }
    return AccountReconciliation.countToAsk(
      occurredAt: occurredAt, savedAt: now, keys: AccountReconciliation.movedKeys(of: transfer),
      balances: books.balances, calendar: calendar,
      remembered: remembered ?? environment.rememberedCountAnswers())
  }

  /// The owner's answer to «Это было до сверки в 14:05?»: the moment it gives the transfer, or
  /// the next count of the day to ask about. With «Больше не спрашивать для этой сверки»
  /// ticked (`remember`) the answer is kept for that count's reconciliation, and what is saved
  /// next on that day is dated by it without a question — for a count that offers the box
  /// (`CountQuestions.remembers`) only.
  func answer(
    _ questions: CountQuestions, wasBefore: Bool, remember: Bool
  ) -> CountQuestions.Step {
    if remember, questions.remembers, let reconciliation = questions.reconciliation {
      environment.rememberCountAnswer(reconciliation: reconciliation, wasBefore: wasBefore)
    }
    return questions.answer(wasBefore: wasBefore)
  }

  // MARK: Reading

  /// The live fee of a transfer, if it has one.
  nonisolated static func fee(
    of transferId: UUID, in entries: [TransactionEntry]
  )
    -> TransactionEntry?
  {
    let key = TransferRules.feeKey(of: transferId)
    return entries.first { $0.transaction.externalId == key && !$0.transaction.isDeleted }
  }

  /// Why the fee `old` may not become `new` — `nil` takes it off —, or `nil` when it may.
  /// What came back for it leans on its money: a refund on the amount it took back and on the
  /// currency, money a person gave back on the amount and the currency it was worked out
  /// from. Taking a fee off follows the rule of deleting any operation
  /// (`BulkEditRule.deletion`). Another account or moment is no other money.
  nonisolated static func feeRefusal(
    _ old: TransactionEntry, becoming new: TransactionEntry?, refunds: RefundIndex,
    moneyBack: Set<UUID>
  ) -> TransferRefusal? {
    guard let new else {
      switch BulkEditRule.deletion(of: [old], refunds: refunds).skipped.first?.reason {
      case .hasRefunds: return .feeRefunded
      case .closedByReimbursement: return .feeMoneyBack
      default:
        return old.parts.contains { refunds.refunded(part: $0.id).raw > 0 } ? .feeRefunded : nil
      }
    }
    let currencyMoved = old.transaction.currency != new.transaction.currency
    let edited = Dictionary(new.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for part in old.parts {
      let now = edited[part.id]
      let refunded = refunds.refunded(part: part.id)
      if refunded.raw > 0, currencyMoved || (now?.amountE4 ?? .zero) < refunded {
        return .feeRefunded
      }
      let cameBack = moneyBack.contains(part.id) || part.reimbursementStatus == .returned
      if cameBack, currencyMoved || now?.amountE4 != part.amountE4 {
        return .feeMoneyBack
      }
    }
    return nil
  }

  /// The category of fees a new fee would bring back from the archive, by name, with its
  /// parent's name when the parent comes back too; `nil` when the fee goes to a live category
  /// or to a new one (`TransferRules.feeCategory`).
  nonisolated static func feeCategoryComingBack(
    categories: [CoreKit.Category], remembered: UUID?
  ) -> FeeCategoryComingBack? {
    guard
      case .revive(let id, let parentId) = TransferRules.feeCategory(
        categories: categories, remembered: remembered)
    else { return nil }
    let tree = CategoryTree(categories)
    guard let category = tree[id] else { return nil }
    return FeeCategoryComingBack(category: category.name, parent: tree.category(parentId)?.name)
  }

  /// `feeCategoryComingBack(categories:remembered:)` for the categories and the remembered
  /// category of fees the database holds now.
  func feeCategoryComingBack() -> FeeCategoryComingBack? {
    Self.feeCategoryComingBack(categories: store.categories(), remembered: rememberedFeeCategory)
  }

  /// The category of fees kept in the settings (`transfers.feeCategory`), if one is.
  private var rememberedFeeCategory: UUID? {
    let stored = try? environment.settings?.string(AccountSettings.transferFeeCategoryKey)
    return stored.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
  }

  /// Why deleting each of `transfers` is refused as `dataset` has them, by the transfer's id;
  /// a transfer that may go is not among them. A fee something came back for keeps its
  /// transfer. A transfer of an account in the archive may go: the money it would leave on
  /// that account, or take off it, is moved by a transfer the deletion asks for
  /// (`ArchivedMoney`). The screen of an account and the lists of operations ask this one
  /// question. `refunds` are the live refunds of `dataset` (`refunds(in:)`).
  nonisolated static func deletionRefusals(
    of transfers: [Transfer], in dataset: Dataset, refunds: RefundIndex
  ) -> [UUID: TransferRefusal] {
    guard !transfers.isEmpty else { return [:] }
    let keys = Set(transfers.map { TransferRules.feeKey(of: $0.id) })
    // The live fee of each transfer, the first one as `fee(of:in:)` finds it.
    var fees: [String: TransactionEntry] = [:]
    for entry in dataset.entries where !entry.transaction.isDeleted {
      guard let key = entry.transaction.externalId, keys.contains(key), fees[key] == nil
      else { continue }
      fees[key] = entry
    }
    let moneyBack = fees.isEmpty ? [] : Self.moneyBack(in: dataset)
    var refusals: [UUID: TransferRefusal] = [:]
    for transfer in transfers {
      if let fee = fees[TransferRules.feeKey(of: transfer.id)],
        let refusal = Self.feeRefusal(fee, becoming: nil, refunds: refunds, moneyBack: moneyBack)
      {
        refusals[transfer.id] = refusal
      }
    }
    return refusals
  }

  /// The parts some live money back was linked to.
  nonisolated static func moneyBack(in dataset: Dataset) -> Set<UUID> {
    let live = Set(dataset.entries.filter { !$0.transaction.isDeleted }.map(\.id))
    return Set(dataset.links.filter { live.contains($0.reimbursementTxId) }.map(\.partId))
  }

  /// What the live refunds of `dataset` took back from each part.
  nonisolated static func refunds(in dataset: Dataset) -> RefundIndex {
    RefundIndex(entries: dataset.entries, debts: dataset.debtsById)
  }

  // MARK: Writing, one step of ⌘Z each

  /// Saves a new transfer or an edit of `form.previous`, with its fee, in one write.
  ///
  /// `settling` are the transfers that keep an archived side at zero when the edit changes the
  /// money of a transfer of an account in the archive (`leftovers(of:books:)`): written in the
  /// same change and taken back by the same ⌘Z.
  @discardableResult
  func save(
    _ form: TransferForm, occurredAt: Date, books: AccountBooks, settling: [Transfer] = []
  ) -> TransferOutcome {
    switch change(for: form, occurredAt: occurredAt, books: books, settling: settling) {
    case .failure(let refusal):
      return .refused(refusal)
    case .success(let change):
      // Money left on an archived account is moved in the same change, never left there.
      if settling.isEmpty, !Self.leftovers(of: change, books: books).leftovers.isEmpty {
        return .refused(.issue(.archivedAccount))
      }
      guard store.apply(change) else { return .failed }
      // A category of the change that was already there came back from the archive.
      let known = Set(books.dataset.categories.map(\.id))
      let shape = [
        LogPair("exchange", .flag(form.isExchange)), LogPair("fee", .flag(form.fee.raw > 0)),
        LogPair(
          "feeCategoryRevived",
          .flag(change.upsert.categories.contains { known.contains($0.id) })),
      ]
      if form.previous == nil {
        AppLog.info("transfer.created", .db, "a transfer was written", shape)
      } else {
        AppLog.info("transfer.edited", .db, "a transfer was edited", shape)
      }
      return .done
    }
  }

  /// Deletes a transfer and its fee, in one write — the fee as the books have it now, not as a
  /// list shows it: a list a moment behind would leave the fee with nothing to belong to.
  @discardableResult
  func delete(_ transfer: Transfer) async -> TransferOutcome {
    guard let books = await books() else { return .failed }
    return delete(transfer, books: books)
  }

  /// Deletes a transfer as the books have it now — unless the deletion would leave money on an
  /// account in the archive, or take it below zero: then nothing is written, and the step
  /// hands back where that money has to go, to be asked (`ArchivedMoneySheet`) and written
  /// with the transfers picked by `delete(_:books:settling:)`, in one step of ⌘Z. What keeps
  /// the transfer anyway — a fee something came back for — is said before anything is asked.
  func deleteAsking(_ transfer: Transfer) async -> TransferDeletionStep {
    guard let books = await books() else { return .finished(.failed) }
    let check = deletion(of: transfer, books: books)
    guard !check.leftovers.isEmpty else { return .finished(delete(transfer, books: books)) }
    let dataset = books.dataset
    if let stored = dataset.transfers.first(where: { $0.id == transfer.id }),
      let refusal = Self.deletionRefusals(
        of: [stored], in: dataset, refunds: Self.refunds(in: dataset))[stored.id]
    {
      return .finished(.refused(refusal))
    }
    return .ask(check, books: books)
  }

  /// Deletes a transfer and its fee as `books` has them, in one write — unless
  /// `deletionRefusals` keeps it, which is then refused in words. `settling` are the transfers
  /// that keep an archived side at zero (`deletion(of:books:)` says which are needed), written
  /// in the same change.
  @discardableResult
  func delete(
    _ transfer: Transfer, books: AccountBooks, settling: [Transfer] = []
  ) -> TransferOutcome {
    let dataset = books.dataset
    guard let stored = dataset.transfers.first(where: { $0.id == transfer.id }) else {
      return .refused(.notFound)
    }
    let refusals = Self.deletionRefusals(
      of: [stored], in: dataset, refunds: Self.refunds(in: dataset))
    if let refusal = refusals[stored.id] { return .refused(refusal) }
    let fee = Self.fee(of: transfer.id, in: dataset.entries)
    for settle in settling {
      if let issue = Self.settlingIssue(settle, accounts: dataset.paymentMethods) {
        return .refused(.issue(issue))
      }
    }
    // Money the deletion would leave on an archived account is moved with it, never left.
    if settling.isEmpty, !deletion(of: stored, books: books).leftovers.isEmpty {
      return .refused(.issue(.archivedAccount))
    }
    let change = PlanningChange(
      upsert: PlanningRows(transfers: settling), delete: PlanningRowIDs(transfers: [transfer.id]),
      softDeleted: fee.map { [$0.id] } ?? [], at: environment.now())
    guard store.apply(change) else { return .failed }
    AppLog.info(
      "transfer.deleted", .db, "a transfer was deleted",
      [LogPair("fee", .flag(fee != nil))])
    return .done
  }

  /// What deleting `transfer` would leave on an account in the archive: the leftovers the
  /// deletion asks a live account for, before anything is written.
  func deletion(of transfer: Transfer, books: AccountBooks) -> ArchivedMoneyCheck {
    let dataset = books.dataset
    guard let stored = dataset.transfers.first(where: { $0.id == transfer.id }) else {
      return .none
    }
    let fee = Self.fee(of: stored.id, in: dataset.entries)
    return TransactionsStore.archivedLeftovers(
      removing: fee.map { [$0] } ?? [], adding: [], transfersRemoved: [stored], dataset: dataset,
      balances: books.balances)
  }

  /// What the change a form comes to would leave on an account in the archive: the transfer
  /// before and after, and its fee before and after.
  nonisolated static func leftovers(
    of change: PlanningChange, books: AccountBooks
  ) -> ArchivedMoneyCheck {
    let dataset = books.dataset
    let touched = Set(change.upsert.transfers.map(\.id)).union(change.delete.transfers)
    let rewritten = Set(change.rewritten.map(\.id)).union(change.softDeleted)
    return TransactionsStore.archivedLeftovers(
      removing: dataset.entries.filter {
        rewritten.contains($0.id) && !$0.transaction.isDeleted
      },
      adding: change.created + change.rewritten,
      transfersRemoved: dataset.transfers.filter { touched.contains($0.id) },
      transfersAdded: change.upsert.transfers, dataset: dataset, balances: books.balances)
  }

  /// Why a transfer that keeps an archived account at zero may not be written: its archived
  /// side is allowed, every other rule of a transfer holds.
  nonisolated static func settlingIssue(
    _ transfer: Transfer, accounts: [PaymentMethod]
  ) -> TransferIssue? {
    let archived = Set(accounts.filter(\.archived).map(\.id))
    let sides = Set([transfer.fromAccountId, transfer.toAccountId]).intersection(archived)
    // Only one side may be in the archive: the money goes to or comes from a live account.
    guard sides.count <= 1 else { return .archivedAccount }
    return TransferRules.validate(transfer, accounts: accounts, allowingArchived: sides)
  }

  /// The one write a form comes to — the transfer, and its fee created, rewritten or deleted,
  /// with the category of the fees made and remembered at the first one — and `settling`, the
  /// transfers that keep an archived side at zero.
  func change(
    for form: TransferForm, occurredAt: Date, books: AccountBooks, settling: [Transfer]
  ) -> Result<PlanningChange, TransferRefusal> {
    for settle in settling {
      if let issue = Self.settlingIssue(settle, accounts: books.dataset.paymentMethods) {
        return .failure(.issue(issue))
      }
    }
    return change(for: form, occurredAt: occurredAt, books: books).map { change in
      var change = change
      change.upsert.transfers += settling
      return change
    }
  }

  /// The one write a form comes to: the transfer, and its fee created, rewritten or deleted —
  /// with the category of the fees made and remembered at the first one.
  ///
  /// An edit of a transfer of an account in the archive keeps that side — a comment, the
  /// amount, the day —; a new transfer, or an edit that moves a side, may not name an archived
  /// account.
  func change(
    for form: TransferForm, occurredAt: Date, books: AccountBooks
  ) -> Result<PlanningChange, TransferRefusal> {
    guard form.fromAccountId != nil, form.fromCurrency != nil else { return .failure(.noFrom) }
    guard form.toAccountId != nil, form.toCurrency != nil else { return .failure(.noTo) }
    let now = environment.now()
    let dataset = books.dataset
    if let previous = form.previous,
      !dataset.transfers.contains(where: { $0.id == previous.id })
    {
      return .failure(.notFound)
    }
    guard
      let transfer = form.transfer(
        id: form.previous?.id ?? UUID(), occurredAt: occurredAt, now: now)
    else { return .failure(.noFrom) }
    let archived = Set(dataset.paymentMethods.filter(\.archived).map(\.id))
    let kept = Set([form.previous?.fromAccountId, form.previous?.toAccountId].compactMap { $0 })
      .intersection(archived)
    if let issue = TransferRules.validate(
      transfer, accounts: dataset.paymentMethods, allowingArchived: kept)
    {
      return .failure(.issue(issue))
    }
    guard form.fee.raw >= 0 else { return .failure(.negativeFee) }

    var rows = PlanningRows(transfers: [transfer])
    var change = PlanningChange(upsert: rows, at: now)
    let old = form.previous.flatMap { Self.fee(of: $0.id, in: dataset.entries) }
    let refunds = old == nil ? RefundIndex.empty : Self.refunds(in: dataset)
    let moneyBack = old == nil ? [] : Self.moneyBack(in: dataset)
    guard form.fee.raw > 0 else {
      if let old {
        if let refusal = Self.feeRefusal(old, becoming: nil, refunds: refunds, moneyBack: moneyBack)
        {
          return .failure(refusal)
        }
        change.softDeleted = [old.id]
      }
      return .success(change)
    }
    if let old {
      return rewriteFee(old, to: form.fee, of: transfer, refunds: refunds, moneyBack: moneyBack)
        .map { rewritten in
          change.rewritten = rewritten.map { [$0] } ?? []
          return change
        }
    }

    // A new fee: in the category of fees — brought back from the archive, with its parent,
    // when that is where it is, or made at the first fee — and remembered.
    let categories = store.categories()
    var tree = CategoryTree(categories)
    let categoryId: UUID
    let remembered = rememberedFeeCategory
    switch TransferRules.feeCategory(categories: categories, remembered: remembered) {
    case .existing(let id):
      categoryId = id
    case .revive(let id, let parent):
      // Written live in the same change, the parent first, so the same ⌘Z sends both back to
      // the archive.
      let back = [parent, id].compactMap { tree.category($0) }.map { category in
        var category = category
        category.archived = false
        return category
      }
      let backIds = Set(back.map(\.id))
      rows.categories = back
      tree = CategoryTree(categories.filter { !backIds.contains($0.id) } + back)
      categoryId = id
    case .create(let nameKey, let parent, let quality):
      let name = environment.language(nameKey, table: AccountText.table)
      let siblings = categories.filter { $0.parentId == parent && $0.kind == .expense }
      let made = CoreKit.Category(
        parentId: parent, kind: .expense, name: name,
        sort: (siblings.map(\.sort).max() ?? 0) + 1, quality: quality)
      rows.categories = [made]
      tree = CategoryTree(categories + [made])
      categoryId = made.id
    }
    if remembered != categoryId {
      change.settings = [AccountSettings.transferFeeCategoryKey: categoryId.uuidString]
    }
    change.upsert = rows

    var draft = TransferRules.feeDraft(
      transfer: transfer, fee: form.fee, categoryId: categoryId, tree: tree)
    environment.applyRate(to: &draft)
    let convert = environment.rublesConverter(for: draft)
    do {
      var entry = try draft.materialize(now: now, rublesConverter: convert)
      entry.transaction.externalId = TransferRules.feeKey(of: transfer.id)
      change.created = [entry]
    } catch {
      return .failure(.rateMissing(draft.currency))
    }
    return .success(change)
  }

  /// The fee `old` following its transfer: the amount the form gives it, the account, the
  /// currency and the moment of the transfer — and nothing else. Its parts, their notes,
  /// categories, ratings and whom they were for stay as the owner left them; a fee of several
  /// parts shares the new amount out as the old one was. `nil` when nothing it is made of
  /// moved: the fee is not written at all.
  private func rewriteFee(
    _ old: TransactionEntry, to amount: AmountE4, of transfer: Transfer, refunds: RefundIndex,
    moneyBack: Set<UUID>
  ) -> Result<TransactionEntry?, TransferRefusal> {
    let before = old.transaction
    if before.amountE4 == amount, before.currency == transfer.fromCurrency,
      before.paymentMethodId == transfer.fromAccountId, before.occurredAt == transfer.occurredAt
    {
      return .success(nil)
    }
    var draft = TransactionDraft(entry: old)
    if draft.currency != transfer.fromCurrency {
      // Another currency takes the rate of its own.
      draft.currency = transfer.fromCurrency
      draft.rate = nil
      draft.rateDate = nil
      draft.rateSource = nil
      draft.rateProvisional = false
    }
    draft.occurredAt = transfer.occurredAt
    draft.paymentMethodId = transfer.fromAccountId
    // The account holds the currency the money left in: nothing to say about a charge.
    draft.accountCurrency = nil
    draft.accountAmount = nil
    if draft.amount != amount {
      let shares = amount.allocated(
        proportionallyTo: draft.parts.map(\.amount), outOf: draft.amount)
      for index in draft.parts.indices {
        draft.parts[index].amount = shares[index]
        draft.parts[index].amountExpression = nil
      }
      draft.amount = amount
      draft.amountExpression = nil
    }
    environment.applyRate(to: &draft)
    let convert = environment.rublesConverter(for: draft)
    let now = environment.now()
    let rewritten: TransactionEntry
    do {
      rewritten = try draft.materialize(updating: old, now: now, rublesConverter: convert)
    } catch {
      return .failure(.rateMissing(draft.currency))
    }
    if let refusal = Self.feeRefusal(
      old, becoming: rewritten, refunds: refunds, moneyBack: moneyBack)
    {
      return .failure(refusal)
    }
    return .success(rewritten)
  }
}

/// The words of transfers.
@MainActor
enum TransferText {
  /// «Комиссия пойдёт в «Комиссии» — она вернётся из архива», and «… вместе с «Банк»» when
  /// the parent comes back too.
  static func feeComingBack(
    _ back: FeeCategoryComingBack, _ environment: AppEnvironment
  ) -> String {
    guard let parent = back.parent else {
      return environment.format(
        "transfer.fee.fromArchive", table: AccountText.table, back.category)
    }
    return environment.format(
      "transfer.fee.fromArchiveWithParent", table: AccountText.table, back.category, parent)
  }

  /// What the refusal says.
  static func message(_ refusal: TransferRefusal, _ environment: AppEnvironment) -> String {
    func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }
    switch refusal {
    case .noFrom: return t("transfer.refusal.noFrom")
    case .noTo: return t("transfer.refusal.noTo")
    case .negativeFee: return t("transfer.refusal.negativeFee")
    case .notFound: return t("account.refusal.notFound")
    case .feeRefunded: return t("transfer.refusal.feeRefunded")
    case .feeMoneyBack: return t("transfer.refusal.feeMoneyBack")
    case .rateMissing(let currency):
      return environment.format(
        "transfer.refusal.rateMissing", table: AccountText.table, currency.code)
    case .issue(let issue):
      switch issue {
      case .sameKey: return t("transfer.refusal.sameKey")
      case .currencyNotHeld(let side):
        return t(side == .from ? "transfer.refusal.fromCurrency" : "transfer.refusal.toCurrency")
      case .archivedAccount: return t("transfer.refusal.archived")
      case .amountsDiffer: return t("transfer.refusal.amountsDiffer")
      case .notPositive: return t("transfer.refusal.notPositive")
      }
    }
  }

  /// The rate an exchange implies, the stronger currency counted as one unit: «1 € = 98.5 ₽»,
  /// never «1 ₽ = 0.0102 €».
  static func rate(
    sent: AmountE4, from: CurrencyCode, received: AmountE4, to: CurrencyCode,
    money: MoneyFormatter
  ) -> String? {
    guard from != to, sent.raw > 0, received.raw > 0 else { return nil }
    let perSent = received.decimal / sent.decimal
    if perSent >= 1 {
      return
        "1\u{00A0}\(money.symbol(for: from)) = \(money.rate(perSent))\u{00A0}\(money.symbol(for: to))"
    }
    let perReceived = sent.decimal / received.decimal
    return
      "1\u{00A0}\(money.symbol(for: to)) = \(money.rate(perReceived))\u{00A0}\(money.symbol(for: from))"
  }
}
