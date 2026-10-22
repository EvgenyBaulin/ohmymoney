import AppCore
import SwiftUI

/// «3 черновика ждут — дописать?»: the row of «Стоит посмотреть» for lines left for later. From
/// 21:00 only (`DraftReminder`); until the notifications of a later version, the row is the whole
/// reminder. «Дописать…» opens the list of drafts over the entry line.
struct DraftReminderRow: View {
  @Dependency(\.environment) private var environment
  @State private var drafts: [PendingDraft] = []

  var body: some View {
    TimelineView(.everyMinute) { context in
      content(now: context.date)
    }
    .onAppear(perform: reload)
    .onReceive(NotificationCenter.default.publisher(for: .draftsChanged)) { _ in reload() }
  }

  @ViewBuilder
  private func content(now: Date) -> some View {
    if let line = DraftReminder.line(drafts: drafts, now: now, calendar: environment.calendar) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "clock.arrow.circlepath")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(verbatim: QuickText.counted("quick.drafts.reminder", environment, line.count))
          .appFont(.callout)
        Spacer(minLength: 6)
        Button(QuickText.t("quick.drafts.reminder.action", environment)) {
          NotificationCenter.default.post(name: .openDrafts, object: nil)
        }
        .buttonStyle(.link)
        .appFont(.caption)
        .accessibilityIdentifier("quick.drafts.reminder.action")
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("quick.drafts.reminder")
    }
  }

  private func reload() {
    drafts = SettingsDraftStore(settings: environment.settings).load()
  }
}
