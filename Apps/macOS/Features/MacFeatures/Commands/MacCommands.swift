import AppCore
import Foundation

/// What a command from outside the windows comes to: «Быстрые команды» (App Intents) and
/// AppleScript call the same `MacCommands`, so the two never answer differently.
enum CommandOutcome: Equatable, Sendable {
  /// Done; the words say what was written or read.
  case done(String)
  /// A question the entry line or the editor would ask first («Такая же операция уже
  /// записана…»): nothing is written; the same command with `confirmed` writes it anyway.
  case question(String)
  /// Not done, and why — the app is locked, read-only, or the command needs the owner's choice
  /// in a window.
  case refused(String)

  var text: String {
    switch self {
    case .done(let text), .question(let text), .refused(let text): text
    }
  }
}

/// An operation as a command names it: what Shortcuts lists as a choice and what a search
/// returns. The amount is written as the interface writes it, so «Скрыть суммы» masks it too.
struct CommandOperation: Equatable, Sendable, Identifiable {
  let id: UUID
  let day: DateOnly
  let title: String
  let amount: String
}

/// The commands of the Mac — read the summary of a month, add an operation with a line, a
/// transfer with a line, change or delete an operation — over the same machinery the windows
/// use: every write goes through `TransactionsStore` (one step of ⌘Z, the copy after every
/// change, the read-only gate), every new operation through the same reading of the line and
/// the same questions as the entry line (`EntryLineCommand`), every edit through the editor of a
/// saved operation (`TransactionEditorModel`).
///
/// Nothing here goes around the lock or «Только просмотр»: a locked app reads and writes
/// nothing, a read-only one only reads. The hidden accounts are never named by a command — not
/// even while they are shown in the windows — because what a command answers is read outside
/// the app.
@MainActor
struct MacCommands {
  let dependencies: AppDependencies
  /// The moment of a command; tests set it.
  var now: () -> Date = Date.init

  var environment: AppEnvironment { dependencies.environment }
  var store: TransactionsStore { dependencies.store }
  var compute: ComputeStore { dependencies.compute }

  static let table = "MacFeatures"

  func t(_ key: String) -> String { environment.language(key, table: Self.table) }

  func f(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: t(key), locale: environment.language.locale, arguments: arguments)
  }

  // MARK: The gate

  /// Why nothing can be done now, or `nil`. `writes` — the command would change the data.
  func refusal(writes: Bool) -> String? {
    if environment.lock.isLocked { return t("mac.command.locked") }
    guard store.isAttached, snapshot != nil else { return t("mac.command.notReady") }
    if writes, environment.shield.isReadOnly { return t("mac.command.readOnly") }
    return nil
  }

  /// The books without the hidden accounts, whether or not the windows show them now.
  var snapshot: DataSnapshot? {
    guard let whole = compute.wholeSnapshot else { return nil }
    return whole.presented(hiding: HiddenAccounts(accounts: whole.ledger.dataset.paymentMethods))
  }

  /// The operations a command may name: those the presented books list, never a hidden
  /// account's.
  private func visibleEntry(_ id: UUID) -> TransactionEntry? {
    guard let snapshot, let entry = snapshot.ledger.entry(id), entry.transaction.deletedAt == nil
    else { return nil }
    return HiddenOperations(snapshot: snapshot).hides(entry) ? nil : entry
  }

  // MARK: Reading

  /// The operations whose description, place or category holds `text` (letters folded, «ё» as
  /// «е»), newest first; every operation when `text` is empty.
  func operations(matching text: String, limit: Int = 50) -> [CommandOperation] {
    guard refusal(writes: false) == nil, let snapshot else { return [] }
    let hidden = HiddenOperations(snapshot: snapshot)
    let names = SummaryNames(dataset: snapshot.dataset)
    let wanted = NameKey.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
    var found: [CommandOperation] = []
    let entries = snapshot.ledger.dataset.entries.sorted {
      $0.transaction.occurredAt > $1.transaction.occurredAt
    }
    for entry in entries where entry.transaction.deletedAt == nil && !hidden.hides(entry) {
      let line = describe(entry, names: names)
      if !wanted.isEmpty {
        let words =
          [
            entry.transaction.note,
            entry.transaction.placeId.flatMap { names.places[$0] },
          ] + entry.parts.map { $0.categoryId.flatMap { names.categories[$0] } }
        guard words.compactMap({ $0 }).contains(where: { NameKey.fold($0).contains(wanted) })
        else { continue }
      }
      found.append(line)
      if found.count == limit { break }
    }
    return found
  }

  /// The operations with these ids that a command may name, in the order asked.
  func operations(ids: [UUID]) -> [CommandOperation] {
    guard refusal(writes: false) == nil, let snapshot else { return [] }
    let names = SummaryNames(dataset: snapshot.dataset)
    return ids.compactMap { id in visibleEntry(id).map { describe($0, names: names) } }
  }

  private func describe(_ entry: TransactionEntry, names: SummaryNames) -> CommandOperation {
    let transaction = entry.transaction
    let title =
      transaction.note.flatMap { $0.isEmpty ? nil : $0 }
      ?? transaction.placeId.flatMap { names.places[$0] }
      ?? entry.parts.first?.categoryId.flatMap { names.categories[$0] }
      ?? t("mac.command.untitled")
    return CommandOperation(
      id: entry.id, day: environment.calendar.day(of: transaction.occurredAt), title: title,
      amount: environment.money.exact(transaction.amountE4, currency: transaction.currency))
  }

  /// The summary of a month as Markdown — the last finished month when none is named. With
  /// «Скрыть суммы» on, without amounts.
  func monthSummary(_ month: MonthKey?) -> CommandOutcome {
    if let refusal = refusal(writes: false) { return .refused(refusal) }
    guard
      let text = MonthMarkdownExport.text(
        month: month ?? environment.today.monthKey.previous, dependencies: dependencies,
        hidesAmounts: environment.amounts.isHidingNow)
    else { return .refused(t("mac.command.notReady")) }
    return .done(text)
  }

  // MARK: Writing

  /// A new operation — or a transfer, «перевод 5000 сбер т-банк» — from a line, read and saved
  /// exactly as Return in the entry line saves it.
  func add(
    line: String, confirmed: Bool = false, bankFields: BankStoredFields? = nil
  ) async -> CommandOutcome {
    if let refusal = refusal(writes: true) { return .refused(refusal) }
    return await EntryLineCommand(commands: self).save(
      line, confirmed: confirmed, bankFields: bankFields)
  }

  /// Deletes an operation: the rules and the one step of ⌘Z of «Удалить» in the list.
  func delete(_ id: UUID) -> CommandOutcome {
    if let refusal = refusal(writes: true) { return .refused(refusal) }
    guard let entry = visibleEntry(id), let snapshot else {
      return .refused(t("mac.command.notFound"))
    }
    let plan = store.planDeletion(ids: [id])
    guard plan.changedIds.contains(id) else { return .refused(t("mac.command.deleteRefused")) }
    let title = describe(entry, names: SummaryNames(dataset: snapshot.dataset)).title
    guard store.delete(ids: [id]) else { return .refused(t("mac.command.deleteRefused")) }
    AppLog.info("commands.deleted", .db, "a command deleted an operation")
    return .done(f("mac.command.deleted", title))
  }

  /// Changes the description, the amount or the category of an operation, through the editor of
  /// a saved operation: the same rules, the same questions about a card's limit and a kept
  /// balance, one step of ⌘Z. `nil` leaves a field as it is.
  func edit(
    _ id: UUID, description: String? = nil, amount: Decimal? = nil, category: String? = nil,
    confirmed: Bool = false
  ) -> CommandOutcome {
    if let refusal = refusal(writes: true) { return .refused(refusal) }
    guard let entry = visibleEntry(id), let snapshot else {
      return .refused(t("mac.command.notFound"))
    }
    let tree = CategoryTree(snapshot.dataset.categories)
    let title = describe(entry, names: SummaryNames(dataset: snapshot.dataset)).title
    let editor = TransactionEditorModel(entry: entry, environment: environment, tree: tree)
    let model = editor.draft
    if let description {
      let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
      model.draft.note = trimmed.isEmpty ? nil : trimmed
    }
    if let amount {
      guard model.draft.parts.count == 1 else { return .refused(t("mac.command.splitAmount")) }
      guard let value = try? AmountE4(decimal: amount), value.raw > 0 else {
        return .refused(environment.language("entry.error.amountNotPositive", table: "Entry"))
      }
      model.setTotal(value)
    }
    if let category {
      let wanted = NameKey.fold(category.trimmingCharacters(in: .whitespacesAndNewlines))
      let kind = model.draft.kind.categoryKind
      guard
        let found = model.categories.first(where: {
          $0.kind == kind && NameKey.fold($0.name) == wanted
        })
      else { return .refused(f("mac.command.categoryUnknown", category)) }
      for index in model.draft.parts.indices { model.setCategory(found.id, forPartAt: index) }
    }
    guard editor.hasChanges else { return .done(f("mac.command.unchanged", title)) }
    let money = EntrySaveQuestions.Money(compute.wholeSnapshot)
    let balances = compute.wholeSnapshot?.planning.accounts.balances ?? .empty
    var saved = editor.save(
      store: store, environment: environment, balances: balances, money: money, now: now())
    if !saved, let question = editor.saveQuestion {
      guard confirmed else { return .question(EntryLineCommand.words(of: question, self)) }
      if case .mileage(let asked) = question {
        editor.answerMileage(asked, km: nil)
      } else {
        editor.answerSaveQuestion()
      }
      saved = editor.save(
        store: store, environment: environment, balances: balances, money: money, now: now())
    }
    if saved {
      AppLog.info("commands.edited", .db, "a command changed an operation")
      return .done(f("mac.command.edited", title))
    }
    if editor.countQuestion != nil { return .refused(t("mac.command.countQuestion")) }
    if editor.archivedLeftovers != nil { return .refused(t("mac.command.archivedLeftovers")) }
    return .refused(
      environment.language(editor.errorKey ?? "entry.error.notSaved", table: "Entry"))
  }
}

extension TransactionKind {
  /// The kind of the categories an operation of this kind is filed under.
  fileprivate var categoryKind: CategoryKind {
    switch self {
    case .income: .income
    case .expense, .refund, .reimbursement: .expense
    }
  }
}
