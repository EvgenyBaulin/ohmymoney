import SwiftUI

extension View {
  /// How a screen without a store of its own says that a write was refused
  /// (`AppEnvironment.attempt`): an alert over that screen, with the reason in the words of
  /// the interface and the way on. The journal already has the line; this is the half the
  /// owner sees.
  func refusedWriteAlert(_ isPresented: Binding<Bool>, _ environment: AppEnvironment) -> some View {
    alert(
      Text(verbatim: environment.language("write.refused.title")), isPresented: isPresented
    ) {
      Button(environment.language("action.ok")) {}
    } message: {
      Text(verbatim: environment.language("write.refused"))
    }
  }
}
