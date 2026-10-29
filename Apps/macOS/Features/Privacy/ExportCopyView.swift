import AppCore
import AppDatabase
import CoreKit
import SwiftUI

/// «Экспорт копии…»: a locked file for a person who must not see everything. The owner sets a
/// password, says which part of the history goes, whether the names are replaced, whether the
/// hidden accounts and the attached files go, and how the file is packed; the dialog counts what
/// will go in before anything is written. Whatever is chosen, the original stays as it is.
struct ExportCopyView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var model: ExportCopyModel
  @State private var moving = false
  @State private var attachmentPlan: AttachmentArchive.Plan?

  private static let table = "PrivacyExport"
  private func t(_ key: String) -> String { environment.language(key, table: Self.table) }

  init(model: ExportCopyModel) {
    _model = State(initialValue: model)
  }

  /// The things that change what would go in; the count is made again when one changes.
  private struct CountKey: Hashable {
    let period: Bool
    let start: Date
    let end: Date
    let hidden: Bool
    let files: Bool
    let archive: Bool
  }

  private var countKey: CountKey {
    CountKey(
      period: model.scope == .period, start: model.periodStart, end: model.periodEnd,
      hidden: model.includeHidden, files: model.includeAttachments,
      archive: model.format == .archive)
  }

  var body: some View {
    VStack(spacing: 0) {
      switch model.stage {
      case .done(let report): done(report)
      default: form
      }
    }
    .frame(minWidth: 460, idealWidth: 520, minHeight: 420)
    .task(id: countKey) { await recount() }
    .task { attachmentPlan = try? environment.archives?.attachmentPlan() }
    .fileMover(
      isPresented: $moving, file: model.pending?.url,
      onCompletion: { result in
        switch result {
        case .success(let destination):
          model.moved(to: destination)
          environment.privacyJournal.record(.exportedCopy)
        case .failure:
          model.cancelled()
        }
      }
    )
    .accessibilityIdentifier("privacy.copy.sheet")
  }

  // MARK: Form

  private var form: some View {
    Form {
      Section {
        if model.showsPassword {
          TextField(t("privacy.copy.password"), text: $model.password)
          TextField(t("privacy.copy.passwordAgain"), text: $model.confirmation)
        } else {
          SecureField(t("privacy.copy.password"), text: $model.password)
          SecureField(t("privacy.copy.passwordAgain"), text: $model.confirmation)
        }
        Toggle(t("privacy.copy.showPassword"), isOn: $model.showsPassword)
        if let problem = model.problemShown() {
          Label {
            Text(verbatim: text(of: problem))
          } icon: {
            Image(systemName: "exclamationmark.octagon")
          }
          .foregroundStyle(.red)
          .appFont(.callout)
        }
      } header: {
        Text(verbatim: t("privacy.copy.title")).settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("privacy.copy.passwordHint"))
          .appFont(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        Picker(t("privacy.copy.scope"), selection: $model.scope) {
          Text(verbatim: t("privacy.copy.scope.whole")).tag(ExportCopyModel.ScopeChoice.whole)
          Text(verbatim: t("privacy.copy.scope.period")).tag(ExportCopyModel.ScopeChoice.period)
        }
        .pickerStyle(.segmented)
        if model.scope == .period {
          DatePicker(
            t("privacy.copy.from"), selection: $model.periodStart, displayedComponents: .date)
          DatePicker(
            t("privacy.copy.to"), selection: $model.periodEnd, displayedComponents: .date)
        }
        Toggle(isOn: $model.anonymize) {
          Text(verbatim: t("privacy.copy.anonymize"))
          Text(verbatim: t("privacy.copy.anonymize.hint"))
        }
        if (model.counts?.hiddenAccounts ?? 0) > 0 {
          Toggle(isOn: $model.includeHidden) {
            Text(verbatim: t("privacy.copy.hidden"))
            Text(verbatim: t("privacy.copy.hidden.hint"))
          }
          if model.warnsAboutHidden {
            Label {
              Text(verbatim: t("privacy.copy.hidden.warning"))
            } icon: {
              Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            .appFont(.callout)
          }
        }
        if let plan = attachmentPlan, !plan.included.isEmpty || !plan.skipped.isEmpty {
          Toggle(isOn: $model.includeAttachments) {
            Text(
              verbatim: environment.format(
                "privacy.copy.attachments", table: Self.table,
                ByteCountFormatter.string(fromByteCount: plan.includedBytes, countStyle: .file)))
          }
          .disabled(model.format == .csvOnly)
        }
        Picker(t("privacy.copy.format"), selection: $model.format) {
          Text(verbatim: t("privacy.copy.format.archive")).tag(ExportCopyRequest.Format.archive)
          Text(verbatim: t("privacy.copy.format.csv")).tag(ExportCopyRequest.Format.csvOnly)
        }
      }

      Section {
        Text(verbatim: previewText)
          .monospacedDigit()
          .accessibilityIdentifier("privacy.copy.preview")
        if model.leftOut > 0 {
          Text(
            verbatim: environment.format(
              "privacy.copy.leftOut", table: Self.table, counts: model.leftOut)
          )
          .appFont(.callout).foregroundStyle(.secondary)
        }
        Label {
          Text(verbatim: t("privacy.copy.originalStays"))
        } icon: {
          Image(systemName: "checkmark.shield")
        }
        .appFont(.callout).foregroundStyle(.secondary)
        if case .failed(let failure) = model.stage {
          Label {
            Text(verbatim: t(failure.key))
          } icon: {
            Image(systemName: "exclamationmark.octagon")
          }
          .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .safeAreaInset(edge: .bottom, spacing: 0) { buttons }
  }

  private var buttons: some View {
    HStack {
      if model.stage == .working {
        ProgressView().controlSize(.small)
        Text(verbatim: t("privacy.copy.working")).appFont(.callout).foregroundStyle(.secondary)
      }
      Spacer()
      Button(environment.language("action.cancel")) { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("privacy.copy.cancel")
      Button(t("privacy.copy.save")) { save() }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSave)
        .accessibilityIdentifier("privacy.copy.save")
    }
    .padding(16)
    .background(.bar)
  }

  private func done(_ report: ExportCopyReport) -> some View {
    VStack(spacing: 14) {
      Image(systemName: "lock.doc")
        .appFont(.largeTitle)
        .foregroundStyle(.secondary)
      Text(verbatim: t("privacy.copy.done")).appFont(.title3)
      VStack(alignment: .leading, spacing: 4) {
        Text(
          verbatim: environment.format(
            "privacy.copy.done.operations", table: Self.table, counts: report.operations))
        Text(
          verbatim: environment.format(
            "privacy.copy.done.transfers", table: Self.table, counts: report.transfers))
        if report.attachments > 0 {
          Text(
            verbatim: environment.format(
              "privacy.copy.done.attachments", table: Self.table, counts: report.attachments))
        }
        if report.operationsLeftOut + report.transfersLeftOut > 0 {
          Text(
            verbatim: environment.format(
              "privacy.copy.leftOut", table: Self.table,
              counts: report.operationsLeftOut + report.transfersLeftOut))
        }
        Text(verbatim: t("privacy.copy.done.locked"))
      }
      .monospacedDigit()
      .appFont(.callout)
      Text(verbatim: t("privacy.copy.originalStays"))
        .appFont(.callout).foregroundStyle(.secondary)
      Button(environment.language("action.close")) { dismiss() }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("privacy.copy.close")
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Actions and words

  private func save() {
    guard let service = environment.exportCopies else { return }
    let settings = environment.portableSettings()
    let today = environment.today
    Task {
      await model.prepare(with: service, settings: settings, today: today)
      moving = model.pending != nil
    }
  }

  private func recount() async {
    guard let stack = environment.stack else { return }
    let request = model.countingRequest()
    let counted = await Task.detached(priority: .userInitiated) {
      try? ExportCopyPreviewer(writer: stack.writer).counts(for: request)
    }.value
    if let counted { model.counts = counted }
  }

  /// «Войдёт: 1 240 операций, 18 переводов; вложений 12».
  private var previewText: String {
    guard model.counts != nil else { return t("privacy.copy.preview.counting") }
    let parts = model.previewParts.map {
      environment.format($0.key, table: Self.table, counts: $0.count)
    }
    return t("privacy.copy.preview.lead") + " " + parts.joined(separator: ", ")
  }

  private func text(of problem: ExportCopyModel.Problem) -> String {
    switch problem {
    case .passwordEmpty: t("privacy.copy.problem.passwordEmpty")
    case .passwordMismatch: t("privacy.copy.problem.passwordMismatch")
    case .periodEmpty: t("privacy.copy.problem.periodEmpty")
    }
  }
}
