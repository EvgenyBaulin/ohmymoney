import AppCore
import SwiftUI
import UniformTypeIdentifiers

/// «Импорт выписки»: the files, what each would do line by line, the questions the file could not
/// answer, and one «Записать». Nothing is written before it, and ⌘Z takes it back. Opened from the
/// File menu and by dropping files on the window on the Mac, and from Settings → Счета on every
/// device (on the phone: «Ещё» → «Настройки» → «Счета»).
struct StatementImportFlow: View {
  enum Step: String, CaseIterable, Identifiable {
    case files, rows, questions
    var id: String { rawValue }
    var titleKey: String { "import.step.\(rawValue)" }
  }

  let urls: [URL]

  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dependencies) private var dependencies

  @State private var model: StatementImportModel?
  @State private var step: Step = .files
  @State private var picking = false
  @State private var editsIdentity = false
  @State private var isDropTarget = false
  @State private var failed = false

  private func t(_ key: String) -> String { ImportText.t(key, environment) }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let model {
        content(model)
        Divider()
        footer(model)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .sheetFrame(minWidth: 720, idealWidth: 820, minHeight: 540, idealHeight: 660)
    .task {
      guard model == nil else { return }
      let made = StatementImportModel(
        environment: environment, store: store, dataset: { compute.snapshot?.dataset })
      model = made
      if urls.isEmpty { picking = true } else { await made.add(urls: urls) }
    }
    .fileImporter(
      isPresented: $picking, allowedContentTypes: Self.contentTypes,
      allowsMultipleSelection: true
    ) { result in
      guard case .success(let chosen) = result, let model else { return }
      Task { await model.add(urls: chosen) }
    }
    .dropDestination(for: URL.self) { dropped, _ in
      guard let model, !dropped.isEmpty else { return false }
      Task { await model.add(urls: dropped) }
      return true
    } isTargeted: {
      isDropTarget = $0
    }
    .overlay {
      if isDropTarget {
        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
          .padding(6).allowsHitTesting(false)
      }
    }
    .sheet(isPresented: $editsIdentity) {
      if let model {
        StatementIdentitySheet(identity: model.identity) { model.saveIdentity($0) }
          .handingOver(dependencies)
      }
    }
    .accessibilityIdentifier("import.flow")
  }

  /// CSV, text and PDF; a bank's file with an odd extension is read by its content.
  static let contentTypes: [UTType] = [.commaSeparatedText, .pdf, .plainText, .data]

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: t("import.title")).appFont(.headline)
        Text(verbatim: t("import.subtitle"))
          .appFont(.callout).foregroundStyle(.secondary)
      }
      if let model, model.outcome == nil, !model.files.isEmpty {
        Picker(selection: $step) {
          ForEach(Step.allCases) { step in
            Text(verbatim: t(step.titleKey)).tag(step)
          }
        } label: {
          EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("import.steps")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }

  // MARK: Content

  @ViewBuilder
  private func content(_ model: StatementImportModel) -> some View {
    if let outcome = model.outcome {
      StatementImportDone(outcome: outcome)
    } else if model.files.isEmpty {
      emptyState(model)
    } else {
      switch step {
      case .files:
        StatementFilesStep(model: model, picking: $picking, editsIdentity: $editsIdentity)
      case .rows: StatementRowsStep(model: model)
      case .questions: StatementQuestionsStep(model: model)
      }
    }
  }

  private func emptyState(_ model: StatementImportModel) -> some View {
    VStack(spacing: 14) {
      if model.isReading {
        ProgressView()
        Text(verbatim: t("import.reading")).foregroundStyle(.secondary)
      } else {
        Image(systemName: "tray.and.arrow.down")
          .appFont(.largeTitle)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(verbatim: t("import.empty.title")).appFont(.title3)
        Text(verbatim: t("import.empty.body"))
          .appFont(.callout).foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
        Button {
          picking = true
        } label: {
          Label(t("import.choose"), systemImage: "doc.badge.plus")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("import.choose")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  // MARK: Footer

  private func footer(_ model: StatementImportModel) -> some View {
    HStack(spacing: 12) {
      if model.outcome == nil {
        Text(verbatim: summary(model))
          .appFont(.callout).foregroundStyle(.secondary).monospacedDigit()
          .accessibilityIdentifier("import.summary")
        if failed {
          Label(t("import.failed"), systemImage: "exclamationmark.octagon")
            .appFont(.callout).foregroundStyle(.red)
        }
      }
      Spacer()
      if model.outcome == nil {
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(t("import.apply")) {
          failed = !model.apply()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canApply || store.isWritingInBackground)
        .accessibilityIdentifier("import.apply")
      } else {
        Button(t("import.close")) { dismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("import.close")
      }
    }
    .padding(16)
  }

  private func summary(_ model: StatementImportModel) -> String {
    let plan = model.plan
    if plan.write + plan.change + plan.transfers == 0 { return t("import.summary.nothing") }
    return ImportText.counted(
      "import.summary.plan", environment, plan.write, plan.change, plan.transfers)
  }
}
