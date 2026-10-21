import AppCore
import SwiftUI

/// The sheet of the allocation of one income: what the rules suggest — into goals, to
/// accounts, to the cushion, the tax first —, each line an amount the owner may change or
/// clear; what is only shown (payments, dues of debts, the tax, what is left of the limits until
/// the next income); and what stays unallocated. «Записать» writes the lines with an amount, one
/// record and one step of ⌘Z (`AllocationActions.write`); nothing is written without it.
///
/// Opened with `AllocationRequest`: `.sheet(item: $request) { AllocationSheetView(request: $0) }`.
struct AllocationSheetView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let request: AllocationRequest

  @State private var amounts: [String: AmountE4] = [:]
  /// Lines whose transfer to the account of their goal the owner unticked or ticked.
  @State private var transfers: [String: Bool] = [:]
  @State private var cushionAccount: UUID?
  @State private var started = false
  @State private var failed = false
  @State private var showsRules = false

  var body: some View {
    let snapshot = compute.snapshot
    let sheet = snapshot.flatMap { AllocationActions.sheet(for: request.incomeId, snapshot: $0) }
    VStack(alignment: .leading, spacing: 12) {
      if let sheet, let snapshot {
        content(sheet, snapshot: snapshot)
      } else {
        Text(verbatim: AllocationText.t("allocation.gone", environment))
          .foregroundStyle(.secondary)
        HStack {
          Spacer()
          Button(environment.language("action.ok")) { dismiss() }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 600)
    .onAppear {
      guard !started, let sheet else { return }
      started = true
      for line in sheet.lines { amounts[line.id] = line.suggestedE4 }
      cushionAccount =
        sheet.lines.compactMap { line -> UUID? in
          if case .cushion(let account) = line.kind { return account }
          return nil
        }.first
    }
    .sheet(isPresented: $showsRules) {
      AllocationRulesSheet()
        .handingOver(dependencies)
    }
  }

  @ViewBuilder
  private func content(_ sheet: AllocationSheet, snapshot: DataSnapshot) -> some View {
    let money = environment.money
    let currency = sheet.currency
    Text(
      verbatim: AllocationText.format(
        "allocation.title", environment, money.rounded(sheet.incomeE4, currency: currency))
    )
    .appFont(.headline)
    .accessibilityIdentifier("allocation.title")
    if sheet.earlierE4.raw > 0 {
      Text(
        verbatim: AllocationText.format(
          "allocation.earlier", environment, money.rounded(sheet.earlierE4, currency: currency),
          money.rounded(sheet.incomeE4, currency: currency))
      )
      .foregroundStyle(.secondary)
    }
    if let over = sheet.overAllocatedE4 {
      Label {
        Text(
          verbatim: AllocationText.format(
            "allocation.over", environment, money.rounded(over, currency: currency)))
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .foregroundStyle(.orange)
    }
    if sheet.taxE4.raw > 0 {
      Text(
        verbatim: AllocationText.format(
          "allocation.base", environment, money.exact(sheet.taxE4, currency: currency),
          money.exact(sheet.baseE4, currency: currency))
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
    if let raise = sheet.raise {
      HStack {
        Text(
          verbatim: AllocationText.format(
            "allocation.raise", environment, money.rounded(raise.differenceE4, currency: currency))
        )
        Spacer()
        Button(AllocationText.t("allocation.raise.spread", environment)) {
          for (id, amount) in AllocationActions.spreading(raise.differenceE4, over: sheet.lines) {
            amounts[id] = amount
          }
        }
      }
      .appFont(.callout)
    }
    Form {
      if !sheet.lines.isEmpty {
        Section(AllocationText.t("allocation.write.title", environment)) {
          ForEach(sheet.lines) { line in
            lineRow(line, sheet: sheet, snapshot: snapshot)
          }
        }
      }
      if !sheet.shown.isEmpty {
        Section(
          AllocationText.format(
            "allocation.shown.title", environment, environment.dates.longDay(sheet.until))
        ) {
          ForEach(sheet.shown) { shown in
            HStack {
              Text(verbatim: name(of: shown, snapshot: snapshot))
              Spacer()
              Text(verbatim: money.rounded(shown.amountE4, currency: currency))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
          Text(verbatim: AllocationText.t("allocation.shown.hint", environment))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Section {
        let chosen = AmountE4.sum(amounts.values.filter { $0.raw > 0 })
        let left = sheet.unallocatedE4 - chosen
        LabeledContent(AllocationText.t("allocation.unallocated", environment)) {
          Text(verbatim: money.rounded(left, currency: currency))
            .monospacedDigit()
            .accessibilityIdentifier("allocation.unallocated")
        }
        if sheet.shownNotWrittenE4.raw > 0 {
          Text(
            verbatim: AllocationText.format(
              "allocation.shownNotWritten", environment,
              money.rounded(sheet.shownNotWrittenE4, currency: currency))
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    if failed {
      Text(verbatim: AllocationText.t("allocation.failed", environment))
        .appFont(.caption)
        .foregroundStyle(.red)
    }
    HStack {
      Button(AllocationText.t("allocation.rules", environment)) { showsRules = true }
      Button(AllocationText.t("allocation.decline", environment)) {
        guard let dependencies else { return }
        if AllocationActions(dependencies).decline(sheet.incomeId) { dismiss() }
      }
      Spacer()
      Button(environment.language("action.cancel")) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(AllocationText.t("allocation.write", environment)) {
        guard let dependencies else { return }
        var lines = sheet
        for index in lines.lines.indices {
          guard let ticked = transfers[lines.lines[index].id],
            case .goal(let goalId) = lines.lines[index].kind
          else { continue }
          let account = snapshot.dataset.goals.first { $0.id == goalId }?.accountId
          lines.lines[index].transferTo = ticked ? account : nil
        }
        if AllocationActions(dependencies).write(
          sheet: lines, chosen: amounts, cushionAccount: cushionAccount)
        {
          dismiss()
        } else {
          failed = true
        }
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!amounts.values.contains { $0.raw > 0 })
      .accessibilityIdentifier("allocation.write")
    }
  }

  @ViewBuilder
  private func lineRow(
    _ line: AllocationLine, sheet: AllocationSheet, snapshot: DataSnapshot
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(verbatim: name(of: line, snapshot: snapshot))
        Spacer()
        AmountField(
          amount: Binding(
            get: { amounts[line.id] ?? .zero }, set: { amounts[line.id] = $0 })
        )
        .frame(width: 120)
        .disabled(line.kind == .cushion(nil) && cushionAccount == nil)
        Text(verbatim: environment.money.symbol(for: sheet.currency))
          .foregroundStyle(.secondary)
      }
      if case .goal(let goalId) = line.kind,
        let goal = snapshot.dataset.goals.first(where: { $0.id == goalId }),
        let account = goal.accountId,
        let accountName = snapshot.dataset.paymentMethods.first(where: { $0.id == account })?.name
      {
        Toggle(
          AllocationText.format("allocation.line.transfer", environment, accountName),
          isOn: Binding(
            get: { transfers[line.id] ?? (line.transferTo != nil) },
            set: { transfers[line.id] = $0 })
        )
        .appFont(.caption)
      }
      if case .cushion = line.kind {
        let accounts = snapshot.dataset.paymentMethods.filter { $0.cushion && !$0.archived }
        if accounts.count > 1 {
          Picker(
            AllocationText.t("allocation.line.cushionAccount", environment),
            selection: $cushionAccount
          ) {
            ForEach(accounts) { account in
              Text(verbatim: account.name).tag(UUID?.some(account.id))
            }
          }
          .appFont(.caption)
        }
      }
      if let note = line.note {
        noteView(note, currency: line.targetCurrency)
      }
    }
  }

  @ViewBuilder
  private func noteView(_ note: AllocationLine.Note, currency: CurrencyCode) -> some View {
    switch note {
    case .goalCompleteDropRule(let ruleId):
      HStack {
        Text(verbatim: AllocationText.t("allocation.note.goalComplete", environment))
        Button(AllocationText.t("allocation.note.dropRule", environment)) {
          guard let dependencies else { return }
          AllocationActions(dependencies).dropRule(ruleId)
        }
        .buttonStyle(.link)
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
    case .goalMissing(let amount):
      Text(
        verbatim: AllocationText.format(
          "allocation.note.goalPlan", environment,
          environment.money.rounded(amount, currency: currency))
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
    case .noCushionAccount:
      Label {
        Text(verbatim: AllocationText.t("allocation.note.noCushion", environment))
      } icon: {
        Image(systemName: "exclamationmark.circle")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
    case .cushionLeft(let amount):
      Text(
        verbatim: AllocationText.format(
          "allocation.note.cushionLeft", environment,
          environment.money.rounded(amount, currency: currency))
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func name(of line: AllocationLine, snapshot: DataSnapshot) -> String {
    switch line.kind {
    case .goal(let id):
      return snapshot.dataset.goals.first { $0.id == id }?.name ?? ""
    case .account(let id):
      return snapshot.dataset.paymentMethods.first { $0.id == id }?.name ?? ""
    case .cushion:
      return AllocationText.t("allocation.line.cushion", environment)
    case .tax:
      return AllocationText.t("allocation.line.tax", environment)
    }
  }

  private func name(of shown: AllocationShown, snapshot: DataSnapshot) -> String {
    switch shown.kind {
    case .scheduled(let id, let due):
      let name = snapshot.planning.book.scheduled.first { $0.id == id }?.name ?? ""
      return AllocationText.format(
        "allocation.shown.due", environment, name, environment.dates.dayAndMonth(due))
    case .debt(let id, let due):
      let name = snapshot.dataset.debts.first { $0.id == id }?.name ?? ""
      return AllocationText.format(
        "allocation.shown.due", environment, name, environment.dates.dayAndMonth(due))
    case .limitLeft(let categoryId):
      let name = snapshot.ledger.tree.category(categoryId)?.name ?? ""
      return AllocationText.format("allocation.shown.limit", environment, name)
    case .npdTax:
      return AllocationText.t("allocation.line.tax", environment)
    }
  }
}
