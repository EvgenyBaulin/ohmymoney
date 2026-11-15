import AppCore
import SwiftUI

/// The words of «Челленджи», from the Challenges catalog.
enum ChallengeText {
  static let table = "Challenges"

  @MainActor
  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  /// The symbol of a state; the word always stands beside it.
  static func symbol(_ state: ChallengeState) -> String {
    switch state {
    case .upcoming: "clock"
    case .running: "flame"
    case .succeeded: "checkmark.circle"
    case .failed: "xmark.circle"
    case .stopped: "stop.circle"
    }
  }

  /// The text a finished challenge is shared with: the sum only when amounts are not hidden.
  @MainActor
  static func shareText(
    _ challenge: Challenge, _ progress: ChallengeProgress, _ environment: AppEnvironment
  ) -> String {
    if !environment.amounts.isHidingNow, let saved = progress.saved, !saved.isZero {
      return environment.format(
        "challenges.share.saved", table: table, challenge.title, progress.keptDays,
        progress.dayCount, environment.money.rounded(saved))
    }
    return environment.format(
      "challenges.share.kept", table: table, challenge.title, progress.keptDays, progress.dayCount)
  }

  /// The words a finished challenge is shared with as a picture: its state, period, days kept and
  /// streak, and the saving only when amounts are not hidden — no line carries a sum otherwise.
  @MainActor
  static func shareCard(
    _ challenge: Challenge, _ progress: ChallengeProgress, _ environment: AppEnvironment
  ) -> (title: String, lines: [String]) {
    var lines = [
      environment.format(
        "challenges.period", table: table, environment.dates.dayAndMonth(challenge.start),
        environment.dates.dayAndMonth(challenge.end)),
      environment.format("challenges.keptDays", table: table, counts: progress.keptDays),
      environment.format("challenges.streak", table: table, counts: progress.bestStreak),
    ]
    if !environment.amounts.isHidingNow, let saved = progress.saved, !saved.isZero {
      lines.append(
        environment.format("challenges.saved", table: table, environment.money.rounded(saved)))
    }
    let state: String
    switch progress.state {
    case .succeeded: state = "succeeded"
    case .failed: state = "failed"
    case .stopped: state = "stopped"
    case .running: state = "running"
    case .upcoming: state = "upcoming"
    }
    return (title: t("challenges.state.\(state)", environment), lines: lines)
  }

  /// The picture to share: one card on the page of the summaries, drawn the same way.
  @MainActor
  static func sharePicture(
    _ challenge: Challenge, _ progress: ChallengeProgress, _ environment: AppEnvironment
  ) -> URL? {
    let page = SummaryPage(
      title: challenge.title, cards: [shareCard(challenge, progress, environment)])
    return SummaryExport.pngFile(of: page, name: "OhMyMoney-challenge")
  }
}

/// «Челленджи»: the ones running with their days, streak and what is left of a limit, the finished
/// ones with what each saved, and a way to start a new one. Everything is about the owner's own
/// spending (the ledger's rule: my expenses), compared with nobody.
struct ChallengesScreen: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.layoutIdiom) private var idiom
  @State private var book = ChallengeBook()
  @State private var adds = false

  private func t(_ key: String) -> String { ChallengeText.t(key, environment) }

  private var items: [(challenge: Challenge, progress: ChallengeProgress)] {
    guard let ledger = compute.snapshot?.ledger else { return [] }
    return ChallengeLists.ordered(
      book, ledger: ledger, planning: ledger.dataset.planning, today: environment.today)
  }

  var body: some View {
    let items = items
    VStack(spacing: 0) {
      HStack {
        Text(verbatim: t("challenges.title")).appFont(.title2.weight(.semibold))
        Spacer()
        Button {
          dismiss()
        } label: {
          Text(verbatim: environment.language("action.close"))
            // A finger needs 44 pt; the Mac keeps the button as it was.
            .frame(minHeight: LayoutIdiom.resolved(idiom) == .mac ? 0 : 44)
            .contentShape(.rect)
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding(16)
      Form {
        Section {
          Text(verbatim: t("challenges.subtitle")).secondaryInk()
          let total = ChallengeLists.totalSaved(items)
          if !total.isZero {
            Text(
              verbatim: environment.format(
                "challenges.saved.total", table: ChallengeText.table,
                environment.money.rounded(total))
            )
            .accessibilityIdentifier("challenges.savedTotal")
          }
        }
        let open = items.filter { !$0.progress.isFinished }
        let done = items.filter { $0.progress.isFinished }
        Section {
          if open.isEmpty { Text(verbatim: t("challenges.empty")).secondaryInk() }
          ForEach(open, id: \.challenge.id) { item in
            ChallengeRow(challenge: item.challenge, progress: item.progress, onChange: reload)
          }
          Button(t("challenges.new")) { adds = true }
            .accessibilityIdentifier("challenges.new")
        } header: {
          Text(verbatim: t("challenges.section.active")).settingsHeaderStyle()
        }
        if !done.isEmpty {
          Section {
            ForEach(done, id: \.challenge.id) { item in
              ChallengeRow(challenge: item.challenge, progress: item.progress, onChange: reload)
            }
          } header: {
            Text(verbatim: t("challenges.section.done")).settingsHeaderStyle()
          }
        }
      }
      .formStyle(.grouped)
    }
    .sheetFrame(minWidth: 520, idealWidth: 600, minHeight: 560, idealHeight: 680)
    .sheet(isPresented: $adds) {
      NewChallengeForm(onSaved: reload).handingOver(dependencies)
    }
    .onAppear(perform: reload)
    .accessibilityIdentifier("challenges.screen")
  }

  private func reload() {
    if let stored = try? environment.challenges?.book() { book = stored }
  }
}

/// One challenge: its state with a word and a symbol, the days, the streak, the spending against
/// a limit, the saving and the way it was counted, and what the owner can do with it.
struct ChallengeRow: View {
  @Dependency(\.environment) private var environment
  let challenge: Challenge
  let progress: ChallengeProgress
  let onChange: () -> Void
  /// The picture of a finished challenge, made again when «Скрыть суммы» changes.
  @State private var picture: URL?
  @State private var settingLimit = false
  @Environment(\.dependencies) private var dependencies

  private func t(_ key: String) -> String { ChallengeText.t(key, environment) }
  private func money(_ amount: AmountE4) -> String { environment.money.rounded(amount) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(verbatim: challenge.title).appFont(.headline)
        Spacer()
        Label {
          Text(verbatim: t("challenges.state.\(stateKey)"))
        } icon: {
          Image(systemName: ChallengeText.symbol(progress.state))
        }
        .appFont(.callout)
      }
      Text(
        verbatim: environment.format(
          "challenges.period", table: ChallengeText.table,
          environment.dates.dayAndMonth(challenge.start),
          environment.dates.dayAndMonth(challenge.end))
      )
      .appFont(.caption)
      .secondaryInk()
      if progress.limitIsMissing {
        // Nothing can break a limit that is not there, so no progress is drawn.
        Label {
          Text(verbatim: t("challenges.limit.missing"))
        } icon: {
          Image(systemName: "questionmark.circle")
        }
        .appFont(.callout)
        .accessibilityIdentifier("challenge.limitMissing")
      } else {
        ProgressView(value: Double(progress.elapsedDays), total: Double(max(1, progress.dayCount)))
          .accessibilityHidden(true)
      }
      if progress.state == .running && !progress.limitIsMissing {
        line(
          environment.format(
            "challenges.day", table: ChallengeText.table, progress.elapsedDays,
            progress.dayCount))
      }
      if progress.elapsedDays > 0 && !progress.limitIsMissing {
        line(
          environment.format(
            "challenges.streak", table: ChallengeText.table, counts: progress.currentStreak))
        line(
          environment.format(
            "challenges.keptDays", table: ChallengeText.table, counts: progress.keptDays))
      }
      if challenge.kind != .noNewSubscriptions {
        line(
          environment.format("challenges.spent", table: ChallengeText.table, money(progress.spent)))
      }
      if let remaining = progress.remaining {
        line(
          environment.format("challenges.left", table: ChallengeText.table, money(remaining)))
      }
      if let brokenOn = progress.brokenOn {
        line(
          environment.format(
            "challenges.brokenOn", table: ChallengeText.table,
            environment.dates.dayAndMonth(brokenOn)))
      }
      if !progress.newSubscriptionIds.isEmpty {
        line(
          environment.format(
            "challenges.newSubscriptions", table: ChallengeText.table,
            counts: progress.newSubscriptionIds.count))
      }
      savingLines
      actions
    }
    .padding(.vertical, 4)
    .sheet(isPresented: $settingLimit) {
      ChallengeLimitForm(challenge: challenge, onSaved: onChange).handingOver(dependencies)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("challenge.\(challenge.id.uuidString)")
  }

  private var stateKey: String {
    switch progress.state {
    case .upcoming: "upcoming"
    case .running: "running"
    case .succeeded: "succeeded"
    case .failed: "failed"
    case .stopped: "stopped"
    }
  }

  private func line(_ text: String) -> some View {
    Text(verbatim: text).appFont(.callout).monospacedDigit()
  }

  @ViewBuilder
  private var savingLines: some View {
    if let saved = progress.saved, let base = progress.baseline,
      let source = progress.baselineSource
    {
      line(environment.format("challenges.saved", table: ChallengeText.table, money(saved)))
        .accessibilityIdentifier("challenge.saved")
      Text(
        verbatim: environment.format(
          source == .owner ? "challenges.baseline.owner" : "challenges.baseline.median",
          table: ChallengeText.table, money(base))
      )
      .appFont(.caption)
      .secondaryInk()
    } else if challenge.kind != .noNewSubscriptions {
      Text(verbatim: t("challenges.saved.none")).appFont(.caption).secondaryInk()
    }
  }

  @ViewBuilder
  private var actions: some View {
    HStack {
      if progress.isFinished {
        Group {
          if let picture {
            ShareLink(
              item: picture,
              preview: SharePreview(challenge.title, image: Image(systemName: "flame"))
            ) {
              Text(verbatim: t("challenges.share"))
            }
          } else {
            ShareLink(item: ChallengeText.shareText(challenge, progress, environment)) {
              Text(verbatim: t("challenges.share"))
            }
          }
        }
        .task(id: environment.amounts.isHidingNow) {
          if let picture { try? FileManager.default.removeItem(at: picture) }
          picture = ChallengeText.sharePicture(challenge, progress, environment)
        }
        .accessibilityIdentifier("challenge.share")
      } else {
        if progress.limitIsMissing {
          Button(t("challenges.limit.set")) { settingLimit = true }
            .accessibilityIdentifier("challenge.limit.set")
        }
        Button(t("challenges.stop")) {
          _ = try? environment.challenges?.stop(challenge.id, on: environment.today)
          onChange()
        }
        .accessibilityIdentifier("challenge.stop")
      }
      Spacer()
      Button(t("challenges.remove"), role: .destructive) {
        _ = try? environment.challenges?.remove(challenge.id)
        onChange()
      }
      .accessibilityIdentifier("challenge.remove")
    }
    .buttonStyle(.borderless)
    .appFont(.callout)
  }
}
