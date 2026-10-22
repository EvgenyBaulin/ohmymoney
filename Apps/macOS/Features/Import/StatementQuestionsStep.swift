import AppCore
import SwiftUI

/// The third step: what the files could not answer by themselves. Transfers between the person's
/// own accounts (written as one transfer, not as spending and income), proposals to confirm,
/// held lines nobody posted, and the groups of like operations: «Наталья Б — 20 переводов на
/// 128 000 ₽: что это?» with «Запомнить» and «Решить позже».
struct StatementQuestionsStep: View {
  let model: StatementImportModel

  @Dependency(\.environment) private var environment

  private func t(_ key: String) -> String { ImportText.t(key, environment) }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        transfersCard
        staleCard
        if model.questions.isEmpty {
          Text(verbatim: t("import.questions.none"))
            .appFont(.callout).foregroundStyle(.secondary)
            .accessibilityIdentifier("import.questions.none")
        } else {
          Text(verbatim: t("import.questions.hint"))
            .appFont(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          ForEach(model.questions) { question in
            QuestionCard(model: model, question: question)
          }
        }
      }
      .padding(16)
    }
  }

  // MARK: Transfers

  @ViewBuilder
  private var transfersCard: some View {
    let transfers = model.transfers
    let hasAnything =
      !transfers.pairs.isEmpty || !transfers.softPairs.isEmpty || !transfers.ambiguous.isEmpty
      || !transfers.withoutStatement.isEmpty || !transfers.onTheWay.isEmpty
      || !transfers.overdue.isEmpty
    if hasAnything {
      VStack(alignment: .leading, spacing: 10) {
        ScreenCardHeader(title: t("import.transfers.title"))
        ForEach(Array(transfers.pairs.enumerated()), id: \.offset) { _, pair in
          pairRow(pair, soft: false)
        }
        ForEach(Array(transfers.softPairs.enumerated()), id: \.offset) { _, pair in
          pairRow(pair, soft: true)
        }
        if !transfers.ambiguous.isEmpty {
          Label(
            ImportText.counted(
              "import.transfers.ambiguous", environment, transfers.ambiguous.count),
            systemImage: "questionmark.circle"
          )
          .appFont(.callout).foregroundStyle(.secondary)
        }
        ForEach(Array(transfers.withoutStatement.enumerated()), id: \.offset) { _, ask in
          Label(
            ImportText.format(
              "import.transfers.noStatement", environment, ask.bankName ?? "?",
              ask.lines.count, environment.money.exact(ask.total)),
            systemImage: "building.columns"
          )
          .appFont(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        if !transfers.onTheWay.isEmpty {
          Label(
            ImportText.counted("import.transfers.onTheWay", environment, transfers.onTheWay.count),
            systemImage: "paperplane"
          )
          .appFont(.callout).foregroundStyle(.secondary)
        }
        if !transfers.overdue.isEmpty {
          Label(
            ImportText.counted("import.transfers.overdue", environment, transfers.overdue.count),
            systemImage: "clock.badge.exclamationmark"
          )
          .appFont(.callout).foregroundStyle(.secondary)
        }
      }
      .contentCard()
      .accessibilityIdentifier("import.transfers")
    }
  }

  @ViewBuilder
  private func pairRow(_ pair: StatementPairedLines, soft: Bool) -> some View {
    if let out = model.row(pair.outgoing), let into = model.row(pair.incoming) {
      let text = ImportText.format(
        "import.transfers.pair", environment,
        environment.money.exact(out.operation.amount.magnitude, currency: out.operation.currency),
        accountName(of: pair.outgoing), accountName(of: pair.incoming))
      if soft {
        Toggle(
          isOn: Binding(
            get: { model.confirmedSoft.contains(pair.outgoing) },
            set: { model.confirmSoft(pair, $0) })
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: text).monospacedDigit()
            Text(
              verbatim: ImportText.format(
                "import.transfers.soft", environment,
                environment.dates.longDay(out.operation.moment.day),
                environment.dates.longDay(into.operation.moment.day))
            )
            .appFont(.caption).foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("import.transfers.soft")
      } else {
        Label(text, systemImage: "arrow.left.arrow.right").monospacedDigit()
      }
    }
  }

  private func accountName(of ref: StatementRowRef) -> String {
    let id = model.files.first { $0.id == ref.file }?.accountID
    return model.accounts.first { $0.id == id }?.name ?? "?"
  }

  // MARK: Held lines

  @ViewBuilder
  private var staleCard: some View {
    let stale = model.files.filter { !($0.preview?.staleHeld.isEmpty ?? true) }
    if !stale.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        ScreenCardHeader(title: t("import.stale.title"))
        ForEach(stale) { file in
          Toggle(
            isOn: Binding(
              get: { file.deleteStaleHeld }, set: { model.setDeleteStaleHeld($0, file: file.id) })
          ) {
            Text(
              verbatim: ImportText.counted(
                "import.stale.delete", environment, file.preview?.staleHeld.count ?? 0))
          }
          .toggleStyle(.checkbox)
        }
        Text(verbatim: t("import.stale.hint"))
          .appFont(.caption).foregroundStyle(.secondary)
      }
      .contentCard()
      .accessibilityIdentifier("import.stale")
    }
  }
}

/// One group of like operations and its answer.
struct QuestionCard: View {
  let model: StatementImportModel
  let question: StatementQuestion

  @Dependency(\.environment) private var environment

  private func t(_ key: String) -> String { ImportText.t(key, environment) }

  var body: some View {
    let group = question.group
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label(t("import.topic.\(group.topic.rawValue)"), systemImage: symbol(group.topic))
          .appFont(.callout).foregroundStyle(.secondary)
        Spacer()
        Text(verbatim: environment.money.exact(group.total)).monospacedDigit()
      }
      Text(verbatim: question.title).appFont(.headline).lineLimit(1)
      Text(
        verbatim: ImportText.format(
          "import.question.summary", environment, question.lines.count,
          environment.dates.longDay(group.from), environment.dates.longDay(group.to))
      )
      .appFont(.caption).foregroundStyle(.secondary)
      if !group.messages.isEmpty {
        Text(verbatim: group.messages.prefix(3).joined(separator: " · "))
          .appFont(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      HStack {
        Picker(selection: answer) {
          Text(verbatim: t("import.answer.later")).tag(Choice.later)
          ForEach(model.categoryChoices(spending: question.isSpending), id: \.id) { choice in
            Text(verbatim: choice.title).tag(Choice.category(choice.id))
          }
        } label: {
          Text(verbatim: t("import.answer.category"))
        }
        .accessibilityIdentifier("import.answer")
        Toggle(
          isOn: Binding(
            get: { model.shouldRemember(question) },
            set: { model.remember[question.id] = $0 })
        ) {
          Text(verbatim: t("import.answer.remember"))
        }
        .toggleStyle(.checkbox)
        .disabled(answerCategory == nil)
        .accessibilityIdentifier("import.answer.remember")
      }
    }
    .contentCard()
    .accessibilityIdentifier("import.question")
  }

  private enum Choice: Hashable {
    case later
    case category(UUID)
  }

  private var answerCategory: UUID? {
    if case .category(let id)? = model.answers[question.id] { return id }
    return nil
  }

  private var answer: Binding<Choice> {
    Binding(
      get: {
        switch model.answers[question.id] {
        case .category(let id)?: .category(id)
        default: .later
        }
      },
      set: { choice in
        switch choice {
        case .later: model.answer(.later, for: question)
        case .category(let id): model.answer(.category(id), for: question)
        }
      })
  }

  private func symbol(_ topic: StatementQuestionTopic) -> String {
    switch topic {
    case .person: "person.crop.circle"
    case .unknownIncomingSource: "arrow.down.circle"
    case .loan: "banknote"
    case .selfEmployedIncome: "briefcase"
    case .merchant: "storefront"
    case .unknownCard: "creditcard"
    }
  }
}

/// The end: what was written, and the way back.
struct StatementImportDone: View {
  let outcome: StatementImportOutcome

  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @State private var undone = false

  private func t(_ key: String) -> String { ImportText.t(key, environment) }

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: undone ? "arrow.uturn.backward.circle" : "checkmark.circle")
        .appFont(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
      Text(verbatim: t(undone ? "import.done.undone" : "import.done.title")).appFont(.title3)
      VStack(alignment: .leading, spacing: 4) {
        line("import.done.created", outcome.created)
        line("import.done.merged", outcome.merged)
        line("import.done.upgraded", outcome.upgraded)
        line("import.done.transfers", outcome.transfers)
        line("import.done.duplicates", outcome.duplicates)
        line("import.done.unsorted", outcome.unsorted)
        line("import.done.waiting", outcome.waitingForRate)
        line("import.done.remembered", outcome.remembered)
      }
      .monospacedDigit()
      if !undone, !outcome.imports.isEmpty {
        Button {
          for id in outcome.imports.reversed() { _ = store.undoImport(id: id) }
          undone = true
        } label: {
          Label(t("import.done.undo"), systemImage: "arrow.uturn.backward")
        }
        .accessibilityIdentifier("import.done.undo")
        Text(verbatim: t("import.done.undoHint"))
          .appFont(.caption).foregroundStyle(.secondary)
          .multilineTextAlignment(.center).frame(maxWidth: 420)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
    .accessibilityIdentifier("import.done")
  }

  @ViewBuilder
  private func line(_ key: String, _ number: Int) -> some View {
    if number > 0 {
      Text(verbatim: ImportText.counted(key, environment, number))
    }
  }
}
