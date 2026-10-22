import AppCore
import SwiftUI

/// The quick filters under the title of «Операции»: «Все», «Расходы», «Доходы» choose the type,
/// «Сегодня» the day. They set the same filters the popover edits — nothing of their own — so
/// the popover, the count on its button and «Сбросить» agree with them.
enum OperationsQuickFilter: String, CaseIterable, Identifiable, Sendable {
  case all, expenses, income, today

  var id: String { rawValue }

  var titleKey: String { "operations.chip.\(rawValue)" }

  /// The type each of the first three chooses; «Сегодня» chooses none.
  private var kind: TransactionKind? {
    switch self {
    case .expenses: .expense
    case .income: .income
    case .all, .today: nil
    }
  }

  func isActive(in filters: TransactionFilters, today: DateOnly) -> Bool {
    switch self {
    case .all: filters.kind == nil
    case .expenses, .income: filters.kind == kind
    case .today:
      filters.period == .custom && filters.customStart == today && filters.customEnd == today
    }
  }

  /// Chooses the chip. A type chip replaces the type; «Сегодня» turns the day on and, pressed
  /// again, goes back to the whole history.
  func apply(to filters: inout TransactionFilters, tree: [CoreKit.Category], today: DateOnly) {
    switch self {
    case .all, .expenses, .income:
      filters.setKind(kind, tree: tree)
    case .today:
      if isActive(in: filters, today: today) {
        filters.period = .allTime
      } else {
        filters.customStart = today
        filters.customEnd = today
        filters.period = .custom
      }
    }
  }
}

/// A row of capsule chips; the chosen one stands on the accent tint, in the accent's content
/// colour and a heavier weight, and says «selected» to VoiceOver — not the colour alone.
struct QuickFilterChips: View {
  @Environment(\.appTheme) private var theme
  let chips: [OperationsQuickFilter]
  let isActive: (OperationsQuickFilter) -> Bool
  let title: (OperationsQuickFilter) -> String
  let choose: (OperationsQuickFilter) -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(chips) { chip in
        let active = isActive(chip)
        Button {
          choose(chip)
        } label: {
          Text(verbatim: title(chip))
            .appFont(.callout.weight(active ? .semibold : .regular))
            .foregroundStyle(
              active ? Color(theme.palette.accentContent) : Color(theme.palette.contentPrimary)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
              active ? Color(theme.palette.accentTint) : Color(theme.palette.surfaceCard),
              in: .capsule
            )
            .overlay {
              Capsule().strokeBorder(Color(theme.palette.borderCard), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .accessibilityIdentifier("operations.chip.\(chip.rawValue)")
      }
    }
  }
}
