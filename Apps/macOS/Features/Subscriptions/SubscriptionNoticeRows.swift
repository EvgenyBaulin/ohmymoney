import AppCore
import SwiftUI

/// The lines of «Стоит посмотреть» that come from the subscriptions: «Завтра Кинопоиск спишет
/// 399 ₽ — пробный период кончается», «Через 14 дней — годовая оплата Яндекс 360», «Коммуналка
/// 5 900 ₽ вместо обычных 3 800–4 400». Each says what it is about in words and a symbol; «Отложить»
/// puts it away on this Mac until the occasion changes (its id holds the day or the charge), the
/// same marks the reminders of debts use.
struct SubscriptionNoticeRows: View {
  /// How many lines the card shows at most.
  static let shown = 3

  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @State private var notices: [SubscriptionNotice] = []
  @State private var dismissed: Set<String> = []

  var body: some View {
    let names = Dictionary(
      (compute.snapshot?.dataset.planning.scheduled ?? []).map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first })
    let visible = Self.visible(notices, dismissed: dismissed)
    VStack(alignment: .leading, spacing: 6) {
      ForEach(visible) { notice in
        VStack(alignment: .leading, spacing: 4) {
          Label {
            Text(verbatim: SubscriptionsText.notice(notice, names: names, environment))
              .monospacedDigit()
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: SubscriptionsText.symbol(notice.kind))
          }
          .appFont(.callout)
          HStack(spacing: 8) {
            Button(SubscriptionsText.t("subs.open", environment)) {
              NotificationCenter.default.post(
                name: .selectSection, object: MainWindow.Section.planning.shortcutIndex)
            }
            Button(SubscriptionsText.t("subs.notice.later", environment)) {
              DebtReminderMarks.dismiss(notice.id, in: .standard)
              dismissed.insert(notice.id)
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("look.subscription")
      }
    }
    .task(id: compute.generation) { await load() }
    .onAppear { dismissed = DebtReminderMarks.read(from: .standard).dismissed }
  }

  /// The notices to show: those not put away, soonest first, the first few.
  static func visible(
    _ notices: [SubscriptionNotice], dismissed: Set<String>
  )
    -> [SubscriptionNotice]
  {
    Array(notices.filter { !dismissed.contains($0.id) }.prefix(shown))
  }

  private func load() async {
    guard compute.states.data.phase == .ready, let snapshot = compute.snapshot else { return }
    guard let counted = try? await compute.analysis.subscriptions.allNotices(snapshot),
      !Task.isCancelled
    else { return }
    notices = counted
  }
}
