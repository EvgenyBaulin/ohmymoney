import AppCore
import AppDatabase
import SwiftUI

/// The questions about the debts made before this version, one debt after another
/// (`DebtReview`): a loan — its costs, its full cost of credit, early repayments on any day, the
/// days of notice, the ladder; a purchase on credit — whether it is an instalment plan; a credit
/// card kept as a debt — keeping only the account. «Сохранить» writes the answers and «Не нужно»
/// nothing but that the debt was seen — one step of ⌘Z for a debt —; «Позже» writes nothing and
/// asks again another time. Nothing is worked out anew before an answer.
struct DebtReviewSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let items: [DebtReviewItem]
  var onDone: () -> Void = {}

  @State private var position = 0
  @State private var answers = Answers()
  @State private var failed = false

  /// What the owner answered for the debt on screen.
  struct Answers {
    var costs: [DebtWizardModel.CostDraft] = []
    var pskText = ""
    var prepayAnyDay = true
    var noticeDays = DebtReminders.defaultNoticeDays
    var inLadder = true
    var isPlan = false
    var parts = InstalmentPlan.defaultCount
    var everyTwoWeeks = false
    var markup: AmountE4 = .zero

    init() {}

    init(debt: Debt) {
      pskText = debt.psk.map { "\($0)" } ?? ""
      prepayAnyDay = debt.prepayAnyDay
      noticeDays = debt.prepayNoticeDays ?? DebtReminders.defaultNoticeDays
      inLadder = debt.inLadder != false
    }

    /// `debt` with the answers about its terms.
    func applied(to debt: Debt) -> Debt {
      var answered = debt
      answered.psk = DebtPayoff.parseRate(pskText)
      answered.prepayAnyDay = prepayAnyDay
      answered.prepayNoticeDays =
        noticeDays == DebtReminders.defaultNoticeDays ? nil : noticeDays
      answered.inLadder = inLadder ? nil : false
      answered.termsReviewed = true
      return answered
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let item = current, let debt = debt(of: item) {
        Text(verbatim: t("review.title")).appFont(.headline)
        Text(
          verbatim: environment.format(
            "review.progress", table: "Debts", debt.name, String(position + 1), String(items.count))
        )
        .foregroundStyle(.secondary)
        Text(verbatim: t("review.hint"))
          .appFont(.caption).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
        Form { fields(item, debt: debt) }
          .formStyle(.grouped)
        if failed {
          Text(verbatim: environment.language("form.notSaved", table: "Planning"))
            .appFont(.caption).foregroundStyle(.red)
        }
        HStack {
          Button(t("review.later")) { later(item) }
            .accessibilityIdentifier("debts.review.later")
          Spacer()
          Button(t("review.notNeeded")) { answer(item, debt: debt, saving: false) }
            .accessibilityIdentifier("debts.review.notNeeded")
          Button(t("form.save")) { answer(item, debt: debt, saving: true) }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(dependencies == nil)
        }
      } else {
        Text(verbatim: t("review.done"))
        HStack {
          Spacer()
          Button(environment.language("action.ok")) { close() }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .sheetFrame(width: 500)
    .onAppear { prepare() }
  }

  private var current: DebtReviewItem? { items.indices.contains(position) ? items[position] : nil }

  private func debt(of item: DebtReviewItem) -> Debt? {
    compute.snapshot?.dataset.debts.first { $0.id == item.debtId }
  }

  @ViewBuilder
  private func fields(_ item: DebtReviewItem, debt: Debt) -> some View {
    if item.fields.contains(.costs) {
      Section(t("costs.title")) {
        ForEach($answers.costs) { $cost in
          CostRow(cost: $cost, currency: debt.currency) {
            answers.costs.removeAll { $0.id == cost.id }
          }
        }
        Button(t("costs.add")) { answers.costs.append(DebtWizardModel.CostDraft()) }
      }
    }
    if item.fields.contains(.psk) {
      TextField(t("wizard.psk"), text: $answers.pskText)
    }
    if item.fields.contains(.prepayAnyDay) {
      Toggle(t("wizard.prepayAnyDay"), isOn: $answers.prepayAnyDay)
    }
    if item.fields.contains(.prepayNotice) {
      Stepper(value: $answers.noticeDays, in: 0...90) {
        Text(
          verbatim: environment.format("wizard.notice", table: "Debts", String(answers.noticeDays)))
      }
    }
    if item.fields.contains(.ladder) {
      Toggle(t("ladder.inLadder"), isOn: $answers.inLadder)
    }
    if item.fields.contains(.instalmentPlan) {
      Toggle(t("review.isPlan"), isOn: $answers.isPlan)
      if answers.isPlan {
        Stepper(value: $answers.parts, in: 2...120) {
          Text(verbatim: environment.format("wizard.parts", table: "Debts", String(answers.parts)))
        }
        Picker(t("wizard.step.every"), selection: $answers.everyTwoWeeks) {
          Text(verbatim: t("wizard.every.twoWeeks")).tag(true)
          Text(verbatim: t("wizard.every.month")).tag(false)
        }
        .pickerStyle(.segmented)
        LabeledContent(t("wizard.markup")) { AmountField(amount: $answers.markup) }
      }
    }
    if item.fields.contains(.keepOnlyAccount) {
      Text(verbatim: t("review.card.hint")).fixedSize(horizontal: false, vertical: true)
      if let account = DebtCardExtras.account(for: debt, in: compute.snapshot),
        account.credit != nil
      {
        Button(t("keepOnlyAccount.action")) {
          guard let dependencies else { return }
          if DebtActions(dependencies).keepOnlyAccount(debt, account: account) {
            next()
          } else {
            failed = true
          }
        }
      }
    }
  }

  private func prepare() {
    guard let item = current, let debt = debt(of: item) else { return }
    answers = Answers(debt: debt)
    failed = false
  }

  private func later(_ item: DebtReviewItem) {
    AppLog.info(
      "debts.review.later", .db, "an old debt was put off", [LogPair("debt", .id(item.debtId))])
    next()
  }

  private func answer(_ item: DebtReviewItem, debt: Debt, saving: Bool) {
    guard let dependencies else { return }
    let actions = DebtActions(dependencies)
    var written: Bool
    if saving, item.fields.contains(.instalmentPlan), answers.isPlan {
      written = actions.makeInstalmentPlan(
        debt, parts: answers.parts,
        everyDays: answers.everyTwoWeeks ? InstalmentPlan.defaultEveryDays : nil,
        firstDue: environment.today, markup: answers.markup.raw > 0 ? answers.markup : nil)
    } else if saving {
      let costs = answers.costs.filter { $0.amount.raw > 0 }.enumerated().map { index, cost in
        DebtCost(
          id: cost.id, debtId: debt.id, kind: cost.kind, amountE4: cost.amount, every: cost.every,
          day: environment.today, inLoan: cost.every == .once && cost.inLoan, sort: index)
      }
      written = actions.review(answers.applied(to: debt), costs: costs)
    } else {
      written = actions.review(debt)
    }
    if written { next() } else { failed = true }
  }

  private func next() {
    position += 1
    if current == nil {
      close()
    } else {
      prepare()
    }
  }

  private func close() {
    onDone()
    dismiss()
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
