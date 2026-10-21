import AppCore
import SwiftUI

extension EnvironmentValues {
  /// The block stands inside a card of the Planning screen, which draws its title, total and
  /// controls: the block draws its body alone, without a title and a card of its own.
  @Entry var planningCardHosted: Bool = false
}

/// A card of the Planning screen: a header with the block's symbol, title and total, the menu
/// of how many items a long block shows and the chevron that collapses it; below, the block.
/// Content, never glass. Collapsing is a look of this window only, never kept: every launch
/// opens every block.
struct PlanningCard<Content: View>: View {
  @Dependency(\.environment) private var environment
  let block: PlanningBlock
  /// The total of the header, or nothing to add up.
  let total: String?
  let layout: PlanningLayoutStore
  @Binding var collapsed: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      if !collapsed {
        content()
          .environment(\.planningCardHosted, true)
      }
    }
    .contentCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: PlanningBlockText.name(of: block, environment)))
    .accessibilityIdentifier("planning.card.\(block.rawValue)")
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Label {
        Text(verbatim: PlanningBlockText.name(of: block, environment))
          .appFont(.headline)
          .lineLimit(2)
      } icon: {
        Image(systemName: PlanningBlockText.symbol(of: block))
          .foregroundStyle(.secondary)
      }
      .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      if let total {
        Text(verbatim: total)
          .appFont(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .accessibilityIdentifier("planning.card.\(block.rawValue).total")
      }
      if block.hasShortList {
        PlanningLengthMenu(block: block, layout: layout)
      }
      Button {
        collapsed.toggle()
      } label: {
        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
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
