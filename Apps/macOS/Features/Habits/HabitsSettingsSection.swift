import AppCore
import SwiftUI

/// «Привычки» in the settings: after how many days without entries «Стоит посмотреть» offers to
/// restore them (a setting of the database: it travels with the archive and between devices), the
/// question of the evening and its hour, and the mode of a beginner (habits of this Mac).
struct HabitsSettingsSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @AppStorage(HabitNotesOnMac.eveningEnabledKey) private var evening = true
  @AppStorage(HabitNotesOnMac.eveningHourKey) private var hour = HabitNotes.defaultEveningHour
  @State private var missedAfter = HabitSettings.defaultMissedDaysAfter
  @State private var beginner = false
  @State private var loaded = false

  /// The hours the evening may start at.
  static let eveningHours = 16...23

  private func t(_ key: String) -> String { HabitText.t(key, environment) }

  var body: some View {
    Section {
      Stepper(
        value: Binding(get: { missedAfter }, set: { save(missedAfter: $0) }),
        in: HabitSettings.missedDaysRange
      ) {
        Text(verbatim: t("settings.habits.missedAfter") + ": \(missedAfter)")
        Text(verbatim: t("settings.habits.missedAfterHint"))
      }
      .accessibilityIdentifier("settings.habits.missedAfter")
      Toggle(isOn: $evening) {
        Text(verbatim: t("settings.habits.evening"))
        Text(verbatim: t("settings.habits.eveningHint"))
      }
      .accessibilityIdentifier("settings.habits.evening")
      if evening {
        Picker(t("settings.habits.eveningHour"), selection: $hour) {
          ForEach(Array(Self.eveningHours), id: \.self) { value in
            Text(verbatim: String(format: "%02d:00", value)).tag(value)
          }
        }
        .accessibilityIdentifier("settings.habits.eveningHour")
      }
      Toggle(
        isOn: Binding(
          get: { beginner },
          set: {
            beginner = $0
            BeginnerModeOnMac.set($0)
          })
      ) {
        Text(verbatim: t("settings.habits.beginner"))
        Text(verbatim: t("settings.habits.beginnerHint"))
      }
      .accessibilityIdentifier("settings.habits.beginner")
    } header: {
      Text(verbatim: t("settings.habits.title"))
        .settingsHeaderStyle()
    }
    .onAppear(perform: load)
    .onChange(of: compute.generation) { load() }
  }

  private func load() {
    beginner = BeginnerModeOnMac.enabled()
    guard let habits = environment.habits, let data = try? habits.data() else { return }
    missedAfter = data.settings.missedDaysAfter
    loaded = true
  }

  private func save(missedAfter value: Int) {
    let settings = HabitSettings(missedDaysAfter: value)
    guard let habits = environment.habits, (try? habits.save(settings)) != nil else { return }
    missedAfter = settings.missedDaysAfter
    AppLog.info(
      "habits.settingSaved", .db, "the days before the wizard of missed days were set",
      [LogPair("days", .count(settings.missedDaysAfter))])
  }
}
