import AppCore
import SwiftUI

/// What the round mark in front of an operation shows: a line symbol and the theme's tint for
/// the kind of the row. Income is a plus, spending an arrow down, a transfer the two arrows;
/// the amount beside it carries the sign, so the tint only helps the eye and never alone.
enum OperationBadgeKind: Equatable, Sendable {
  case income, expense, refund, moneyBack, transfer

  init(_ item: TransactionRowItem) {
    if item.isTransfer {
      self = .transfer
      return
    }
    switch item.kind {
    case .income: self = .income
    case .expense: self = .expense
    case .refund: self = .refund
    case .reimbursement: self = .moneyBack
    }
  }

  var symbol: String {
    switch self {
    case .income: "plus"
    case .expense: "arrow.down"
    case .refund: "arrow.uturn.left"
    case .moneyBack: "person.crop.circle.badge.checkmark"
    case .transfer: "arrow.left.arrow.right"
    }
  }
}

/// The round mark of a row: 28 pt, the symbol in the tint's own colour. Content, never glass.
struct OperationBadge: View {
  @Environment(\.appTheme) private var theme
  @ScaledMetric(relativeTo: .body) private var side: CGFloat = 28
  let kind: OperationBadgeKind

  var body: some View {
    let palette = theme.palette
    Image(systemName: kind.symbol)
      .appFont(.caption.weight(.semibold))
      .foregroundStyle(foreground(palette))
      .frame(width: side, height: side)
      .background(tint(palette), in: .circle)
      .accessibilityHidden(true)
  }

  private func tint(_ palette: ThemePalette) -> Color {
    switch kind {
    case .income: Color(palette.statusPositiveTint)
    case .expense: Color(palette.accentTint)
    case .refund: Color(palette.chart2Tint)
    case .moneyBack: Color(palette.chart3Tint)
    case .transfer: Color(palette.contentSecondaryTint)
    }
  }

  private func foreground(_ palette: ThemePalette) -> Color {
    switch kind {
    case .income: Color(palette.statusPositive)
    case .expense: Color(palette.accentDefault)
    case .refund: Color(palette.chart2)
    case .moneyBack: Color(palette.chart3)
    case .transfer: Color(palette.contentSecondary)
    }
  }
}

/// The sign in front of an amount in the table: spending takes «−» (U+2212), what comes in —
/// income, a refund, money given back — «+»; a transfer and a part of a split carry none.
/// With the sign the direction is in the text, so the green of income is only a help.
enum OperationAmountSign {
  static func prefix(kind: TransactionKind, isTransfer: Bool, isPart: Bool) -> String {
    guard !isTransfer, !isPart else { return "" }
    switch kind {
    case .expense: return "\u{2212}"
    case .income, .refund, .reimbursement: return "+"
    }
  }
}
