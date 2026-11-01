import AppCore
import Foundation

/// A line saved by a command — «кофе 250», «+ 50000 зарплата», «перевод 5000 сбер т-банк» —
/// with the very steps Return in the entry line takes (`EntryBar.saveTheLine` and `commit`), in
/// the same order: the line read by the same interpreter, the defaults and the rules laid by the
/// same draft, then the refusals and the questions of the line, then `EntrySave.write`.
///
/// Where the line opens its panel or a sheet for a choice — no category said, the purchase a
/// refund takes money back from, money back from a person, the parts of a loan payment above its
/// due, a count made earlier that day — a command cannot choose for the owner: it writes nothing
/// and says what to choose in the window. The questions answered with «Записать всё равно» — a
/// date ahead, a card past its limit, a balance below its minimum, a repeat of the last minutes,
/// a pause before a big purchase, the mileage of a fill-up — come back as `.question`; the same
/// command with `confirmed` answers them as that button does.
@MainActor
struct EntryLineCommand {
  let commands: MacCommands

  private var environment: AppEnvironment { commands.environment }
  private var store: TransactionsStore { commands.store }
  private var compute: ComputeStore { commands.compute }

  private var interpreter: any LineInterpreter {
    TaggingInterpreter(
      base: CoreLineInterpreter(
        vocabulary: environment.vocabulary, calendar: environment.calendar,
        catalog: environment.currencyCatalog))
  }

  private func entryText(_ key: String) -> String { environment.language(key, table: "Entry") }

  func save(_ line: String, confirmed: Bool) async -> CommandOutcome {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .refused(entryText("entry.error.amountMissing")) }
    let model = EntryDraftModel(environment: environment)
    model.reload()

    let reading = interpreter.read(trimmed, today: environment.today, kind: model.draft.kind)
    let parsed = reading.parsed
    if parsed.dateProblem != nil || reading.timeProblem != nil {
      return .refused(commands.t("mac.command.badDate"))
    }
    guard let typed = parsed.amount else {
      return .refused(entryText(parsed.missingAmountErrorKey))
    }
    let amount: AmountE4
    do {
      amount = try AmountE4(decimal: typed)
    } catch CoreError.amountOutOfRange {
      return .refused(entryText("entry.error.amountTooLarge"))
    } catch {
      return .refused(entryText("entry.error.badExpression"))
    }
    model.apply(reading, amount: amount, today: environment.today, text: trimmed)
    model.applyRules(
      compute.snapshot?.dataset.rules ?? [], lineTags: TagText.extract(from: trimmed).tags,
      calendar: environment.calendar)
    if let transfer = parsed.transfer {
      return await saveTransfer(transfer, model: model)
    }
    if let refusal = model.saveRefusalKey { return .refused(entryText(refusal)) }
    return commit(model, confirmed: confirmed)
  }

  /// `EntryBar.commit`, without a window: what it would open for a choice is said instead.
  private func commit(_ model: EntryDraftModel, confirmed: Bool) -> CommandOutcome {
    model.takeTheMomentOfSaving(now: commands.now())
    if let refusal = model.saveRefusalKey { return .refused(entryText(refusal)) }
    if model.needsRefundPurchase { return .refused(commands.t("mac.command.refundPurchase")) }
    if model.gapToAsk() != nil { return .refused(commands.t("mac.command.categoryMissing")) }
    let money = EntrySaveQuestions.Money(compute.snapshot)
    // The same questions in the same order; each answered as «Записать всё равно» answers it
    // when the command says so, and asked again only when it does not.
    var asked = 0
    while let question = EntrySaveQuestions.next(
      for: model, environment: environment, money: money, now: commands.now())
    {
      guard confirmed, asked < EntrySaveQuestions.Kind.allCases.count else {
        return .question(Self.words(of: question, commands))
      }
      asked += 1
      switch question {
      case .ahead: model.aheadAnswered = true
      case .overLimit: model.overLimitAnswered = true
      case .minBalance: model.minBalanceAnswered = true
      case .repeated: model.repeatConfirmed = true
      case .pause: model.pauseAnswered = true
      case .mileage(let mileage): model.answerMileage(nil, previous: mileage.previous)
      }
    }
    switch model.countAsk(
      savedAt: commands.now(), balances: compute.snapshot?.planning.accounts.balances ?? .empty,
      remembered: environment.rememberedCountAnswers())
    {
    case .none: break
    case .answered(let stamp): model.stampCount(stamp)
    case .ask: return .refused(commands.t("mac.command.countQuestion"))
    }
    if model.prepayChoice == nil, asksAboutPrepayment(model) {
      return .refused(commands.t("mac.command.prepayQuestion"))
    }
    if model.instalmentPlanOfTheRefund != nil {
      return .refused(commands.t("mac.command.instalmentReturn"))
    }
    if model.recordsThroughReimbursementSheet {
      return .refused(commands.t("mac.command.moneyBack"))
    }
    do {
      guard let written = try EntrySave.write(model, environment: environment, store: store)
      else { return .refused(entryText("entry.error.notSaved")) }
      CategoryLearning.saved(
        written.entry, choice: model.categoryChoice(), environment: environment)
      let state = model.ruleState
      let ruleTags = state.ruleTags.map(\.value)
      if !state.typedTags.isEmpty || !ruleTags.isEmpty {
        store.tag(
          parts: written.entry.parts.map(\.id), names: state.typedTags, ruleTagIds: ruleTags)
      }
      if written.openedCredit?.isNew == true { environment.refreshVocabulary() }
      AppLog.info("commands.added", .db, "a command added an operation")
      let summary = QuickEntrySummary.text(of: model, environment: environment)
      model.reset()
      return .done(commands.f("mac.command.saved", summary))
    } catch {
      return .refused(entryText(EntryCommit.errorKey(of: error)))
    }
  }

  /// A payment of a loan above its due asks how the bank takes the rest (`DebtPrepayment`).
  private func asksAboutPrepayment(_ model: EntryDraftModel) -> Bool {
    guard let debt = model.debtBeingPaid, debt.currency == model.draft.currency else {
      return false
    }
    let snapshot = compute.snapshot
    let dues = snapshot?.planning.debts.iOwe.first { $0.debt.id == debt.id }?.dues
    let journal =
      (try? environment.references?.debtEntries(debtId: debt.id))
      ?? snapshot?.dataset.planning.debtEntries.filter { $0.debtId == debt.id } ?? []
    return DebtPrepayment.question(
      debt: debt, amount: model.draft.amount,
      day: environment.calendar.day(of: model.draft.occurredAt), dues: dues, journal: journal)
      != nil
  }

  /// «перевод 5000 сбер т-банк»: written when the line names both accounts in one currency, as
  /// the line writes it at once; otherwise the owner finishes it in the window.
  private func saveTransfer(
    _ reading: TransferReading, model: EntryDraftModel
  ) async
    -> CommandOutcome
  {
    let form = TransferForm(
      fromTheLine: reading, draft: model.draft, accounts: model.paymentMethods,
      calendar: environment.calendar)
    guard form.savesAtOnce(reading) else {
      return .refused(commands.t("mac.command.transferIncomplete"))
    }
    let actions = TransferActions(environment: environment, store: store)
    guard let books = await actions.books() else {
      return .refused(entryText("entry.error.notSaved"))
    }
    let entry = TransferEntry(form: form, fromTheLine: true)
    entry.books = books
    entry.tripIsOn = environment.tripEntryDefaults != nil
    entry.rubPerUnit = environment.rubPerUnitReader(on: form.day)
    entry.layCreditFee(accounts: books.dataset.paymentMethods)
    let now = commands.now()
    var occurredAt = entry.form.occurredAt(now: now, calendar: environment.calendar)
    if case .failure(let refusal) = actions.change(
      for: entry.form, occurredAt: occurredAt, books: books)
    {
      return .refused(TransferText.message(refusal, environment))
    }
    switch actions.countStep(for: entry.form, occurredAt: occurredAt, books: books, now: now) {
    case .none: break
    case .answered(let stamp): occurredAt = stamp
    case .ask: return .refused(commands.t("mac.command.countQuestion"))
    }
    let summary = QuickEntrySummary.text(
      of: entry.form, accounts: model.paymentMethods, environment: environment)
    switch actions.save(entry.form, occurredAt: occurredAt, books: books) {
    case .done:
      AppLog.info("commands.transferred", .db, "a command added a transfer")
      return .done(commands.f("mac.command.saved", summary))
    case .refused(let refusal):
      return .refused(TransferText.message(refusal, environment))
    case .failed:
      return .refused(entryText("entry.error.notSaved"))
    }
  }

  /// The question as the window asks it, in words a command can say.
  static func words(of question: EntrySaveQuestions.Question, _ commands: MacCommands) -> String {
    let environment = commands.environment
    let asked: String
    switch question {
    case .ahead(let ahead): asked = ahead.title(environment)
    case .overLimit(let over): asked = over.title(environment)
    case .minBalance(let minimum): asked = minimum.title(environment)
    case .repeated(let same): asked = same.message(environment)
    case .pause(let pause): asked = pause.message(environment)
    case .mileage: asked = commands.t("mac.command.mileage")
    }
    return commands.f("mac.command.confirm", asked)
  }
}
