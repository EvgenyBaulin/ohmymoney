import SwiftUI

extension View {
  /// Common write buttons keep their place but show that the book is read-only.
  func requiresWritableBook() -> some View { modifier(WritableBookControl()) }
  /// How a screen without a store of its own says that a write was refused
  /// (`AppEnvironment.attempt`): an alert over that screen, with the reason in the words of
  /// the interface and the way on. The journal already has the line; this is the half the
  /// owner sees.
  func refusedWriteAlert(_ isPresented: Binding<Bool>, _ environment: AppEnvironment) -> some View {
    let words = WriteRefusalWords.keys(readOnly: environment.shield.isReadOnly)
    return alert(
      Text(verbatim: environment.language(words.title)), isPresented: isPresented
    ) {
      Button(environment.language("action.ok")) {}
    } message: {
      Text(verbatim: environment.language(words.message))
    }
  }
}

private struct WritableBookControl: ViewModifier {
  @Dependency(\.environment) private var environment

  func body(content: Content) -> some View {
    content.disabled(environment.shield.isReadOnly)
  }
}

/// What a refused write says. In «Только просмотр» every refusal is one sentence — the mode is
/// on, nothing can be changed — instead of a failure the owner would take for a breakage.
enum WriteRefusalWords {
  static func keys(readOnly: Bool) -> (title: String, message: String) {
    readOnly
      ? ("write.refused.readOnly.title", "write.refused.readOnly")
      : ("write.refused.title", "write.refused")
  }

  /// The line under a form whose save did not land: in «Только просмотр» the mode, otherwise
  /// the form's own reason, else «не сохранилось».
  @MainActor
  static func failureText(reason: String, _ environment: AppEnvironment) -> String {
    if environment.shield.isReadOnly { return environment.language("write.refused.readOnly") }
    return reason.isEmpty ? environment.language("form.notSaved", table: "Planning") : reason
  }
}
