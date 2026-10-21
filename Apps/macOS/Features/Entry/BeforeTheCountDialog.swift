import AppCore
import Foundation
import SwiftUI

/// «Это было до сверки в 14:05?» — asked when an operation is saved after the latest count of a
/// balance it moves and dated on that count's day (`EntryDraftModel.countToAskAbout`). The
/// answer dates it before or after the count (`EntryDraftModel.answerCount`) and the save goes
/// on; closing the question saves nothing.
///
/// A question made from the counts of the whole day (`questions`, from `countToAsk` of
/// `AccountReconciliation`) is walked by `beforeTheCountQuestions(_:stamped:)`: «Нет» asks
/// about the next count of the day, and the last answer gives the moment to save at.
///
/// A question that knows its reconciliation, and whose answer would be kept (`remembers`),
/// offers «Больше не спрашивать для этой сверки»: the answer given with it is remembered for
/// that reconciliation (`reconcile.beforeCountAnswers`, no step of ⌘Z), and what saves next
/// reads it and dates its operation without asking, until a newer count of the account asks
/// again. A question about a due date of a payment or a debt (`due`) names the payment and the
/// count: «Деньги за «Аренда» ушли до сверки 26 сентября в 14:05?».
struct BeforeTheCountQuestion: Identifiable, Hashable {
  /// The moment of the count.
  let count: Date
  /// The reconciliation of the count, when it is known: an answer can be remembered for it.
  var reconciliation: UUID? = nil
  /// The due date of a scheduled payment or a debt being paid, when the question is about one.
  var due: DateOnly? = nil
  /// The name of that payment or debt.
  var name: String? = nil
  /// Every count of the day still to be asked about, this one first.
  var questions: CountQuestions? = nil

  var id: Date { count }

  /// Whether the question offers «Больше не спрашивать для этой сверки»: its reconciliation is
  /// known, and an answer for it would be kept (`CountQuestions.remembers`). A count of an
  /// earlier day than its balances' latest is asked about again whatever is ticked, so it is
  /// asked without the box. A question about a due date has no walk: its count is the latest
  /// of its balance.
  var remembers: Bool {
    guard reconciliation != nil else { return false }
    return questions?.remembers ?? true
  }

  /// What an answer leads to on the walk through the counts of the day.
  enum Step: Equatable {
    /// The next count to ask about.
    case next(BeforeTheCountQuestion)
    /// The moment the answers give: the save goes on with it.
    case stamp(Date)
  }

  /// The answer to this question on the walk: the question about the next count, or the moment
  /// to save at. `nil` for a question made without `questions`, which only the dialog of
  /// `beforeTheCountQuestion(_:answered:)` answers.
  func answered(wasBefore: Bool) -> Step? {
    guard let questions else { return nil }
    switch questions.answer(wasBefore: wasBefore) {
    case .stamp(let moment):
      return .stamp(moment)
    case .ask(let next):
      return .next(
        BeforeTheCountQuestion(
          count: next.count, reconciliation: next.reconciliation, due: due, name: name,
          questions: next))
    }
  }

  // The walk is not Hashable, as its calendar is not: two questions are equal by its counts,
  // the count asked about and the moment the walk starts from.
  static func == (left: BeforeTheCountQuestion, right: BeforeTheCountQuestion) -> Bool {
    left.count == right.count && left.reconciliation == right.reconciliation
      && left.due == right.due && left.name == right.name
      && left.questions?.counts == right.questions?.counts
      && left.questions?.index == right.questions?.index
      && left.questions?.occurredAt == right.questions?.occurredAt
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(count)
    hasher.combine(reconciliation)
    hasher.combine(due)
    hasher.combine(name)
    hasher.combine(questions?.index)
  }
}

/// The question as a dialog of whatever view saves: «Да» and «Нет» answer it, and `answered`
/// gets the question and whether the operation was before its count. With an answer the
/// question's reconciliation would keep (`BeforeTheCountQuestion.remembers`), the dialog carries
/// the system's «don't ask again» checkbox and keeps the answer by itself before it hands it on.
struct BeforeTheCountDialog: ViewModifier {
  @Dependency(\.environment) private var environment
  @Binding var question: BeforeTheCountQuestion?
  let answered: (_ question: BeforeTheCountQuestion, _ wasBefore: Bool) -> Void
  /// «Больше не спрашивать для этой сверки», ticked for the question on screen.
  @State private var dontAsk = false

  func body(content: Content) -> some View {
    // A question that cannot be remembered is asked by the view itself, without the
    // checkbox; one that can is asked by a clear view behind it, which carries the checkbox —
    // so the view that saves keeps its identity whichever is asked.
    dialog(on: content, remembering: false)
      .background {
        dialog(on: Color.clear, remembering: true)
          .dialogSuppressionToggle(
            Text(verbatim: t("entry.beforeCount.dontAsk")), isSuppressed: $dontAsk)
      }
      // Every question starts unticked: a box ticked for one count never answers another.
      .onChange(of: question) { _, _ in dontAsk = false }
  }

  private func dialog<Host: View>(on host: Host, remembering: Bool) -> some View {
    host.confirmationDialog(
      title, isPresented: isPresented(remembering: remembering), titleVisibility: .visible,
      presenting: question
    ) { question in
      Button(t("entry.beforeCount.yes")) { answer(question, wasBefore: true) }
      Button(t("entry.beforeCount.no")) { answer(question, wasBefore: false) }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { question in
      Text(verbatim: Self.message(of: question, environment))
    }
  }

  private func answer(_ question: BeforeTheCountQuestion, wasBefore: Bool) {
    Self.remember(question, wasBefore: wasBefore, dontAsk: dontAsk, in: environment)
    dontAsk = false
    answered(question, wasBefore)
  }

  /// Keeps the answer for the question's reconciliation when «Больше не спрашивать» was ticked:
  /// the next save of that day reads it (`AppEnvironment.rememberedCountAnswers`). A question
  /// that does not offer the box (`BeforeTheCountQuestion.remembers`) keeps nothing. Returns
  /// whether it was kept.
  @discardableResult
  static func remember(
    _ question: BeforeTheCountQuestion, wasBefore: Bool, dontAsk: Bool,
    in environment: AppEnvironment
  ) -> Bool {
    guard dontAsk, question.remembers, let reconciliation = question.reconciliation else {
      return false
    }
    return environment.rememberCountAnswer(reconciliation: reconciliation, wasBefore: wasBefore)
  }

  /// The title: «Это было до сверки в 14:05?»; about a due date, «Деньги за «Аренда» ушли до
  /// сверки 26 сентября в 14:05?».
  static func title(of question: BeforeTheCountQuestion, _ environment: AppEnvironment) -> String {
    let time = environment.dates.time(question.count)
    guard question.due != nil else {
      return environment.language.format("entry.beforeCount.title", table: "Entry", time)
    }
    let day = environment.dates.dayAndMonth(environment.calendar.day(of: question.count))
    return environment.language.format(
      "planning.dueBeforeCount.title", table: "Planning", question.name ?? "—", day, time)
  }

  /// The words under the title: what either answer does; about a due date, which day it was
  /// due and where each answer dates the payment.
  static func message(
    of question: BeforeTheCountQuestion, _ environment: AppEnvironment
  )
    -> String
  {
    guard let due = question.due else {
      return environment.language("entry.beforeCount.message", table: "Entry")
    }
    return environment.language.format(
      "planning.dueBeforeCount.message", table: "Planning", environment.dates.dayAndMonth(due))
  }

  private var title: String {
    guard let question else { return "" }
    return Self.title(of: question, environment)
  }

  /// Shown while there is a question that offers the checkbox (`remembering`) or not.
  private func isPresented(remembering: Bool) -> Binding<Bool> {
    Binding(
      get: { question.map { $0.remembers == remembering } ?? false },
      set: { isShown in
        if !isShown { question = nil }
      })
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }
}

/// The dialog walking every count of the day: «Нет» asks about the next count once this dialog
/// has gone, and the last answer hands the moment to `stamped`. Closing it saves nothing.
struct BeforeTheCountWalk: ViewModifier {
  @Binding var question: BeforeTheCountQuestion?
  let stamped: (Date) -> Void

  /// How long the next question waits for the dialog before it to go: presented at once, it
  /// would be taken for the one just answered and dismissed with it.
  static let pause = Duration.milliseconds(300)

  func body(content: Content) -> some View {
    content.modifier(
      BeforeTheCountDialog(question: $question) { asked, wasBefore in
        switch asked.answered(wasBefore: wasBefore) {
        case .next(let next):
          let binding = $question
          Task { @MainActor in
            try? await Task.sleep(for: Self.pause)
            binding.wrappedValue = next
          }
        case .stamp(let moment):
          stamped(moment)
        case nil:
          break
        }
      })
  }
}

extension View {
  /// Asks «Это было до сверки в 14:05?» while `question` is set.
  func beforeTheCountQuestion(
    _ question: Binding<BeforeTheCountQuestion?>,
    answered: @escaping (_ count: Date, _ wasBefore: Bool) -> Void
  ) -> some View {
    modifier(
      BeforeTheCountDialog(question: question) { asked, wasBefore in
        answered(asked.count, wasBefore)
      })
  }

  /// Asks about every count of the day `question.questions` holds, oldest first, and hands the
  /// moment the answers give to `stamped`.
  func beforeTheCountQuestions(
    _ question: Binding<BeforeTheCountQuestion?>, stamped: @escaping (Date) -> Void
  ) -> some View {
    modifier(BeforeTheCountWalk(question: question, stamped: stamped))
  }
}
