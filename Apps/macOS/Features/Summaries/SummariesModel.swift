import AppCore
import Foundation
import Observation

/// A summary ready to be shown: the numbers of a month or a year, or the cards of a week.
enum SummaryContent: Sendable {
  case period(PeriodSummary)
  case week(WeekCards)

  /// Works the content out of the ledger. Pure, so it can run off the main thread.
  nonisolated static func make(
    _ id: SummaryID, ledger: Ledger, today: DateOnly, moods: [WeekMood]
  ) -> SummaryContent? {
    switch id.kind {
    case .week:
      id.weekKey.map { .week(WeekCards.build(week: $0, ledger: ledger, moods: moods)) }
    case .month, .year:
      SummaryBuilder.summary(id: id, ledger: ledger, today: today, moods: moods).map(
        SummaryContent.period)
    }
  }

  var hasData: Bool {
    switch self {
    case .period(let summary): summary.hasData
    case .week(let cards): cards.hasData
    }
  }

  func cards(hideAmounts: Bool) -> [SummaryCard] {
    switch self {
    case .period(let summary): SummaryCards.cards(for: summary, hideAmounts: hideAmounts)
    case .week(let cards): SummaryCards.cards(for: cards, hideAmounts: hideAmounts)
    }
  }
}

/// What the summaries need from the app: the answers to the question of the week, and the
/// memory of what was already shown. Both the card above the tiles and the screen make one.
@MainActor
@Observable
final class SummariesModel {
  private(set) var moods: [WeekMood] = []
  private(set) var shown: Set<SummaryID>
  /// The answers could not be written; the card says so.
  private(set) var answerFailed = false

  @ObservationIgnored private let store: (any WeekAnswerStore)?
  @ObservationIgnored let storage: SummaryStorage

  init(store: (any WeekAnswerStore)?, storage: SummaryStorage = SummaryStorage()) {
    self.store = store
    self.storage = storage
    shown = storage.shown
  }

  convenience init(environment: AppEnvironment) {
    self.init(store: DatabaseWeekAnswers.current(environment))
  }

  var switches: SummarySwitches { storage.switches }

  func load() async {
    moods = ((try? await store?.answers()) ?? []).sorted { $0.week < $1.week }
    shown = storage.shown
  }

  func markShown(_ id: SummaryID) {
    storage.markShown(id)
    shown = storage.shown
  }

  /// The weeks that need no question: answered, or put away.
  var settledWeeks: Set<WeekKey> {
    Set(moods.map(\.week)).union(shown.compactMap(\.weekKey))
  }

  func announcement(ledger: Ledger, today: DateOnly) -> SummaryAnnouncement? {
    SummaryScheduler.announcement(
      today: today, firstDay: ledger.firstDay, switches: switches, shown: shown,
      answered: settledWeeks)
  }

  /// Writes the answer; the week is also put away so its card is gone.
  @discardableResult
  func answer(week: WeekKey, mood: Int, at moment: Date) async -> Bool {
    let answer = WeekMood(week: week, mood: mood, answeredAt: moment)
    guard let store else {
      answerFailed = true
      return false
    }
    do {
      try await store.save(answer)
      moods.removeAll { $0.week == week }
      moods.append(answer)
      moods.sort { $0.week < $1.week }
      answerFailed = false
      AppLog.info("summaries.answered", .ui, "the owner answered the question of the week")
      return true
    } catch {
      answerFailed = true
      AppLog.warning(
        "summaries.answerFailed", .db, "the answer to the question of the week was not saved")
      return false
    }
  }
}
