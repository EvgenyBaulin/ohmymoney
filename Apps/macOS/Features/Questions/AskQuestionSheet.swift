import AppCore
import SwiftUI

/// One question in a sheet of its own: for the palette's «Задать вопрос…», for the phone, and for
/// the owner who keeps the form at the side instead of the entry line. A field, the answer card
/// under it. Nothing here can write an operation: it holds no store at all.
struct AskQuestionSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themeSurfaces) private var surfaces
  @State private var model = QuestionLineModel()
  @State private var text = ""
  @FocusState private var focused: Bool

  private func t(_ key: String) -> String { QuestionsText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(verbatim: t("questions.sheet.title")).appFont(.headline)
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("question.sheet.close")
      }
      HStack(spacing: 8) {
        TextField(text: $text, prompt: Text(verbatim: t("questions.prompt"))) {
          Text(verbatim: t("questions.sheet.title"))
        }
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .onSubmit(ask)
        .onChange(of: text) { _, _ in model.textChanged() }
        .accessibilityIdentifier("question.sheet.field")
        Button(t("questions.ask"), action: ask)
          .buttonStyle(.borderedProminent)
          .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
          .accessibilityIdentifier("question.sheet.ask")
      }
      ScrollView {
        QuestionPanel(model: model) { again in
          text = again
          ask()
        }
      }
    }
    .padding(16)
    .sheetFrame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 460)
    .background(surfaces.background)
    .onAppear {
      model.setMode(.question)
      focused = true
    }
    .onChange(of: compute.generation) { _, _ in model.askWaiting(compute: compute) }
    .accessibilityIdentifier("question.sheet")
  }

  private func ask() {
    model.ask(text, compute: compute)
  }
}
