import AppCore
import SwiftUI

/// The limits of the month in the one order of the lists of limits (`LimitLists`) — over the
/// limit, then close to it, then by the share spent — at most three, each with its amounts, a
/// bar of what is spent and its status as a symbol and a word; then how many more there are in
/// Planning. While a limit is over, the title names it and a label counts how many are
/// (`LimitsTile`).
struct LimitsCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.appTheme) private var theme
  @Environment(\.layoutIdiom) private var idiom

  var body: some View {
    let tile = compute.states.data.value.map { self.tile($0) }
    ComputedBlock(
      title: tile?.title ?? OverviewTileText.name(of: .limits, environment),
      state: compute.states.data,
      fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let tile = self.tile(snapshot)
      if tile.rows.isEmpty, tile.footer == nil {
        VStack(alignment: .leading, spacing: StyleMetrics.tileGap) {
          Text(verbatim: t("overview.limitsNone"))
            .appFont(StyleType.tileRow)
            .foregroundStyle(surfaces.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button(t("overview.limitsOpen"), action: openPlanning)
            .buttonStyle(.link)
            .appFont(StyleType.tileHint)
        }
      } else {
        VStack(alignment: .leading, spacing: StyleMetrics.tileGap) {
          if let label = tile.overLabel {
            StatusLabel(tone: .bad, text: label)
          }
          ForEach(Array(tile.rows.enumerated()), id: \.offset) { _, row in
            LimitTileRow(
              row: row, barWidth: StyleMetrics.limitBarWidth(LayoutIdiom.resolved(idiom)))
          }
          if let footer = tile.footer {
            Button(action: openPlanning) {
              Text(verbatim: footer)
                .appFont(StyleType.tileHint)
                .foregroundStyle(theme.accentContent)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isLink)
          }
        }
      }
    }
  }

  private func tile(_ snapshot: DataSnapshot) -> LimitsTile {
    let lines = Self.lines(snapshot, environment)
    return LimitsTile.make(
      shown: lines.shown, rest: lines.rest,
      names: { PlanningText.limitName($0.budget, tree: snapshot.ledger.tree, environment) },
      environment)
  }

  /// The most the card lists, whatever Planning shows: the three limits closest to running out
  /// (the owner's answer) — the rest are in Planning, and the card shares a row of Overview with
  /// others, which would grow with every line.
  static let most = 3

  /// The limits the card lists — the top of the one order, as many as Planning shows, `most`
  /// at most — and the ones after them.
  static func lines(
    _ snapshot: DataSnapshot, _ environment: AppEnvironment
  ) -> (shown: [LimitLine], rest: [LimitLine]) {
    let all = LimitLists.ranked(snapshot, environment, all: true).shown
    let count = max(min(snapshot.planning.book.settings.limitsTopN ?? most, most), 0)
    return (Array(all.prefix(count)), Array(all.dropFirst(count)))
  }

  private func openPlanning() {
    NotificationCenter.default.post(
      name: .selectSection, object: MainWindow.Section.planning.shortcutIndex)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// A limit on a tile: its name and «spent / available», under them a bar in the colour of its
/// status and the status as a symbol and a word — the words carry it, the colour repeats it.
struct LimitTileRow: View {
  @Environment(\.appTheme) private var theme
  let row: LimitsTile.Row
  let barWidth: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: StyleMetrics.limitBarGap) {
      TileFigureRow(label: row.name, figure: row.amounts)
      HStack(spacing: StyleMetrics.limitStatusGap) {
        TileBar(fillBp: row.fillBp, ink: Self.ink(row.status, theme))
          .frame(maxWidth: barWidth)
        HStack(spacing: StyleMetrics.tileInlineGap) {
          Image(systemName: LimitsTile.symbol(row.status))
            .appFont(StyleType.tileHintMedium)
            .foregroundStyle(Self.ink(row.status, theme))
            .frame(width: StyleMetrics.tileIcon, height: StyleMetrics.tileIcon)
            .accessibilityHidden(true)
          Text(verbatim: row.statusWord)
            .appFont(StyleType.tileHintMedium)
            .foregroundStyle(Self.textInk(row.status, theme))
            .lineLimit(1)
        }
        .fixedSize()
      }
    }
    // Keep the decorative bar out of the text's AX bounds: a combined StaticText rectangle
    // included the bar's pixels in the contrast audit even though the bar is AX-hidden.
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: row.name))
  }

  /// The bar and the symbol: red over the limit, the warning ink close to it, green within.
  static func ink(_ status: LimitStatus, _ theme: AppThemeColors) -> Color {
    switch status {
    case .over: theme.statusNegative
    case .warning: theme.contentWarning
    case .ok: theme.statusPositive
    }
  }

  static func textInk(_ status: LimitStatus, _ theme: AppThemeColors) -> Color {
    Color(textColor(status, theme.palette))
  }

  /// The status word's ink as plain bytes: the status colour, moved only as far as 4.5 : 1 on
  /// the card needs.
  static func textColor(_ status: LimitStatus, _ palette: ThemePalette) -> ThemeColor {
    let ink: ThemeColor =
      switch status {
      case .over: palette.statusNegative
      case .warning: palette.contentWarning
      case .ok: palette.contentPrimary
      }
    return ink.ensuringTextContrast(on: palette.surfaceCard)
  }
}

/// One limit: its status as a symbol and a word — never colour alone — its name and
/// «spent / available». Given `editing`, the amount is a button that turns into a field in
/// place: Enter saves (one step of ⌘Z), Esc or leaving the field puts it back.
struct LimitStatusLine: View {
  @Dependency(\.environment) private var environment
  let line: LimitLine
  let tree: CategoryTree
  var editing: LimitAmountEditing?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: PlanningText.statusSymbol(line.status))
        .foregroundStyle(PlanningText.statusTint(line.status))
        .accessibilityHidden(true)
      // The status in words too, never by colour and symbol alone. In a narrow card the name
      // goes on to a second line rather than being cut down to the status word.
      Text(verbatim: "\(PlanningText.statusWord(line.status, environment)): \(name)")
        .lineLimit(2)
      Spacer(minLength: 6)
      // The amounts are never wrapped: a long name gives way and is cut short instead.
      Group {
        if let editing {
          LimitAmountField(line: line, name: name, editing: editing)
        } else {
          Text(
            verbatim:
              "\(environment.money.rounded(line.spent)) / \(environment.money.rounded(line.available))"
          )
          .monospacedDigit()
        }
      }
      .fixedSize()
    }
    .appFont(.callout)
    // Read as one line, unless there is a button in it to reach.
    .accessibilityElement(children: editing == nil ? .combine : .contain)
  }

  private var name: String { PlanningText.limitName(line.budget, tree: tree, environment) }
}

/// «spent / available» with the available amount as a button; clicked, a field with the
/// limit's monthly amount — what a new amount replaces, the carry aside.
private struct LimitAmountField: View {
  @Dependency(\.environment) private var environment
  let line: LimitLine
  let name: String
  let editing: LimitAmountEditing
  @State private var text = ""
  @FocusState private var focused: Bool

  private var isEditing: Bool { editing.editing.wrappedValue == line.budget.id }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(verbatim: "\(environment.money.rounded(line.spent)) /")
        .monospacedDigit()
      if isEditing {
        TextField(text: $text) {
          Text(verbatim: t("limits.amount.placeholder"))
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .appFont(.callout.monospacedDigit())
        .frame(width: 104)
        .focused($focused)
        .accessibilityIdentifier("limits.amount.field")
        .onAppear {
          text = AmountField.text(for: line.amount)
          editing.refusal.wrappedValue = nil
          Task { @MainActor in focused = true }
        }
        .onSubmit(commit)
        .onExitCommand(perform: close)
        .onChange(of: focused) { _, now in
          if !now { close() }
        }
      } else {
        Button {
          editing.refusal.wrappedValue = nil
          editing.editing.wrappedValue = line.budget.id
        } label: {
          Text(verbatim: environment.money.rounded(line.available))
            .monospacedDigit()
            .underline(pattern: .dot)
        }
        .buttonStyle(.plain)
        .help(t("limits.amount.help"))
        .accessibilityLabel(environment.format("limits.amount.edit", table: "Planning", name))
        .accessibilityIdentifier("limits.amount")
      }
    }
  }

  /// Enter: the write lands and the field closes, or the refusal is said under the line and
  /// the field stays with what was typed.
  private func commit() {
    if let refusal = editing.save(line.budget, text) {
      editing.refusal.wrappedValue = refusal
    } else {
      close()
    }
  }

  private func close() {
    guard isEditing else { return }
    editing.refusal.wrappedValue = nil
    editing.editing.wrappedValue = nil
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
