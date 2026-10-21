import AppCore
import AppDatabase
import SwiftUI

/// The sheet «Add…» of a menu opens: the name of the new record and, for an event and a
/// payment method, what a new one needs besides — its days, its kind. «Save» writes it and
/// chooses it in the menu the sheet came from; «Cancel» leaves everything as it was.
///
/// Presented from the ↓ panel, which is the entry line's, the edit sheet's and the inspector's,
/// it is laid out in a host of its own and gets the app's dependencies handed to it there.
struct AddRecordSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  let model: EntryDraftModel
  /// Closes the sheet: the panel clears what it was presented for.
  let close: () -> Void
  @State private var form: NewRecordForm
  /// «Save» was asked for: from then on the sheet says why nothing was added, an empty name
  /// included, which says nothing while the field is simply not typed into yet.
  @State private var asked = false
  /// Why the last «Save» wrote nothing, in words: a write the database refused, a name a live
  /// row has, an account in the archive that cannot come back.
  @State private var failure: String?
  /// Written once: Return in the field and the default button can both ask.
  @State private var saved = false

  init(
    kind: AddFromPicker.Kind, model: EntryDraftModel, today: DateOnly,
    close: @escaping () -> Void
  ) {
    self.model = model
    self.close = close
    _form = State(initialValue: NewRecordForm(kind: kind, model: model, today: today))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: title)
        .appFont(.headline)
      if let context {
        Text(verbatim: context)
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      Form {
        TextField(text: $form.name) {
          Text(verbatim: environment.language("references.name", table: "Settings"))
        }
        .onSubmit(save)
        if case .event = form.kind {
          EventDaysFields(
            owner: nil, start: startBinding, end: endBinding,
            startLabel: environment.language("references.start", table: "Settings"),
            endLabel: environment.language("references.end", table: "Settings"))
        }
        if form.kind == .paymentMethod {
          Picker(selection: $form.paymentKind) {
            ForEach(PaymentMethodKind.allCases, id: \.self) { kind in
              Text(verbatim: environment.language("payment.\(kind.rawValue)", table: "Settings"))
                .tag(kind)
            }
          } label: {
            Text(verbatim: environment.language("references.kind", table: "Settings"))
          }
        }
      }
      .formStyle(.columns)

      if let refusal {
        Text(verbatim: refusal)
          .appFont(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel, action: close)
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save"), action: save)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(form.refusalKey(in: model) != nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 380)
    // Return in the name saves the record, never the operation of the panel behind it.
    .submitScope()
    // The dictionaries may have grown in another window since the panel read them, and a name
    // is judged taken against what is there now.
    .onAppear { model.reload() }
  }

  private func save() {
    guard !saved else { return }
    asked = true
    failure = nil
    guard form.refusalKey(in: model) == nil else { return }
    let saveContext = NewRecordForm.Context.app(environment, store: store)
    if let refused = form.commit(into: model, today: environment.today, context: saveContext) {
      failure = refused.text(environment)
      return
    }
    saved = true
    // The entry line knows the new name from now on.
    environment.refreshVocabulary()
    environment.scheduleBackup()
    close()
  }

  /// What the sheet says under the fields: a name that cannot be added, at once — the button
  /// is grey and nothing else says why — an empty one only once «Save» was asked for, and a
  /// write the database refused.
  private var refusal: String? {
    if let key = form.refusalKey(in: model), asked || key != "entry.add.nameMissing" {
      return t(key)
    }
    return failure
  }

  private var title: String {
    switch form.kind {
    case .category: t("entry.add.title.category")
    case .subcategory: t("entry.add.title.subcategory")
    case .person, .debtor, .payingFor: t("entry.newPerson")
    case .place: t("entry.newPlace")
    case .event: t("entry.add.title.event")
    case .paymentMethod: t("entry.add.title.paymentMethod")
    }
  }

  /// Where the record goes, when the name alone does not say: the side a category is on, the
  /// category a subcategory is under.
  private var context: String? {
    switch form.kind {
    case .category:
      return t(
        model.draft.kind.categoryKind == .income
          ? "entry.add.incomeCategory" : "entry.add.expenseCategory")
    case .subcategory(let part):
      guard let parentId = model.categoryOfPart(model.part(at: part)),
        let parent = model.categories.first(where: { $0.id == parentId })
      else { return nil }
      return environment.format("entry.add.under", table: "Entry", parent.name)
    case .person, .debtor, .payingFor, .place, .event, .paymentMethod:
      return nil
    }
  }

  private var startBinding: Binding<DateOnly> {
    Binding(get: { form.start }, set: { form.setStart($0) })
  }

  private var endBinding: Binding<DateOnly> {
    Binding(get: { form.end }, set: { form.setEnd($0) })
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }
}
