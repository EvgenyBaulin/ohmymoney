import AppCore
import AppDatabase
import SwiftUI

/// «Категории кэшбэка на месяц»: what the bank offers this month, which of it to take — the
/// app counts the best choice by the purchases of the last three months —, and the bank's table
/// «категория банка → ваша». «Сохранить» writes the offers and the table, and the month's rules
/// of the account for the labels taken (one step of ⌘Z for the rules).
struct CashbackChoiceSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss

  let accountId: UUID
  let month: MonthKey

  @State private var draft: CashbackChoiceDraft?
  @State private var choices: [CoreKit.Category] = []
  @State private var spending: [UUID: AmountE4] = [:]
  @State private var failed = false

  static let table = "SyncHistory"
  private func t(_ key: String) -> String { environment.language(key, table: "SyncHistory") }

  private var account: PaymentMethod? {
    store.listing?.dataset.paymentMethods.first { $0.id == accountId }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        verbatim: environment.format(
          "cashback.choice.title", table: "SyncHistory", account?.name ?? "—",
          environment.dates.monthTitle(month))
      )
      .appFont(.headline)
      if let draft {
        form(draft)
      } else {
        ProgressView()
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save"), action: save)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(draft?.canSave != true || store.isWritingInBackground)
          .accessibilityIdentifier("cashback.choice.save")
      }
    }
    .padding(20)
    .sheetFrame(width: 600, height: 640)
    .task { load() }
    .refusedWriteAlert($failed, environment)
  }

  private func load() {
    guard let ledger = store.listing else { return }
    let dataset = ledger.dataset
    let actions = CardActions(environment: environment, store: store)
    let categories = actions.categories
    choices = CashbackRules.categoryChoices(
      tree: CategoryTree(categories), categories: categories,
      reconcileCategoryIds: actions.reconcileCategoryIds)
    spending = CashbackChoiceAdvisor.monthlySpending(ledger: ledger, before: month)
    let book = dataset.cashbackChoice
    let previous = book.offers(of: accountId, month: month.previous).filter(\.chosen).count
    draft = CashbackChoiceDraft(
      accountId: accountId, bankId: account?.bankId, month: month, offers: book.offers,
      mappings: book.mappings, previousChosen: previous > 0 ? previous : nil)
  }

  private var binding: Binding<CashbackChoiceDraft>? {
    guard let current = draft else { return nil }
    return Binding(get: { draft ?? current }, set: { draft = $0 })
  }

  @ViewBuilder
  private func form(_ current: CashbackChoiceDraft) -> some View {
    if let model = binding {
      Form {
        Section {
          ForEach(model.rows) { $row in
            HStack {
              Toggle(isOn: $row.chosen) { EmptyView() }
                .labelsHidden()
                #if os(macOS)
                  .toggleStyle(.checkbox)
                #endif
                .help(t("cashback.choice.take"))
              TextField(text: $row.label) { Text(verbatim: t("cashback.choice.label")) }
                .labelsHidden()
              TextField(text: $row.percentText) { Text(verbatim: t("cashback.choice.percent")) }
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 60)
              Text(verbatim: "%").foregroundStyle(.secondary)
              Button {
                draft?.rows.removeAll { $0.id == row.id }
              } label: {
                Image(systemName: "minus.circle")
                  .accessibilityLabel(Text(verbatim: t("cashback.choice.remove")))
              }
              .buttonStyle(.borderless)
            }
            if current.problems.contains(row.id) {
              Label {
                Text(verbatim: t("cashback.choice.percentUnreadable"))
              } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
              }
              .appFont(.caption)
            }
          }
          Button(t("cashback.choice.add")) { draft?.rows.append(.init()) }
          Stepper(value: model.pick, in: 1...10) {
            Text(
              verbatim: environment.format(
                "cashback.choice.pick", table: "SyncHistory", current.pick))
          }
        } header: {
          Text(verbatim: t("cashback.choice.offered"))
        } footer: {
          Text(verbatim: t("cashback.choice.offeredHint")).foregroundStyle(.secondary)
        }
        bestSection(current)
        mappingSection(current, model: model)
      }
      .formStyle(.grouped)
    }
  }

  @ViewBuilder
  private func bestSection(_ current: CashbackChoiceDraft) -> some View {
    let tree = CategoryTree(store.listing?.dataset.categories ?? [])
    let picks = current.best(
      spending: spending, tree: tree, accountCap: account?.cashbackMonthlyCapE4)
    Section {
      if picks.isEmpty || picks.allSatisfy({ $0.expectedRub.isZero }) {
        Text(verbatim: t("cashback.choice.noBest")).foregroundStyle(.secondary)
      } else {
        ForEach(Array(picks.enumerated()), id: \.offset) { _, pick in
          HStack {
            let labels = pick.offerIds.compactMap { id in
              current.rows.first { $0.id == id }?.label
            }
            Text(verbatim: labels.joined(separator: " + "))
            Spacer()
            Text(
              verbatim: environment.format(
                "cashback.choice.perMonth", table: "SyncHistory",
                environment.money.rounded(pick.expectedRub, currency: .rub))
            )
            .monospacedDigit()
            .foregroundStyle(.secondary)
            Button(t("cashback.choice.takeThese")) { draft?.take(pick) }
          }
        }
      }
      ForEach(current.unmappedChosen, id: \.self) { label in
        Label {
          Text(
            verbatim: environment.format("cashback.choice.unmapped", table: "SyncHistory", label))
        } icon: {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        .appFont(.caption)
      }
    } header: {
      Text(verbatim: t("cashback.choice.best"))
    } footer: {
      Text(verbatim: t("cashback.choice.bestHint")).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func mappingSection(
    _ current: CashbackChoiceDraft, model: Binding<CashbackChoiceDraft>
  ) -> some View {
    Section {
      if current.bankId == nil {
        Text(verbatim: t("cashback.choice.noBank")).foregroundStyle(.secondary)
      } else {
        let labels = Array(
          Set(current.rows.filter { !$0.isBlank }.map { BankCategoryMapping.normalized($0.label) })
        ).sorted()
        ForEach(labels, id: \.self) { key in
          let shown =
            current.rows.first { BankCategoryMapping.normalized($0.label) == key }?.label ?? key
          Picker(
            selection: Binding(
              get: { current.mapping[key] },
              set: { draft?.mapping[key] = $0 })
          ) {
            Text(verbatim: t("cashback.choice.notMapped")).tag(UUID?.none)
            ForEach(choices, id: \.id) { category in
              Text(verbatim: category.parentId == nil ? category.name : "    " + category.name)
                .tag(UUID?.some(category.id))
            }
          } label: {
            Text(verbatim: shown)
          }
        }
      }
    } header: {
      Text(verbatim: t("cashback.choice.mapping"))
    } footer: {
      Text(verbatim: t("cashback.choice.mappingHint")).foregroundStyle(.secondary)
    }
  }

  private func save() {
    guard let draft, draft.canSave, let stack = environment.stack else { return }
    let repository = CashbackChoiceRepository(stack: stack)
    do {
      try repository.saveOffers(draft.offers, of: accountId, month: month)
      if let bankId = draft.bankId {
        try repository.saveMappings(draft.mappings, ofBank: bankId)
      }
    } catch {
      AppLog.warning(
        "cashback.choiceNotSaved", .db, "the month's choice of cashback was not saved",
        [LogPair("error", .error(error))])
      failed = true
      return
    }
    let actions = CardActions(environment: environment, store: store)
    let holder = CashbackHolder.account(accountId)
    let existing = actions.rules.filter { $0.holder == holder }
    switch actions.saveRules(of: [holder], draft.rules(replacing: existing)) {
    case .done: dismiss()
    case .refused, .failed: failed = true
    }
    AppLog.info(
      "cashback.choiceSaved", .db, "the month's choice of cashback was saved",
      [
        LogPair("offers", .count(draft.offers.count)),
        LogPair("chosen", .count(draft.offers.filter(\.chosen).count)),
      ])
  }
}
