import AppCore
import SwiftUI

/// The words of the recalculation: the subtitle of the main window and the status line of
/// Overview.
@MainActor
enum RecomputeText {
  /// «Пересчитано в 14:32», with the date when it was not today; «Пересчитывается…» during a
  /// full run; «Считается, ожидайте» while the first one goes. A light refresh after a new
  /// operation, «Повторить» after a run and the forecast of a new day do not move the time:
  /// none of them is a recalculation.
  static func subtitle(compute: ComputeStore, environment: AppEnvironment) -> String {
    switch phase(isAttached: compute.isAttached, run: compute.states.run) {
    case .silent: ""
    case .calculating: environment.language("common.calculating")
    case .recomputing: environment.language("compute.recomputing")
    case .recomputed(let at): recomputed(at, environment: environment)
    }
  }

  /// What the subtitle says, without its words.
  enum Phase: Equatable {
    case silent
    case calculating
    case recomputing
    case recomputed(Date)
  }

  nonisolated static func phase(isAttached: Bool, run: ComputeStore.RunState) -> Phase {
    // Without a pipeline — the database did not open, or this is the test host — nothing is
    // being calculated, and the window must not promise otherwise.
    guard isAttached else { return .silent }
    // Only the first run of the launch is «Считается»: once one has ended — even with its
    // data failed — the next is a recalculation.
    if run.isRunning { return run.hasEnded ? .recomputing : .calculating }
    if let lastCompletedAt = run.lastCompletedAt { return .recomputed(lastCompletedAt) }
    // No full run has ended with its data — the first one failed on it — and none is going:
    // nothing is being calculated. The lists say what failed and offer «Повторить».
    return .silent
  }

  static func recomputed(_ instant: Date, environment: AppEnvironment) -> String {
    isToday(instant, environment)
      ? environment.format("compute.recomputedAt", environment.dates.time(instant))
      : environment.format("compute.recomputedOn", environment.dates.moment(instant))
  }

  /// «Данные не обновились — показаны на 14:32»: a reload failed, and the screen shows the
  /// read of that moment — with its day when it was not today («на 17 сент., 14:32»): after
  /// midnight, or a Mac asleep over a day, the time alone would read as a moment of today.
  static func stale(_ readAt: Date, environment: AppEnvironment) -> String {
    environment.format("status.dataStale", table: "Overview", readMoment(readAt, environment))
  }

  /// The moment of a read on screen: «14:32» today, «17 сент., 14:32» before. The
  /// Transactions window says it in its subtitle with the same words.
  static func readMoment(_ readAt: Date, _ environment: AppEnvironment) -> String {
    isToday(readAt, environment)
      ? environment.dates.time(readAt) : environment.dates.moment(readAt)
  }

  /// The «·» of the status line between the time of the recalculation and the rates: only
  /// when both say something. Rates without enough data or planned for a later milestone
  /// show nothing, and a store no longer attached has no time to show.
  nonisolated static func separates(_ subtitle: String, rates: BlockPhase) -> Bool {
    guard !subtitle.isEmpty else { return false }
    switch rates {
    case .calculating, .ready, .failed: return true
    case .notEnoughData, .plannedFor: return false
    }
  }

  private static func isToday(_ instant: Date, _ environment: AppEnvironment) -> Bool {
    environment.calendar.day(of: instant) == environment.today
  }
}

/// One line under the cards: when the numbers were recalculated, what became of the rates
/// of the Bank of Russia, and — when a reload failed while older data stays on screen — that
/// the screen shows data of an earlier moment. «Повторить» reruns only the step it is about.
struct RecomputeStatusLine: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        if compute.lastCompletedAt != nil {
          let subtitle = RecomputeText.subtitle(compute: compute, environment: environment)
          if !subtitle.isEmpty { Text(verbatim: subtitle) }
          if RecomputeText.separates(subtitle, rates: compute.states.rates.phase) {
            Text(verbatim: "·")
          }
        }
        rates
      }
      if compute.states.reloadFailed, let readAt = compute.states.readAt {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.octagon")
            .foregroundStyle(.red)
            .accessibilityHidden(true)
          Text(verbatim: RecomputeText.stale(readAt, environment: environment))
          retryButton(ComputeStep.data)
        }
      }
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
  }

  /// The compact form of the rates' block: one line with its symbol.
  @ViewBuilder
  private var rates: some View {
    switch compute.states.rates {
    case .calculating:
      ProgressView()
        .controlSize(.mini)
        .accessibilityHidden(true)
      Text(verbatim: t("status.ratesUpdating"))
    case .ready(let result, _):
      Text(verbatim: t(result.provisional == 0 ? "status.ratesNothing" : "status.ratesUpdated"))
    case .failed:
      Image(systemName: "exclamationmark.octagon")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      Text(verbatim: t("status.ratesFailed"))
      retryButton(ComputeStep.rates)
    case .notEnoughData, .plannedFor:
      EmptyView()
    }
  }

  private func retryButton(_ step: StepID) -> some View {
    Button(environment.language("action.retry")) { compute.retry(step) }
      .buttonStyle(.link)
  }

  private func t(_ key: String, _ arguments: CVarArg...) -> String {
    String(
      format: environment.language(key, table: "Overview"), locale: environment.language.locale,
      arguments: arguments)
  }
}
