import AppCore
import SwiftUI

/// The stripe of a payment of a debt, and of the debt as a whole, on the phone and the tablet:
/// light green for an extra payment, yellow for a standard one, red for a late one. The colour
/// comes from the theme (`debtStripeExtra`, …); a symbol and a spoken label say the same, so the
/// colour is never alone. The Mac does not show it.
extension DebtPaymentMark {
  /// Whether this platform draws the stripes.
  static var isShown: Bool {
    #if os(iOS)
      true
    #else
      false
    #endif
  }

  var symbol: String {
    switch self {
    case .extra: "plus.circle"
    case .regular: "calendar.badge.checkmark"
    case .overdue: "exclamationmark.triangle"
    }
  }

  /// The label of one payment: «Дополнительный платёж», «Платёж по графику», «Платёж с просрочкой».
  var paymentKey: String { "debts.stripe.payment.\(rawValue)" }

  /// The label of a whole debt: «Были дополнительные платежи», «Платежи по графику», «Были просрочки».
  var debtKey: String { "debts.stripe.debt.\(rawValue)" }

  func color(in theme: AppThemeColors) -> Color {
    switch self {
    case .extra: theme.debtStripeExtra
    case .regular: theme.debtStripeRegular
    case .overdue: theme.debtStripeOverdue
    }
  }
}

enum DebtStripeMetrics {
  /// The bar: 4 wide, as high as a line of text.
  static let barWidth: CGFloat = 4
  static let barHeight: CGFloat = 18
  static let gap: CGFloat = 4
}

/// A bar in the colour of the mark with its symbol beside it; the pair is one element for
/// VoiceOver, spoken as `key`.
struct DebtStripeMark: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let mark: DebtPaymentMark
  /// `mark.paymentKey` or `mark.debtKey`.
  let key: String

  var body: some View {
    HStack(spacing: DebtStripeMetrics.gap) {
      Capsule().fill(mark.color(in: theme))
        .frame(width: DebtStripeMetrics.barWidth, height: DebtStripeMetrics.barHeight)
      Image(systemName: mark.symbol)
        .appFont(.caption).foregroundStyle(theme.contentSecondary)
    }
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: environment.language(key, table: "Debts")))
    .accessibilityIdentifier("debts.stripe.\(mark.rawValue)")
  }
}

/// The long bar of a debt card, along its leading edge inside the padding.
struct DebtStripeEdge: View {
  @Environment(\.appTheme) private var theme
  let mark: DebtPaymentMark
  let padding: CGFloat

  var body: some View {
    Capsule().fill(mark.color(in: theme))
      .frame(width: DebtStripeMetrics.barWidth)
      .padding(.vertical, padding)
      .padding(.leading, (padding - DebtStripeMetrics.barWidth) / 2)
      .accessibilityHidden(true)
  }
}

/// The symbol of a debt card's stripe, spoken as `key`; the bar itself is `DebtStripeEdge`.
struct DebtStripeSymbol: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let mark: DebtPaymentMark
  let key: String

  var body: some View {
    Image(systemName: mark.symbol)
      .appFont(.caption).foregroundStyle(theme.contentSecondary)
      .accessibilityLabel(Text(verbatim: environment.language(key, table: "Debts")))
      .accessibilityIdentifier("debts.stripe.\(mark.rawValue)")
  }
}
