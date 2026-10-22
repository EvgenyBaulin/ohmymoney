import AppCore
import SwiftUI

/// What is under the question line: the answer to the question asked, or — before one is asked
/// — the questions asked lately and a shape that works. A content card, not glass: «Понял так»
/// with each part to correct, the figure, the other periods, and the ways to the operations
/// behind it.
struct QuestionPanel: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.openWindow) private var openWindow
  let model: QuestionLineModel
  /// Asks a question again from the history: puts its words in the line and asks.
  let askAgain: (String) -> Void

  private func t(_ key: String) -> String { QuestionsText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch model.phase {
      case .idle: idle
      case .asking: asking
      case .failed(let fallback): failed(fallback)
      case .answered(let answered): answer(answered)
      }
    }
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("question.panel")
  }

  // MARK: Before an answer

  @ViewBuilder
  private var idle: some View {
    Label {
      Text(verbatim: t("questions.hint.shape"))
    } icon: {
      Image(systemName: "questionmark.bubble")
    }
    .appFont(.callout)
    .foregroundStyle(.secondary)
    if !model.history.items.isEmpty {
      historyList
    }
  }

  private var historyList: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(verbatim: t("questions.history.title"))
          .appFont(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button(t("questions.history.clear")) { model.clearHistory() }
          .buttonStyle(.borderless)
          .appFont(.caption)
          .accessibilityIdentifier("question.history.clear")
      }
      FlowRow(spacing: 6, lineSpacing: 6) {
        ForEach(model.history.items.prefix(6)) { item in
          Button {
            askAgain(item.text)
          } label: {
            Label {
              Text(verbatim: item.text).lineLimit(1)
            } icon: {
              Image(systemName: "clock.arrow.circlepath")
            }
            .appFont(.callout)
            .chip(surfaces)
          }
          .buttonStyle(.plain)
          .contextMenu {
            Button(t("questions.history.forget")) { model.forget(item) }
          }
          .accessibilityIdentifier("question.history.item")
        }
      }
    }
  }

  private var asking: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(verbatim: environment.language("common.calculating"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
    }
    .accessibilityIdentifier("question.asking")
  }

  @ViewBuilder
  private func failed(_ fallback: QuestionFallback) -> some View {
    Label {
      Text(verbatim: t(fallback.messageKey))
    } icon: {
      Image(systemName: "questionmark.circle")
    }
    .appFont(.callout.weight(.semibold))
    .accessibilityIdentifier("question.failed")
    VStack(alignment: .leading, spacing: 4) {
      ForEach(fallback.exampleKeys, id: \.self) { key in
        Button {
          askAgain(t(key))
        } label: {
          Text(verbatim: t(key)).appFont(.callout)
        }
        .buttonStyle(.link)
      }
    }
    if let hint = fallback.hintKey {
      Label {
        Text(verbatim: t(hint))
      } icon: {
        Image(systemName: "sparkles")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("question.hint")
    }
  }

  // MARK: The answer

  @ViewBuilder
  private func answer(_ answered: QuestionAnswered) -> some View {
    let today = compute.snapshot?.today ?? environment.today
    understood(answered, today: today)
    figures(answered, today: today)
    if !answered.answer.periodLinks.isEmpty {
      otherPeriods(answered.answer.periodLinks, today: today)
    }
    if answered.viaModel {
      Label {
        Text(verbatim: t("questions.model.note"))
      } icon: {
        Image(systemName: "sparkles")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("question.model.note")
    }
    actions(answered, today: today)
  }

  /// «Понял так: расходы · категория «Такси» · сентябрь 2026»; each part is a menu that
  /// puts another reading in its place.
  private func understood(_ answered: QuestionAnswered, today: DateOnly) -> some View {
    let resolved = answered.resolved
    return VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: t("questions.understood"))
        .appFont(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      FlowRow(spacing: 6, lineSpacing: 6) {
        measureMenu(resolved)
        ForEach(Array(resolved.terms.enumerated()), id: \.offset) { index, term in
          termMenu(term, at: index)
        }
        periodMenu(resolved, today: today)
      }
    }
    .accessibilityIdentifier("question.understood")
  }

  private func measureMenu(_ resolved: ResolvedQuestion) -> some View {
    Menu {
      ForEach([QuestionMeasure.spending, .income], id: \.self) { measure in
        Button {
          withSnapshot { model.choose(measure: measure, ledger: $0, today: $1) }
        } label: {
          Text(verbatim: t("questions.measure.\(measure.rawValue)"))
        }
      }
    } label: {
      Text(
        verbatim: QuestionsText.name(of: resolved.intent, measure: resolved.measure, environment)
      )
      .appFont(.callout)
      .chip(surfaces)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.visible)
    .fixedSize()
    .accessibilityIdentifier("question.measure")
  }

  private func termMenu(_ term: ResolvedTerm, at index: Int) -> some View {
    Menu {
      ForEach(Array(term.alternatives.enumerated()), id: \.offset) { _, subject in
        Button {
          withSnapshot { model.choose(subject, forTermAt: index, ledger: $0, today: $1) }
        } label: {
          Label {
            Text(verbatim: QuestionsText.label(of: subject, environment))
          } icon: {
            Image(systemName: QuestionsText.symbol(of: subject))
          }
        }
      }
    } label: {
      Label {
        Text(verbatim: QuestionsText.label(of: term.chosen, environment))
      } icon: {
        Image(systemName: QuestionsText.symbol(of: term.chosen))
      }
      .appFont(.callout)
      .chip(surfaces)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(term.alternatives.isEmpty ? .hidden : .visible)
    .disabled(term.alternatives.isEmpty)
    .fixedSize()
    .accessibilityIdentifier("question.term.\(index)")
  }

  private func periodMenu(_ resolved: ResolvedQuestion, today: DateOnly) -> some View {
    Menu {
      ForEach(QuestionsText.choosablePeriods, id: \.self) { period in
        Button {
          withSnapshot { model.choose(period: period, ledger: $0, today: $1) }
        } label: {
          Text(verbatim: QuestionsText.title(of: period, today: today, environment))
        }
      }
    } label: {
      Label {
        Text(verbatim: QuestionsText.title(of: resolved.period, today: today, environment))
      } icon: {
        Image(systemName: "calendar")
      }
      .appFont(.callout)
      .chip(surfaces)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .fixedSize()
    .accessibilityIdentifier("question.period")
  }

  @ViewBuilder
  private func figures(_ answered: QuestionAnswered, today: DateOnly) -> some View {
    let answer = answered.answer
    if answer.hasNoOperations {
      // Never a confident «0 ₽» for a period with nothing in it.
      Label {
        Text(
          verbatim: QuestionsText.format(
            "questions.answer.none", environment,
            QuestionsText.title(of: answer.current.period, environment)))
      } icon: {
        Image(systemName: "tray")
      }
      .appFont(.callout)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("question.none")
    } else {
      switch answered.resolved.intent {
      case .howMuch: single(answer)
      case .compare: comparison(answer)
      case .biggest: ranked(answer, usual: false)
      case .whatGrew: ranked(answer, usual: true)
      }
    }
  }

  private func single(_ answer: QuestionAnswer) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: environment.money.rounded(answer.current.total))
        .appFont(.title.bold().monospacedDigit())
        .accessibilityIdentifier("question.figure")
      Text(
        verbatim:
          "\(QuestionsText.title(of: answer.current.period, environment)) · "
          + QuestionsText.count(
            "questions.answer.operations", environment, answer.current.operationCount)
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func comparison(_ answer: QuestionAnswer) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 18) {
        figure(answer.current)
        if let other = answer.other { figure(other) }
      }
      if let change = answer.change {
        let words = environment.money.change(change)
        Label {
          Text(
            verbatim: [words.delta, words.percent].compactMap { $0 }.joined(separator: " · "))
        } icon: {
          Image(systemName: Self.arrow(words.direction))
        }
        .appFont(.callout.monospacedDigit())
        .accessibilityIdentifier("question.change")
      }
      if answer.comparedLikeForLike {
        Text(verbatim: t("questions.answer.likeForLike"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func figure(_ value: QuestionFigure) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: environment.money.rounded(value.total))
        .appFont(.title2.bold().monospacedDigit())
      Text(verbatim: QuestionsText.title(of: value.period, environment))
        .appFont(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// A direction and a sign, never «good» or «bad» by colour.
  static func arrow(_ direction: ChangeDirection) -> String {
    switch direction {
    case .up: "arrow.up.right"
    case .down: "arrow.down.right"
    case .flat: "equal"
    }
  }

  @ViewBuilder
  private func ranked(_ answer: QuestionAnswer, usual: Bool) -> some View {
    let names = AnalyticsNames(dataset: compute.snapshot?.dataset ?? Dataset())
    if answer.items.isEmpty {
      Text(verbatim: t(usual ? "questions.answer.nothingGrew" : "questions.answer.none.short"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("question.none")
    } else {
      VStack(alignment: .leading, spacing: 6) {
        Text(
          verbatim: QuestionsText.title(of: answer.current.period, environment)
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
        ForEach(Array(answer.items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline) {
            Text(verbatim: AnalyticsText.name(of: item.key, names, environment))
              .appFont(.callout)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
              Text(verbatim: environment.money.rounded(item.amount))
                .appFont(.callout.monospacedDigit())
              if let excess = item.excess, let typical = item.usual {
                Text(
                  verbatim: QuestionsText.format(
                    "questions.answer.usual", environment,
                    environment.money.rounded(typical),
                    environment.money.signedRounded(excess))
                )
                .appFont(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
              }
            }
          }
        }
        if usual {
          Text(
            verbatim: QuestionsText.count(
              "questions.answer.usualPeriods", environment, answer.usualPeriods)
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .accessibilityIdentifier("question.ranked")
    }
  }

  private func otherPeriods(_ periods: [RelativePeriod], today: DateOnly) -> some View {
    HStack(spacing: 4) {
      Text(verbatim: t("questions.otherPeriods"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
      ForEach(periods, id: \.self) { period in
        Button(QuestionsText.title(of: period, today: today, environment)) {
          withSnapshot { model.choose(period: period, ledger: $0, today: $1) }
        }
        .buttonStyle(.link)
        .appFont(.caption)
        .accessibilityIdentifier("question.otherPeriod")
      }
    }
  }

  private func actions(_ answered: QuestionAnswered, today: DateOnly) -> some View {
    let link = answered.answer.link
    return HStack(spacing: 12) {
      Button {
        QuestionOpening.prepareAnalytics(period: link.period, today: today)
        AppScreens.open(.analytics, with: openWindow)
      } label: {
        Label {
          Text(verbatim: t("questions.open.analytics"))
        } icon: {
          Image(systemName: "chart.xyaxis.line")
        }
      }
      .accessibilityIdentifier("question.open.analytics")
      Button {
        QuestionOpening.showOperations(OperationsFilterRequest(filter: link.filter, columns: nil))
      } label: {
        Label {
          Text(verbatim: t("questions.open.operations"))
        } icon: {
          Image(systemName: "list.bullet")
        }
      }
      .accessibilityIdentifier("question.open.operations")
      Spacer(minLength: 0)
      Button {
        model.clear()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text(verbatim: environment.language("action.close")))
      .accessibilityIdentifier("question.dismiss")
    }
    .appFont(.callout)
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private func withSnapshot(_ work: (Ledger, DateOnly) -> Void) {
    guard let snapshot = compute.snapshot else { return }
    work(snapshot.ledger, snapshot.today)
  }
}

extension View {
  /// A capsule on the card: the parts of «Понял так» and the questions asked lately.
  fileprivate func chip(_ surfaces: ThemeSurfaces) -> some View {
    padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(surfaces.background, in: .capsule)
      .overlay { Capsule().strokeBorder(surfaces.cardBorder, lineWidth: 0.5) }
      .foregroundStyle(surfaces.primary)
  }
}
