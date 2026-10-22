import AppCore
import Observation
import SwiftUI

/// The state of the palette while it is open: what was typed, the lines it finds, the one the
/// keyboard stands on, and the last five commands run (kept on this Mac).
@MainActor
@Observable
final class CommandPaletteModel {
  var query = "" {
    didSet { if query != oldValue { refresh() } }
  }
  private(set) var results: [PaletteEntry] = []
  /// The line Return runs.
  private(set) var highlighted = 0
  private(set) var recents: PaletteRecents

  @ObservationIgnored private let index: PaletteIndex
  @ObservationIgnored private let defaults: UserDefaults

  init(entries: [PaletteEntry], defaults: UserDefaults = .standard) {
    index = PaletteIndex(entries)
    self.defaults = defaults
    recents = QuestionsStorage.loadRecents(defaults).keeping(existing: entries)
    refresh()
  }

  func refresh() {
    results = CommandPalette.search(query, in: index, recents: recents)
    highlighted = 0
  }

  /// ↓ and ↑: one line, stopping at the ends.
  func move(_ delta: Int) {
    guard !results.isEmpty else { return }
    highlighted = min(max(highlighted + delta, 0), results.count - 1)
  }

  func highlight(_ position: Int) {
    if results.indices.contains(position) { highlighted = position }
  }

  var chosen: PaletteEntry? {
    results.indices.contains(highlighted) ? results[highlighted] : nil
  }

  /// How many of the lines at the top are the recent ones: only while nothing is typed.
  var recentCount: Int {
    guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
    let recent = Set(recents.ids)
    return results.prefix { recent.contains($0.id) }.count
  }

  /// The line was run: it comes first the next time.
  func ran(_ entry: PaletteEntry) {
    recents = recents.recording(entry.id)
    QuestionsStorage.save(recents, defaults)
    refresh()
  }
}

/// ⌘K: a field and the lines it finds — commands, screens and the owner's accounts, debts,
/// goals, categories and people to open. A sheet on the Mac and on the phone alike; Return
/// runs the line the keyboard is on, ↑ and ↓ move it, Esc closes.
struct CommandPaletteView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.appTheme) private var theme
  @State private var model: CommandPaletteModel
  @FocusState private var focused: Bool
  let run: (PaletteEntry) -> Void
  let close: () -> Void

  init(
    entries: [PaletteEntry], run: @escaping (PaletteEntry) -> Void,
    close: @escaping () -> Void
  ) {
    _model = State(initialValue: CommandPaletteModel(entries: entries))
    self.run = run
    self.close = close
  }

  private func t(_ key: String) -> String { QuestionsText.t(key, environment) }

  var body: some View {
    VStack(spacing: 0) {
      field
      Divider()
      if model.results.isEmpty {
        Text(verbatim: t("questions.palette.empty"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(24)
          .accessibilityIdentifier("palette.empty")
      } else {
        results
      }
    }
    .sheetFrame(width: 520, height: 440)
    .background(surfaces.background)
    .onAppear { focused = true }
    .accessibilityIdentifier("palette")
  }

  private var field: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(text: $model.query, prompt: Text(verbatim: t("questions.palette.prompt"))) {
        Text(verbatim: t("questions.palette.title"))
      }
      .textFieldStyle(.plain)
      .appFont(.title3)
      .focused($focused)
      .onSubmit(runChosen)
      .onKeyPress(.downArrow) {
        model.move(1)
        return .handled
      }
      .onKeyPress(.upArrow) {
        model.move(-1)
        return .handled
      }
      .onKeyPress(.escape) {
        close()
        return .handled
      }
      .accessibilityIdentifier("palette.field")
      Button(environment.language("action.close"), action: close)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("palette.close")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
  }

  private var results: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(Array(model.results.enumerated()), id: \.element.id) { position, entry in
            if position == 0 && model.recentCount > 0 {
              header(t("questions.palette.recent"))
            } else if position == model.recentCount && model.recentCount > 0 {
              header(t("questions.palette.all"))
            }
            row(entry, position: position)
              .id(entry.id)
          }
        }
        .padding(8)
      }
      .onChange(of: model.highlighted) { _, position in
        guard model.results.indices.contains(position) else { return }
        proxy.scrollTo(model.results[position].id)
      }
    }
  }

  private func header(_ title: String) -> some View {
    Text(verbatim: title)
      .appFont(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.top, 8)
      .accessibilityAddTraits(.isHeader)
  }

  private func row(_ entry: PaletteEntry, position: Int) -> some View {
    let lit = position == model.highlighted
    return Button {
      model.highlight(position)
      runChosen()
    } label: {
      HStack(spacing: 10) {
        Image(systemName: QuestionsText.symbol(of: entry))
          .frame(width: 22)
          .foregroundStyle(lit ? surfaces.accent : surfaces.secondary)
          .accessibilityHidden(true)
        Text(verbatim: QuestionsText.title(of: entry, environment))
          .appFont(.body)
          .foregroundStyle(surfaces.primary)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(verbatim: QuestionsText.kindName(entry.kind, environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        lit ? Color(theme.palette.accentTint) : Color.clear, in: .rect(cornerRadius: 8)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(lit ? [.isSelected] : [])
    .accessibilityIdentifier("palette.row.\(entry.id)")
  }

  private func runChosen() {
    guard let entry = model.chosen else { return }
    model.ran(entry)
    run(entry)
  }
}
