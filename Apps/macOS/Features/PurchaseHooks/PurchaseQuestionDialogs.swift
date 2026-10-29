import AppCore
import SwiftUI

/// «Подождать?» over the line, the form and the editor of a saved operation: «Записать» writes the
/// purchase, «Отмена» leaves it as typed.
private struct PauseDialog: ViewModifier {
  @Dependency(\.environment) private var environment
  @Binding var question: PauseQuestion?
  let record: () -> Void

  func body(content: Content) -> some View {
    content.confirmationDialog(
      PurchaseHookText.t("purchase.pause.title", environment),
      isPresented: Binding(
        get: { question != nil }, set: { if !$0 { question = nil } }),
      titleVisibility: .visible, presenting: question
    ) { _ in
      Button(PurchaseHookText.t("purchase.pause.record", environment)) { record() }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { asked in
      Text(verbatim: asked.message(environment))
    }
  }
}

/// «Сколько проехали с прошлой заправки?»: a number to type, «Не помню» to write the fill-up
/// without a mileage, «Отмена» to leave it as typed.
private struct MileageAlert: ViewModifier {
  @Dependency(\.environment) private var environment
  @Binding var question: MileageQuestion?
  /// The kilometres typed, or `nil` for «Не помню».
  let answered: (MileageQuestion, Int?) -> Void
  @State private var text = ""

  private func t(_ key: String) -> String { PurchaseHookText.t(key, environment) }

  func body(content: Content) -> some View {
    content.alert(
      t("purchase.mileage.question"),
      isPresented: Binding(
        get: { question != nil }, set: { if !$0 { question = nil } }),
      presenting: question
    ) { asked in
      TextField(
        text: $text,
        prompt: Text(
          verbatim: t(
            asked.previous == nil ? "purchase.mileage.prompt" : "purchase.mileage.prompt.km"))
      ) {
        Text(verbatim: t("purchase.mileage.title"))
      }
      Button(t("purchase.mileage.save")) {
        let km = PurchaseFieldRules.mileage(from: text)
        text = ""
        answered(asked, km)
      }
      Button(t("purchase.mileage.unknown")) {
        text = ""
        answered(asked, nil)
      }
      Button(environment.language("action.cancel"), role: .cancel) { text = "" }
    } message: { asked in
      Text(
        verbatim: t(
          asked.previous == nil ? "purchase.mileage.messageFirst" : "purchase.mileage.message"))
    }
  }
}

extension View {
  /// The pause over a view that keeps its own question.
  func pauseDialog(
    _ question: Binding<PauseQuestion?>, record: @escaping () -> Void
  )
    -> some View
  {
    modifier(PauseDialog(question: question, record: record))
  }

  func mileageAlert(
    _ question: Binding<MileageQuestion?>, answered: @escaping (MileageQuestion, Int?) -> Void
  ) -> some View {
    modifier(MileageAlert(question: question, answered: answered))
  }

  /// The pause and the mileage over the editor of a saved operation, which keeps the one
  /// question its save asked (`TransactionEditorModel.saveQuestion`).
  func purchaseSaveQuestions(
    _ question: Binding<EntrySaveQuestions.Question?>, record: @escaping () -> Void,
    answeredMileage: @escaping (MileageQuestion, Int?) -> Void
  ) -> some View {
    let pause = Binding<PauseQuestion?>(
      get: {
        if case .pause(let asked) = question.wrappedValue { return asked }
        return nil
      },
      set: { if $0 == nil, case .pause = question.wrappedValue { question.wrappedValue = nil } })
    let mileage = Binding<MileageQuestion?>(
      get: {
        if case .mileage(let asked) = question.wrappedValue { return asked }
        return nil
      },
      set: { if $0 == nil, case .mileage = question.wrappedValue { question.wrappedValue = nil } })
    return pauseDialog(pause, record: record).mileageAlert(mileage, answered: answeredMileage)
  }
}
