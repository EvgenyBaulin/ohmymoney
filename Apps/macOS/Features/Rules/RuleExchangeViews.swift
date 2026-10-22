import AppCore
import SwiftUI
import UniformTypeIdentifiers

/// The exchange file of rules (`.ohmymoneyrules`): categories, tags and rules by name. A plain
/// JSON text, so it opens anywhere and a person can read it.
enum RuleBundleFile {
  /// Declared by extension only: the file opens through the picker of the app, not by a
  /// double click (the extension is not registered with the system).
  static let type: UTType =
    UTType(filenameExtension: RuleBundle.fileExtension, conformingTo: .json) ?? .json

  /// The key of the words for a file that cannot be read.
  static func errorKey(_ error: RuleBundle.FileError) -> String {
    switch error {
    case .tooLarge: "exchange.error.tooLarge"
    case .notABundle: "exchange.error.notABundle"
    case .newerFormat: "exchange.error.newerFormat"
    case .tooManyRules: "exchange.error.tooManyRules"
    }
  }

  /// The name the file is offered under.
  static func defaultName(title: String) -> String {
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    return cleaned.isEmpty ? "OhMyMoney" : cleaned
  }
}

/// What the exporter writes.
struct RuleBundleDocument: FileDocument {
  static let readableContentTypes: [UTType] = [RuleBundleFile.type, .json]
  static let writableContentTypes: [UTType] = [RuleBundleFile.type]

  var bundle: RuleBundle

  init(_ bundle: RuleBundle) { self.bundle = bundle }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    bundle = try RuleBundle.decoded(from: data)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: try bundle.encoded())
  }
}

/// The ticks before a file is written: every rule of the list, the ones about people and
/// accounts unticked (a file is for sharing, and those are the owner's own).
struct RuleExportSelection: Equatable {
  var candidates: [ExchangeCandidate]
  var ticked: Set<UUID>

  init(rules: [Rule]) {
    candidates = RuleExchange.candidates(rules)
    ticked = Set(candidates.filter(\.selectedByDefault).map(\.id))
  }

  var chosen: [Rule] { candidates.filter { ticked.contains($0.id) }.map(\.rule) }
}

/// «Выгрузить правила…»: pick the rules with ticks, name the file, save it.
struct RuleExportSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss

  @State private var selection: RuleExportSelection
  @State private var title = ""
  @State private var exporting = false
  @State private var document: RuleBundleDocument?
  @State private var failed = false

  init(rules: [Rule]) {
    _selection = State(initialValue: RuleExportSelection(rules: rules))
  }

  private func t(_ key: String) -> String { RulesText.t(key, environment) }

  var body: some View {
    let dataset = compute.snapshot?.dataset
    let wording = RuleWording(
      environment: environment, names: dataset.map(RuleNames.init(dataset:)) ?? RuleNames())
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("exchange.export.title")).appFont(.headline)
      Text(verbatim: t("exchange.export.hint"))
        .appFont(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextField(text: $title) { Text(verbatim: t("exchange.export.name")) }
      List {
        ForEach(selection.candidates) { candidate in
          Toggle(
            isOn: Binding(
              get: { selection.ticked.contains(candidate.id) },
              set: { on in
                if on {
                  selection.ticked.insert(candidate.id)
                } else {
                  selection.ticked.remove(candidate.id)
                }
              })
          ) {
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: wording.title(candidate.rule)).lineLimit(1)
              if candidate.isPersonal {
                Label(t("exchange.export.personal"), systemImage: "person.crop.circle")
                  .appFont(.caption).foregroundStyle(.secondary)
              }
            }
          }
          .toggleStyle(.checkbox)
        }
      }
      .listStyle(.inset)
      .frame(minHeight: 200)
      if failed {
        Label(t("exchange.export.failed"), systemImage: "exclamationmark.octagon")
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(t("exchange.export.save")) { prepare() }
          .keyboardShortcut(.defaultAction)
          .disabled(selection.ticked.isEmpty)
          .accessibilityIdentifier("exchange.export.save")
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 480)
    .fileExporter(
      isPresented: $exporting, document: document, contentType: RuleBundleFile.type,
      defaultFilename: RuleBundleFile.defaultName(title: title)
    ) { result in
      switch result {
      case .success: dismiss()
      case .failure(let error):
        if (error as? CocoaError)?.code != .userCancelled { failed = true }
      }
    }
  }

  private func prepare() {
    guard let dataset = compute.snapshot?.dataset else {
      failed = true
      return
    }
    let bundle = RuleExchange.export(
      rules: selection.chosen, directory: ExchangeDirectory(dataset: dataset),
      title: title.trimmingCharacters(in: .whitespacesAndNewlines))
    document = RuleBundleDocument(bundle)
    failed = false
    exporting = true
  }
}

/// «Открыть файл…»: the file is read, the preview of what would be added is shown, and
/// nothing is written before «Добавить». Nothing is removed or renamed — ever.
struct RuleImportSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss

  let bundle: RuleBundle
  @State private var preview: RuleImportPreview?
  @State private var outcome: RuleExchangeWriter.Outcome?

  private func t(_ key: String) -> String { RulesText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: bundle.title.isEmpty ? t("exchange.import.title") : bundle.title)
        .appFont(.headline)
      if let outcome {
        resultView(outcome)
      } else if let preview {
        previewView(preview)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      HStack {
        Spacer()
        if outcome == nil {
          Button(environment.language("action.cancel")) { dismiss() }
            .keyboardShortcut(.cancelAction)
          Button(t("exchange.import.add")) { add() }
            .keyboardShortcut(.defaultAction)
            .disabled(preview?.isEmpty ?? true)
            .accessibilityIdentifier("exchange.import.add")
        } else {
          Button(environment.language("action.ok")) { dismiss() }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 460)
    .task { makePreview() }
    .accessibilityIdentifier("exchange.import")
  }

  private func makePreview() {
    guard let dataset = compute.snapshot?.dataset else { return }
    preview = RuleExchange.preview(
      bundle, into: ExchangeDirectory(dataset: dataset), existing: dataset.rules)
  }

  @ViewBuilder
  private func previewView(_ preview: RuleImportPreview) -> some View {
    let wording = RuleWording(
      environment: environment,
      names: compute.snapshot.map { RuleNames(dataset: $0.dataset) } ?? RuleNames())
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          verbatim: environment.format(
            "exchange.import.summary", table: RulesText.table,
            counts:
              preview.categoriesToAdd.count, preview.tagsToAdd.count, preview.rulesToAdd.count)
        )
        .accessibilityIdentifier("exchange.import.summary")
        names("exchange.import.newCategories", preview.categoriesToAdd.map(\.name), "plus.circle")
        names("exchange.import.newTags", preview.tagsToAdd.map { "#" + $0.name }, "plus.circle")
        names("exchange.import.matched", preview.categoriesMatched + preview.tagsMatched, "link")
        names("exchange.import.already", preview.rulesAlreadyThere, "equal.circle")
        if !preview.rulesRejected.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Label(t("exchange.import.rejected"), systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
            ForEach(Array(preview.rulesRejected.enumerated()), id: \.offset) { _, rejected in
              Text(verbatim: "• " + rejected.name + " — " + reason(rejected, wording))
                .appFont(.callout).foregroundStyle(.secondary)
            }
          }
        }
        Text(verbatim: t("exchange.import.promise"))
          .appFont(.callout).foregroundStyle(.secondary)
        if !preview.sections.isEmpty {
          Text(verbatim: t("exchange.import.sections"))
            .appFont(.callout).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func names(_ key: String, _ items: [String], _ symbol: String) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        Label(t(key), systemImage: symbol)
        Text(verbatim: items.joined(separator: ", "))
          .appFont(.callout).foregroundStyle(.secondary)
      }
    }
  }

  private func reason(_ rejected: RejectedRule, _ wording: RuleWording) -> String {
    switch rejected.reason {
    case .missing(let kind, let name):
      RulesText.format("exchange.import.missing.\(kind.rawValue)", environment, name)
    case .invalid(let problems):
      problems.first.map(wording.problem) ?? t("exchange.import.invalid")
    }
  }

  @ViewBuilder
  private func resultView(_ outcome: RuleExchangeWriter.Outcome) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if outcome.failed {
        Label(t("exchange.import.failed"), systemImage: "exclamationmark.octagon")
          .foregroundStyle(.red)
      } else {
        Label(
          environment.format(
            "exchange.import.done", table: RulesText.table, counts: outcome.categories,
            outcome.tags, outcome.rules), systemImage: "checkmark.circle"
        )
        .accessibilityIdentifier("exchange.import.result")
        Text(verbatim: t("exchange.import.undoHint")).appFont(.callout).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func add() {
    guard let preview, !preview.isEmpty else { return }
    outcome = RuleExchangeWriter.write(preview, environment: environment, store: store)
  }
}
