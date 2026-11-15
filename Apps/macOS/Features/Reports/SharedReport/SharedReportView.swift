import AppCore
import SwiftUI

/// «Отчёт для другого человека…»: a PDF or a table for parents, a partner or an accountant — only
/// the picked accounts and categories of a span, with or without descriptions and places, headed
/// «Подготовлено в OhMyMoney» and the day. «Зашифровать» is on every time: the PDF is then locked
/// with the password and opens in any reader, the table goes into the app's locked file.
struct SharedReportView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var model: SharedReportModel
  @State private var moving = false
  @State private var pending: URL?

  private static let table = "Utilities"
  private func t(_ key: String) -> String { environment.language(key, table: Self.table) }
  private func p(_ key: String) -> String { environment.language(key, table: "PrivacyExport") }

  init(model: SharedReportModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    Form {
      Section {
        DatePicker(
          t("sharedReport.from"), selection: $model.periodStart, displayedComponents: .date)
        DatePicker(t("sharedReport.to"), selection: $model.periodEnd, displayedComponents: .date)
      } header: {
        Text(verbatim: t("sharedReport.title")).settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("sharedReport.hint"))
          .appFont(.callout).secondaryInk()
          .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        ForEach(model.visibleAccounts) { choice in
          Toggle(
            isOn: Binding(
              get: { model.accounts.contains(choice.id) },
              set: { _ in model.toggle(account: choice.id) })
          ) {
            Text(verbatim: choice.name)
          }
          .accessibilityIdentifier("sharedReport.account.\(choice.id.uuidString)")
        }
        if model.hasHiddenAccounts {
          Toggle(t("sharedReport.showHidden"), isOn: $model.showsHidden)
        }
        if model.warnsAboutHidden {
          Label {
            Text(verbatim: p("privacy.copy.hidden.warning"))
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .foregroundStyle(.orange)
          .appFont(.callout)
        }
      } header: {
        Text(verbatim: t("sharedReport.accounts")).settingsHeaderStyle()
      }

      categorySection(t("sharedReport.spending"), model.spendingChoices)
      categorySection(t("sharedReport.income"), model.incomeChoices)

      Section {
        Toggle(t("sharedReport.showsNotes"), isOn: $model.showsNotes)
        Toggle(t("sharedReport.showsPlaces"), isOn: $model.showsPlaces)
        Picker(t("sharedReport.format"), selection: $model.format) {
          Text(verbatim: t("sharedReport.format.pdf")).tag(SharedReportModel.Format.pdf)
          Text(verbatim: t("sharedReport.format.csv")).tag(SharedReportModel.Format.csv)
        }
        .accessibilityIdentifier("sharedReport.format")
      }

      Section {
        Toggle(t("sharedReport.encrypt"), isOn: $model.lock.encrypt)
          .accessibilityIdentifier("sharedReport.encrypt")
        if model.lock.encrypt {
          SecureField(p("privacy.copy.password"), text: $model.lock.password)
          SecureField(p("privacy.copy.passwordAgain"), text: $model.lock.confirmation)
          if let problem = model.lock.problemShown() {
            Label {
              Text(verbatim: p(problem.messageKey))
            } icon: {
              Image(systemName: "exclamationmark.octagon")
            }
            .foregroundStyle(.red)
            .appFont(.callout)
          }
        }
      } footer: {
        Text(
          verbatim: t(
            model.format == .pdf ? "sharedReport.encrypt.pdf" : "sharedReport.encrypt.csv")
        )
        .appFont(.callout).secondaryInk()
        .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        Text(verbatim: preview)
          .monospacedDigit()
          .accessibilityIdentifier("sharedReport.preview")
        if model.stage == .failed {
          Label {
            Text(verbatim: t("sharedReport.failed"))
          } icon: {
            Image(systemName: "exclamationmark.octagon")
          }
          .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .safeAreaInset(edge: .bottom, spacing: 0) { buttons }
    .frame(minWidth: 460, idealWidth: 520, minHeight: 520)
    .fileMover(isPresented: $moving, file: pending) { result in
      if case .success = result {
        environment.privacyJournal.record(.exportedCopy)
        dismiss()
      }
      model.stage = .editing
    }
    .accessibilityIdentifier("sharedReport.sheet")
  }

  private func categorySection(
    _ title: String, _ choices: [SharedReportModel.Choice]
  )
    -> some View
  {
    Section {
      ForEach(choices) { choice in
        Toggle(
          isOn: Binding(
            get: { model.categories.contains(choice.id) },
            set: { _ in model.toggle(category: choice.id) })
        ) {
          Text(verbatim: choice.name)
        }
      }
    } header: {
      Text(verbatim: title).settingsHeaderStyle()
    }
  }

  private var buttons: some View {
    HStack {
      if model.stage == .working {
        ProgressView().controlSize(.small)
      }
      Spacer()
      Button(environment.language("action.cancel")) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(t("sharedReport.save")) { save() }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSave)
        .accessibilityIdentifier("sharedReport.save")
    }
    .padding(16)
    .background(.bar)
  }

  /// «Войдёт: 42 операции» or why nothing would.
  private var preview: String {
    if model.periodIsEmpty { return p("privacy.copy.problem.periodEmpty") }
    let count = model.report.lines.count
    if count == 0 { return t("sharedReport.pdf.empty") }
    return environment.format("sharedReport.preview", table: Self.table, counts: count)
  }

  private func save() {
    let report = model.report
    let words = SharedReportWords.make(environment, report: report)
    let version = AppEnvironment.appVersion
    let schema = environment.stack?.applied.onDisk ?? 0
    model.stage = .working
    do {
      pending = try model.write(words: words, appVersion: version, schemaVersion: schema)
      AppLog.info(
        "sharedReport.written", .archive, "a report for another person was made",
        [LogPair("lines", .count(report.lines.count))])
      moving = true
    } catch {
      AppLog.error(
        "sharedReport.failed", .archive, "the report for another person was not made",
        [LogPair("error", .error(error))])
      model.stage = .failed
    }
  }
}
