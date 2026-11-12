import AppCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → «Приватность» → «Сообщения банков» → «Форматы СМС»: the formats the owner keeps,
/// the ones proposed from texts he corrected, the folder of formats he chose (read, never
/// shipped or downloaded), the files skipped with the reason, and the question of two formats
/// that fit one text. Lists only — the texts themselves are never shown or kept.
struct AutoEntryFormatsView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss

  @State private var own = OwnSmsFormats()
  @State private var offers: [OwnSmsFormats.Item] = []
  @State private var conflicts: [[String]] = []
  @State private var contents = SmsFolderContents()
  @State private var hasFolder = false
  @State private var picksFolder = false
  @State private var refused: [String: [SmsFormatProblem]] = [:]

  private var words: AutoEntryWords { AutoEntryWords(environment: environment) }

  var body: some View {
    NavigationStack {
      List {
        folderSection
        if !contents.skipped.isEmpty { skippedSection }
        if !conflicts.isEmpty { conflictsSection }
        if !offers.isEmpty { offersSection }
        ownSection
      }
      .navigationTitle(words.t("autoEntry.formats.title"))
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(words.t("autoEntry.formats.done")) { dismiss() }
            .accessibilityIdentifier("settings.autoEntry.formats.done")
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 520, minHeight: 560)
    #endif
    .onAppear(perform: load)
    .fileImporter(isPresented: $picksFolder, allowedContentTypes: [.folder]) { result in
      guard case .success(let url) = result else { return }
      contents = AutoEntryFormats.chooseFolder(url)
      hasFolder = AutoEntryFormats.folder.isStored
    }
  }

  private func load() {
    own = AutoEntryFormats.own(environment)
    offers = AutoEntryFormats.offers()
    conflicts = AutoEntryFormats.conflicts()
    contents = AutoEntryFormats.folderContents
    hasFolder = AutoEntryFormats.folder.isStored
  }

  // MARK: Folder

  private var folderSection: some View {
    Section {
      if hasFolder {
        Text(
          verbatim: words.f(
            "autoEntry.formats.folder.summary", contents.bankCount, contents.entries.count,
            contents.categories.count)
        )
        .appFont(.callout)
        Button(words.t("autoEntry.formats.folder.reload")) {
          contents = AutoEntryFormats.reloadFolder()
        }
        .accessibilityIdentifier("settings.autoEntry.formats.reload")
        Button(words.t("autoEntry.formats.folder.forget"), role: .destructive) {
          AutoEntryFormats.forgetFolder()
          contents = SmsFolderContents()
          hasFolder = false
        }
        .accessibilityIdentifier("settings.autoEntry.formats.forget")
      }
      Button(words.t("autoEntry.formats.folder.choose")) { picksFolder = true }
        .accessibilityIdentifier("settings.autoEntry.formats.choose")
    } header: {
      Text(verbatim: words.t("autoEntry.formats.folder.header")).settingsHeaderStyle()
    } footer: {
      Text(verbatim: words.t("autoEntry.formats.folder.footer"))
        .appFont(.callout).foregroundStyle(.secondary)
    }
  }

  private var skippedSection: some View {
    Section {
      ForEach(contents.skipped) { skip in
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: skip.path).appFont(.callout)
          ForEach(Array(skip.problems.enumerated()), id: \.offset) { _, problem in
            Text(verbatim: reason(problem)).appFont(.caption).foregroundStyle(.secondary)
          }
        }
        .accessibilityElement(children: .combine)
      }
    } header: {
      Text(verbatim: words.t("autoEntry.formats.skipped.header")).settingsHeaderStyle()
    }
  }

  // MARK: Conflicts

  private var conflictsSection: some View {
    Section {
      ForEach(conflicts, id: \.self) { ids in
        VStack(alignment: .leading, spacing: 4) {
          ForEach(ids, id: \.self) { id in
            Button {
              AutoEntryFormats.resolveConflict(ids, pick: id, environment: environment)
              conflicts = AutoEntryFormats.conflicts()
            } label: {
              Text(verbatim: words.f("autoEntry.formats.conflicts.use", id))
            }
          }
        }
      }
    } header: {
      Text(verbatim: words.t("autoEntry.formats.conflicts.header")).settingsHeaderStyle()
    } footer: {
      Text(verbatim: words.t("autoEntry.formats.conflicts.footer"))
        .appFont(.callout).foregroundStyle(.secondary)
    }
  }

  // MARK: Proposed

  private var offersSection: some View {
    Section {
      ForEach(offers) { item in
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: example(of: item)).appFont(.callout)
          if let problems = refused[item.id] {
            Text(
              verbatim: words.f(
                "autoEntry.formats.offer.problem", problems.map(reason).joined(separator: "; "))
            )
            .appFont(.caption).foregroundStyle(.secondary)
          }
          HStack {
            Button(words.t("autoEntry.formats.offer.save")) {
              let problems = AutoEntryFormats.accept(item, environment: environment)
              if !problems.isEmpty { refused[item.id] = problems }
              load()
            }
            Button(words.t("autoEntry.formats.offer.dismiss"), role: .cancel) {
              AutoEntryFormats.dismiss(item)
              load()
            }
          }
        }
      }
    } header: {
      Text(verbatim: words.t("autoEntry.formats.offers.header")).settingsHeaderStyle()
    } footer: {
      Text(verbatim: words.t("autoEntry.formats.offers.footer"))
        .appFont(.callout).foregroundStyle(.secondary)
    }
  }

  // MARK: Own

  private var ownSection: some View {
    Section {
      if own.items.isEmpty {
        Text(verbatim: words.t("autoEntry.formats.own.empty")).foregroundStyle(.secondary)
      }
      ForEach(own.items) { item in
        HStack {
          Text(verbatim: example(of: item)).appFont(.callout)
          Spacer(minLength: 8)
          Button(words.t("autoEntry.formats.own.delete"), role: .destructive) {
            var kept = own
            kept.remove(id: item.id)
            AutoEntryFormats.save(kept, environment: environment)
            own = kept
          }
        }
      }
    } header: {
      Text(verbatim: words.t("autoEntry.formats.own.header")).settingsHeaderStyle()
    }
  }

  // MARK: Words

  /// The made-up example of a format: all that is shown of it.
  private func example(of item: OwnSmsFormats.Item) -> String {
    if case .success(let format) = SmsFormat.parse(fileText: item.text, id: item.id),
      let first = format.examples.first
    {
      return first
    }
    return item.id
  }

  private func reason(_ problem: SmsFormatProblem) -> String {
    let format = words.t(problem.key)
    return String(
      format: format, locale: environment.language.locale,
      arguments: problem.arguments.map { $0 as CVarArg })
  }
}
