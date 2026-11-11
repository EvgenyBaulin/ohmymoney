import AppCore
import SwiftUI

struct PhoneCalendarDayRoute: Hashable {
  let day: DateOnly
  var tab: PhoneCalendarDayTab = .operations
}

/// A month retains its grid; a week is a list with a spending figure beside each day.
/// The chosen day's card previews it, and opens its operations and plans on their own screen.
struct PhoneCalendarView: View {
  let actions: OperationActions
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.phoneEntryGate) private var entryGate
  @State private var state: PhoneCalendarState
  @State private var detail: PhoneCalendarDayRoute?
  @State private var width: CGFloat = 0
  @State private var mover = MoveToDayModel()

  init(actions: OperationActions, state: PhoneCalendarState = PhoneCalendarState()) {
    self.actions = actions
    _state = State(initialValue: state)
  }

  var body: some View {
    Group {
      if let snapshot = compute.snapshot {
        page(snapshot)
          .modifier(MoveToDayPresentation(mover: mover, snapshot: snapshot))
      } else if let waiting = compute.states.data.waiting {
        ComputedBlock(waiting: waiting, retry: { compute.retry(ComputeStep.data) })
      } else {
        ProgressView()
      }
    }
    .navigationDestination(item: $detail) { route in
      PhoneCalendarDayScreen(route: route, actions: actions)
        .handingOver(dependencies)
    }
    .onChange(of: detail) { _, _ in entryGate?.send(.tappedOutside) }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
  }

  private func page(_ snapshot: DataSnapshot) -> some View {
    let calendar = CalendarScreen.calendar(
      of: snapshot, scope: state.scope, anchor: state.anchor ?? snapshot.today,
      firstWeekday: CalendarScreen.firstWeekday(locale: environment.language.locale))
    let selected = state.selected(in: calendar)
    let gifts = CalendarBirthdays.gifts(
      people: snapshot.dataset.people, on: calendar.weeks.flatMap { $0 }.map(\.day),
      today: snapshot.today)
    return ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text(verbatim: CalendarText.title(of: calendar, environment)).appFont(.title3)
          Spacer(minLength: 4)
          stepper(calendar)
        }
        SectionSegments(
          options: [
            (CalendarScope.month, t("calendar.scope.month")),
            (CalendarScope.week, t("calendar.scope.week")),
          ],
          selection: Binding(
            get: { state.scope },
            set: { state.changeScope(to: $0, today: snapshot.today) }),
          chipsOnTouch: false, fillsWidth: true,
          identifier: { "calendar.scope.\($0.rawValue)" })
        if let message = mover.message {
          QuickCalendarMessage(text: message, failed: mover.failed)
        }
        if state.showsWeekList {
          PhoneCalendarWeekList(
            calendar: calendar, chosen: selected?.day, choose: { state.choose($0) })
        } else {
          CalendarGridCard(
            calendar: calendar, chosen: selected?.day ?? snapshot.today,
            noteDays: Set(snapshot.dataset.dayNotes.map(\.day)), birthdays: Set(gifts.keys),
            dropTarget: nil, choose: { state.choose($0) },
            drop: { items, day in drop(items, on: day, snapshot: snapshot) },
            target: { _, _ in },
            width: CalendarMetrics.gridWidth(column: max(0, width - 32)))
        }
        if let selected {
          VStack(alignment: .leading, spacing: 12) {
            SectionCardHeader(title: CalendarText.dayTitle(selected.day, environment))
            PhoneCalendarDayChips(
              days: state.chips(in: calendar), chosen: selected.day,
              choose: { state.choose($0) })
            Text(verbatim: CalendarText.label(of: selected, in: calendar, environment))
              .appFont(.callout)
              .foregroundStyle(.secondary)
            HStack {
              Button(t("calendar.day.operations")) {
                detail = PhoneCalendarDayRoute(day: selected.day)
              }
              Spacer(minLength: 8)
              Button(t("calendar.day.plans")) {
                detail = PhoneCalendarDayRoute(day: selected.day, tab: .plans)
              }
            }
            .appFont(.callout)
            .buttonStyle(.bordered)
          }
          .sectionCard()
          .accessibilityIdentifier("calendar.phone.selectedDay")
        }
        CalendarUpcomingCard(calendar: calendar)
      }
      .padding(16)
      .padding(.horizontal, PhoneMetrics.screenMargin - 16)
    }
    .background(surfaces.background)
    .accessibilityIdentifier("calendar.phone")
  }

  private func stepper(_ calendar: SpendingCalendar) -> some View {
    HStack(spacing: 0) {
      Button {
        state.step(in: calendar, by: -1)
      } label: {
        Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44)
      }
      .accessibilityLabel(t("calendar.previous"))
      Button(t("calendar.today")) { state.showToday() }
        .frame(minHeight: 44)
      Button {
        state.step(in: calendar, by: 1)
      } label: {
        Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
      }
      .accessibilityLabel(t("calendar.next"))
    }
    .appFont(.callout)
    .buttonStyle(.plain)
  }

  private func drop(_ items: [String], on day: DateOnly, snapshot: DataSnapshot) -> Bool {
    guard let payload = items.first, let id = OperationDrag.id(in: payload),
      let entry = snapshot.ledger.entry(id), let dependencies
    else { return false }
    mover.request(
      entry, to: day, environment: environment, store: dependencies.store, compute: compute)
    return true
  }

  private func t(_ key: String) -> String { CalendarText.t(key, environment) }
}

struct PhoneCalendarWeekList: View {
  let calendar: SpendingCalendar
  let chosen: DateOnly?
  let choose: (DateOnly) -> Void
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.appTheme) private var theme

  var body: some View {
    VStack(spacing: 4) {
      ForEach(calendar.days) { day in
        Button {
          choose(day.day)
        } label: {
          HStack(spacing: 10) {
            Text(
              verbatim: environment.dates.shortWeekday(
                environment.calendar.weekdayIndex(day.day)) + " \(day.day.day)"
            )
            .appFont(.headline)
            if let symbol = CalendarText.symbol(of: day.level) {
              Image(systemName: symbol).accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
              if let spent = day.spent {
                Text(
                  verbatim: environment.format(
                    "calendar.spent", table: CalendarText.table,
                    CalendarText.money(spent, of: calendar, environment)))
              } else {
                Text(verbatim: CalendarText.t("calendar.day.plans", environment))
              }
              if !day.plans.isEmpty {
                Label("\(day.plans.count)", systemImage: "clock")
                  .foregroundStyle(.secondary)
              }
            }
            .appFont(.callout)
          }
          .foregroundStyle(surfaces.primary)
          .padding(10)
          .frame(minHeight: 44)
          .background(
            chosen == day.day ? theme.accentTint : .clear,
            in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CalendarText.label(of: day, in: calendar, environment))
        .accessibilityAddTraits(chosen == day.day ? [.isSelected] : [])
        .accessibilityIdentifier("calendar.phone.week.\(day.day.iso)")
      }
    }
    .sectionCard()
    .accessibilityIdentifier("calendar.phone.weekList")
  }
}

struct PhoneCalendarDayChips: View {
  let days: [SpendingCalendarDay]
  let chosen: DateOnly
  let choose: (DateOnly) -> Void
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 4) {
        ForEach(days) { day in
          Button {
            choose(day.day)
          } label: {
            VStack(spacing: 2) {
              Text(
                verbatim: environment.dates.shortWeekday(
                  environment.calendar.weekdayIndex(day.day)))
              Text(verbatim: "\(day.day.day)")
            }
            .appFont(.callout)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(chosen == day.day ? surfaces.onAccent : surfaces.primary)
            .background(
              chosen == day.day ? surfaces.accent : surfaces.card,
              in: .rect(cornerRadius: 12))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(environment.dates.longDay(day.day))
          .accessibilityAddTraits(chosen == day.day ? [.isSelected] : [])
          .accessibilityIdentifier("calendar.phone.chip.\(day.day.iso)")
        }
      }
    }
    .scrollIndicators(.hidden)
    .accessibilityIdentifier("calendar.phone.dayChips")
  }
}

/// The day is a separate navigation destination, with operations and plans kept apart.
struct PhoneCalendarDayScreen: View {
  let actions: OperationActions
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var day: DateOnly
  @State private var tab: PhoneCalendarDayTab
  @State private var selection: Set<UUID> = []
  @State private var mover = MoveToDayModel()
  @State private var giftMessage: String?

  init(route: PhoneCalendarDayRoute, actions: OperationActions) {
    self.actions = actions
    _day = State(initialValue: route.day)
    _tab = State(initialValue: route.tab)
  }

  var body: some View {
    Group {
      if let snapshot = compute.snapshot {
        content(snapshot)
          .modifier(MoveToDayPresentation(mover: mover, snapshot: snapshot))
          .onChange(of: compute.generation, initial: true) { _, _ in
            actions.reloadDictionaries(from: snapshot.dataset)
          }
      }
    }
    .navigationTitle(CalendarText.t("calendar.day.title", environment))
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: day) { _, _ in
      selection = []
      giftMessage = nil
    }
  }

  private func content(_ snapshot: DataSnapshot) -> some View {
    let calendar = CalendarScreen.calendar(
      of: snapshot, scope: .week, anchor: day,
      firstWeekday: CalendarScreen.firstWeekday(locale: environment.language.locale))
    let selected = calendar.day(day)
    return VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: CalendarText.dayTitle(day, environment)).appFont(.title3)
      PhoneCalendarDayChips(days: calendar.days, chosen: day, choose: { day = $0 })
      SectionSegments(
        options: PhoneCalendarDayTab.allCases.map {
          ($0, CalendarText.t($0.titleKey, environment))
        },
        selection: $tab, chipsOnTouch: false, fillsWidth: true,
        identifier: { "calendar.phone.day.\($0.rawValue)" })
      if let message = mover.message {
        QuickCalendarMessage(text: message, failed: mover.failed)
      }
      if tab == .operations {
        DayList(
          groups: CalendarScreen.groups(of: selected, in: snapshot, calendar: environment.calendar),
          selection: $selection, ledger: snapshot.ledger,
          emptyText: CalendarText.t("calendar.day.empty", environment),
          header: { EmptyView() },
          menu: { ids in
            BulkMenuItems(ids: ids, actions: actions, offersEdit: true)
            if ids.count == 1, let id = ids.first {
              Button(QuickText.t("quick.move.menu", environment)) {
                mover.picking = MoveToDayModel.Pick(id: id)
              }
            }
          },
          primaryAction: { actions.edit($0, store: store) },
          deleteAction: { actions.requestDeletion(of: $0, store: store) },
          dragsRows: true, showsDayHeaders: false
        )
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("calendar.phone.day.operationsList")
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            DayNoteRow(day: day, note: snapshot.dataset.dayNotes.first { $0.day == day })
            birthdays(snapshot)
            if let selected, selected.plans.isEmpty {
              Text(verbatim: CalendarText.t("calendar.day.noPlans", environment))
                .appFont(.callout).foregroundStyle(.secondary)
            }
            if let selected {
              ForEach(selected.plans) { plan in
                HStack(spacing: 8) {
                  Image(systemName: CalendarMark.symbol(plan.source))
                    .accessibilityLabel(
                      CalendarText.t(CalendarMark.wordKey(plan.source), environment))
                  Text(verbatim: CalendarText.title(of: plan, environment))
                  Spacer(minLength: 8)
                  Text(verbatim: CalendarText.amount(of: plan, environment)).monospacedDigit()
                }
                .appFont(.callout)
                .accessibilityElement(children: .combine)
              }
            }
            if let giftMessage { Text(verbatim: giftMessage).appFont(.callout) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .sectionCard()
        }
        .accessibilityIdentifier("calendar.phone.day.plansList")
      }
    }
    .padding(16)
    .padding(.horizontal, PhoneMetrics.screenMargin - 16)
    .accessibilityIdentifier("calendar.phone.dayScreen")
  }

  @ViewBuilder
  private func birthdays(_ snapshot: DataSnapshot) -> some View {
    let gifts =
      CalendarBirthdays.gifts(
        people: snapshot.dataset.people, on: [day], today: snapshot.today)[day] ?? []
    ForEach(gifts) { gift in
      VStack(alignment: .leading, spacing: 4) {
        Label(PurchaseHookText.calendarLine(gift, environment), systemImage: "gift")
        if CalendarBirthdays.offersEvent(
          for: gift, events: snapshot.dataset.events, environment), let dependencies
        {
          Button(PurchaseHookText.t("calendar.birthday.createEvent", environment)) {
            giftMessage = PurchaseHookText.t(
              PurchaseHookActions.createEvent(for: gift, deps: dependencies)
                ? "calendar.birthday.created" : "calendar.birthday.notCreated", environment)
          }
        }
      }
      .appFont(.callout)
    }
  }
}
