import AppCore
import SwiftUI

/// «Другие названия»: the other ways a name is typed in the entry line — «Пятёрочка» is also
/// «пятёрка» and «5ка». A row for each name with × to take it away, and a field to add one.
///
/// A section of a grouped form. A name is refused with a sentence under the field when it says
/// nothing, when the row has it already, and when another row answers to it: the entry line
/// could not tell the two apart.
struct OtherNamesEditor: View {
  @Dependency(\.environment) private var environment
  @Binding var names: [String]
  /// The row's own name, which an other name would only repeat.
  let ownName: String
  /// The name of the other row that already answers to a name, as its name or one of its other
  /// names; nil when none does.
  let owner: (String) -> String?

  @State private var typed = ""
  @State private var refusal: OtherNames.Refusal?

  var body: some View {
    Section {
      ForEach(Array(names.enumerated()), id: \.offset) { index, name in
        HStack {
          Text(verbatim: name)
          Spacer()
          Button {
            names.remove(at: index)
          } label: {
            Image(systemName: "xmark.circle.fill")
              .appFont(.callout)
              .foregroundStyle(.secondary)
              .accessibilityLabel(
                Text(verbatim: environment.format("names.other.remove", table: "Settings", name)))
          }
          .buttonStyle(.borderless)
          .help(environment.format("names.other.remove", table: "Settings", name))
        }
      }
      HStack {
        TextField(text: $typed) {
          Text(verbatim: t("names.other.new"))
        }
        .onSubmit(add)
        Button(t("names.other.add"), action: add)
          .disabled(ReferenceNames.folded(typed).isEmpty)
      }
      if let refusal {
        Label {
          Text(verbatim: message(refusal))
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.circle")
        }
        .appFont(.callout)
        .foregroundStyle(.secondary)
      }
    } header: {
      Text(verbatim: t("names.other.title"))
    } footer: {
      Text(verbatim: t("names.other.hint"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
    }
    .onChange(of: typed) { _, _ in refusal = nil }
  }

  private func add() {
    if let refused = OtherNames.refusal(
      adding: typed, to: names, ownName: ownName, owner: owner)
    {
      refusal = refused
      return
    }
    names.append(typed.trimmingCharacters(in: .whitespaces))
    typed = ""
    refusal = nil
  }

  private func message(_ refusal: OtherNames.Refusal) -> String {
    switch refusal {
    case .empty: t("names.other.empty")
    case .sameAsName: t("names.other.sameAsName")
    case .alreadyHere: t("names.other.alreadyHere")
    case .taken(let other): environment.format("names.other.taken", table: "Settings", other)
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }
}

/// The rule of «Другие названия», apart from the view that follows it.
enum OtherNames {
  /// Why a name is not added.
  enum Refusal: Equatable {
    /// It says nothing: empty, or spaces.
    case empty
    /// It is the row's own name.
    case sameAsName
    /// The row has it already.
    case alreadyHere
    /// Another row answers to it; the associated value is that row's name.
    case taken(by: String)
  }

  /// Why `name` cannot join `names` of a row called `ownName`, or nil when it can. Names are
  /// compared the way the entry line compares them (`ReferenceNames`).
  static func refusal(
    adding name: String, to names: [String], ownName: String, owner: (String) -> String?
  ) -> Refusal? {
    let wanted = ReferenceNames.folded(name)
    guard !wanted.isEmpty else { return .empty }
    if wanted == ReferenceNames.folded(ownName) { return .sameAsName }
    if names.contains(where: { ReferenceNames.folded($0) == wanted }) { return .alreadyHere }
    if let other = owner(name) { return .taken(by: other) }
    return nil
  }
}
