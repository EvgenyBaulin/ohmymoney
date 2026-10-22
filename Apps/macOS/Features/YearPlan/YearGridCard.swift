import AppCore
import SwiftUI

/// The frame every card of the page stands on: a title in `.headline` with its symbol, what it is
/// measured over in `.caption`, then the body. No glass — content is never glass.
struct YearCard<Content: View>: View {
  let title: String
  var symbol: String?
  var subtitle: String?
  var identifier: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          if let symbol {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
          }
          Text(verbatim: title)
            .appFont(.headline)
            .accessibilityAddTraits(.isHeader)
        }
        if let subtitle {
          Text(verbatim: subtitle)
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: title))
    .accessibilityIdentifier(identifier)
  }
}

/// The plan of the twelve months: income, payments, goals and big spends, with the balance of
/// every month. A cell is a menu: its items open the payment, the goal, the expectation or the
/// event they come from, and «Добавить в этот месяц…» adds one. A grey cell is a guess and says
/// «оценка»; a minus is a minus. On a narrow screen the months are a list, one disclosure each.
/// It is a grid of buttons, not a `Table`: nothing in it edits in place.
struct YearGridCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.windowWidth) private var windowWidth
  let page: YearPage
  let open: (YearSheet) -> Void

  /// A column of the wide grid is at least this wide; a narrower window scrolls sideways.
  static let columnWidth: CGFloat = 78
  static let labelWidth: CGFloat = 118

  var body: some View {
    YearCard(
      title: YearText.t("year.plan.title", environment), symbol: YearText.symbol,
      subtitle: YearText.t("year.plan.subtitle", environment), identifier: "year.plan"
    ) {
      if ScreenWidth.isCompact(windowWidth) {
        monthList
      } else {
        ScrollView(.horizontal) { grid.padding(.bottom, 4) }
          .scrollBounceBehavior(.basedOnSize)
      }
      if !page.plan.withoutRate.isEmpty {
        Label {
          Text(verbatim: YearText.t("year.plan.withoutRate", environment))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
      Text(verbatim: YearText.t("year.plan.hint", environment))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var spansYears: Bool { Set(page.plan.months.map(\.year)).count > 1 }

  // MARK: Wide

  private var grid: some View {
    Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 6) {
      GridRow {
        Color.clear.frame(width: Self.labelWidth, height: 1)
        ForEach(page.plan.months, id: \.self) { month in
          Text(verbatim: YearText.monthHead(month, spansYears: spansYears, environment))
            .appFont(.caption.weight(.semibold))
            .frame(width: Self.columnWidth, alignment: .trailing)
            .accessibilityLabel(Text(verbatim: environment.dates.monthTitle(month)))
        }
      }
      Divider()
      ForEach(page.plan.rows, id: \.kind) { row in
        GridRow {
          Label {
            Text(verbatim: YearText.t(YearText.rowKey(row.kind), environment))
          } icon: {
            Image(systemName: YearText.rowSymbol(row.kind)).accessibilityHidden(true)
          }
          .appFont(.callout)
          .frame(width: Self.labelWidth, alignment: .leading)
          ForEach(row.cells, id: \.month) { cell in
            cellView(cell, kind: row.kind)
          }
        }
      }
      Divider()
      GridRow {
        Text(verbatim: YearText.t("year.row.balance", environment))
          .appFont(.callout.weight(.semibold))
          .frame(width: Self.labelWidth, alignment: .leading)
        ForEach(page.plan.months, id: \.self) { month in
          let amount = page.plan.balance[month] ?? .zero
          Text(verbatim: YearText.balance(amount, environment))
            .appFont(.callout.weight(.semibold).monospacedDigit())
            .frame(width: Self.columnWidth, alignment: .trailing)
            .accessibilityIdentifier("year.balance.\(month.iso)")
        }
      }
    }
  }

  private func cellView(_ cell: YearPlanCell, kind: YearPlanRowKind) -> some View {
    Menu {
      cellMenu(cell, kind: kind)
    } label: {
      VStack(alignment: .trailing, spacing: 0) {
        Text(verbatim: YearText.cell(cell, environment))
          .appFont(.callout.monospacedDigit())
          .foregroundStyle(cell.items.isEmpty || cell.isEstimate ? .secondary : .primary)
        if cell.isEstimate {
          Text(verbatim: YearText.t("year.estimate", environment))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: Self.columnWidth, alignment: .trailing)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .accessibilityIdentifier("year.cell.\(kind.rawValue).\(cell.month.iso)")
  }

  // MARK: The menu of a cell

  @ViewBuilder
  private func cellMenu(_ cell: YearPlanCell, kind: YearPlanRowKind) -> some View {
    if !cell.items.isEmpty {
      Section {
        ForEach(cell.items) { item in
          Button(YearText.itemTitle(item, environment)) { openSource(of: item) }
            .disabled(item.sourceId == nil)
        }
      }
    }
    if cell.month >= page.today.monthKey {
      Section {
        ForEach(YearPlanAddAction.allCases, id: \.self) { action in
          Button(YearText.t("year.add.\(action.rawValue)", environment)) {
            add(action, in: cell.month)
          }
        }
      } header: {
        Text(
          verbatim: YearText.f(
            "year.add.header", environment, environment.dates.monthTitle(cell.month)))
      }
    }
  }

  // MARK: Narrow

  private var monthList: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(page.plan.months, id: \.self) { month in
        DisclosureGroup {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(page.plan.rows, id: \.kind) { row in
              if let cell = row.cells.first(where: { $0.month == month }) {
                monthRow(cell, kind: row.kind)
              }
            }
            Menu {
              addMenu(for: month)
            } label: {
              Label(YearText.t("year.add.button", environment), systemImage: "plus")
            }
            .disabled(month < page.today.monthKey)
          }
          .padding(.vertical, 4)
        } label: {
          HStack {
            Text(verbatim: environment.dates.monthTitle(month)).appFont(.callout)
            Spacer(minLength: 8)
            Text(verbatim: YearText.balance(page.plan.balance[month] ?? .zero, environment))
              .appFont(.callout.monospacedDigit())
          }
        }
      }
    }
  }

  private func monthRow(_ cell: YearPlanCell, kind: YearPlanRowKind) -> some View {
    Menu {
      cellMenu(cell, kind: kind)
    } label: {
      HStack {
        Label {
          Text(verbatim: YearText.t(YearText.rowKey(kind), environment))
        } icon: {
          Image(systemName: YearText.rowSymbol(kind)).accessibilityHidden(true)
        }
        .appFont(.callout)
        Spacer(minLength: 8)
        Text(verbatim: YearText.cell(cell, environment))
          .appFont(.callout.monospacedDigit())
          .foregroundStyle(cell.items.isEmpty || cell.isEstimate ? .secondary : .primary)
        if cell.isEstimate {
          Text(verbatim: YearText.t("year.estimate", environment))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .menuStyle(.borderlessButton)
  }

  @ViewBuilder
  private func addMenu(for month: MonthKey) -> some View {
    ForEach(YearPlanAddAction.allCases, id: \.self) { action in
      Button(YearText.t("year.add.\(action.rawValue)", environment)) { add(action, in: month) }
    }
  }

  // MARK: What a click does

  /// The form of what a figure comes from; the Planning screens already hold the rules of
  /// changing it.
  private func openSource(of item: YearPlanItem) {
    guard let id = item.sourceId, let dataset = compute.snapshot?.dataset else { return }
    switch item.kind {
    case .payments:
      if let payment = dataset.planning.scheduled.first(where: { $0.id == id }) {
        open(.planning(.payment(payment)))
      }
    case .income:
      if let income = dataset.planning.expected.first(where: { $0.id == id }) {
        open(.planning(.expected(income)))
      }
    case .goals:
      if let goal = dataset.goals.first(where: { $0.id == id }) { open(.planning(.goal(goal))) }
    case .bigSpends:
      if let event = dataset.events.first(where: { $0.id == id }) { open(.event(event)) }
    }
  }

  /// «Добавить в этот месяц…»: the form of the kind, on the day the plan suggests for the month
  /// (today in this one, the 1st in a later one).
  private func add(_ action: YearPlanAddAction, in month: MonthKey) {
    let day = page.plan.addActions(for: month, today: page.today).suggestedDay
    switch action {
    case .payment:
      var payment = ScheduledPaymentForm.newPayment(
        defaultCurrency: environment.defaultCurrency, today: day)
      payment.nextDate = day
      open(.planning(.newPayment(payment, currencyChosen: false)))
    case .expectedIncome:
      open(
        .newExpected(
          ExpectedIncomeForm.newIncome(defaultCurrency: environment.defaultCurrency, today: day)))
    case .goal:
      open(.planning(.goal(nil)))
    case .event:
      open(.newEvent(day: day))
    }
  }
}
