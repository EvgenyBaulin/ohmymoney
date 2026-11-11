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
  @Environment(\.dependencies) private var dependencies
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
  /// «Только подписки»: the grid gives way to the days subscriptions are charged on.
  /// What the button «Создать событие с бюджетом» said last.
  @State private var giftMessage: String?
  @Environment(\.layoutIdiom) private var idiom

  private func t(_ key: String) -> String { CalendarText.t(key, environment) }

  var body: some View {
    #if os(iOS)
      if LayoutIdiom.resolved(idiom) == .phone {
        PhoneCalendarView(actions: actions)
      } else {
        sharedCalendar
      }
    #else
      sharedCalendar
    #endif
  }

  @ViewBuilder
  private var sharedCalendar: some View {
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
    let gifts = CalendarBirthdays.gifts(
      people: snapshot.dataset.people, on: calendar.weeks.flatMap { $0 }.map(\.day),
      today: snapshot.today)
    let design = LayoutIdiom.resolved(idiom)
    let wide = design != .phone && CalendarLayout.isWide(width: width)
    let content = max(0, width - 2 * SectionMetrics.side(design))
    // The tablet's columns are 448 and 584 of its 1,052, as Capital's; the Mac's are equal.
    let columns = CapitalLayout.columnWidths(forContent: content, idiom: design)
    let column = wide ? columns.1 : content
    let grid = CalendarGridCard(
      calendar: calendar, chosen: chosen ?? calendar.today, noteDays: noteDays,
      birthdays: Set(gifts.keys), dropTarget: dropTarget,
      choose: { chosen = $0 }, drop: { drop($0, on: $1) },
      target: { day, targeted in
        if targeted {
          dropTarget = day
        } else if dropTarget == day {
          dropTarget = nil
        }
      }, width: width > 0 ? CalendarMetrics.gridWidth(column: column) : 0)
    let dayCard = dayCard(
      chosenDay, calendar: calendar, snapshot: snapshot,
      gifts: gifts[chosenDay?.day ?? snapshot.today] ?? [])
    return VStack(alignment: .leading, spacing: SectionMetrics.headerToContent) {
      header(calendar, today: snapshot.today)
      if let text = mover.message {
        QuickCalendarMessage(text: text, failed: mover.failed)
      }
      if let giftMessage {
        Label(giftMessage, systemImage: "gift")
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("calendar.birthday.message")
      }
      if wide {
        // The frame: the switch, the chosen day and the dearer days on the left; the month and
        // what is ahead on the right, 16 apart.
        HStack(alignment: .top, spacing: SectionMetrics.columnGap(design)) {
          VStack(alignment: .leading, spacing: SectionMetrics.stackGap) {
            scopeSwitch
            dayCard
            CalendarDearDaysCard(calendar: calendar) { chosen = $0 }
          }
          .frame(width: width > 0 ? columns.0 : nil)
          .frame(maxHeight: .infinity, alignment: .top)
          ScrollView {
            VStack(alignment: .leading, spacing: SectionMetrics.stackGap) {
              grid
              CalendarUpcomingCard(calendar: calendar)
            }
          }
          .scrollIndicators(.never)
          .frame(width: width > 0 ? columns.1 : nil)
        }
      } else {
        VStack(alignment: .leading, spacing: SectionMetrics.stackGap) {
          scopeSwitch
          grid
          dayCard
          CalendarUpcomingCard(calendar: calendar)
        }
      }
    }
    .padding(.horizontal, SectionMetrics.side(design))
    .padding(.top, SectionMetrics.top(design))
    .padding(.bottom, SectionMetrics.bottom(design))
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(surfaces.background)
    .onChange(of: compute.generation) { _, _ in actions.reloadDictionaries(from: snapshot.dataset) }
    .onAppear { actions.reloadDictionaries(from: snapshot.dataset) }
    .onChange(of: chosen) { _, _ in
      selection = []
      giftMessage = nil
    }
    .modifier(MoveToDayPresentation(mover: mover, snapshot: snapshot))
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
  }

  /// «Месяц | Неделя»: the track of the frame on the Mac and a tablet.
  private var scopeSwitch: some View {
    SectionSegments(
      options: [
        (CalendarScope.month, t("calendar.scope.month")),
        (CalendarScope.week, t("calendar.scope.week")),
      ],
      selection: $scope, chipsOnTouch: false, fillsWidth: LayoutIdiom.resolved(idiom) == .pad,
      identifier: { "calendar.scope.\($0.rawValue)" }
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("calendar.scope")
  }

  /// The card of the chosen day: «Среда, 21 октября» and what it cost at the right, then what is
  /// planned for it and its operations — the list of «Траты», with its selection, its menu, a
  /// double click to edit and its rows dragged to another day.
  private func dayCard(
    _ chosenDay: SpendingCalendarDay?, calendar: SpendingCalendar, snapshot: DataSnapshot,
    gifts: [GiftDay]
  ) -> some View {
    VStack(alignment: .leading, spacing: SectionMetrics.cardGap) {
      SectionCardHeader(
        title: CalendarText.dayTitle(chosenDay?.day ?? snapshot.today, environment),
        caption: CalendarFigures.spent(on: chosenDay).map {
          "−" + CalendarText.money($0, of: calendar, environment)
        }
      )
      .accessibilityIdentifier("calendar.day.title")
      DayList(
        groups: CalendarScreen.groups(of: chosenDay, in: snapshot, calendar: environment.calendar),
        selection: $selection,
        ledger: snapshot.ledger,
        emptyText: chosenDay.map { _ in t("calendar.day.empty") },
        header: {
          plans(of: chosenDay, in: calendar, gifts: gifts, events: snapshot.dataset.events)
        },
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
        dragsRows: true,
        showsDayHeaders: false
      )
      .scrollContentBackground(.hidden)
      .frame(minHeight: CalendarMetrics.dayListMinimum)
      .accessibilityIdentifier("calendar.dayList")
    }
    .sectionCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("calendar.dayCard")
  }

  // MARK: - Header

  /// «Календарь» 22 bold, the month under it, «Новая операция» at the right; the steppers of the
  /// month — which the frame does not draw — stand before the button.
  private func header(_ calendar: SpendingCalendar, today: DateOnly) -> some View {
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
    .accessibilityIdentifier("calendar.stepper")
    return SectionHeader(
      title: environment.language("section.calendar"),
      subtitle: CalendarText.title(of: calendar, environment),
      identifier: "calendar.screenTitle",
      primary: (
        environment.language("operations.new", table: "Transactions"), "calendar.newOperation",
        { NotificationCenter.default.post(name: .focusEntryLine, object: nil) }
      ),
      trailing: AnyView(stepper))
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
  private func plans(
    of day: SpendingCalendarDay?, in calendar: SpendingCalendar, gifts: [GiftDay] = [],
    events: [Event] = []
  ) -> some View {
    if let day {
      VStack(alignment: .leading, spacing: 4) {
        DayNoteRow(
          day: day.day,
          note: compute.snapshot?.dataset.dayNotes.first { $0.day == day.day })
        ForEach(gifts) { gift in birthdayRow(gift, events: events) }
        if !day.plans.isEmpty {
          Text(verbatim: t("calendar.planned"))
            .appFont(.subheadline)
            .foregroundStyle(.secondary)
          ForEach(day.plans) { plan in
            HStack(spacing: 6) {
              Image(systemName: CalendarText.symbol(of: plan.kind))
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                  Text(verbatim: t(CalendarMark.wordKey(plan.source))))
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: CalendarText.title(of: plan, environment)).lineLimit(1)
                if let full = CalendarText.fullAmount(of: plan, environment) {
                  Text(verbatim: full).appFont(.caption).foregroundStyle(.secondary)
                }
              }
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

  // MARK: - Birthdays

  /// «День рождения Маши, бюджет 5 000 ₽» and, until the event exists, the button that makes it.
  private func birthdayRow(_ gift: GiftDay, events: [Event]) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "gift")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(verbatim: PurchaseHookText.calendarLine(gift, environment))
        .lineLimit(2)
      Spacer(minLength: 6)
      if CalendarBirthdays.offersEvent(for: gift, events: events, environment),
        let dependencies
      {
        Button(PurchaseHookText.t("calendar.birthday.createEvent", environment)) {
          giftMessage =
            PurchaseHookActions.createEvent(for: gift, deps: dependencies)
            ? PurchaseHookText.t("calendar.birthday.created", environment)
            : PurchaseHookText.t("calendar.birthday.notCreated", environment)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("calendar.birthday.createEvent")
      }
    }
    .appFont(.callout)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("calendar.birthday")
  }
}
