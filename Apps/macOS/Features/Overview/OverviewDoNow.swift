import AppCore
import SwiftUI

/// The words of one row of «Что сделать сейчас».
struct DoNowRowText: Equatable {
  var title: String
  var detail: String
  var button: String
  /// Whether the dot is the warm one (overdue or today, something to sort out) or the grey one.
  var urgent: Bool
}

/// «Пропустить» on «Загрузить выписку»: what this Mac remembers of it, a habit like the hint
/// about burnout — never in the database or the archive. Gone after `statementDays` days.
enum StatementSkipMarks {
  static let key = "doNow.statementSkips"

  static func read(_ defaults: UserDefaults = .standard) -> StatementSkips {
    StatementSkips(encoded: defaults.string(forKey: key))
  }

  static func skip(
    _ account: UUID, today: DateOnly, _ defaults: UserDefaults = .standard
  ) {
    let marks = read(defaults).pruned(today: today).skipping(account, on: today)
    defaults.set(marks.encoded, forKey: key)
  }
}

enum OverviewDoNow {
  static let table = "Overview"

  /// The filter requested by one of the two review rows.
  static func operationsRequest(for item: DoNowItem, today: DateOnly) -> OperationsFilterRequest? {
    guard item.action == .review else { return nil }
    var filters = TransactionFilters(today: today)
    filters.setUncategorizedOnly(true)
    switch item.id {
    case "review:\(DoNowSources.recentReviewId)":
      filters.period = .custom
      filters.customStart = today.adding(days: -(DoNowSources.reviewDays - 1))
      filters.customEnd = today
    case "review:\(DoNowSources.olderReviewId)":
      filters.period = .olderThanWeek
    default:
      return nil
    }
    return OperationsFilterRequest(filter: filters.entryFilter(today: today), columns: nil)
  }

  /// The list the block shows, from the snapshot: due payments, operations to sort out and
  /// banks whose statement is old. Accounts hidden by «Только просмотр» stay out of the lists.
  @MainActor
  static func list(
    snapshot: DataSnapshot, environment: AppEnvironment, skipTick: Int = 0,
    skips: StatementSkips = StatementSkipMarks.read()
  ) -> DoNowList {
    let hidden = snapshot.hiding
    let entries = snapshot.dataset.entries.filter {
      guard let account = $0.transaction.paymentMethodId else { return true }
      return !hidden.isHidden(account)
    }
    let statementImportMoments = snapshot.dataset.statementImportMoments.reduce(
      into: [UUID: Date]()
    ) { visible, imported in
      if !hidden.isHidden(imported.key) { visible[imported.key] = imported.value }
    }
    let payments = snapshot.dataset.planning.scheduled.filter {
      guard let account = $0.paymentMethodId else { return true }
      return !hidden.isHidden(account)
    }
    // Incomes whose day passed without the money, apart from those of hidden accounts.
    let expected = snapshot.planning.expected.filter {
      guard let account = $0.income.paymentMethodId else { return true }
      return !hidden.isHidden(account)
    }
    let visiblePaymentIds = Set(payments.map(\.id))
    let partQuestions = snapshot.planning.scheduled.compactMap { status -> DoNowItem? in
      guard visiblePaymentIds.contains(status.payment.id),
        status.partDues[status.nextUnpaid]?.needsCloseDecision == true
      else { return nil }
      let due = status.nextUnpaid
      return DoNowItem(
        id: "close-remainder:\(status.payment.id.uuidString):\(due.iso)",
        action: .closeRemainder, paymentId: status.payment.id, day: due)
    }
    return WhatToDoNow.list(
      payments: payments,
      overdueIncomes: IncomeEstimate.overdue(statuses: expected, today: environment.today),
      partQuestions: partQuestions,
      reviews: DoNowSources.reviews(
        entries: entries, today: environment.today, calendar: environment.calendar),
      statements: DoNowSources.statements(
        entries: entries, today: environment.today, calendar: environment.calendar,
        statementImportMoments: statementImportMoments,
        archivedAccounts: Set(
          snapshot.dataset.paymentMethods.filter(\.archived).map(\.id)),
        skips: skips),
      today: environment.today)
  }

  /// What is still awaited for the item: of a recurring income, that one due — not every due
  /// that has passed; of a one-off one, the whole rest.
  static func remaining(of item: DoNowItem, in status: ExpectedIncomeStatus) -> AmountE4? {
    guard item.recurring else { return status.remaining }
    return status.occurrences.first { $0.scheduled == item.scheduled }?.remaining
  }

  @MainActor
  static func text(
    _ item: DoNowItem, snapshot: DataSnapshot, environment: AppEnvironment
  ) -> DoNowRowText {
    let money = environment.money
    switch item.action {
    case .closeRemainder:
      let payment = snapshot.dataset.planning.scheduled.first { $0.id == item.paymentId }
      return DoNowRowText(
        title: payment?.name ?? "",
        detail: environment.language("scheduled.closeRemainder.question", table: "Planning"),
        button: environment.language("scheduled.closeRemainder.close", table: "Planning"),
        urgent: true)
    case .post:
      let payment = snapshot.dataset.planning.scheduled.first { $0.id == item.paymentId }
      let due = item.day ?? environment.today
      let amount =
        payment.map {
          money.rounded(
            ScheduledRules.amountToPay(
              $0, due: due, prices: snapshot.dataset.planning.prices,
              matches: snapshot.planning.matches),
            currency: $0.currency)
        } ?? ""
      let when: String
      if due == environment.today {
        when = environment.language("overview.doNow.today", table: table)
      } else if due < environment.today {
        when = environment.format(
          "overview.doNow.overdue", table: table, environment.dates.dayAndMonth(due))
      } else {
        when = environment.dates.dayAndMonth(due)
      }
      return DoNowRowText(
        title: environment.format("overview.doNow.post", table: table, payment?.name ?? ""),
        detail: environment.format("overview.doNow.postDetail", table: table, when, amount),
        button: environment.language("overview.doNow.postButton", table: table), urgent: true)
    case .income:
      let status = snapshot.planning.expected.first { $0.id == item.incomeId }
      let due = item.day ?? environment.today
      var detail = environment.format(
        "overview.doNow.incomeDetail", table: table, environment.dates.dayAndMonth(due))
      if let status, let remaining = Self.remaining(of: item, in: status), remaining.raw > 0 {
        detail += " · " + money.rounded(remaining, currency: status.income.currency)
      }
      return DoNowRowText(
        title: environment.format(
          "overview.doNow.income", table: table, status?.income.name ?? ""),
        detail: detail,
        button: environment.language("overview.doNow.incomeButton", table: table), urgent: true)
    case .review:
      let isOlder = item.id == "review:\(DoNowSources.olderReviewId)"
      return DoNowRowText(
        title: environment.format(
          isOlder ? "overview.doNow.reviewOlder" : "overview.doNow.review", table: table,
          counts: item.count),
        detail: environment.language(
          isOlder ? "overview.doNow.reviewOlderDetail" : "overview.doNow.reviewDetail",
          table: table),
        button: environment.language("overview.doNow.reviewButton", table: table), urgent: true)
    case .load:
      let name = snapshot.dataset.paymentMethods.first { $0.id == item.accountId }?.name ?? ""
      return DoNowRowText(
        title: environment.format("overview.doNow.load", table: table, name),
        detail: environment.format("overview.doNow.loadDetail", table: table, counts: item.daysAgo),
        button: environment.language("overview.doNow.loadButton", table: table), urgent: false)
    }
  }
}

/// «Что сделать сейчас»: up to three things with a button. With nothing to do the block is not
/// drawn at all. «Все» opens the full list of «Стоит посмотреть». A white card with the theme's
/// card edge, as the main card wears it — not the outline of a tile.
struct OverviewDoNowCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.openWindow) private var openWindow
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.appTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.layoutIdiom) private var idiom
  let screen: OverviewScreen
  /// In a row of tiles the card takes the height of the row.
  var fillsHeight = false
  @State private var failure: [String: String] = [:]
  /// Bumped by «Пропустить» so the list is read again: the skips live in the defaults.
  @State private var skipTick = 0
  /// The income whose day of coming is being chosen, and the day chosen so far.
  @State private var datingIncome: UUID?
  @State private var pickedDay = Date()
  /// «Это ошибка» of a recurring income: its form, to edit the recurrence itself.
  @State private var editingIncome: ExpectedIncome?

  /// The colour of a row's dot: the accent for what is due, the secondary ink for the rest; the
  /// words of the row say which it is.
  static func dot(urgent: Bool, in theme: AppThemeColors) -> Color {
    urgent ? theme.accentDefault : theme.contentSecondary
  }

  /// «3 дела · Все»: the accent's words on a phone, the secondary ink on the Mac and a tablet,
  /// as their frames draw it.
  static func countInk(in theme: AppThemeColors, idiom: LayoutIdiom) -> Color {
    OverviewPageMetrics.of(idiom).countIsAccent ? theme.accentContent : theme.contentSecondary
  }

  var body: some View {
    if let snapshot = compute.snapshot {
      let list = OverviewDoNow.list(
        snapshot: snapshot, environment: environment, skipTick: skipTick)
      if !list.isEmpty {
        let shape = RoundedRectangle(cornerRadius: ContentCard.cornerRadius)
        VStack(alignment: .leading, spacing: StyleMetrics.doNowGap) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: t("overview.doNow.title"))
              .appFont(StyleType.groupName)
              .foregroundStyle(surfaces.primary)
              .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
              Text(
                verbatim: environment.format(
                  "overview.doNow.count", table: OverviewDoNow.table, counts: list.items.count)
                  + " · ")
              TouchButton(
                title: t("overview.doNow.all"), identifier: "overview.doNow.all",
                idiom: LayoutIdiom.resolved(idiom), alignment: .trailing
              ) {
                screen.open(.worthALook)
              } drawn: { tap in
                Button(t("overview.doNow.all"), action: tap).buttonStyle(.plain)
              }
            }
            .appFont(StyleType.rowDetail)
            .foregroundStyle(Self.countInk(in: theme, idiom: LayoutIdiom.resolved(idiom)))
          }
          ForEach(Array(list.items.enumerated()), id: \.element.id) { position, item in
            if position > 0 {
              Rectangle().fill(theme.borderHairline).frame(height: 1)
            }
            row(item, snapshot: snapshot)
          }
        }
        .frame(
          maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading
        )
        .padding(.horizontal, StyleMetrics.doNowHorizontal)
        .padding(.top, StyleMetrics.doNowTop)
        .padding(.bottom, StyleMetrics.doNowBottom)
        .background(surfaces.card, in: shape)
        .overlay {
          shape.strokeBorder(surfaces.cardBorder, lineWidth: StyleMetrics.cardBorder)
          if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.doNow")
      }
    }
  }

  private func row(_ item: DoNowItem, snapshot: DataSnapshot) -> some View {
    let text = OverviewDoNow.text(item, snapshot: snapshot, environment: environment)
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: StyleMetrics.doNowRowGap) {
        Circle()
          .fill(Self.dot(urgent: text.urgent, in: theme))
          .frame(width: StyleMetrics.doNowDot, height: StyleMetrics.doNowDot)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(verbatim: text.title)
            .appFont(StyleType.rowTitle)
            .foregroundStyle(surfaces.primary)
          Text(verbatim: text.detail)
            .appFont(StyleType.rowDetail)
            .foregroundStyle(surfaces.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if item.action == .load, let account = item.accountId {
          TouchButton(
            title: t("overview.doNow.skipButton"), identifier: "overview.doNow.skip",
            idiom: LayoutIdiom.resolved(idiom), alignment: .center
          ) {
            StatementSkipMarks.skip(account, today: environment.today)
            skipTick += 1
          } drawn: { tap in
            Button(t("overview.doNow.skipButton"), action: tap).buttonStyle(.rowAction)
          }
        }
        if item.action == .income {
          incomeMenu(item, text: text, snapshot: snapshot)
        } else if item.action == .closeRemainder {
          remainderButtons(item, text: text, snapshot: snapshot)
        } else {
          TouchButton(
            title: text.button, identifier: "overview.doNow.\(item.action.rawValue)",
            idiom: LayoutIdiom.resolved(idiom), alignment: .center
          ) {
            perform(item, snapshot: snapshot)
          } drawn: { tap in
            Button(text.button, action: tap).buttonStyle(.rowAction)
          }
        }
      }
      .padding(.vertical, StyleMetrics.doNowRowVertical)
      if let message = failure[item.id] {
        Text(verbatim: message).appFont(.footnote).foregroundStyle(surfaces.negative)
      }
    }
  }

  /// «Не пришёл?»: of a one-off income the three answers — the day it will come, closed, moved
  /// a week on; of a recurring one the answers for this due alone — closed (skipped), moved to
  /// a chosen day — and «Это ошибка», the form of the recurrence itself.
  private func incomeMenu(
    _ item: DoNowItem, text: DoNowRowText, snapshot: DataSnapshot
  )
    -> some View
  {
    Menu(text.button) {
      ForEach(Self.incomeAnswers(recurring: item.recurring), id: \.self) { choice in
        Button(t(choice.key(recurring: item.recurring))) {
          choose(choice, item, snapshot: snapshot)
        }
      }
    }
    .accessibilityIdentifier("overview.doNow.income")
    .sheet(
      item: Binding(
        get: { editingIncome?.id == item.incomeId ? editingIncome : nil },
        set: { editingIncome = $0 })
    ) { income in
      ExpectedIncomeForm(original: income)
        .handingOver(dependencies)
    }
    .sheet(
      isPresented: Binding(
        get: { datingIncome != nil && datingIncome == item.incomeId },
        set: { if !$0 { datingIncome = nil } })
    ) {
      VStack(spacing: 16) {
        Text(
          verbatim: t(
            item.recurring ? "overview.doNow.income.moveDue" : "overview.doNow.income.setDate")
        )
        .appFont(.headline)
        DatePicker("", selection: $pickedDay, displayedComponents: .date)
          .datePickerStyle(.graphical)
          .labelsHidden()
        HStack {
          Button(environment.language("action.cancel")) { datingIncome = nil }
            .keyboardShortcut(.cancelAction)
          Button(environment.language("action.save")) {
            answer(
              item, .moveTo(environment.calendar.day(of: pickedDay)), snapshot: snapshot)
            datingIncome = nil
          }
          .keyboardShortcut(.defaultAction)
        }
      }
      .padding(20)
      .presentationDetents([.medium])
      .handingOver(dependencies)
    }
  }

  enum IncomeAnswer {
    case close
    case postpone
    case moveTo(DateOnly)
  }

  /// One line of the menu «Решить» of an income that did not come.
  enum IncomeChoice: String, Hashable {
    /// The day it will come (a one-off income), or the day this due is moved to (recurring).
    case pickDay
    /// A one-off income closed whole.
    case close
    /// Of a recurring income, this due alone closed — skipped; the recurrence stays.
    case skip
    /// A one-off income a week on.
    case postpone
    /// «Это ошибка»: the form of a recurring income, to edit the recurrence.
    case editRecurrence

    /// The key of its words: the day of a recurring income moves this due.
    func key(recurring: Bool) -> String {
      switch self {
      case .pickDay:
        recurring ? "overview.doNow.income.moveDue" : "overview.doNow.income.setDate"
      case .close: "overview.doNow.income.close"
      case .skip: "overview.doNow.income.skip"
      case .postpone: "overview.doNow.income.move"
      case .editRecurrence: "overview.doNow.income.mistake"
      }
    }
  }

  /// The lines of the menu: a recurring income is answered for this due alone — closed, moved
  /// to a day — or its recurrence is edited; a one-off one as a whole.
  static func incomeAnswers(recurring: Bool) -> [IncomeChoice] {
    recurring ? [.skip, .pickDay, .editRecurrence] : [.pickDay, .close, .postpone]
  }

  private func choose(_ choice: IncomeChoice, _ item: DoNowItem, snapshot: DataSnapshot) {
    switch choice {
    case .pickDay:
      pickedDay = environment.calendar.noon(of: environment.today)
      datingIncome = item.incomeId
    case .close, .skip: answer(item, .close, snapshot: snapshot)
    case .postpone: answer(item, .postpone, snapshot: snapshot)
    case .editRecurrence:
      editingIncome =
        snapshot.planning.expected.first { $0.id == item.incomeId }?.income
    }
  }

  /// Writes the answer to «не пришёл?» on the expectation as the database holds it, one step of
  /// ⌘Z. A recurring income is answered for the due of the item alone: closed skips it, a day
  /// moves it; the recurrence stays.
  private func answer(_ item: DoNowItem, _ answer: IncomeAnswer, snapshot: DataSnapshot) {
    guard let dependencies, let id = item.incomeId,
      let income = snapshot.planning.expected.first(where: { $0.id == id })?.income
    else { return }
    let actions = PlanningActions(dependencies)
    if income.kind == .recurring, let due = item.scheduled {
      switch answer {
      case .close: actions.skip(income, due: due)
      case .moveTo(let day): actions.move(income, due: due, to: day)
      case .postpone: break
      }
      return
    }
    switch answer {
    case .close: actions.close(income)
    case .postpone:
      if let moved = ExpectedIncomeRules.postponed(income, today: environment.today) {
        actions.save(moved)
      }
    case .moveTo(let day):
      if let moved = ExpectedIncomeRules.moved(income, to: day) { actions.save(moved) }
    }
  }

  private func perform(_ item: DoNowItem, snapshot: DataSnapshot) {
    switch item.action {
    case .income, .closeRemainder: break
    case .post: post(item, snapshot: snapshot)
    case .review:
      guard
        let request = OverviewDoNow.operationsRequest(for: item, today: environment.today)
      else { return }
      QuestionOpening.showOperations(request)
    case .load:
      environment.statementImportRequest = StatementImportRequest(urls: [])
    }
  }

  private func remainderButtons(
    _ item: DoNowItem, text: DoNowRowText, snapshot: DataSnapshot
  ) -> some View {
    HStack(spacing: 4) {
      TouchButton(
        title: text.button, identifier: "overview.doNow.closeRemainder.close",
        idiom: LayoutIdiom.resolved(idiom), alignment: .center
      ) {
        answerRemainder(item, .close, snapshot: snapshot)
      } drawn: { tap in
        Button(text.button, action: tap).buttonStyle(.rowAction)
      }
      TouchButton(
        title: environment.language("scheduled.closeRemainder.keep", table: "Planning"),
        identifier: "overview.doNow.closeRemainder.keep",
        idiom: LayoutIdiom.resolved(idiom), alignment: .center
      ) {
        answerRemainder(item, .keep, snapshot: snapshot)
      } drawn: { tap in
        Button(
          environment.language("scheduled.closeRemainder.keep", table: "Planning"),
          action: tap
        ).buttonStyle(.rowAction)
      }
    }
  }

  private func answerRemainder(
    _ item: DoNowItem, _ answer: ScheduledPartAnswer, snapshot: DataSnapshot
  ) {
    guard let dependencies, let due = item.day,
      let payment = snapshot.dataset.planning.scheduled.first(where: { $0.id == item.paymentId })
    else { return }
    failure[item.id] =
      PlanningActions(dependencies).answerRemainder(answer, for: payment, due: due)
      ? nil : environment.language("form.notSaved", table: "Planning")
  }

  /// «Провести» without a form, as a row of the reminders does it: on the payment's own account.
  private func post(_ item: DoNowItem, snapshot: DataSnapshot) {
    guard let dependencies, let id = item.paymentId,
      let payment = snapshot.dataset.planning.scheduled.first(where: { $0.id == id }),
      let due = item.day
    else { return }
    let actions = PlanningActions(dependencies)
    let moment = PlanningActions.paidAt(
      due: due, today: environment.today, calendar: environment.calendar)
    let price = ScheduledRules.amountToPay(
      payment, due: due, prices: snapshot.dataset.planning.prices,
      matches: snapshot.planning.matches)
    if actions.markAsPaid(
      payment, due: due, amount: price, on: moment, account: payment.paymentMethodId,
      charged: nil, updatePrice: false)
    {
      failure[item.id] = nil
    } else {
      failure[item.id] = environment.format(
        actions.failureKey(currency: payment.currency, on: moment, at: .reminder),
        table: "Planning", payment.currency.code)
    }
  }

  private func t(_ key: String) -> String {
    environment.language(key, table: OverviewDoNow.table)
  }
}

/// A small button of a card. On the Mac it is the button as drawn. On a phone and a tablet it
/// reaches 44 × 44 pt with its picture and the room it takes unchanged: a button's accessibility
/// frame is its own layout, so the control a finger finds is a clear 44 pt button laid over the
/// drawn one, which stands behind it for the eye only.
struct TouchButton<Drawn: View>: View {
  let title: String
  let identifier: String
  let idiom: LayoutIdiom
  let alignment: Alignment
  let action: () -> Void
  /// The button as drawn, given what a tap on it does.
  @ViewBuilder let drawn: (@escaping () -> Void) -> Drawn
  private static var side: CGFloat { 44 }

  var body: some View {
    if idiom == .mac {
      drawn(action)
        .accessibilityIdentifier(identifier)
    } else {
      drawn {}
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .overlay(alignment: alignment) {
          Button(action: action) {
            Color.clear.frame(minWidth: Self.side, minHeight: Self.side)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(title)
          .accessibilityIdentifier(identifier)
        }
    }
  }
}
