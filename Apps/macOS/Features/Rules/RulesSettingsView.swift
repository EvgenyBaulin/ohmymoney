import AppCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → «Правила и теги»: the owner's rules (a list in the order they win in), the tags,
/// and the file the rules are shared in. A rule fills the entry line before Enter and never
/// moves money; what the owner chooses by hand beats it.
struct RulesSettingsView: View {
  enum Pane: String, CaseIterable, Identifiable {
    case rules, tags, exchange
    var id: String { rawValue }
    var titleKey: String { "rules.pane.\(rawValue)" }
  }

  @Dependency(\.environment) private var environment
  @State private var pane: Pane = .rules

  var body: some View {
    VStack(spacing: 0) {
      Picker(selection: $pane) {
        ForEach(Pane.allCases) { pane in
          Text(verbatim: RulesText.t(pane.titleKey, environment)).tag(pane)
        }
      } label: {
        EmptyView()
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 20)
      .padding(.vertical, 8)
      .accessibilityIdentifier("rules.pane")
      switch pane {
      case .rules: RulesPane()
      case .tags: TagsPane()
      case .exchange: RuleExchangePane()
      }
    }
  }
}

/// What the rules list is asked to open.
private enum RulesSheet: Identifiable {
  case edit(RuleDraft)
  case backfill

  var id: String {
    switch self {
    case .edit(let draft): "edit-\(draft.id)"
    case .backfill: "backfill"
    }
  }
}

/// The list of rules: switch, summary, order by drag (or by the menu), edit, delete.
struct RulesPane: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store
  @Environment(\.dependencies) private var dependencies

  @State private var sheet: RulesSheet?
  @State private var refused = false

  private func t(_ key: String) -> String { RulesText.t(key, environment) }

  var body: some View {
    let dataset = compute.snapshot?.dataset
    let rules = RuleOrder.sorted(dataset?.rules ?? [])
    let wording = RuleWording(
      environment: environment, names: dataset.map(RuleNames.init(dataset:)) ?? RuleNames())
    Form {
      Section {
        if rules.isEmpty {
          Text(verbatim: t("rules.empty"))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("rules.empty")
        }
        ForEach(rules) { rule in
          row(rule, in: rules, wording: wording)
        }
        .onMove { from, to in
          var ids = rules.map(\.id)
          ids.move(fromOffsets: from, toOffset: to)
          reorder(ids)
        }
      } header: {
        Text(verbatim: t("rules.title")).settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("rules.hint"))
          .appFont(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        Button {
          sheet = .edit(newDraft(after: rules))
        } label: {
          Label(t("rules.new"), systemImage: "plus")
        }
        .accessibilityIdentifier("rules.new")
        Button {
          sheet = .backfill
        } label: {
          Label(t("rules.backfill"), systemImage: "clock.arrow.2.circlepath")
        }
        .disabled(!rules.contains { $0.enabled })
        .accessibilityIdentifier("rules.backfill")
        if refused {
          Label(t("rules.refused"), systemImage: "exclamationmark.octagon")
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .sheet(item: $sheet) { asked in
      switch asked {
      case .edit(let draft): RuleEditorSheet(draft: draft).handingOver(dependencies)
      case .backfill: BackfillSheet().handingOver(dependencies)
      }
    }
  }

  private func newDraft(after rules: [Rule]) -> RuleDraft {
    var draft = RuleDraft()
    draft.position = (rules.map(\.position).max() ?? -1) + 1
    return draft
  }

  private func row(_ rule: Rule, in rules: [Rule], wording: RuleWording) -> some View {
    let index = rules.firstIndex { $0.id == rule.id } ?? 0
    return HStack(spacing: 8) {
      Toggle(
        isOn: Binding(
          get: { rule.enabled },
          set: { on in
            var changed = rule
            changed.enabled = on
            changed.updatedAt = Date()
            refused = !store.updateRule(changed)
          })
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: wording.title(rule)).lineLimit(1)
          if !rule.name.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(verbatim: wording.summary(rule))
              .appFont(.callout).foregroundStyle(.secondary).lineLimit(2)
          }
          if let origin = wording.origin(rule.origin) {
            Label(origin, systemImage: rule.origin == .imported ? "tray.and.arrow.down" : "doc")
              .appFont(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Spacer(minLength: 4)
      Button(t("rules.edit")) {
        sheet = .edit(RuleDraft(rule, book: compute.snapshot?.dataset.tagBook ?? TagBook()))
      }
      .buttonStyle(.borderless)
      Menu {
        Button(t("rules.moveUp")) { move(rule, by: -1, in: rules) }
          .disabled(index == 0)
        Button(t("rules.moveDown")) { move(rule, by: 1, in: rules) }
          .disabled(index == rules.count - 1)
        Divider()
        Button(t("rules.delete"), role: .destructive) {
          refused = !store.deleteRules(ids: [rule.id])
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel(Text(verbatim: t("rules.more")))
    }
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: Text(verbatim: t("rules.moveUp"))) {
      move(rule, by: -1, in: rules)
    }
    .accessibilityAction(named: Text(verbatim: t("rules.moveDown"))) {
      move(rule, by: 1, in: rules)
    }
    .accessibilityIdentifier("rules.row")
  }

  private func move(_ rule: Rule, by step: Int, in rules: [Rule]) {
    guard let from = rules.firstIndex(where: { $0.id == rule.id }) else { return }
    let target = from + step
    guard rules.indices.contains(target) else { return }
    var ids = rules.map(\.id)
    ids.swapAt(from, target)
    reorder(ids)
  }

  private func reorder(_ ids: [UUID]) {
    refused = !store.reorderRules(ids)
  }
}

/// «Файл обмена»: the rules (with the categories and tags they need) written to a file to share,
/// and a file opened with a preview of what it would add.
struct RuleExchangePane: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  @State private var exporting = false
  @State private var picking = false
  @State private var opened: OpenedBundle?
  @State private var failure: String?

  private struct OpenedBundle: Identifiable {
    let id = UUID()
    let bundle: RuleBundle
  }

  private func t(_ key: String) -> String { RulesText.t(key, environment) }

  var body: some View {
    let rules = compute.snapshot?.dataset.rules ?? []
    Form {
      Section {
        Button {
          exporting = true
        } label: {
          Label(t("exchange.export"), systemImage: "square.and.arrow.up")
        }
        .disabled(rules.isEmpty)
        .accessibilityIdentifier("exchange.export")
        Button {
          picking = true
        } label: {
          Label(t("exchange.open"), systemImage: "square.and.arrow.down")
        }
        .accessibilityIdentifier("exchange.open")
        if let failure {
          Label(failure, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
        }
      } header: {
        Text(verbatim: t("exchange.title")).settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("exchange.hint"))
          .appFont(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $exporting) {
      RuleExportSheet(rules: rules).handingOver(dependencies)
    }
    .sheet(item: $opened) { opened in
      RuleImportSheet(bundle: opened.bundle).handingOver(dependencies)
    }
    .fileImporter(
      isPresented: $picking, allowedContentTypes: [RuleBundleFile.type, .json]
    ) { result in
      read(result)
    }
  }

  private func read(_ result: Result<URL, any Error>) {
    failure = nil
    guard case .success(let url) = result else { return }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let data = try Data(contentsOf: url)
      opened = OpenedBundle(bundle: try RuleBundle.decoded(from: data))
    } catch let error as RuleBundle.FileError {
      failure = t(RuleBundleFile.errorKey(error))
    } catch {
      failure = t("exchange.error.unreadable")
    }
  }
}
