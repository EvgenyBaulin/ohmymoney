import AppCore
import AppDatabase
import Observation
import SwiftUI

/// What the picker of purchases holds: the purchases a refund can take money back from, which
/// one is picked, and how much of it comes back. Apart from the view, so a test reads it.
@MainActor
@Observable
final class RefundPickerModel {
  private let transactions: TransactionRepository?
  private let references: ReferenceRepository?
  private let calendar: CalendarContext
  private let today: DateOnly
  private let query: RefundQuery

  /// «Показать раньше»: purchases older than 90 days too.
  var showsEarlier = false { didSet { if showsEarlier != oldValue { load() } } }
  /// «Показать все покупки»: what the line said no longer narrows the list.
  var showsAll = false { didSet { if showsAll != oldValue { load() } } }

  private(set) var candidates: [RefundCandidate] = []
  /// The list is narrowed by what the line said.
  private(set) var narrowed = false
  private(set) var placeNames: [UUID: String] = [:]
  /// The part picked.
  var selectedId: UUID? { didSet { if selectedId != oldValue { settleTheAmount() } } }
  /// «Вся сумма»: everything left of the part.
  var wholeAmount = true
  /// An amount typed instead, in the purchase's currency.
  var amount: AmountE4 = .zero

  init(
    transactions: TransactionRepository?, references: ReferenceRepository?,
    calendar: CalendarContext, today: DateOnly, query: RefundQuery
  ) {
    self.transactions = transactions
    self.references = references
    self.calendar = calendar
    self.today = today
    self.query = query
  }

  func load() {
    let since = showsEarlier ? nil : RefundCandidates.windowStart(today: today, calendar: calendar)
    let from = since.map { calendar.startOfDay($0) } ?? .distantPast
    let entries = (try? transactions?.entries(from: from, to: .distantFuture)) ?? []
    let tree = CategoryTree((try? references?.categories(includeArchived: true)) ?? [])
    placeNames = Dictionary(
      ((try? references?.places(includeArchived: true)) ?? []).map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first })
    let found = RefundCandidates.list(
      entries: entries, index: RefundIndex(entries: entries, debts: [:]), tree: tree,
      since: since, calendar: calendar,
      query: showsAll ? RefundQuery(latestDay: query.latestDay) : query,
      placeNames: placeNames, plans: instalmentPlans())
    candidates = found.candidates
    narrowed = found.narrowed
    if let selectedId, !candidates.contains(where: { $0.id == selectedId }) {
      self.selectedId = nil
    }
    // One purchase fits what the line said: it is picked already.
    if selectedId == nil, narrowed, candidates.count == 1 { selectedId = candidates[0].id }
  }

  /// The instalment plans, open or not: a thing bought on one can be returned.
  private func instalmentPlans() -> [UUID: Debt] {
    let debts = (try? references?.debts(includeClosed: true)) ?? []
    return Dictionary(
      debts.filter(\.isInstalmentPlan).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  var selected: RefundCandidate? { candidates.first { $0.id == selectedId } }

  /// A new part picked: the amount the line typed, in the purchase's currency — rubles typed
  /// for a purchase in dollars are taken at the purchase's rate —, while it is no more than
  /// what is left; the line said nothing, or more than is left: the whole of what is left. An
  /// amount that cannot be taken into the purchase's currency is typed here: «Вся сумма» is
  /// never ticked for the owner then.
  private func settleTheAmount() {
    guard let selected else { return }
    guard let typed = query.amount, typed.raw > 0 else {
      amount = selected.remaining
      wholeAmount = true
      return
    }
    guard let own = Self.inPurchaseCurrency(typed, currency: query.currency, of: selected) else {
      amount = .zero
      wholeAmount = false
      return
    }
    if own <= selected.remaining {
      amount = own
      wholeAmount = own == selected.remaining
    } else {
      amount = selected.remaining
      wholeAmount = true
    }
  }

  /// `amount` in `currency` as an amount in the purchase's currency: itself in that currency;
  /// rubles at the purchase's rate; nil for another currency, whose rate the picker does not
  /// know.
  static func inPurchaseCurrency(
    _ amount: AmountE4, currency: CurrencyCode?, of candidate: RefundCandidate
  ) -> AmountE4? {
    guard let currency, currency != candidate.currency else { return amount }
    guard currency == .rub, let rate = candidate.purchase.transaction.rate, rate > 0 else {
      return nil
    }
    return try? AmountE4(decimal: DecimalMath.round(amount.decimal / rate, scale: 4))
  }

  /// Why «Вернуть» is off, as the key of the words that say so; nil once it is on.
  var refusalKey: String? {
    guard let selected else { return "refund.pickOne" }
    guard !wholeAmount else { return nil }
    guard amount.raw > 0 else { return "entry.error.amountNotPositive" }
    return amount <= selected.remaining ? nil : "refund.exceeds"
  }

  /// The choice: the part, and how much of it — nil for «Вся сумма».
  var choice: (candidate: RefundCandidate, amount: AmountE4?)? {
    guard refusalKey == nil, let selected else { return nil }
    return (selected, wholeAmount ? nil : amount)
  }
}

/// The picker of purchases a refund takes money back from: newest first, the last 90 days and
/// «Показать раньше», narrowed by the words, the place and the amount of the line. A split
/// purchase offers each of its parts. «Вся сумма» or an amount up to what is left; «Без
/// покупки» records a refund of its own — of something bought before the ledger, or taken out
/// of a goal. Parts paid for somebody else and purchases on credit are not offered.
struct RefundPicker: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss

  let entry: EntryDraftModel
  /// The owner picked a purchase or «Без покупки»; closing the picker otherwise says nothing.
  let chosen: () -> Void
  @State private var picker: RefundPickerModel?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("refund.title"))
        .appFont(.headline)
      if let picker {
        content(picker)
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 520, minHeight: 360)
    .onAppear {
      let model = RefundPickerModel(
        transactions: environment.transactions, references: environment.references,
        calendar: environment.calendar, today: environment.today, query: entry.refundQuery)
      model.load()
      picker = model
    }
  }

  @ViewBuilder
  private func content(_ picker: RefundPickerModel) -> some View {
    @Bindable var picker = picker
    HStack {
      if picker.narrowed {
        Text(verbatim: t("refund.narrowed"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
        Button(t("refund.showAll")) { picker.showsAll = true }
          .buttonStyle(.link)
      }
      Spacer()
      Toggle(isOn: $picker.showsEarlier) {
        Text(verbatim: t("refund.showEarlier"))
      }
      .toggleStyle(.checkbox)
    }
    if picker.candidates.isEmpty {
      Text(verbatim: t("refund.empty"))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 160)
    } else {
      List(selection: $picker.selectedId) {
        ForEach(picker.candidates) { candidate in
          row(candidate, placeNames: picker.placeNames)
            .tag(candidate.id)
        }
      }
      .frame(minHeight: 200)
      .accessibilityIdentifier("refund.list")
    }
    if let selected = picker.selected {
      HStack(spacing: 10) {
        Toggle(isOn: $picker.wholeAmount) {
          Text(
            verbatim: environment.language.format(
              "refund.whole", table: "Entry",
              environment.money.exact(selected.remaining, currency: selected.currency)))
        }
        .toggleStyle(.checkbox)
        if !picker.wholeAmount {
          AmountField(amount: $picker.amount)
            .frame(width: 120)
            .accessibilityLabel(
              Text(verbatim: environment.language("entry.amount", table: "Entry")))
          Text(verbatim: selected.currency.code)
            .foregroundStyle(.secondary)
        }
      }
    }
    if let key = picker.refusalKey, picker.selected != nil {
      Text(verbatim: t(key))
        .appFont(.caption)
        .foregroundStyle(.red)
    }
    HStack {
      Button(t("refund.withoutPurchase")) {
        entry.refundWithoutPurchase = true
        chosen()
        dismiss()
      }
      .help(t("refund.withoutPurchaseHelp"))
      Spacer()
      Button(environment.language("action.cancel"), role: .cancel) { dismiss() }
      Button(t("refund.choose")) {
        guard let choice = picker.choice else { return }
        entry.chooseRefund(of: choice.candidate, amount: choice.amount)
        chosen()
        dismiss()
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .disabled(picker.choice == nil)
    }
  }

  /// One part: what it was, when and where, what it cost, and what refunds already took back.
  private func row(_ candidate: RefundCandidate, placeNames: [UUID: String]) -> some View {
    let place = candidate.purchase.transaction.placeId.flatMap { placeNames[$0] }
    let day = environment.calendar.day(of: candidate.occurredAt)
    let money = environment.money
    return HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: candidate.description ?? "—")
        Text(
          verbatim: [environment.dates.longDay(day), place].compactMap { $0 }.joined(
            separator: " · ")
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
        if candidate.isPartOfASplit {
          Text(
            verbatim: environment.language.format(
              "refund.partOfSplit", table: "Entry",
              money.exact(candidate.purchase.transaction.amountE4, currency: candidate.currency))
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text(verbatim: money.exact(candidate.part.amountE4, currency: candidate.currency))
          .appFont(.body.monospacedDigit())
        if candidate.refunded.raw > 0 {
          Label {
            Text(
              verbatim: environment.language.format(
                "refund.refunded", table: "Entry",
                money.exact(candidate.refunded, currency: candidate.currency)))
          } icon: {
            Image(systemName: "arrow.uturn.left.circle")
          }
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }
}
