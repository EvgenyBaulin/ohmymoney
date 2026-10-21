import AppCore
import AppDatabase
import SwiftUI

/// The interest of one statement of a credit card to record: the card, its currency, the day of
/// the statement and the estimate the form starts with.
struct CreditInterestPrefill: Identifiable, Hashable, Sendable {
  var accountId: UUID
  var currency: CurrencyCode
  var statementDay: DateOnly
  var amount: AmountE4

  var id: String { CreditInterest.recordKey(account: accountId, statementDay: statementDay) }
}

/// Why the interest of a statement was not recorded.
enum CreditInterestRefusal: Error, Hashable, Sendable {
  case notFound
  /// Nothing above zero to record.
  case noAmount
  /// The interest of this statement was recorded and then deleted: it is in the bin, and comes
  /// back from there.
  case inTheBin
}

/// «Записать проценты»: the expense of the interest of one statement, on the card, dated on the
/// day of the statement, in «Кредиты → Проценты по кредитке». The sum starts at the estimate; the
/// owner corrects it to what the statement says, and the recorded sum replaces the estimate of
/// that statement. Recorded twice, the second sum writes over the first. One step of ⌘Z; a day
/// of a count asks whether it came before it, like every form that moves money.
struct CreditInterestRecordSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute

  let prefill: CreditInterestPrefill
  let finish: () -> Void

  @State private var amount: AmountE4 = .zero
  @State private var loaded = false
  @State private var refusal: CreditInterestRefusal?

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  private var moment: Date { environment.calendar.noon(of: prefill.statementDay) }

  var body: some View {
    VStack(alignment: .leading) {
      Text(verbatim: t("account.credit.recordTitle"))
        .appFont(.headline)
      Text(
        verbatim: environment.format(
          "account.credit.recordStatement", table: AccountText.table, cardName,
          environment.dates.longDay(prefill.statementDay))
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
      Form {
        LabeledContent(t("account.credit.recordAmount")) {
          HStack {
            AmountField(amount: $amount, locale: environment.language.locale)
              .accessibilityIdentifier("account.credit.recordAmount")
            Text(verbatim: prefill.currency.code).foregroundStyle(.secondary)
          }
        }
        LabeledContent(t("account.credit.recordCategory")) {
          Text(verbatim: categoryName)
        }
        Text(verbatim: t("account.credit.recordHint"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let refusal {
          Label {
            Text(verbatim: t(Self.refusalKey(refusal)))
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      CountingFormButtons(
        title: t("account.credit.recordSave"), enabled: amount.raw > 0,
        failure: { refusal.map { t(Self.refusalKey($0)) } ?? "" }, ask: question,
        moment: { moment }
      ) { at in
        switch actions.recordCreditInterest(
          prefill, amount: amount, at: at ?? moment, dataset: compute.snapshot?.dataset)
        {
        case .success: return true
        case .failure(let reason):
          refusal = reason
          return false
        }
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 380)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      amount = prefill.amount
    }
    .onDisappear(perform: finish)
  }

  static func refusalKey(_ refusal: CreditInterestRefusal) -> String {
    switch refusal {
    case .notFound: "account.credit.refusal.notFound"
    case .noAmount: "account.credit.refusal.noAmount"
    case .inTheBin: "account.credit.refusal.inTheBin"
    }
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  private var cardName: String {
    compute.snapshot?.dataset.paymentMethods.first { $0.id == prefill.accountId }?.name ?? ""
  }

  /// The category the interest goes to: the one remembered, or the one the save will make.
  private var categoryName: String {
    let dataset = compute.snapshot?.dataset
    let id = dataset?.debtSettings.creditInterestCategoryId
    return dataset?.categories.first { $0.id == id && !$0.archived }?.name
      ?? t("account.credit.category")
  }

  /// «Это было до сверки?» when the expense is dated on the day of a count of the card.
  private func question() -> DueCountAsk {
    guard
      let entry = try? actions.creditInterestEntry(
        prefill, amount: amount, at: moment, categoryId: UUID())
    else { return .none }
    return .sameDay(
      FormAccounts.countAsk(
        about: entry, savedAt: Date(), snapshot: compute.snapshot,
        calendar: environment.calendar, remembered: environment.rememberedCountAnswers()))
  }
}

// MARK: - The category of the interest of credit cards

extension AccountActions {
  /// The names a subcategory of the interest of credit cards may already have, folded.
  nonisolated static let creditInterestNames: Set<String> = [
    NameKey.fold("Проценты по кредитке"), NameKey.fold("Credit card interest"),
  ]

  /// The category the interest of credit cards goes to, the first that applies:
  ///
  /// 1. the one remembered (`cards.creditInterestCategory`), while it is a live expense
  ///    category under a live parent;
  /// 2. a live expense subcategory of «Кредиты» called «Проценты по кредитке» (or `name`);
  /// 3. the one remembered, when it or its parent is in the archive: both come back;
  /// 4. such a subcategory of «Кредиты» in the archive: it comes back;
  /// 5. a new subcategory of «Кредиты» called `name` — at the top level of spending when there
  ///    is no «Кредиты».
  nonisolated static func creditInterestCategory(
    categories: [CoreKit.Category], remembered: UUID?, loansId: UUID?, name: String
  ) -> InterestCategoryChoice {
    let byId = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func parent(of category: CoreKit.Category) -> CoreKit.Category? {
      category.parentId.flatMap { byId[$0] }
    }
    func isLive(_ category: CoreKit.Category) -> Bool {
      !category.archived && parent(of: category).map { !$0.archived } ?? true
    }
    var names = creditInterestNames
    names.insert(NameKey.fold(name))
    let remembered = remembered.flatMap { byId[$0] }.flatMap { $0.kind == .expense ? $0 : nil }
    if let remembered, isLive(remembered) { return .existing(remembered.id) }
    let named = categories.filter {
      $0.kind == .expense && $0.parentId == loansId && loansId != nil
        && names.contains(NameKey.fold($0.name))
    }
    if let live = named.first(where: { isLive($0) }) { return .existing(live.id) }
    if let remembered {
      let back = [parent(of: remembered), remembered].compactMap { $0 }.filter(\.archived)
        .map { category -> CoreKit.Category in
          var category = category
          category.archived = false
          return category
        }
      return .revive(remembered.id, back)
    }
    if var archived = named.first {
      archived.archived = false
      return .revive(archived.id, [archived])
    }
    let siblings = categories.filter { $0.parentId == loansId && $0.kind == .expense }
    return .create(
      CoreKit.Category(
        parentId: loansId, kind: .expense, name: name,
        sort: (siblings.map(\.sort).max() ?? 0) + 1))
  }

  /// The expense of the interest of a statement as the books keep it: one part in
  /// `categoryId`, on the card, with the key of the statement (`ccinterest:…`).
  func creditInterestEntry(
    _ prefill: CreditInterestPrefill, amount: AmountE4, at: Date, categoryId: UUID
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: at, currency: prefill.currency, amount: amount,
      paymentMethodId: prefill.accountId)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = categoryId
    draft.parts[0].categorySource = .manual
    environment.applyRate(to: &draft)
    var entry = try draft.materialize(
      now: environment.now(), rublesConverter: environment.rublesConverter(for: draft))
    entry.transaction.externalId = CreditInterest.recordKey(
      account: prefill.accountId, statementDay: prefill.statementDay)
    return entry
  }

  /// Records the interest of a statement — or writes the new sum over the one recorded —, and
  /// makes or brings back the category of the interest of credit cards in the same write, with
  /// the setting that remembers it: one step of ⌘Z. `dataset` is the data the form was shown
  /// on.
  func recordCreditInterest(
    _ prefill: CreditInterestPrefill, amount: AmountE4, at: Date, dataset: Dataset?
  ) -> Result<Void, CreditInterestRefusal> {
    guard amount.raw > 0 else { return .failure(.noAmount) }
    guard let dataset,
      dataset.paymentMethods.contains(where: { $0.id == prefill.accountId && $0.credit != nil })
    else { return .failure(.notFound) }
    let key = CreditInterest.recordKey(
      account: prefill.accountId, statementDay: prefill.statementDay)
    let existing = dataset.entries.first { $0.transaction.externalId == key }
    if existing?.transaction.isDeleted == true { return .failure(.inTheBin) }
    let now = environment.now()
    var change = PlanningChange(at: now)
    let tree = CategoryTree(dataset.categories)
    let remembered = dataset.debtSettings.creditInterestCategoryId
    let choice = Self.creditInterestCategory(
      categories: dataset.categories, remembered: remembered,
      loansId: tree.systemCategory(.loans)?.id,
      name: environment.language("account.credit.category", table: AccountText.table))
    switch choice {
    case .existing: break
    case .revive(_, let categories): change.upsert.categories += categories
    case .create(let category): change.upsert.categories.append(category)
    }
    if remembered != choice.categoryId {
      change.settings.updateValue(
        choice.categoryId.uuidString, forKey: DebtSettings.creditInterestCategoryKey)
    }
    do {
      var entry = try creditInterestEntry(
        prefill, amount: amount, at: at, categoryId: choice.categoryId)
      if let existing {
        // The same statement again: the new sum over the recorded one, the rest kept.
        var rewritten = existing
        rewritten.transaction.amountE4 = entry.transaction.amountE4
        rewritten.transaction.amountRubE4 = entry.transaction.amountRubE4
        rewritten.parts = existing.parts.prefix(1).map { part in
          var part = part
          part.amountE4 = entry.transaction.amountE4
          return part
        }
        entry = rewritten
        change.rewritten = [entry]
      } else {
        change.created = [entry]
      }
    } catch {
      return .failure(.notFound)
    }
    guard apply(change) == .done else { return .failure(.notFound) }
    AppLog.info(
      "cards.interestRecorded", .db, "the interest of a credit card was recorded",
      [LogPair("account", .id(prefill.accountId)), LogPair("again", .flag(existing != nil))])
    return .success(())
  }

  // MARK: «Оставить только счёт»

  /// «Оставить только счёт» of a credit card kept both as an account and as a debt of the kind
  /// `credit_card`: the debt is deleted softly — its live subcategory of «Кредиты» goes to the
  /// archive, as any deleted debt's —, its rate becomes the account's rate of purchases when
  /// that has none, and an account without terms takes `terms` (the sheet asks for the limit).
  /// One step of ⌘Z. Refused when the account has no terms and none are given.
  func keepOnlyAccount(
    debt: Debt, account: PaymentMethod, terms: CreditCardTerms? = nil
  ) -> AccountActionOutcome {
    guard CreditCardDebtMerge.offered(for: debt) else { return .refused(.notFound) }
    var account = account
    if account.credit == nil { account.credit = terms }
    guard account.credit != nil else { return .refused(.credit(.limit)) }
    let now = environment.now()
    var merged = CreditCardDebtMerge.keepOnlyAccount(debt: debt, account: account)
    merged.debtDeleted.deletedAt = now
    var rows = PlanningRows(paymentMethods: [merged.account])
    rows.debts = [merged.debtDeleted]
    let categories = (try? environment.references?.categories(includeArchived: true)) ?? []
    if let id = debt.loansSubcategoryId,
      var subcategory = categories.first(where: { $0.id == id }), !subcategory.archived
    {
      subcategory.archived = true
      rows.categories = [subcategory]
    }
    let outcome = apply(PlanningChange(upsert: rows, at: now))
    if outcome == .done {
      AppLog.info(
        "cards.credit.saved", .db, "a credit card kept as a debt is kept as its account only",
        [LogPair("account", .id(account.id)), LogPair("debt", .id(debt.id))])
    }
    return outcome
  }
}
