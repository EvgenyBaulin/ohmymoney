import AppCore
import AppDatabase
import SwiftUI

/// «Я в поездке» of the toolbar. Mode off: the trips still to come to pick from, and «Новая
/// поездка…» below them; mode on: where the trip is, «Я вернулся» and «Продлить…». Choosing a
/// trip or making one turns the mode on for it; what the mode then changes is only the defaults
/// of the entry. The rules (which trips are offered, what a new trip is) are the core's
/// (`TripStart`); this lays them out and writes through `TripStartActions`.
struct TripStartSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  /// A form for a new trip is shown instead of the list.
  @State private var making: TripStart.Draft?
  @State private var extending: TripRef?

  var body: some View {
    let dataset = compute.snapshot?.dataset
    let state = TripMode.state(
      settings: dataset?.tripSettings ?? .off, events: dataset?.events ?? [],
      today: environment.today)
    Group {
      if let making {
        NewTripForm(draft: making, onDone: { self.making = nil })
      } else if case .on(let event) = state {
        onView(event)
      } else {
        offView(dataset?.events ?? [])
      }
    }
    .padding(20)
    .sheetFrame(width: 460)
    .frame(minHeight: 260)
    .sheet(item: $extending) { trip in
      TripExtendSheet(eventId: trip.id).handingOver(dependencies)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("travel.start")
  }

  private func offView(_ events: [Event]) -> some View {
    let trips = TripStart.choices(events: events, today: environment.today)
    return VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: TravelText.t("travel.start.title", environment)).appFont(.headline)
      if trips.isEmpty {
        Text(verbatim: TravelText.t("travel.start.none", environment))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(verbatim: TravelText.t("travel.start.pick", environment))
          .appFont(.callout)
          .foregroundStyle(.secondary)
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(trips) { trip in
              Button {
                if let dependencies, TripStartActions(dependencies).switchOn(trip) {
                  dismiss()
                }
              } label: {
                HStack {
                  Text(verbatim: trip.name)
                  Spacer(minLength: 8)
                  Text(verbatim: days(of: trip))
                    .foregroundStyle(.secondary)
                    .appFont(.callout.monospacedDigit())
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .padding(.vertical, 4)
              .accessibilityIdentifier("travel.start.trip")
            }
          }
        }
        .frame(maxHeight: 200)
      }
      Divider()
      HStack {
        Button(TravelText.t("travel.start.new", environment)) {
          making = TripStart.Draft(
            name: "", startDate: environment.today, endDate: environment.today,
            budgetCurrency: environment.defaultCurrency)
        }
        .accessibilityIdentifier("travel.start.new")
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
  }

  private func onView(_ event: Event) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: TravelText.t("travel.start.title", environment)).appFont(.headline)
      Label {
        Text(
          verbatim: TravelText.format(
            "travel.start.on", environment, event.name,
            PlanningBlockText.dayText(event.endDate, environment)))
      } icon: {
        Image(systemName: "airplane")
      }
      .accessibilityIdentifier("travel.start.current")
      Text(verbatim: TravelText.t("travel.start.onHint", environment))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      HStack {
        Button(TravelText.t("travel.start.back", environment)) {
          if let dependencies, TripStartActions(dependencies).switchOff() { dismiss() }
        }
        .accessibilityIdentifier("travel.start.back")
        Button(TravelText.t("travel.start.extend", environment)) {
          extending = TripRef(id: event.id)
        }
        .accessibilityIdentifier("travel.start.extend")
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
  }

  private func days(of trip: Event) -> String {
    TravelText.format(
      "travel.start.days", environment, PlanningBlockText.dayText(trip.startDate, environment),
      PlanningBlockText.dayText(trip.endDate, environment))
  }
}

/// A trip named for a sheet to show.
struct TripRef: Identifiable {
  let id: UUID
}

/// A new trip: the country or the name, the days, the currency of the trip and the budget. The
/// same form serves «Сделать поездкой» on a gathered goal, which starts it filled in.
struct NewTripForm: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  @State private var draft: TripStart.Draft
  @State private var budget: AmountE4
  @State private var switchesOn = true
  /// Left to the sheet that shows the form in place of its list; absent, the form closes it all.
  var onDone: (() -> Void)?

  init(draft: TripStart.Draft, onDone: (() -> Void)? = nil) {
    _draft = State(initialValue: draft)
    _budget = State(initialValue: draft.budget ?? .zero)
    self.onDone = onDone
  }

  /// The draft as the fields hold it.
  private var typed: TripStart.Draft {
    var typed = draft
    typed.budget = budget > .zero ? budget : nil
    typed.endDate = max(typed.startDate, typed.endDate)
    return typed
  }

  var body: some View {
    let issue = TripStart.issue(of: typed, today: environment.today)
    let currencies = (try? environment.settings?.enabledCurrencies()) ?? [.rub]
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: TravelText.t("travel.new.title", environment)).appFont(.headline)
      Form {
        TextField(TravelText.t("travel.new.name", environment), text: $draft.name)
          .accessibilityIdentifier("travel.new.name")
        DatePicker(
          TravelText.t("travel.new.start", environment),
          selection: Binding(
            get: { environment.calendar.startOfDay(draft.startDate) },
            set: { draft.startDate = environment.calendar.day(of: $0) }),
          displayedComponents: .date)
        DatePicker(
          TravelText.t("travel.new.end", environment),
          selection: Binding(
            get: { environment.calendar.startOfDay(max(draft.startDate, draft.endDate)) },
            set: { draft.endDate = environment.calendar.day(of: $0) }),
          in: environment.calendar.startOfDay(draft.startDate)...,
          displayedComponents: .date)
        Picker(TravelText.t("travel.new.currency", environment), selection: $draft.tripCurrency) {
          Text(verbatim: TravelText.t("travel.new.currencyNone", environment))
            .tag(CurrencyCode?.none)
          ForEach(currencies, id: \.self) { Text(verbatim: $0.code).tag(CurrencyCode?.some($0)) }
        }
        LabeledContent(TravelText.t("travel.new.budget", environment)) {
          HStack {
            AmountField(amount: $budget)
              .accessibilityIdentifier("travel.new.budget")
            Picker(selection: $draft.budgetCurrency) {
              ForEach(currencies, id: \.self) { Text(verbatim: $0.code).tag($0) }
            } label: {
              EmptyView()
            }
            .labelsHidden()
            .fixedSize()
          }
        }
        Toggle(TravelText.t("travel.new.switchOn", environment), isOn: $switchesOn)
          .accessibilityIdentifier("travel.new.switchOn")
        if let issue {
          Text(verbatim: TravelText.t("travel.new.issue.\(issue.rawValue)", environment))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      FormButtons(
        title: TravelText.t("travel.new.confirm", environment), enabled: issue == nil,
        failure: { TravelText.t("travel.new.failed", environment) }
      ) {
        guard let dependencies else { return false }
        let done = TripStartActions(dependencies).start(typed, switchingOn: switchesOn)
        if done { onDone?() }
        return done
      }
    }
  }
}

/// «Сделать поездкой…» on a goal that has gathered its target: the form of a new trip, filled in
/// from the goal (`TripGoal.draft`) — its name, its money as the budget in its currency, the first
/// two weeks from its date. The mode goes on for the trip unless the owner unticks it.
struct TripFromGoalSheet: View {
  @Dependency(\.environment) private var environment
  let status: GoalStatus

  var body: some View {
    Group {
      if let draft = TripGoal.draft(
        goalName: status.goal.name, target: status.goal.targetE4, saved: status.saved,
        currency: status.currency, targetDate: status.goal.targetDate, today: environment.today)
      {
        NewTripForm(draft: draft)
      } else {
        Text(verbatim: TravelText.t("travel.goal.notGathered", environment))
          .foregroundStyle(.secondary)
      }
    }
    .padding(20)
    .sheetFrame(width: 460)
    .frame(minHeight: 260)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("travel.goalTrip")
  }
}
