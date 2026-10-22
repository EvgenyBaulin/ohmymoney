import AppCore
import SwiftUI

/// How the settings of the spending analysis turn into values and back: the weekend window as
/// two moments of a week, and the hours of work in a month. Apart from the section so a test
/// reads them.
enum SpendingAnalysisSettingsForm {
  /// The hours of work in a month the stepper allows: up to 31 days of 24 hours.
  static let hoursRange = 1...744

  /// A moment of the day as a `Date` today, for a time picker.
  static func date(
    for time: TimeOfDay, calendar: Calendar = .current, on day: Date = Date()
  ) -> Date {
    calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) ?? day
  }

  /// The time of day a picker shows.
  static func time(from date: Date, calendar: Calendar = .current) -> TimeOfDay {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
  }

  /// The window with its start changed; the end stays.
  static func settingStart(
    _ window: WeekendWindow, weekday: Int? = nil, time: TimeOfDay? = nil
  ) -> WeekendWindow {
    WeekendWindow(
      startWeekday: weekday ?? window.startWeekday, start: time ?? window.start,
      endWeekday: window.endWeekday, end: window.end)
  }

  /// The window with its end changed; the start stays.
  static func settingEnd(
    _ window: WeekendWindow, weekday: Int? = nil, time: TimeOfDay? = nil
  ) -> WeekendWindow {
    WeekendWindow(
      startWeekday: window.startWeekday, start: window.start,
      endWeekday: weekday ?? window.endWeekday, end: time ?? window.end)
  }
}

/// «Анализ трат» in the planning settings: which hours are the weekend, and the price in hours of
/// work. Both live in the `settings` table, so they travel in the archive and reach the numbers
/// through the observation of the database.
struct SpendingAnalysisSettingsSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @State private var window = WeekendWindow.standard
  @State private var hours = WorkHoursSettings()
  @State private var loaded = false

  var body: some View {
    Section {
      weekendRows
      workHoursRows
    } header: {
      Text(verbatim: t("spending.settings.title"))
        .settingsHeaderStyle()
    }
    .onAppear { load() }
  }

  private func load() {
    guard !loaded, let dataset = compute.snapshot?.dataset else { return }
    window = dataset.weekendWindow
    hours = dataset.workHours
    loaded = true
  }

  // MARK: The weekend

  @ViewBuilder
  private var weekendRows: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: t("spending.settings.weekend")).appFont(.body)
      HStack(spacing: 8) {
        Text(verbatim: t("spending.settings.weekend.from"))
        dayPicker(window.startWeekday, id: "start") {
          save(SpendingAnalysisSettingsForm.settingStart(window, weekday: $0))
        }
        timePicker(window.start, id: "start") {
          save(SpendingAnalysisSettingsForm.settingStart(window, time: $0))
        }
      }
      HStack(spacing: 8) {
        Text(verbatim: t("spending.settings.weekend.to"))
        dayPicker(window.endWeekday, id: "end") {
          save(SpendingAnalysisSettingsForm.settingEnd(window, weekday: $0))
        }
        timePicker(window.end, id: "end") {
          save(SpendingAnalysisSettingsForm.settingEnd(window, time: $0))
        }
      }
      Text(verbatim: SpendingText.windowLine(window, environment))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("settings.weekend.line")
      Text(verbatim: t("spending.settings.weekend.hint"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(t("spending.settings.weekend.reset")) { save(.standard) }
        .disabled(window == .standard)
        .accessibilityIdentifier("settings.weekend.reset")
    }
  }

  private func dayPicker(_ weekday: Int, id: String, set: @escaping @MainActor (Int) -> Void)
    -> some View
  {
    Picker(
      selection: Binding(get: { weekday }, set: { value in MainActor.assumeIsolated { set(value) } })
    ) {
      ForEach(1...7, id: \.self) { value in
        Text(verbatim: environment.dates.weekday(value)).tag(value)
      }
    } label: {
      EmptyView()
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .fixedSize()
    .accessibilityIdentifier("settings.weekend.\(id).day")
  }

  private func timePicker(
    _ time: TimeOfDay, id: String, set: @escaping (TimeOfDay) -> Void
  )
    -> some View
  {
    DatePicker(
      selection: Binding(
        get: { SpendingAnalysisSettingsForm.date(for: time) },
        set: { set(SpendingAnalysisSettingsForm.time(from: $0)) }),
      displayedComponents: .hourAndMinute
    ) {
      EmptyView()
    }
    .labelsHidden()
    .environment(\.locale, environment.language.locale)
    .fixedSize()
    .accessibilityIdentifier("settings.weekend.\(id).time")
  }

  private func save(_ new: WeekendWindow) {
    guard new != window else { return }
    window = new
    environment.saveWeekend(new)
  }

  // MARK: The price in hours

  @ViewBuilder
  private var workHoursRows: some View {
    Toggle(
      isOn: Binding(
        get: { hours.isEnabled },
        set: {
          hours.isEnabled = $0
          environment.saveWorkHours(hours)
        })
    ) {
      Text(verbatim: t("spending.settings.hours.enabled"))
      Text(verbatim: t("spending.settings.hours.hint"))
    }
    .accessibilityIdentifier("settings.workHours.enabled")
    if hours.isEnabled {
      Stepper(
        value: Binding(
          get: { hours.hoursPerMonth },
          set: {
            hours.hoursPerMonth = $0
            environment.saveWorkHours(hours)
          }),
        in: SpendingAnalysisSettingsForm.hoursRange
      ) {
        Text(
          verbatim: SpendingText.counted(
            "spending.settings.hours.perMonth", environment, count: hours.hoursPerMonth))
      }
      .accessibilityIdentifier("settings.workHours.perMonth")
    }
  }

  private func t(_ key: String) -> String { SpendingText.t(key, environment) }
}
