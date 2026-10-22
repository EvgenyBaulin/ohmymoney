import AppCore
import SwiftUI

/// «Календарь»: my spending day by day — a month as weeks, or one week — with the days that
/// cost more than usual marked, and what is planned for today and the days ahead. A click on a
/// day lists its operations under the grid, with what is planned for it on top; a double click
/// on an operation edits it, as in «Траты». Every figure is the core's (`SpendingCalendar`),
/// built from the data step's snapshot; the view only lays it out.
struct CalendarView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.themeSurfaces) private var surfaces
  let actions: OperationActions

  @State private var scope: CalendarScope = .month
  /// The month or the week shown; `nil` is the one of today.
  @State private var anchor: DateOnly?
  /// The day whose operations are listed; `nil` is today.
  @State private var chosen: DateOnly?
  @State private var selection: Set<UUID> = []
  @State private var width: CGFloat = 0
  /// An operation moved to another day: by a drop on a day, or by the menu of its row.
  @State private var mover = MoveToDayModel()
  /// The day under a dragged operation, to show where it would land.
  @State private var dropTarget: DateOnly?

  private func t(_ key: String) -> String { CalendarText.t(key, environment) }

  var body: some View {
    if let snapshot = compute.snapshot {
      content(snapshot)
    } else if let waiting = compute.states.data.waiting {
      ComputedBlock(waiting: waiting, retry: { compute.retry(ComputeStep.data) })
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    } else {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func content(_ snapshot: DataSnapshot) -> some View {
    let firstWeekday = CalendarScreen.firstWeekday(locale: environment.language.locale)
    let calendar = CalendarScreen.calendar(
      of: snapshot, scope: scope, anchor: anchor ?? snapshot.today, firstWeekday: firstWeekday)
    let chosenDay = calendar.day(chosen ?? snapshot.today)
    let wide = CalendarLayout.isWide(width: width)
    let dayList = DayList(
      groups: CalendarScreen.groups(of: chosenDay, in: snapshot, calendar: environment.calendar),
      selection: $selection,
      ledger: snapshot.ledger,
      emptyText: chosenDay.map { _ in t("calendar.day.empty") },
      header: { plans(of: chosenDay, in: calendar) },
      menu: { ids in
        BulkMenuItems(ids: ids, actions: actions, offersEdit: true)
        if ids.count == 1, let only = ids.first {
          Divider()
          Button(QuickText.t("quick.move.menu", environment)) {
            mover.picking = MoveToDayModel.Pick(id: only)
          }
        }
      },
      primaryAction: { ids in actions.edit(ids, store: store) },
      deleteAction: { ids in actions.requestDeletion(of: ids, store: store) },
      dragsRows: true
    )
    .frame(minHeight: 160)
    .accessibilityIdentifier("calendar.dayList")
    return VStack(alignment: .leading, spacing: 12) {
      header(calendar, today: snapshot.today)
      if let text = mover.message {
        QuickCalendarMessage(text: text, failed: mover.failed)
      }
      if wide {
        HStack(alignment: .top, spacing: 16) {
          dayList
            .clipShape(.rect(cornerRadius: 12))
            .frame(maxWidth: 360)
          VStack(alignment: .leading, spacing: 12) {
            gridCard(calendar)
            upcomingCard(calendar)
          }
          .frame(maxWidth: .infinity, alignment: .top)
        }
      } else {
        gridCard(calendar)
        dayList.clipShape(.rect(cornerRadius: 12))
        upcomingCard(calendar)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .onChange(of: compute.generation) { _, _ in actions.reloadDictionaries(from: snapshot.dataset) }
    .onAppear { actions.reloadDictionaries(from: snapshot.dataset) }
    .onChange(of: chosen) { _, _ in selection = [] }
    .modifier(MoveToDayPresentation(mover: mover, snapshot: snapshot))
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
  }

  // MARK: - Header

  private func header(_ calendar: SpendingCalendar, today: DateOnly) -> some View {
    let compact = ScreenWidth.isCompact(width)
    let scopePicker = Picker(selection: $scope) {
      Text(verbatim: t("calendar.scope.month")).tag(CalendarScope.month)
      Text(verbatim: t("calendar.scope.week")).tag(CalendarScope.week)
    } label: {
      Text(verbatim: t("calendar.scope"))
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .accessibilityIdentifier("calendar.scope")
    let stepper = ControlGroup {
      Button {
        anchor = SpendingCalendar.step(calendar.anchor, scope: scope, by: -1)
      } label: {
        Label {
          Text(verbatim: t("calendar.previous"))
        } icon: {
          Image(systemName: "chevron.left")
        }
      }
      .help(Text(verbatim: t("calendar.previous")))
      Button {
        anchor = nil
        chosen = nil
      } label: {
        Text(verbatim: t("calendar.today"))
      }
      .disabled(anchor == nil || calendar.range.contains(today))
      Button {
        anchor = SpendingCalendar.step(calendar.anchor, scope: scope, by: 1)
      } label: {
        Label {
          Text(verbatim: t("calendar.next"))
        } icon: {
          Image(systemName: "chevron.right")
        }
      }
      .help(Text(verbatim: t("calendar.next")))
    }
    .labelStyle(.iconOnly)
    .fixedSize()
    return Group {
      if compact {
        // A phone: the page title with the month under it, the steppers beside, and the
        // month/week switch on a full line of its own, as the design has it.
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top, spacing: 12) {
            ScreenTitleBlock(
              title: environment.language("section.calendar"),
              subtitle: CalendarText.title(of: calendar, environment),
              identifier: "calendar.title")
            Spacer(minLength: 8)
            stepper
          }
          scopePicker
        }
      } else {
        #if os(iOS)
          // A tablet draws the page title of the design itself, the month under it, with the
          // switch and the steppers at the right.
          HStack(alignment: .top, spacing: 12) {
            ScreenTitleBlock(
              title: environment.language("section.calendar"),
              subtitle: CalendarText.title(of: calendar, environment),
              identifier: "calendar.title")
            Spacer(minLength: 8)
            scopePicker.fixedSize()
            stepper
          }
        #else
          wideMacHeader(calendar, scopePicker: scopePicker, stepper: stepper)
        #endif
      }
    }
  }

  /// The Mac's wide header: the month as the window's title, the switch and the steppers.
  private func wideMacHeader(
    _ calendar: SpendingCalendar, scopePicker: some View, stepper: some View
  ) -> some View {
    HStack(spacing: 12) {
      Text(verbatim: CalendarText.title(of: calendar, environment))
        .appFont(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("calendar.title")
      Spacer(minLength: 8)
      scopePicker.fixedSize()
      stepper
    }
  }

  /// What the days in scope came to, the usual day, or why there is none.
  private func summary(_ calendar: SpendingCalendar) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 16) { summaryItems(calendar) }
      VStack(alignment: .leading, spacing: 4) { summaryItems(calendar) }
    }
    .appFont(.callout)
  }

  @ViewBuilder
  private func summaryItems(_ calendar: SpendingCalendar) -> some View {
    Text(
      verbatim: environment.format(
        "calendar.total", table: CalendarText.table,
        CalendarText.money(calendar.spent, of: calendar, environment))
    )
    .monospacedDigit()
    if let usual = calendar.usual {
      Text(
        verbatim: environment.format(
          "calendar.usual", table: CalendarText.table,
          CalendarText.money(usual, of: calendar, environment))
      )
      .monospacedDigit()
      .foregroundStyle(.secondary)
    }
    if calendar.lowData || calendar.usual == nil {
      Label {
        Text(verbatim: t("calendar.lowData"))
      } icon: {
        Image(systemName: "hourglass")
      }
      .foregroundStyle(.secondary)
    }
    if calendar.currency != .rub {
      Text(verbatim: t("calendar.atTodaysRate"))
        .foregroundStyle(.secondary)
    }
    legend
  }

  /// The symbols the cells use, each with its words.
  private var legend: some View {
    HStack(spacing: 10) {
      legendItem("arrow.up", "calendar.level.higher", tint: .orange)
      legendItem("flame", "calendar.level.muchHigher", tint: .orange)
      legendItem(CalendarText.symbol(of: .payment), "calendar.payment", tint: .secondary)
      legendItem(CalendarText.symbol(of: .income), "calendar.income", tint: .secondary)
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
  }

  private func legendItem(_ symbol: String, _ key: String, tint: Color) -> some View {
    Label {
      Text(verbatim: t(key))
    } icon: {
      Image(systemName: symbol).foregroundStyle(tint)
    }
  }

  // MARK: - Cards

  /// The grid with the summary and the legend on one card, as in the design.
  private func gridCard(_ calendar: SpendingCalendar) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      summary(calendar)
      grid(calendar)
      Text(verbatim: t("calendar.legend.level"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
    }
    .contentCard()
  }

  /// What is planned from today on, soonest first; hidden when nothing is.
  @ViewBuilder
  private func upcomingCard(_ calendar: SpendingCalendar) -> some View {
    let plans = CalendarLayout.upcoming(in: calendar)
    if !plans.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(verbatim: t("calendar.upcoming")).appFont(.headline)
          Spacer()
          Text(verbatim: "\(plans.count)").appFont(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        ForEach(plans) { plan in
          HStack(spacing: 8) {
            Image(systemName: CalendarText.symbol(of: plan.kind))
              .foregroundStyle(plan.kind == .income ? surfaces.positive : surfaces.accent)
              .frame(width: 22)
              .accessibilityLabel(
                Text(verbatim: t(plan.kind == .payment ? "calendar.payment" : "calendar.income")))
            Text(verbatim: "\(environment.dates.longDay(plan.day)) · \(plan.name)")
              .lineLimit(1)
            Spacer(minLength: 6)
            Text(verbatim: CalendarText.amount(of: plan, environment))
              .monospacedDigit()
              .foregroundStyle(plan.kind == .income ? surfaces.positive : surfaces.primary)
          }
          .appFont(.callout)
          .accessibilityElement(children: .combine)
        }
      }
      .contentCard()
      .accessibilityIdentifier("calendar.upcoming")
    }
  }

  // MARK: - Grid

  private func grid(_ calendar: SpendingCalendar) -> some View {
    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
      GridRow {
        ForEach(calendar.weekdays, id: \.self) { weekday in
          Text(verbatim: environment.dates.shortWeekday(weekday))
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
      }
      ForEach(calendar.weeks, id: \.first?.day) { week in
        GridRow {
          ForEach(week) { day in
            Button {
              chosen = day.day
            } label: {
              CalendarDayCell(
                day: day, calendar: calendar, detailed: calendar.scope == .week,
                isChosen: day.day == (chosen ?? calendar.today),
                hasNote: noteDays.contains(day.day), isDropTarget: dropTarget == day.day)
            }
            .buttonStyle(.plain)
            .dropDestination(for: String.self) { items, _ in
              drop(items, on: day.day)
            } isTargeted: { targeted in
              if targeted {
                dropTarget = day.day
              } else if dropTarget == day.day {
                dropTarget = nil
              }
            }
            .accessibilityIdentifier("calendar.day.\(day.day.iso)")
          }
        }
      }
    }
  }

  // MARK: - Moving and notes

  /// The days that have a note, for the mark on their cells.
  private var noteDays: Set<DateOnly> {
    Set((compute.snapshot?.dataset.dayNotes ?? []).map(\.day))
  }

  /// An operation dropped on a day: it is moved there, with every check an edit makes.
  private func drop(_ items: [String], on day: DateOnly) -> Bool {
    dropTarget = nil
    guard let payload = items.first, let id = OperationDrag.id(in: payload),
      let entry = compute.snapshot?.ledger.entry(id)
    else { return false }
    mover.request(
      entry, to: day, environment: environment, store: store, compute: compute)
    return true
  }

  // MARK: - The plans of the chosen day

  @ViewBuilder
  private func plans(of day: SpendingCalendarDay?, in calendar: SpendingCalendar) -> some View {
    if let day {
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: environment.dates.longDay(day.day))
          .appFont(.headline)
        DayNoteRow(
          day: day.day,
          note: compute.snapshot?.dataset.dayNotes.first { $0.day == day.day })
        if !day.plans.isEmpty {
          Text(verbatim: t("calendar.planned"))
            .appFont(.subheadline)
            .foregroundStyle(.secondary)
          ForEach(day.plans) { plan in
            HStack(spacing: 6) {
              Image(systemName: CalendarText.symbol(of: plan.kind))
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                  Text(verbatim: t(plan.kind == .payment ? "calendar.payment" : "calendar.income")))
              Text(verbatim: plan.name)
                .lineLimit(1)
              Spacer(minLength: 6)
              Text(verbatim: CalendarText.amount(of: plan, environment))
                .monospacedDigit()
            }
            .appFont(.callout)
            .accessibilityElement(children: .combine)
          }
        }
      }
      .padding(.vertical, 4)
      .listRowSeparator(.hidden)
      .selectionDisabled()
    }
  }
}
