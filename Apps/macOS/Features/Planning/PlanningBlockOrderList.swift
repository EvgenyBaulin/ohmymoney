import AppCore
import SwiftUI

/// The blocks of Planning in their order, moved by dragging a row onto the row whose place it
/// takes (`draggable` and `dropDestination`: the grouped form of macOS is drawn by SwiftUI, not
/// a table, and `onMove` would do nothing in it); VoiceOver moves a block by the actions «Выше»
/// and «Ниже» of its row. The same rows in «Настройки → Планирование» and under «Изменить» on
/// the Planning screen; every change is written at once (`PlanningLayoutStore`).
struct PlanningBlockOrderRows: View {
  @Dependency(\.environment) private var environment
  let layout: PlanningLayoutStore
  /// The row a dragged block is over: it is shaded where the block will land.
  @State private var targeted: PlanningBlock?

  var body: some View {
    ForEach(layout.order, id: \.self) { block in
      row(block)
        .background {
          if targeted == block {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
          }
        }
        .draggable(PlanningBlockOrderActions.payload(of: block)) {
          Label {
            Text(verbatim: PlanningBlockText.name(of: block, environment))
          } icon: {
            Image(systemName: PlanningBlockText.symbol(of: block))
          }
          .padding(6)
        }
        .dropDestination(for: String.self) { payloads, _ in
          guard let dragged = payloads.lazy.compactMap(PlanningBlockOrderActions.block).first
          else { return false }
          return layout.drop(dragged, onto: block)
        } isTargeted: { isTargeted in
          if isTargeted {
            targeted = block
          } else if targeted == block {
            targeted = nil
          }
        }
    }
  }

  private func row(_ block: PlanningBlock) -> some View {
    HStack(spacing: 8) {
      Label {
        Text(verbatim: PlanningBlockText.name(of: block, environment))
      } icon: {
        Image(systemName: PlanningBlockText.symbol(of: block))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Image(systemName: "line.3.horizontal")
        .foregroundStyle(.tertiary)
        .help(PlanningBlockText.t("layout.drag", environment))
        .accessibilityHidden(true)
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("planning.order.\(block.rawValue)")
    .accessibilityActions {
      ForEach([-1, 1].filter { layout.canMove(block, by: $0) }, id: \.self) { step in
        Button(PlanningBlockText.t(step < 0 ? "layout.moveUp" : "layout.moveDown", environment)) {
          layout.move(block, by: step)
        }
      }
    }
  }
}

/// What a dragged row carries, apart from the view so a test reads it.
enum PlanningBlockOrderActions {
  /// The block, marked as one, so text dragged in from elsewhere is never read as a block.
  static func payload(of block: PlanningBlock) -> String {
    payloadPrefix + block.rawValue
  }

  /// The block a dragged row carries; nil for anything else dropped on the list.
  static func block(_ payload: String) -> PlanningBlock? {
    guard payload.hasPrefix(payloadPrefix) else { return nil }
    return PlanningBlock(rawValue: String(payload.dropFirst(payloadPrefix.count)))
  }

  private static let payloadPrefix = "ohmymoney.planning.block:"
}

/// «Изменить» on the Planning screen: the rows of the order in a card, with «Как было» and
/// «Готово».
struct PlanningOrderEditor: View {
  @Dependency(\.environment) private var environment
  let layout: PlanningLayoutStore
  let done: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: PlanningBlockText.t("layout.edit.hint", environment))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 4) {
        PlanningBlockOrderRows(layout: layout)
      }
      HStack {
        Button(PlanningBlockText.t("layout.reset", environment)) { layout.resetOrder() }
          .disabled(PlanningBlocks.isStandard(layout.order))
        Spacer()
        Button(PlanningBlockText.t("layout.done", environment), action: done)
          .accessibilityIdentifier("planning.order.done")
      }
      .controlSize(.small)
    }
    .contentCard()
    .accessibilityIdentifier("planning.order")
  }
}
