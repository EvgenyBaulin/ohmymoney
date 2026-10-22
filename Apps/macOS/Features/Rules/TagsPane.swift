import AppCore
import SwiftUI

/// The rows of the dictionary of tags: each tag with what it is on. Pure, so a test reads it.
struct TagRow: Identifiable, Equatable {
  var tag: Tag
  var operations: Int
  var parts: Int
  var spent: AmountE4

  var id: UUID { tag.id }

  static func rows(book: TagBook, report: TagReport?, showsArchive: Bool) -> [TagRow] {
    let totals = Dictionary(
      (report?.rows ?? []).map { ($0.tagId, $0) }, uniquingKeysWith: { first, _ in first })
    return book.tags.filter { showsArchive || !$0.archived }.map { tag in
      let total = totals[tag.id]
      return TagRow(
        tag: tag, operations: total?.operations ?? 0,
        parts: total?.parts ?? book.partIds(of: tag.id).count, spent: total?.myRubE4 ?? .zero)
    }.sorted { left, right in
      if left.tag.archived != right.tag.archived { return !left.tag.archived }
      return left.tag.name.localizedCaseInsensitiveCompare(right.tag.name) == .orderedAscending
    }
  }
}

/// What the owner asked of a tag and is being asked about.
private enum TagQuestion: Identifiable {
  case rename(Tag)
  case merge(Tag)
  case delete(Tag)
  /// A new name that is another tag's: merge the two?
  case collision(source: Tag, other: Tag)

  var id: String {
    switch self {
    case .rename(let tag): "rename-\(tag.id)"
    case .merge(let tag): "merge-\(tag.id)"
    case .delete(let tag): "delete-\(tag.id)"
    case .collision(let source, _): "collision-\(source.id)"
    }
  }
}

/// Settings → «Правила и теги» → «Теги»: the tags there are, how much each one is, and the
/// four things done to a tag — rename, merge into another, archive, delete. Each is one step of
/// ⌘Z, and the rules that name a tag follow it.
struct TagsPane: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store

  @State private var showsArchive = false
  @State private var report: TagReport?
  @State private var question: TagQuestion?
  @State private var newName = ""
  @State private var mergeTarget: UUID?
  @State private var note: String?
  @State private var showsReport = false
  @Environment(\.dependencies) private var dependencies

  private func t(_ key: String) -> String { RulesText.t(key, environment) }

  var body: some View {
    let book = compute.snapshot?.dataset.tagBook ?? TagBook()
    let rows = TagRow.rows(book: book, report: report, showsArchive: showsArchive)
    Form {
      Section {
        if rows.isEmpty {
          Text(verbatim: t("tags.empty")).foregroundStyle(.secondary)
        }
        ForEach(rows) { row in
          tagRow(row, book: book)
        }
      } header: {
        Text(verbatim: t("tags.title")).settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("tags.hint")).appFont(.callout).foregroundStyle(.secondary)
      }
      Section {
        Button {
          showsReport = true
        } label: {
          Label(t("tagreport.open"), systemImage: "chart.bar.doc.horizontal")
        }
        .accessibilityIdentifier("tags.report")
        Toggle(isOn: $showsArchive) { Text(verbatim: t("tags.showArchive")) }
          .toggleStyle(.checkbox)
        if let note {
          Label(note, systemImage: "info.circle")
            .appFont(.callout).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .task(id: compute.snapshot?.version.cacheKey) {
      guard let snapshot = compute.snapshot else { return }
      report = try? await compute.analysis.tags.report(snapshot)
    }
    .alert(
      t("tags.rename.title"), isPresented: askingFor(\.isRename),
      presenting: question
    ) { asked in
      if case .rename(let tag) = asked {
        TextField(t("tags.rename.field"), text: $newName)
        Button(environment.language("action.save")) { rename(tag, to: newName, book: book) }
        Button(environment.language("action.cancel"), role: .cancel) {}
      }
    }
    .confirmationDialog(
      t("tags.collision.title"), isPresented: askingFor(\.isCollision), titleVisibility: .visible,
      presenting: question
    ) { asked in
      if case .collision(let source, let other) = asked {
        Button(RulesText.format("tags.collision.merge", environment, source.name, other.name)) {
          merge(source, into: other, book: book)
        }
        Button(environment.language("action.cancel"), role: .cancel) {}
      }
    } message: { _ in
      Text(verbatim: t("tags.collision.message"))
    }
    .confirmationDialog(
      t("tags.delete.title"), isPresented: askingFor(\.isDelete), titleVisibility: .visible,
      presenting: question
    ) { asked in
      if case .delete(let tag) = asked {
        Button(t("tags.delete.confirm"), role: .destructive) { delete(tag, book: book) }
        Button(environment.language("action.cancel"), role: .cancel) {}
      }
    } message: { asked in
      if case .delete(let tag) = asked {
        Text(verbatim: deleteMessage(tag, book: book))
      }
    }
    .sheet(isPresented: $showsReport) {
      TagReportSheet().handingOver(dependencies)
    }
    .sheet(
      isPresented: askingFor(\.isMerge)
    ) {
      if case .merge(let tag) = question {
        mergeSheet(tag, book: book)
      }
    }
  }

  // MARK: Rows

  private func tagRow(_ row: TagRow, book: TagBook) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(verbatim: "#" + row.tag.name)
          if row.tag.archived {
            Label(t("tags.archived"), systemImage: "archivebox")
              .appFont(.caption).foregroundStyle(.secondary)
          }
        }
        Text(verbatim: usage(row)).appFont(.callout).foregroundStyle(.secondary)
      }
      Spacer()
      Menu {
        Button(t("tags.rename")) {
          newName = row.tag.name
          question = .rename(row.tag)
        }
        Button(t("tags.merge")) {
          mergeTarget = nil
          question = .merge(row.tag)
        }
        .disabled(book.tags.count < 2)
        Button(row.tag.archived ? t("tags.restore") : t("tags.archive")) {
          archive(row.tag, !row.tag.archived, book: book)
        }
        Divider()
        Button(t("tags.delete"), role: .destructive) { question = .delete(row.tag) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel(Text(verbatim: RulesText.format("tags.menu", environment, row.tag.name)))
    }
    .accessibilityIdentifier("tags.row")
  }

  /// «12 операций · 34 500 ₽»; a tag on nothing says so.
  private func usage(_ row: TagRow) -> String {
    guard row.operations > 0 || row.parts > 0 else { return t("tags.unused") }
    return environment.format("tags.usage", table: RulesText.table, counts: row.operations)
      + " · " + environment.money.rounded(row.spent)
  }

  private func mergeSheet(_ tag: Tag, book: TagBook) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: RulesText.format("tags.merge.title", environment, tag.name))
        .appFont(.headline)
      Text(verbatim: t("tags.merge.hint")).appFont(.callout).foregroundStyle(.secondary)
      Picker(selection: $mergeTarget) {
        Text(verbatim: t("rules.editor.choose")).tag(UUID?.none)
        ForEach(book.tags.filter { $0.id != tag.id }) { other in
          Text(verbatim: "#" + other.name).tag(UUID?.some(other.id))
        }
      } label: {
        Text(verbatim: t("tags.merge.into"))
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { question = nil }
          .keyboardShortcut(.cancelAction)
        Button(t("tags.merge.confirm")) {
          if let target = mergeTarget.flatMap(book.tag) { merge(tag, into: target, book: book) }
          question = nil
        }
        .keyboardShortcut(.defaultAction)
        .disabled(mergeTarget == nil)
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 380, idealWidth: 420)
  }

  private func deleteMessage(_ tag: Tag, book: TagBook) -> String {
    let rules = compute.snapshot?.dataset.rules ?? []
    let outcome = TagChange.deletion(of: tag.id, book: book, rules: rules)
    var text = environment.format(
      "tags.delete.message", table: RulesText.table, counts: book.partIds(of: tag.id).count)
    if outcome.rulesChanged > 0 || outcome.rulesRemoved > 0 {
      text +=
        " "
        + environment.format(
          "tags.delete.rules", table: RulesText.table, counts: outcome.rulesChanged,
          outcome.rulesRemoved)
    }
    return text
  }

  // MARK: Actions

  private func askingFor(_ test: KeyPath<TagQuestion, Bool>) -> Binding<Bool> {
    Binding(
      get: { question.map { $0[keyPath: test] } ?? false },
      set: { if !$0 { question = nil } })
  }

  private func rename(_ tag: Tag, to name: String, book: TagBook) {
    note = nil
    switch book.renaming(tag.id, to: name) {
    case .renamed(let edit):
      if !store.apply(edit) { note = t("tags.refused") }
    case .collides(let other):
      question = .collision(source: tag, other: other)
    case .invalidName:
      note = t("tags.invalidName")
    case .unknownTag:
      note = t("tags.refused")
    }
  }

  private func merge(_ source: Tag, into target: Tag, book: TagBook) {
    note = nil
    guard let edit = book.merging(source.id, into: target.id) else { return }
    if !store.apply(edit, merged: (source.id, target.id)) { note = t("tags.refused") }
  }

  private func archive(_ tag: Tag, _ archived: Bool, book: TagBook) {
    note = nil
    guard let edit = book.archiving(tag.id, archived) else { return }
    if !store.apply(edit) { note = t("tags.refused") }
  }

  private func delete(_ tag: Tag, book: TagBook) {
    note = nil
    guard let edit = book.deleting(tag.id) else { return }
    if !store.apply(edit) { note = t("tags.refused") }
  }
}

extension TagQuestion {
  fileprivate var isRename: Bool { if case .rename = self { true } else { false } }
  fileprivate var isMerge: Bool { if case .merge = self { true } else { false } }
  fileprivate var isDelete: Bool { if case .delete = self { true } else { false } }
  fileprivate var isCollision: Bool { if case .collision = self { true } else { false } }
}

/// What a change of the dictionary does to the rules, counted before it is made.
enum TagChange {
  struct Deletion: Equatable {
    var rulesChanged: Int
    var rulesRemoved: Int
  }

  /// A rule that names the tag loses that action; a rule left with no action goes.
  static func deletion(of id: UUID, book: TagBook, rules: [Rule]) -> Deletion {
    guard let edit = book.deleting(id) else { return Deletion(rulesChanged: 0, rulesRemoved: 0) }
    let rewritten = edit.rewriting(rules)
    return Deletion(rulesChanged: rewritten.changed.count, rulesRemoved: rewritten.emptied.count)
  }
}
