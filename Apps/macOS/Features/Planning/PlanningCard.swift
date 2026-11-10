import AppCore
import SwiftUI

extension EnvironmentValues {
  /// The block stands inside a card of the Planning screen, which draws its title, total and
  /// controls: the block draws its body alone, without a title and a card of its own.
  @Entry var planningCardHosted: Bool = false
}

/// A card of the Planning screen, as the design draws it: 16 inside a 1 pt hairline, 8 between
/// its rows; a header of the block's symbol in the accent, its title in 15 semibold, the total,
/// «все» to the block's own tab, the menu of how many items a long block shows and the chevron
/// that collapses it; below, the block. Content, never glass. Collapsing is a look of this
/// window only, never kept: every launch opens every block.
struct PlanningCard<Content: View>: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  @Environment(\.windowWidth) private var windowWidth
  let block: PlanningBlock
  /// The total of the header, or nothing to add up.
  let total: String?
  let layout: PlanningLayoutStore
  @Binding var collapsed: Bool
  /// «все»: the block alone on its tab; nil where the card already stands alone or has no tab.
  var showAll: (() -> Void)?
  @ViewBuilder let content: () -> Content

  var body: some View {
    let compact = ScreenWidth.isCompact(windowWidth)
    VStack(alignment: .leading, spacing: PlanningMetrics.cardGap(compact: compact)) {
      header
      if !collapsed {
        content()
          .environment(\.planningCardHosted, true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(PlanningMetrics.cardInset(compact: compact) + PlanningMetrics.cardEdge)
    .planningCardSurface()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: PlanningBlockText.name(of: block, environment)))
    .accessibilityIdentifier("planning.card.\(block.rawValue)")
  }

  private var header: some View {
    // The design's header is the symbol, the title and «все»; the total and the controls that
    // fold the card or set its length sit at the end, small and secondary, and on a touch
    // device the length menu moves into a long press of the title.
    HStack(alignment: .center, spacing: PlanningMetrics.headerIconGap) {
      Image(systemName: PlanningBlockText.symbol(of: block))
        .appFont(.callout.weight(.semibold))
        .foregroundStyle(theme.accentDefault)
        .frame(width: PlanningMetrics.headerIcon, height: PlanningMetrics.headerIcon)
        .accessibilityHidden(true)
      Text(verbatim: PlanningBlockText.name(of: block, environment))
        .appFont(PlanningType.cardTitle)
        .foregroundStyle(theme.contentPrimary)
        .lineLimit(2)
        // The title keeps its words whole; the total gives way first on a narrow card.
        .layoutPriority(1)
        .accessibilityAddTraits(.isHeader)
        .contextMenu {
          if block.hasShortList { PlanningLengthChoices(block: block, layout: layout) }
        }
      Spacer(minLength: 8)
      if let total {
        Text(verbatim: total)
          .appFont(PlanningType.cardLink.monospacedDigit())
          .foregroundStyle(theme.contentSecondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .accessibilityIdentifier("planning.card.\(block.rawValue).total")
      }
      if let showAll {
        Button(action: showAll) {
          Text(verbatim: PlanningBlockText.t("layout.card.all", environment))
            .appFont(PlanningType.cardLink)
            .foregroundStyle(theme.accentContent)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier("planning.card.\(block.rawValue).all")
      }
      #if os(macOS)
        if block.hasShortList {
          PlanningLengthMenu(block: block, layout: layout)
        }
      #endif
      Button {
        collapsed.toggle()
      } label: {
        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
          .appFont(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 14)
      }
      .buttonStyle(.borderless)
      .help(PlanningBlockText.t(collapsed ? "layout.expand" : "layout.collapse", environment))
      .accessibilityLabel(
        Text(
          verbatim: PlanningBlockText.t(
            collapsed ? "layout.expand" : "layout.collapse", environment)
        )
      )
      .accessibilityIdentifier("planning.card.\(block.rawValue).collapse")
    }
  }
}

/// The menu in the header of a long block: «Как в настройках (5)», 3, 5, 10, «Все» — the
/// block's own number of items, which wins over the one of the settings.
struct PlanningLengthMenu: View {
  @Dependency(\.environment) private var environment
  let block: PlanningBlock
  let layout: PlanningLayoutStore

  var body: some View {
    Menu {
      PlanningLengthChoices(block: block, layout: layout)
    } label: {
      Image(systemName: "list.number")
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(PlanningBlockText.t("layout.length", environment))
    .accessibilityLabel(Text(verbatim: PlanningBlockText.t("layout.length", environment)))
    .accessibilityIdentifier("planning.card.\(block.rawValue).length")
  }

}

/// The choices of the length of a block, as an inline picker: in the menu of the card's header
/// and, on a touch device, in the menu of a long press of its title.
struct PlanningLengthChoices: View {
  @Dependency(\.environment) private var environment
  let block: PlanningBlock
  let layout: PlanningLayoutStore

  var body: some View {
    Picker(
      selection: Binding(
        get: { layout.ownLength(of: block).map(Choice.own) ?? .global },
        set: { choice in
          switch choice {
          case .global: layout.setOwnLength(nil, for: block)
          case .own(let length): layout.setOwnLength(length, for: block)
          }
        })
    ) {
      Text(verbatim: PlanningBlockText.globalLengthTitle(layout.length, environment))
        .tag(Choice.global)
      ForEach(PlanningListLength.choices, id: \.self) { length in
        Text(verbatim: PlanningBlockText.lengthTitle(length, environment))
          .tag(Choice.own(length))
      }
    } label: {
      Text(verbatim: PlanningBlockText.t("layout.length", environment))
    }
    .pickerStyle(.inline)
  }

  enum Choice: Hashable {
    case global
    case own(PlanningListLength)
  }
}

/// The hint of an empty block: a sentence of what the block is for, and the button that adds
/// the first item.
struct PlanningEmptyHint: View {
  @Dependency(\.environment) private var environment
  let block: PlanningBlock
  let action: () -> Void

  var body: some View {
    if let hint = PlanningBlockText.emptyHint(of: block) {
      VStack(alignment: .leading, spacing: 8) {
        Text(verbatim: PlanningBlockText.t(hint.text, environment))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button(PlanningBlockText.t(hint.button, environment), action: action)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("planning.empty.\(block.rawValue)")
      }
    }
  }
}

/// «Показать все (12)» under the nearest items of a long block, and «Свернуть» once it is opened.
struct PlanningShowAllButton: View {
  @Dependency(\.environment) private var environment
  let block: PlanningBlock
  let total: Int
  let hidden: Int
  @Binding var expanded: Bool

  var body: some View {
    if expanded || hidden > 0 {
      Button {
        expanded.toggle()
      } label: {
        Text(
          verbatim: expanded
            ? PlanningBlockText.t("layout.showLess", environment)
            : environment.format("layout.showAll", table: "Planning", counts: total))
      }
      .buttonStyle(.link)
      .appFont(.callout)
      .accessibilityIdentifier("planning.showAll.\(block.rawValue)")
    }
  }
}

/// What a long block shows of its items: the nearest first, as many as its length says, unless
/// it is opened out.
enum PlanningShortListView {
  static func shown<Item>(
    _ items: [Item], length: PlanningListLength, expanded: Bool, date: (Item) -> DateOnly?
  ) -> (items: [Item], hidden: Int) {
    let nearest = PlanningShortList.nearestFirst(items, date: date)
    let split = PlanningShortList.split(total: nearest.count, length: length, expanded: expanded)
    return (Array(nearest.prefix(split.shown)), split.hidden)
  }
}
