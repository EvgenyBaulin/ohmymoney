import AppCore
import SwiftUI

/// The card above the tiles of «Обзор»: «Итоги сентября готовы», or on Sunday «Как прошла
/// неделя?» with five faces. It comes on its own day (`SummaryScheduler`) and goes once it was
/// opened or put away.
struct SummaryAnnouncementCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  @State private var model = SummariesModel(store: nil)
  @State private var opened: SummaryID?

  private func t(_ key: String) -> String { environment.language(key, table: "Summaries") }

  var body: some View {
    Group {
      if let snapshot = compute.snapshot,
        let said = model.announcement(ledger: snapshot.ledger, today: snapshot.today)
      {
        card(said)
      }
    }
    .task(id: compute.generation) {
      model = SummariesModel(environment: environment)
      await model.load()
    }
    .sheet(item: $opened) { id in
      SummariesScreen(initial: id)
        .handingOver(dependencies)
    }
    .onChange(of: opened) { old, new in
      // The card is put away when the screen it opened is closed, not when it opens: the sheet
      // hangs on the card.
      if new == nil, let old { model.markShown(old) }
    }
  }

  @ViewBuilder private func card(_ said: SummaryAnnouncement) -> some View {
    switch said {
    case .summary(let id):
      HStack(spacing: 12) {
        Image(systemName: "text.badge.checkmark")
          .appFont(.title2)
          .foregroundStyle(Color.accentColor)
          .accessibilityHidden(true)
        Text(verbatim: headline(of: id))
          .appFont(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button(t("summaries.ready.open")) { opened = id }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .accessibilityIdentifier("summaries.open")
        dismissButton { model.markShown(id) }
      }
      .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
      .contentCard()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("summaries.card")
    case .weekQuestion(let week):
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(verbatim: t("summaries.question.title"))
            .appFont(.headline)
            .accessibilityAddTraits(.isHeader)
          Spacer()
          dismissButton { model.markShown(.week(week)) }
        }
        WeekMoodRow(language: environment.language, chosen: nil) { mood in
          Task { await model.answer(week: week, mood: mood, at: environment.now()) }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentCard()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("summaries.question")
    }
  }

  private func dismissButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .appFont(.caption)
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(t("summaries.ready.dismiss"))
  }

  /// «Итоги сентября готовы», «Итоги 2025 года готовы», «Итоги недели готовы».
  private func headline(of id: SummaryID) -> String {
    SummaryAnnouncementText.headline(of: id, language: environment.language)
  }
}

enum SummaryAnnouncementText {
  @MainActor
  static func headline(of id: SummaryID, language: AppLanguage) -> String {
    let table = "Summaries"
    switch id.kind {
    case .week:
      return language("summaries.ready.week", table: table)
    case .month:
      let month = id.monthKey?.month ?? 1
      return String(
        format: language("summaries.ready.month", table: table), locale: language.locale,
        language("summaries.month.of.\(month)", table: table))
    case .year:
      return String(
        format: language("summaries.ready.year", table: table), locale: language.locale, id.key)
    }
  }
}
