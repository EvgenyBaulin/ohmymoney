import SwiftUI

/// Keeps an editor open until its pending files have finished copying and reports any failure.
struct PurchaseEditorButtons: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  let enabled: Bool
  @Binding var saving: Bool
  let save: () async -> String?
  @State private var failure: String?

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      if let failure {
        Text(verbatim: failure).appFont(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        if saving { ProgressView().controlSize(.small) }
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction).disabled(saving)
        Button(environment.language("action.save")) {
          saving = true
          Task { @MainActor in
            failure = await save()
            saving = false
            if failure == nil { dismiss() }
          }
        }
        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        .disabled(!enabled || saving)
      }
    }
    .padding(.top, 8)
  }
}
