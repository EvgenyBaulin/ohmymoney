import AppCore
import SwiftUI

/// The forms of the Planning section, one sheet at a time on the root of the section. A form
/// is content: system `Form`, no glass of its own. «Save» writes one `PlanningChange` — one
/// step of ⌘Z — and closes the sheet only over a write that landed.
struct PlanningSheetView: View {
  let sheet: PlanningSheet

  var body: some View {
    switch sheet {
    case .payment, .newPayment:
      ScheduledPaymentForm(
        original: sheet.editedPayment, start: sheet.startingPayment,
        startCurrencyChosen: sheet.startCurrencyChosen)
    case .markAsPaid(let status): MarkAsPaidForm(status: status)
    case .budget(let budget): BudgetForm(original: budget)
    case .goal(let goal): GoalForm(original: goal)
    case .moveGoal(let status, let withdraw): GoalMoveForm(status: status, withdraw: withdraw)
    case .expected(let income): ExpectedIncomeForm(original: income)
    case .linkIncome(let status): LinkIncomeForm(status: status)
    }
  }
}

/// The dictionaries the forms offer, from the data on screen: archived values are left out.
@MainActor
struct PlanningChoices {
  let categories: [CoreKit.Category]
  let methods: [PaymentMethod]
  let people: [Person]
  let currencies: [CurrencyCode]
  let tree: CategoryTree?
  /// Every event, archived ones included, by start: a form offers the live ones not over yet
  /// (`events(keeping:today:)`) and keeps the one a record already names.
  let allEvents: [Event]
  /// Every live account, hidden ones too: where a form looks up the account a record names.
  /// `methods` is what a picker offers; it has no hidden account while they are covered.
  let allMethods: [PaymentMethod]
  /// Every card, archived ones and those of hidden accounts too.
  let allCards: [PaymentCard]
  /// The hidden accounts the lists leave out right now; none once they are revealed.
  let hiding: HiddenAccounts

  init(_ compute: ComputeStore, _ environment: AppEnvironment) {
    let dataset = compute.snapshot?.dataset
    categories = (dataset?.categories ?? []).filter { !$0.archived }
    methods = (dataset?.paymentMethods ?? []).filter { !$0.archived }
    let whole = compute.wholeSnapshot?.dataset ?? dataset
    allMethods = (whole?.paymentMethods ?? []).filter { !$0.archived }
    allCards = whole?.cards ?? []
    hiding = compute.snapshot?.hiding ?? HiddenAccounts(ids: [UUID]())
    people = (dataset?.people ?? []).filter { !$0.archived }
    allEvents = (dataset?.events ?? []).sorted { left, right in
      left.startDate != right.startDate
        ? left.startDate < right.startDate : left.id.uuidString < right.id.uuidString
    }
    let enabled = (try? environment.settings?.enabledCurrencies()) ?? []
    currencies = enabled.isEmpty ? [.rub] : enabled
    tree = compute.snapshot?.ledger.tree
  }

  /// Categories of this kind, parents followed by their children, without system ones.
  func options(_ kind: CategoryKind, acceptingLimits: Bool = false) -> [CoreKit.Category] {
    let own = categories.filter { $0.kind == kind && $0.systemRole == nil }
    let roots = own.filter { $0.parentId == nil }.sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
    return roots.flatMap { root in
      [root]
        + own.filter { $0.parentId == root.id }.sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
    }
    .filter { !acceptingLimits || (tree?.acceptsLimit($0.id) ?? true) }
  }

  /// The accounts the picker of a form offers for a record that names `kept`: those of
  /// `methods`, and `kept` even when it is hidden — a payment, a goal or a debt on a hidden
  /// account opens on that account, not on the main one the form would fall back to.
  func methods(keeping kept: UUID?) -> [PaymentMethod] {
    Self.offered(allMethods, hiding: hiding, keeping: kept)
  }

  /// The cards the picker of a form offers for a record that names the account or card in
  /// `kept`: none of a hidden account while covered, except those the record names.
  func cards(keeping kept: Set<UUID>) -> [PaymentCard] {
    Self.offeredCards(allCards, hiding: hiding, keeping: kept)
  }

  /// `methods(keeping:)` without the rest of the choices: for a form of another section that
  /// only needs the accounts.
  static func methods(_ compute: ComputeStore, keeping kept: UUID?) -> [PaymentMethod] {
    let whole = compute.wholeSnapshot?.dataset ?? compute.snapshot?.dataset
    return offered(
      (whole?.paymentMethods ?? []).filter { !$0.archived },
      hiding: compute.snapshot?.hiding ?? HiddenAccounts(ids: [UUID]()), keeping: kept)
  }

  static func offered(
    _ accounts: [PaymentMethod], hiding: HiddenAccounts, keeping kept: UUID?
  ) -> [PaymentMethod] {
    hiding.offered(accounts, visibility: .covered, keeping: kept)
  }

  static func offeredCards(
    _ cards: [PaymentCard], hiding: HiddenAccounts, keeping kept: Set<UUID>
  ) -> [PaymentCard] {
    hiding.offeredCards(cards, visibility: .covered, keeping: kept)
  }

  func label(_ category: CoreKit.Category) -> String {
    category.parentId == nil ? category.name : "   \(category.name)"
  }

  /// The events a scheduled payment may belong to: the live ones not over by `today`, by
  /// start, and `current` — the one the payment names — even archived or over, so a save
  /// never drops it unseen.
  func events(keeping current: UUID?, today: DateOnly) -> [Event] {
    allEvents.filter { event in
      event.id == current || (!event.archived && event.endDate >= today)
    }
  }
}

/// Buttons at the bottom of every form: «Cancel» and the main action, which is disabled
/// while the form cannot be saved.
struct FormButtons: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  let title: String
  let enabled: Bool
  /// Why the save did not happen, asked only when it did not: a form is never left open
  /// without a word (review of the app, 19.09).
  let failure: () -> String
  let save: () -> Bool
  @State private var failed: String?

  init(
    title: String, enabled: Bool, failure: (() -> String)? = nil, save: @escaping () -> Bool
  ) {
    self.title = title
    self.enabled = enabled
    self.failure = failure ?? { "" }
    self.save = save
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      if let failed {
        Text(verbatim: failed)
          .appFont(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(title) {
          if save() {
            dismiss()
          } else {
            let reason = failure()
            failed =
              reason.isEmpty ? environment.language("form.notSaved", table: "Planning") : reason
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!enabled)
      }
    }
    .padding(.top, 8)
  }
}
