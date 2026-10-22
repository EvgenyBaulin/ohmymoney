import AppCore
import SwiftUI

/// A tag as a chip: «#отпуск», with a symbol and words for where it came from, and a button to
/// take it off where it can be taken off. Where it came from is never said by colour alone.
struct TagChip: View {
  enum Source: Equatable {
    /// Typed in the line: it goes when the words go.
    case line
    /// Added in the panel.
    case panel
    /// Put there by a rule of the owner's.
    case rule(String)
  }

  let name: String
  let source: Source
  var remove: (() -> Void)?
  @Dependency(\.environment) private var environment

  var body: some View {
    HStack(spacing: 4) {
      if case .rule = source {
        Image(systemName: "line.3.horizontal.decrease.circle").accessibilityHidden(true)
      }
      Text(verbatim: "#" + name)
      if let remove {
        Button(action: remove) {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(
          Text(verbatim: RulesText.format("entryrule.tag.remove", environment, name)))
      }
    }
    .appFont(.callout)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(.quaternary, in: .capsule)
    .help(helpText)
    .accessibilityElement(children: .combine)
    .accessibilityValue(Text(verbatim: helpText))
    .accessibilityIdentifier("entry.tag.chip")
  }

  private var helpText: String {
    switch source {
    case .line: RulesText.t("entryrule.tag.fromLine", environment)
    case .panel: RulesText.t("entryrule.tag.fromPanel", environment)
    case .rule(let rule): RulesText.format("entryrule.tag.fromRule", environment, rule)
    }
  }
}

/// The ↓ panel's row of tags and of what the rules said: the tags of the line, the tags typed
/// here, the tags a rule adds (each can be taken off for this operation), and a sentence naming
/// the rules that filled fields. Shown for a new operation only.
struct EntryTagsRow: View {
  @Bindable var model: EntryDraftModel
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  @State private var typed = ""
  @FocusState private var focused: Bool

  private func t(_ key: String) -> String { RulesText.t(key, environment) }

  var body: some View {
    let dataset = compute.snapshot?.dataset
    let book = dataset?.tagBook ?? TagBook()
    let state = model.ruleState
    let names = dataset.map(RuleNames.init(dataset:)) ?? RuleNames()
    let wording = RuleWording(environment: environment, names: names)
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: t("entryrule.tags"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
      FlowRow(spacing: 6, lineSpacing: 6) {
        ForEach(state.lineTags, id: \.self) { name in
          TagChip(name: name, source: .line)
        }
        ForEach(state.panelTags, id: \.self) { name in
          TagChip(name: name, source: .panel) { model.removePanelTag(name) }
        }
        ForEach(state.ruleTags, id: \.value) { tag in
          let rule = dataset?.rules.first { $0.id == tag.ruleId }
          TagChip(
            name: names.tags[tag.value] ?? "?",
            source: .rule(rule.map(wording.title) ?? "")
          ) {
            model.dismissRuleTag(tag.value)
          }
        }
        HStack(spacing: 4) {
          TextField(text: $typed, prompt: Text(verbatim: t("entryrule.tag.prompt"))) {
            Text(verbatim: t("entryrule.tags"))
          }
          .textFieldStyle(.plain)
          .frame(minWidth: 90, maxWidth: 160)
          .focused($focused)
          .onSubmit(commit)
          .accessibilityIdentifier("entry.tag.field")
          existingTags(book)
        }
        // Return here adds the tag; it must not also save the operation.
        .submitScope()
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
      }
      if let hint = EntryLineRules.hint(
        state.verdict, rules: dataset?.rules ?? [], wording: wording)
      {
        Label(hint, systemImage: "line.3.horizontal.decrease.circle")
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("entry.rule.hint")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("entry.tags")
  }

  /// The tags there are, to add one with a click.
  @ViewBuilder
  private func existingTags(_ book: TagBook) -> some View {
    let taken = Set((model.ruleState.typedTags).map(TagName.key))
    let choices = book.tags.filter { !$0.archived && !taken.contains(TagName.key($0.name)) }
    if !choices.isEmpty {
      Menu {
        ForEach(choices) { tag in
          Button("#" + tag.name) { model.addPanelTag(tag.name) }
        }
      } label: {
        Image(systemName: "chevron.down")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel(Text(verbatim: t("rules.editor.existingTags")))
    }
  }

  private func commit() {
    if model.addPanelTag(typed) { typed = "" }
  }
}
