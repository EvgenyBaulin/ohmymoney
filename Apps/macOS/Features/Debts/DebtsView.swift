import AppCore
import SwiftUI

/// The Debts section of the main window, ⌘3: the totals on top, «I owe» and «Owed to me» on
/// the left — personal debts and the parts paid for others that wait to come back, by person —
/// and the card of the chosen debt on the right with its journal by groups and its actions.
/// Debt balances are never part of Overview, Analytics or Reports: only operations are.
struct DebtsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.windowWidth) private var windowWidth
  @State private var selection: DebtsSelection?
  @State private var tab: DebtsTab = .iOwe
  @State private var sheet: DebtSheet?
  @State private var recordingReimbursement = false
  /// «Новый долг» step by step (`DebtWizard`).
  @State private var creating = false
  /// A sheet of the debts this version brought (`DebtCreditSheet`).
  @State private var creditSheet: DebtCreditSheet?
  /// The debt «Удалить…» asks about.
  @State private var deleting: DebtLine?
  @State private var deleteFailed = false
  /// The debt a row of «Капитал» asked to open; taken once by the screen that shows it.
  @MainActor static var debtToOpen: UUID?

  var body: some View {
    ComputedBlock(
      title: nil, state: compute.states.data, style: .plain,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let overview = snapshot.planning.debts
      VStack(alignment: .leading, spacing: 0) {
        totals(overview)
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
        Divider()
        if isNarrow {
          // A phone: the list, and the card of the chosen debt in its place with a way back.
          if selection == nil {
            overviewPane(overview, snapshot: snapshot)
          } else {
            Button {
              selection = nil
            } label: {
              Label {
                Text(verbatim: environment.language("section.debts"))
              } icon: {
                Image(systemName: "chevron.backward")
              }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            detail(overview, snapshot: snapshot)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          }
        } else if selection == nil {
          overviewPane(overview, snapshot: snapshot)
        } else {
          HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
              Button {
                selection = nil
              } label: {
                Label(t("debts.allDebts"), systemImage: "square.grid.2x2")
              }
              .buttonStyle(.borderless)
              .padding(.horizontal, 16).padding(.vertical, 8)
              .accessibilityIdentifier("debts.all")
              list(overview, snapshot: snapshot)
            }
            .frame(width: 300)
            Divider()
            detail(overview, snapshot: snapshot)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          }
        }
      }
    }
    .navigationTitle(environment.language("section.debts"))
    .onAppear {
      if let id = Self.debtToOpen {
        Self.debtToOpen = nil
        selection = .debt(id)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .capitalOpensDebt)) { note in
      guard let id = note.object as? UUID else { return }
      Self.debtToOpen = nil
      selection = .debt(id)
    }
    .task {
      // `--present debt`: the card of the first debt, as a click on it shows it.
      guard await LaunchPresentation.due(.debt) else { return }
      for _ in 0..<50 where compute.snapshot == nil {
        try? await Task.sleep(for: .milliseconds(200))
      }
      if let first = compute.snapshot?.planning.debts.iOwe.first { selection = .debt(first.id) }
    }
    .sheet(item: $sheet) { sheet in
      if case .tranche(let debt) = sheet {
        TrancheSheet(debt: debt).handingOver(dependencies)
      } else {
        DebtSheetView(sheet: sheet).handingOver(dependencies)
      }
    }
    .sheet(isPresented: $creating) {
      DebtWizard().handingOver(dependencies)
    }
    .sheet(item: $creditSheet) { sheet in
      creditSheetView(sheet).handingOver(dependencies)
    }
    .sheet(isPresented: $recordingReimbursement) {
      ReimbursementSheet().handingOver(dependencies)
    }
    .confirmationDialog(
      deletionTitle, isPresented: deletionAsked, titleVisibility: .visible, presenting: deleting
    ) { line in
      Button(t("debts.delete.action"), role: .destructive) { delete(line) }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { line in
      Text(verbatim: deletionMessage(line))
    }
    .alert(t("debts.deleteFailed"), isPresented: $deleteFailed) {
      Button(environment.language("action.ok")) {}
    }
  }

  /// Too narrow for the list and the card side by side. The Mac window never gets this narrow
  /// (its minimum is wider); a width not measured yet (0) is not narrow.
  private var isNarrow: Bool { windowWidth > 0 && windowWidth < 640 }

  private func overviewPane(_ overview: DebtsOverview, snapshot: DataSnapshot) -> some View {
    DebtOverviewPane(
      overview: overview, people: snapshot.dataset.people, tab: $tab,
      cardDebts: cardDebts(snapshot),
      ladderAvailable: !LadderSection.candidates(snapshot).isEmpty,
      select: { selection = $0 },
      delete: { id in
        deleting = (overview.iOwe + overview.closed).first { $0.id == id }
      })
  }

  private func list(_ overview: DebtsOverview, snapshot: DataSnapshot) -> some View {
    DebtsList(
      overview: overview, people: snapshot.dataset.people, selection: $selection,
      deleting: $deleting, instalments: snapshot.planning.instalments,
      cardDebts: cardDebts(snapshot),
      hasLadder: !LadderSection.candidates(snapshot).isEmpty
    )
  }

  /// The credit cards whose grace period was lost: a view of what the accounts already hold.
  private func cardDebts(_ snapshot: DataSnapshot) -> [CreditCardDebtLine] {
    CreditCardDebts.lines(
      states: snapshot.planning.creditCardStates, accounts: snapshot.planning.accounts,
      debts: snapshot.dataset.debts)
  }

  private var deletionAsked: Binding<Bool> {
    Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
  }

  private var deletionTitle: String {
    environment.format("debts.delete.title", table: "Debts", deleting?.debt.name ?? "")
  }

  /// What the confirmation says stays and goes, from the data on screen.
  private func deletionMessage(_ line: DebtLine) -> String {
    guard let snapshot = compute.snapshot else { return t("debts.delete.undo") }
    let deletion = DebtActions.deletion(of: line.debt, snapshot: snapshot, at: Date())
    return DebtDeletionText.message(
      deletion, personName: snapshot.dataset.people.first { $0.id == line.debt.personId }?.name,
      language: environment.language, money: environment.money)
  }

  private func delete(_ line: DebtLine) {
    guard let dependencies else { return }
    if DebtActions(dependencies).delete(line.debt) {
      if selection == .debt(line.id) { selection = nil }
    } else {
      deleteFailed = true
    }
    deleting = nil
  }

  @ViewBuilder
  private func creditSheetView(_ sheet: DebtCreditSheet) -> some View {
    switch sheet {
    case .costs(let debt): DebtCostsSheet(debt: debt)
    case .prepay(let debt): PrepaySheet(debt: debt)
    case .typeInstalment(let debt): InstalmentEditSheet(debt: debt)
    case .nudge(let debt, let balance): NudgeSheet(debt: debt, balance: balance)
    case .writeOffPledge(let debt): PledgeWriteOffSheet(debt: debt)
    case .review(let items): DebtReviewSheet(items: items)
    case .refinance(let debt): RefinanceSheet(debt: debt)
    case .cardTerms(let debt, let account):
      AccountEditor(previous: account, defaultCurrency: environment.defaultCurrency) { _ in
        creditSheet = nil
        keepOnlyAccount(debt, accountId: account.id)
      }
    }
  }

  /// «Оставить только счёт» once the account has its terms: read again from the data on screen.
  private func keepOnlyAccount(_ debt: Debt, accountId: UUID) {
    guard let dependencies,
      let account = compute.snapshot?.dataset.paymentMethods.first(where: { $0.id == accountId }),
      account.credit != nil
    else { return }
    DebtActions(dependencies).keepOnlyAccount(debt, account: account)
  }

  private func totals(_ overview: DebtsOverview) -> some View {
    HStack(spacing: 24) {
      figure(t("debts.iOwe"), overview.totalIOweRub)
      figure(t("debts.monthly"), overview.monthlyPaymentsRub)
      figure(t("debts.owedToMe"), overview.totalOwedToMeRub)
      if !overview.withoutRate.isEmpty {
        Text(
          verbatim: environment.language.format(
            "debts.withoutRateCount", table: "Debts", counts: overview.withoutRate.count)
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      if let review = compute.snapshot?.planning.debtReview, !review.isEmpty {
        Button(
          environment.language.format("review.banner", table: "Debts", counts: review.count)
        ) { creditSheet = .review(review) }
        .accessibilityIdentifier("debts.review.open")
      }
      Button(t("debts.add")) { creating = true }
        .buttonStyle(.bordered)
        .guideTarget(GuideTarget.debtsAdd)
    }
  }

  private func figure(_ label: String, _ amount: AmountE4) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: label).appFont(.caption).foregroundStyle(.secondary)
      Text(verbatim: environment.money.rounded(amount)).appFont(.headline.monospacedDigit())
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func detail(_ overview: DebtsOverview, snapshot: DataSnapshot) -> some View {
    switch selection {
    case .debt(let id):
      if let line = (overview.iOwe + overview.closed + overview.owedToMe.flatMap(\.debts))
        .first(where: { $0.id == id })
      {
        DebtDetail(
          line: line, all: overview.iOwe + overview.owedToMe.flatMap(\.debts), sheet: $sheet,
          creditSheet: $creditSheet, deleting: $deleting)
      } else {
        placeholder
      }
    case .person(let id):
      if let group = overview.owedToMe.first(where: { $0.personId == id }) {
        PersonDetail(
          group: group, people: snapshot.dataset.people,
          record: { recordingReimbursement = true }, open: { selection = .debt($0) },
          sheet: $sheet)
      } else {
        placeholder
      }
    case .ladder:
      LadderSection()
    case .card(let id):
      if let line = cardDebts(snapshot).first(where: { $0.accountId == id }) {
        CreditCardDebtDetail(line: line)
      } else {
        placeholder
      }
    case nil:
      placeholder
    }
  }

  private var placeholder: some View {
    Text(verbatim: t("debts.choose"))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

enum DebtsSelection: Hashable {
  case debt(UUID)
  case person(UUID?)
  /// The payoff ladder (`LadderSection`).
  case ladder
  /// A credit card in debt, by its account.
  case card(UUID)
}

/// A row of «Owed to me»: a person with everything they owe, and under them each personal
/// debt of theirs, which opens its card — the journal and every action — as a debt I owe does.
enum OwedToMeRow: Identifiable, Hashable {
  case person(OwedToMeGroup)
  case debt(DebtLine)

  var selection: DebtsSelection {
    switch self {
    case .person(let group): .person(group.personId)
    case .debt(let line): .debt(line.id)
    }
  }

  var id: DebtsSelection { selection }

  static func rows(of overview: DebtsOverview) -> [OwedToMeRow] {
    overview.owedToMe.flatMap { group in [.person(group)] + group.debts.map { .debt($0) } }
  }
}

/// The actions the card of a debt offers. A closed debt offers «Reopen» and «Delete…» only: a
/// payment or a line on it would move a balance no list, total or reminder shows any more.
/// «Delete…» comes last, open or closed.
///
/// A loan I owe offers «График…» — its grace period, main payment and how the bank counts a
/// payment —, and one with a grace period «Добавить транш…».
enum DebtCardAction: Hashable {
  case pay, addEntry, tranche, offset, schedule, transfer, adjust, close, reopen, delete

  static func offered(for debt: Debt) -> [DebtCardAction] {
    guard !debt.closed else { return [.reopen, .delete] }
    let loan = debt.direction == .iOwe && debt.type == .loan
    return [.pay, .addEntry] + (debt.grace != nil && debt.direction == .iOwe ? [.tranche] : [])
      + (debt.direction == .iOwe ? [.offset] : []) + (loan ? [.schedule] : [])
      + [.transfer, .adjust, .close, .delete]
  }
}

extension DebtLine {
  /// The next payment was due before today and is still unpaid: «просрочен» beside it.
  func isOverdue(today: DateOnly) -> Bool {
    guard !debt.closed, let next = nextPayment else { return false }
    return next < today
  }

  /// «Оплачено X из Y — осталось Z» on the card: money paid toward the earliest owed due, less
  /// than the due, of a debt I owe with a monthly payment. The due stays owed until it is covered.
  ///
  /// The due is what that due asks for — a grace payment, the main payment worked out over a
  /// term —, the monthly payment when the dues say nothing of their own.
  var partialDue: (paid: AmountE4, due: AmountE4, left: AmountE4)? {
    guard debt.direction == .iOwe, dues.owes, dues.partialE4.raw > 0 else { return nil }
    let due = dues.firstUnpaidIndex.map(dues.amount(ofDue:)) ?? debt.monthlyPaymentE4
    guard let due, due.raw > 0 else { return nil }
    return (dues.partialE4, due, max(due - dues.partialE4, .zero))
  }

  /// The tranches of the journal: how many, and the money drawn by them.
  var tranches: (count: Int, total: AmountE4)? {
    let drawn = entries.filter(\.tranche)
    guard !drawn.isEmpty else { return nil }
    return (drawn.count, AmountE4.sum(drawn.map(\.amountE4)))
  }

  /// The year of the loan `day` falls in, counted from its first money drawn — the first line
  /// that grew it, a tranche or the loan itself: 1 the first year. The state programme asks a
  /// share of the interest by it.
  func loanYear(on day: DateOnly) -> Int {
    let drawn = entries.filter { $0.amountE4.raw > 0 && $0.kind != .payment }.compactMap(\.date)
    guard let first = drawn.min(), day >= first else { return 1 }
    var years = day.year - first.year
    if (day.month, day.day) < (first.month, first.day) { years -= 1 }
    return max(years, 0) + 1
  }
}

/// The schedule lines of a loan's card: «Льготный период до 1 марта 2029 · платёж ≈ 1,234.56 ₽
/// (проценты по госпрограмме, 40 %)», «С 1 марта 2029 — 12,345 ₽ в месяц», «Транши: 3 на
/// 450,000 ₽», «Начислено процентов ≈ 312 ₽». Words only; the figures come from the planning.
@MainActor
enum DebtScheduleText {
  static func lines(
    _ line: DebtLine, today: DateOnly, language: AppLanguage, money: MoneyFormatter,
    dates: DateFormatting
  ) -> [String] {
    let debt = line.debt
    let currency = debt.currency
    var lines: [String] = []
    if let schedule = line.schedule, let grace = debt.grace {
      if schedule.phase == .grace {
        let kind: String
        switch grace.payment {
        case .interest:
          kind = language("schedule.card.kind.interest", table: "Debts")
        case .programme:
          let share = grace.payment.interestShare(inLoanYear: line.loanYear(on: today)) ?? 1
          kind = language.format(
            "schedule.card.kind.programme", table: "Debts",
            money.number(share * 100, fractionDigits: 0...0))
        case .fixed:
          kind = language("schedule.card.kind.fixed", table: "Debts")
        }
        lines.append(
          language.format(
            "schedule.card.grace", table: "Debts", dates.longDay(grace.mainFrom),
            money.exact(schedule.current, currency: currency), kind))
      }
      if let main = schedule.mainAmount {
        lines.append(
          language.format(
            "schedule.card.main", table: "Debts", dates.longDay(schedule.mainFrom),
            money.rounded(main, currency: currency)))
      } else {
        lines.append(
          language.format(
            "schedule.card.mainLater", table: "Debts", dates.longDay(schedule.mainFrom)))
      }
    } else if debt.monthlyPaymentE4 == nil, debt.repayMonths != nil,
      let index = line.dues.firstUnpaidIndex
    {
      // A main payment worked out over a term: the card says what it came to.
      lines.append(
        language.format(
          "schedule.card.term", table: "Debts",
          money.rounded(line.dues.amount(ofDue: index), currency: currency)))
    }
    if let tranches = line.tranches {
      lines.append(
        language.format(
          "schedule.card.tranches", table: "Debts", money.count(Int64(tranches.count)),
          money.rounded(tranches.total, currency: currency)))
    }
    if line.accruedInterestE4.raw > 0 {
      lines.append(
        language.format(
          "schedule.card.accrued", table: "Debts",
          money.exact(line.accruedInterestE4, currency: currency)))
    }
    return lines
  }
}

/// The words of the confirmation of «Удалить…»: what leaves with the debt and what stays, one
/// sentence a line — the journal, what was left on it, the operations that paid it by what they
/// were, the purchases on credit, the money the journal moved, the archived subcategory, the
/// income a later repayment would be, and that ⌘Z brings it back.
@MainActor
enum DebtDeletionText {
  static func message(
    _ deletion: DebtDeletion, personName: String?, language: AppLanguage, money: MoneyFormatter
  ) -> String {
    let debt = deletion.debt
    var lines = [
      language.format("debts.delete.journal", table: "Debts", counts: deletion.journalLines)
    ]
    if !deletion.balance.isZero {
      let amount = money.exact(deletion.balance.magnitude, currency: debt.currency)
      lines.append(
        language.format(
          "debts.delete.left", table: "Debts",
          deletion.balance.isNegative ? "\u{2212}" + amount : amount))
    }
    if deletion.operations > 0 {
      let key =
        switch deletion.meaning {
        case .loansExpense: "debts.delete.ops.loans"
        case .notSpending: "debts.delete.ops.notSpending"
        case .moneyBack: "debts.delete.ops.moneyBack"
        }
      lines.append(language.format(key, table: "Debts", counts: deletion.operations))
    }
    for purchase in deletion.creditPurchases {
      lines.append(
        language.format(
          "debts.delete.purchase", table: "Debts", purchase.transaction.note ?? debt.name))
    }
    if deletion.movesMoneyLines > 0 { lines.append(language("debts.delete.cash", table: "Debts")) }
    if let subcategory = deletion.archivedSubcategory {
      lines.append(language.format("debts.delete.category", table: "Debts", subcategory.name))
    }
    if deletion.warnsOfIncomeLater {
      lines.append(
        language.format("debts.delete.owedLater", table: "Debts", personName ?? debt.name))
    }
    lines.append(language("debts.delete.undo", table: "Debts"))
    return lines.joined(separator: "\n")
  }
}

/// «I owe», «Owed to me» by person, and the closed debts folded.
private struct DebtsList: View {
  @Dependency(\.environment) private var environment
  let overview: DebtsOverview
  let people: [Person]
  @Binding var selection: DebtsSelection?
  @Binding var deleting: DebtLine?
  /// «В рассрочках …» above «Я должен».
  var instalments: InstalmentsSummary = .empty
  /// The credit cards in debt, under the debts I owe.
  var cardDebts: [CreditCardDebtLine] = []
  /// The ladder has debts on it.
  var hasLadder = false
  @State private var showsClosed = false

  var body: some View {
    List(selection: $selection) {
      Section {
        if instalments.count > 0 {
          Text(verbatim: instalmentsLine)
            .appFont(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("debts.instalments")
        }
        if hasLadder {
          Label(t("ladder.title"), systemImage: "chart.line.downtrend.xyaxis")
            .tag(DebtsSelection.ladder)
            .accessibilityIdentifier("debts.ladder")
        }
        if overview.iOwe.isEmpty {
          Text(verbatim: t("debts.none")).foregroundStyle(.secondary)
        }
        ForEach(overview.iOwe) { line in
          row(
            line.debt.name, line.balanceRub ?? line.balance,
            currency: line.balanceRub == nil ? line.debt.currency : .rub,
            withoutRate: overview.withoutRate.contains(line.id)
          )
          .tag(DebtsSelection.debt(line.id))
          .contextMenu { deleteButton(line) }
        }
      } header: {
        Text(verbatim: t("debts.iOwe"))
      }
      if !cardDebts.isEmpty {
        Section {
          CreditCardDebtRows(lines: cardDebts)
        } header: {
          Text(verbatim: t("debts.cards.header"))
        }
      }
      Section {
        if overview.owedToMe.isEmpty {
          Text(verbatim: t("debts.nobodyOwes")).foregroundStyle(.secondary)
        }
        ForEach(OwedToMeRow.rows(of: overview)) { item in
          switch item {
          case .person(let group):
            row(
              name(group.personId), group.totalRub, currency: .rub,
              withoutRate: group.debts.contains { overview.withoutRate.contains($0.id) }
            )
            .tag(item.selection)
          case .debt(let line):
            row(
              line.debt.name, line.balance, currency: line.debt.currency,
              withoutRate: overview.withoutRate.contains(line.id)
            )
            .padding(.leading, 14)
            .tag(item.selection)
            .contextMenu { deleteButton(line) }
          }
        }
      } header: {
        Text(verbatim: t("debts.owedToMe"))
      }
      if !overview.closed.isEmpty {
        // Folded by default: closed debts pile up over the years. The header
        // is its own button: an inset list on macOS draws no disclosure for a section.
        Section {
          if showsClosed {
            ForEach(overview.closed) { line in
              row(line.debt.name, line.balance, currency: line.debt.currency)
                .foregroundStyle(.secondary)
                .tag(DebtsSelection.debt(line.id))
                .contextMenu { deleteButton(line) }
            }
          }
        } header: {
          Button {
            withAnimation(.snappy) { showsClosed.toggle() }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "chevron.right")
                .rotationEffect(.degrees(showsClosed ? 90 : 0))
                .accessibilityHidden(true)
              Text(verbatim: "\(t("debts.closed")) (\(overview.closed.count))")
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
    // Content, not navigation: no material under the list.
    .listStyle(.inset)
  }

  private func row(
    _ title: String, _ amount: AmountE4, currency: CurrencyCode, withoutRate: Bool = false
  ) -> some View {
    HStack {
      Text(verbatim: title).lineLimit(1)
      Spacer(minLength: 6)
      if withoutRate {
        // Not in the totals: there is no rate to count it in rubles.
        Text(verbatim: t("debts.withoutRate")).appFont(.caption).foregroundStyle(.secondary)
      }
      Text(verbatim: environment.money.rounded(amount, currency: currency)).monospacedDigit()
    }
  }

  private func name(_ id: UUID?) -> String {
    people.first { $0.id == id }?.name ?? t("debts.noPerson")
  }

  /// «В рассрочках 34,000 ₽ · ближайшее 2,500 ₽ 14 ноября».
  private var instalmentsLine: String {
    DebtsInstalmentsText.line(
      instalments, language: environment.language, money: environment.money,
      dates: environment.dates)
  }

  private func deleteButton(_ line: DebtLine) -> some View {
    Button(t("debts.delete"), role: .destructive) { deleting = line }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// The card of one debt: type, balance, payment and day, rate, «payments are expenses», the
/// early payoff scenario, the journal by groups with their totals, and the actions.
private struct DebtDetail: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let line: DebtLine
  let all: [DebtLine]
  @Binding var sheet: DebtSheet?
  @Binding var creditSheet: DebtCreditSheet?
  @Binding var deleting: DebtLine?
  @State private var confirmsToggle = false
  @State private var reopenFailed = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        // Two columns when the window has room for both, one stack below that — and always on
        // a phone.
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) { summaryCards }
              .frame(minWidth: 300, maxWidth: 420)
            VStack(alignment: .leading, spacing: 14) { historyCards }
              .frame(minWidth: 360, maxWidth: .infinity)
          }
          .frame(minWidth: 720)
          VStack(alignment: .leading, spacing: 14) {
            summaryCards
            historyCards
          }
        }
      }
      .padding(20)
    }
  }

  /// The name and, under it, what kind of debt it is.
  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: line.debt.name).appFont(.title2.bold())
      Text(verbatim: t("debts.type.\(line.debt.type.rawValue)"))
        .appFont(.callout).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var summaryCards: some View {
    balanceCard
    if line.debt.isInstalmentPlan, let parts = line.debt.parts, parts > 0 {
      InstalmentPartsCard(parts: parts, paid: min(line.dues.paidCount, parts))
      DebtInfoBlock(
        title: t("wizard.how"), lines: [t("parts.how.once"), t("parts.how.reduces")])
    }
    DebtCostSection(line: line)
    AttachedFilesCard(owner: .debt, id: line.debt.id).contentCard()
    actionsCard
  }

  @ViewBuilder
  private var historyCards: some View {
    if let series = balanceSeries, series.isDrawable {
      DebtBalanceChartCard(series: series)
    }
    journal.contentCard()
  }

  /// «Остаток», the figure, how far it is paid, and the facts a payment is made from.
  private var balanceCard: some View {
    let debt = line.debt
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: t("debts.balance")).appFont(.callout).foregroundStyle(.secondary)
        Spacer(minLength: 8)
        DebtBadgeCapsule(badge: DebtCardModel.badge(of: debt))
      }
      Text(verbatim: environment.money.exact(line.balance, currency: debt.currency))
        .appFont(.largeTitle.bold().monospacedDigit())
        .minimumScaleFactor(0.6).lineLimit(1)
        .accessibilityIdentifier("debts.balance")
      if let progress = DebtCardModel.progress(of: line) {
        ProgressView(value: progress)
          .accessibilityLabel(t("debts.card.paid"))
          .accessibilityValue("\(Int((progress * 100).rounded())) %")
      }
      VStack(alignment: .leading, spacing: 4) {
        if let rate = debt.interestRate {
          DebtFactRow(
            label: t("debts.card.rate"),
            value: environment.format(
              "debts.rate.row", table: "Debts", environment.money.rate(rate)))
        }
        if let payment = debt.monthlyPaymentE4 {
          DebtFactRow(
            label: t("debts.card.payment"),
            value: DebtSheetView.cardPaymentText(
              environment.money.rounded(payment, currency: debt.currency), day: debt.paymentDay,
              language: environment.language))
        }
        if line.paidTotal.raw > 0 {
          DebtFactRow(
            label: t("debts.card.paid"),
            value: environment.money.exact(line.paidTotal, currency: debt.currency))
        }
        if let next = line.nextPayment {
          DebtFactRow(
            label: t("debts.card.nextDue"), value: environment.dates.longDay(next))
          if line.isOverdue(today: environment.today) {
            // A symbol and a word, never a colour alone.
            Label(t("debts.overdue"), systemImage: "exclamationmark.circle")
              .appFont(.callout)
              .accessibilityIdentifier("debts.overdue")
          }
        }
      }
      // Money paid toward a due, less than the due: the due stays owed until it is covered.
      if let partial = line.partialDue {
        Text(
          verbatim: environment.format(
            "debts.partialDue", table: "Debts",
            environment.money.exact(partial.paid, currency: debt.currency),
            environment.money.exact(partial.due, currency: debt.currency),
            environment.money.exact(partial.left, currency: debt.currency))
        )
        .appFont(.caption).foregroundStyle(.secondary)
        .accessibilityIdentifier("debts.partialDue")
      }
      ForEach(scheduleLines, id: \.self) { text in
        Text(verbatim: text).appFont(.callout).foregroundStyle(.secondary)
      }
      if debt.direction == .iOwe {
        Toggle(
          isOn: Binding(
            get: { debt.paymentsAreExpenses },
            set: { _ in confirmsToggle = true })
        ) {
          Text(verbatim: t("debts.paymentsAreExpenses")).appFont(.callout)
        }
        .confirmationDialog(
          t("debts.toggleTitle"), isPresented: $confirmsToggle, titleVisibility: .visible
        ) {
          Button(t("debts.toggleConfirm")) {
            var changed = debt
            changed.paymentsAreExpenses.toggle()
            if let dependencies { DebtActions(dependencies).save(changed) }
          }
        } message: {
          Text(verbatim: t("debts.toggleMessage"))
        }
        if let payoff = payoff {
          Text(verbatim: payoff).appFont(.caption).foregroundStyle(.secondary)
        }
      }
      DebtCardExtras(line: line, part: .details, sheet: $creditSheet)
    }
    .contentCard()
  }

  /// «Действия»: pay, the early repayment, the ladder and the rest, wrapping on a narrow card.
  private var actionsCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: t("debts.actions")).appFont(.headline)
        .accessibilityAddTraits(.isHeader)
      actions
      DebtCardExtras(line: line, part: .more, sheet: $creditSheet)
    }
    .contentCard()
  }

  /// Balance by month from the journal, and the schedule ahead of it for a loan.
  private var balanceSeries: DebtBalanceSeries? {
    let debt = line.debt
    var rows: [AmortizationRow] = []
    if debt.direction == .iOwe, let rate = debt.interestRate, rate > 0,
      let payment = debt.monthlyPaymentE4, payment.raw > 0, line.balance.raw > 0,
      let day = debt.paymentDay
    {
      rows = DebtAmortization.schedule(
        principal: line.balance, percent: rate, payment: payment,
        firstDue: line.nextPayment ?? environment.today, paymentDay: day, limit: 120)
    }
    return DebtBalanceSeries.make(entries: line.entries, schedule: rows)
  }

  private var facts: String {
    let debt = line.debt
    var pieces = [t("debts.type.\(debt.type.rawValue)")]
    if let rate = debt.interestRate {
      pieces.append(
        environment.format(
          "debts.rate", table: "Debts", environment.money.rate(rate)))
    }
    if let payment = debt.monthlyPaymentE4 {
      pieces.append(
        DebtSheetView.cardPaymentText(
          environment.money.rounded(payment, currency: debt.currency), day: debt.paymentDay,
          language: environment.language))
    }
    return pieces.joined(separator: " · ")
  }

  private var scheduleLines: [String] {
    DebtScheduleText.lines(
      line, today: environment.today, language: environment.language, money: environment.money,
      dates: environment.dates)
  }

  /// «Досрочно +2,000 ₽ в месяц — закроется на 7 мес. раньше».
  private var payoff: String? {
    let debt = line.debt
    guard let payment = debt.monthlyPaymentE4, payment.raw > 0, line.balance.raw > 0 else {
      return nil
    }
    // A tenth of the payment in the debt's currency, as Advice tries it: at least 100 of any
    // currency made a 50 USD payment +100 USD a month.
    let extra = DebtPayoff.suggestedExtra(for: payment, currency: debt.currency)
    let scenario = DebtPayoff.scenario(
      balance: line.balance, annualRatePercent: debt.interestRate,
      monthlyPayment: payment, extra: extra)
    guard let saved = scenario.monthsSaved else {
      return scenario.monthsWithout == nil ? t("debts.payoffNever") : nil
    }
    return environment.format(
      "debts.payoff", table: "Debts", environment.money.rounded(extra, currency: debt.currency),
      environment.language.format("advice.months", table: "Planning", counts: saved))
  }

  @ViewBuilder
  private var actions: some View {
    if line.debt.closed {
      Text(verbatim: t("debts.closedCaption")).appFont(.caption).foregroundStyle(.secondary)
    }
    FlowButtons {
      ForEach(DebtCardAction.offered(for: line.debt), id: \.self) { action in
        if action == .pay || action == .reopen {
          button(action).buttonStyle(.borderedProminent)
        } else {
          button(action)
        }
      }
    }
    .alert(t("debts.reopenFailed"), isPresented: $reopenFailed) {
      Button(environment.language("action.ok")) {}
    }
  }

  private func button(_ action: DebtCardAction) -> Button<Text> {
    let debt = line.debt
    switch action {
    case .pay:
      return Button(t("debts.pay")) { sheet = .pay(debt) }
    case .addEntry:
      return Button(t("debts.addEntry")) { sheet = .entry(debt) }
    case .tranche:
      return Button(t("tranche.action")) { sheet = .tranche(debt) }
    case .schedule:
      return Button(t("schedule.action")) { sheet = .schedule(debt) }
    case .offset:
      return Button(t("debts.offset")) { sheet = .offset(debt) }
    case .transfer:
      return Button(t("debts.transfer")) {
        sheet = .transfer(
          debt, balance: line.balance, others: all.map(\.debt).filter { $0.id != debt.id })
      }
    case .adjust:
      return Button(t("debts.adjust")) { sheet = .adjust(debt, balance: line.balance) }
    case .close:
      return Button(t("debts.close")) { sheet = .close(debt, balance: line.balance) }
    case .reopen:
      return Button(t("debts.reopen")) {
        guard let dependencies else { return }
        if !DebtActions(dependencies).reopen(debt) { reopenFailed = true }
      }
    case .delete:
      return Button(t("debts.delete"), role: .destructive) { deleting = line }
    }
  }

  /// The lines by group, each group with its total («журнал записей с группами и итогами
  /// по группам»).
  private var journal: some View {
    let byGroup = Dictionary(grouping: line.entries, by: \.groupName)
    return VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: t("debts.journal")).appFont(.headline)
      if line.entries.isEmpty {
        Text(verbatim: t("debts.journalEmpty")).foregroundStyle(.secondary)
      }
      ForEach(line.groups, id: \.groupName) { group in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(verbatim: group.groupName ?? t("debts.noGroup")).appFont(
              .subheadline.weight(.semibold))
            Spacer()
            Text(
              verbatim: environment.format(
                "debts.groupTotal", table: "Debts",
                environment.money.exact(group.totalE4, currency: line.debt.currency))
            )
            .appFont(.subheadline.monospacedDigit())
          }
          ForEach(byGroup[group.groupName] ?? [], id: \.id) { entry in
            VStack(alignment: .trailing, spacing: 1) {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: entry.date.map(day) ?? "—")
                  .monospacedDigit()
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .frame(width: 110, alignment: .leading)
                Text(verbatim: entry.description ?? t("debts.kind.\(entry.kind.rawValue)"))
                  .lineLimit(1)
                // «В этом месяце больше платежей не будет»: said, so the due is shown as closed.
                if entry.closesTerm {
                  Label {
                    Text(verbatim: t("debts.journal.closesTerm"))
                  } icon: {
                    Image(systemName: "checkmark.circle")
                  }
                  .appFont(.caption).foregroundStyle(.secondary)
                  .help(t("debts.journal.closesTermHelp"))
                }
                // An early repayment, by what the owner chose for it.
                if let prepay = entry.prepay {
                  Label {
                    Text(verbatim: t("debts.journal.prepay.\(prepay.rawValue)"))
                  } icon: {
                    Image(systemName: "forward.end.circle")
                  }
                  .appFont(.caption).foregroundStyle(.secondary)
                }
                // A tranche: a part of the loan drawn, a planned one while its day is ahead.
                if entry.tranche {
                  Label {
                    Text(verbatim: t(trancheMark(entry)))
                  } icon: {
                    Image(systemName: "graduationcap")
                  }
                  .appFont(.caption).foregroundStyle(.secondary)
                }
                if let full = entry.fullAmountE4, let share = entry.share {
                  Text(
                    verbatim: environment.money.rounded(full, currency: line.debt.currency) + " × "
                      + environment.money.number(share)
                  )
                  .appFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                  // Exact, like the group totals and the balance it adds up to.
                  verbatim: (entry.amountE4.isZero ? "" : entry.amountE4.isNegative ? "−" : "+")
                    + environment.money.exact(
                      entry.amountE4.magnitude, currency: line.debt.currency)
                )
                .monospacedDigit()
              }
              // What of a payment the bank took as interest first.
              if let interest = line.interestByPayment[entry.id], interest.raw > 0 {
                Text(
                  verbatim: environment.format(
                    "debts.journal.interest", table: "Debts",
                    environment.money.exact(interest, currency: line.debt.currency))
                )
                .appFont(.caption.monospacedDigit()).foregroundStyle(.secondary)
              }
            }
            .appFont(.callout)
          }
        }
      }
    }
  }

  private func trancheMark(_ entry: DebtEntry) -> String {
    guard let day = entry.date, TrancheSheet.isPlanned(day, today: environment.today) else {
      return "debts.journal.tranche"
    }
    return "debts.journal.tranchePlanned"
  }

  /// «25 августа», with the year when it is not this one: a journal runs over years.
  private func day(_ date: DateOnly) -> String {
    date.year == environment.today.year
      ? environment.dates.dayAndMonth(date) : environment.dates.longDay(date)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// A person in «Owed to me»: personal debts and the parts paid for them that wait to come
/// back, oldest first, with «Record reimbursement». A debt's name opens its card.
private struct PersonDetail: View {
  @Dependency(\.environment) private var environment
  let group: OwedToMeGroup
  let people: [Person]
  let record: () -> Void
  let open: (UUID) -> Void
  @Binding var sheet: DebtSheet?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text(verbatim: people.first { $0.id == group.personId }?.name ?? t("debts.noPerson"))
          .appFont(.title2)
        Text(verbatim: environment.money.rounded(group.totalRub)).appFont(.title3.monospacedDigit())
        if !group.parts.isEmpty {
          Button(environment.language("reimbursement.title", table: "Entry"), action: record)
            .buttonStyle(.bordered)
          Text(verbatim: t("debts.parts")).appFont(.headline)
          ForEach(group.parts) { part in
            HStack {
              Text(verbatim: environment.dates.dayAndMonth(part.day)).monospacedDigit()
                .foregroundStyle(.secondary)
              Text(verbatim: part.note ?? "—").lineLimit(1)
              Spacer()
              Text(verbatim: environment.money.exact(part.amountRub)).monospacedDigit()
            }
            .appFont(.callout)
          }
        }
        ForEach(group.debts) { line in
          HStack {
            Button(line.debt.name) { open(line.debt.id) }
              .buttonStyle(.link)
            Spacer()
            Text(verbatim: environment.money.exact(line.balance, currency: line.debt.currency))
              .monospacedDigit()
            Button(t("debts.pay")) { sheet = .pay(line.debt) }
              .buttonStyle(.bordered).controlSize(.small)
          }
        }
      }
      .padding(20)
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// The line above «Я должен»: what hangs in instalments and the next payment of them.
@MainActor
enum DebtsInstalmentsText {
  static func line(
    _ summary: InstalmentsSummary, language: AppLanguage, money: MoneyFormatter,
    dates: DateFormatting
  ) -> String {
    let total = language.format(
      "instalments.total", table: "Debts", money.rounded(summary.totalRub))
    guard let next = summary.next.first else { return total }
    return total + " · "
      + language.format(
        "instalments.next", table: "Debts", money.exact(next.amountE4, currency: next.currency),
        dates.longDay(next.due))
  }
}
