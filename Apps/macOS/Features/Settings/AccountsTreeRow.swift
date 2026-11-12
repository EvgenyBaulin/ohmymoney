import AppCore
import SwiftUI

/// The measures of «Настройки → Счета» as the design draws them (Mac 68:18658, iPad 6:170097):
/// the tree 416 wide beside a panel of 276, 12 apart; a row 30 tall with 8 of margin and 4
/// between its parts — the mark 14 rounded 3, the handle 10, 12 of indent a level, the chevron
/// 10, the symbol 16, «+» 12 —; the chosen row on the accent's tint rounded 6; the panel 14 of
/// margin and 10 between its rows, the switches 44 × 26. Plain numbers, so a test holds them.
enum AccountsTreeMetrics {
  static let treeWidth: CGFloat = 416
  static let treeMinWidth: CGFloat = 300
  static let panelWidth: CGFloat = 276
  static let columnGap: CGFloat = 12
  static let searchHeight: CGFloat = 30
  static let searchRadius: CGFloat = 8
  /// Between the search and the tree.
  static let searchGap: CGFloat = 12
  /// The card of the tree: 7 inside its outline, radius 12.
  static let treeInset: CGFloat = 7
  static let cardRadius: CGFloat = 12
  static let rowHeight: CGFloat = 30
  static let rowPadding: CGFloat = 8
  static let rowGap: CGFloat = 4
  static let rowRadius: CGFloat = 6
  static let mark: CGFloat = 14
  static let markRadius: CGFloat = 3
  static let handle: CGFloat = 10
  static let indent: CGFloat = 12
  static let chevron: CGFloat = 10
  static let symbol: CGFloat = 16
  static let plus: CGFloat = 12
  /// The bar of the accounts picked: 44 tall, radius 8.
  static let barHeight: CGFloat = 44
  static let panelPadding: CGFloat = 14
  static let panelGap: CGFloat = 10
  static let switchSize = CGSize(width: 44, height: 26)
}

/// One row of the tree: the mark that picks it, the handle, the indent of its depth, the chevron
/// that folds it, its symbol, its name with what tells it apart, its money and «+».
struct AccountsTreeRow: View {
  let row: AccountsTree.Row
  let title: String
  /// Words after the name: «в сводке», «··4821 · основная», «2 счёта».
  let caption: String?
  /// A label on a capsule after the name: «кредитка», «чужая карта».
  let badge: (symbol: String, text: String)?
  /// The money, written; `nil`: none shown.
  let amount: String?
  /// The code of the currency after an account's money.
  let currency: String?
  let isChosen: Bool
  /// The mark: `nil` — the row picks nothing; else whether it is picked.
  let mark: Bool?
  let showsHandle: Bool
  let showsMarks: Bool
  /// What «+» adds: `nil` — no «+».
  let plusHelp: String?
  var toggleFold: () -> Void = {}
  var toggleMark: () -> Void = {}
  var plus: () -> Void = {}
  @Environment(\.appTheme) private var theme

  var body: some View {
    HStack(spacing: AccountsTreeMetrics.rowGap) {
      if showsMarks { markBox }
      if showsMarks || showsHandle { handle }
      if row.depth > 0 {
        Color.clear.frame(
          width: AccountsTreeMetrics.indent * CGFloat(row.depth), height: 1)
      }
      chevron
      Image(systemName: Self.symbol(of: row.node))
        .font(.system(size: AccountsTreeMetrics.symbol - 3))  // font-fixed: symbol in a 16 pt slot
        .foregroundStyle(isChosen ? theme.accentDefault : theme.contentPrimary)
        .frame(width: AccountsTreeMetrics.symbol, height: AccountsTreeMetrics.symbol)
        .accessibilityHidden(true)
      name
        .frame(maxWidth: .infinity, alignment: .leading)
      if let amount {
        Text(verbatim: amount)
          .appFont(AppFont.callout.weight(.medium).monospacedDigit())
          .foregroundStyle(Color(isChosen ? theme.palette.tintedCardText : theme.palette.cardText))
          .lineLimit(1)
          .fixedSize()
      }
      if let currency {
        Text(verbatim: currency)
          .appFont(.footnote)
          .foregroundStyle(theme.contentSecondary)
          .fixedSize()
      }
      if let plusHelp {
        Button(action: plus) {
          Image(systemName: "plus")
            .font(.system(size: AccountsTreeMetrics.plus, weight: .medium))  // font-fixed: 12 pt «+»
            .foregroundStyle(theme.accentDefault)
            .frame(width: AccountsTreeMetrics.plus, height: AccountsTreeMetrics.plus)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(plusHelp)
        .accessibilityLabel(Text(verbatim: plusHelp))
      }
    }
    .padding(.horizontal, AccountsTreeMetrics.rowPadding)
    .frame(height: AccountsTreeMetrics.rowHeight)
    .background(
      isChosen ? theme.accentTint : Color.clear,
      in: .rect(cornerRadius: AccountsTreeMetrics.rowRadius))
  }

  private var markBox: some View {
    Button(action: toggleMark) {
      let shape = RoundedRectangle(cornerRadius: AccountsTreeMetrics.markRadius)
      ZStack {
        if mark == true {
          shape.fill(theme.accentDefault)
          Image(systemName: "checkmark")
            .font(.system(size: 8, weight: .bold))  // font-fixed: tick in a 14 pt box
            .foregroundStyle(theme.contentOnAccent)
        } else {
          shape.strokeBorder(theme.borderOutline, lineWidth: 1)
        }
      }
      .frame(width: AccountsTreeMetrics.mark, height: AccountsTreeMetrics.mark)
      .opacity(mark == nil ? 0 : 1)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(mark == nil)
    .accessibilityHidden(mark == nil)
    .accessibilityLabel(Text(verbatim: title))
    .accessibilityAddTraits(mark == true ? [.isSelected] : [])
  }

  /// Three bars: the place a row is dragged by; accent on the chosen row.
  private var handle: some View {
    VStack(spacing: 2) {
      ForEach(0..<3, id: \.self) { _ in
        Capsule()
          .fill(isChosen ? theme.accentDefault : theme.contentSecondary)
          .frame(width: AccountsTreeMetrics.handle, height: 1.5)
      }
    }
    .frame(width: AccountsTreeMetrics.handle, height: AccountsTreeMetrics.handle)
    .opacity(showsHandle ? 1 : 0)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var chevron: some View {
    if row.isFolder {
      Button(action: toggleFold) {
        Image(systemName: row.isFolded ? "chevron.right" : "chevron.down")
          .font(.system(size: 8, weight: .semibold))  // font-fixed: chevron in a 10 pt slot
          .foregroundStyle(theme.contentSecondary)
          .frame(width: AccountsTreeMetrics.chevron, height: AccountsTreeMetrics.chevron)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
    } else {
      Color.clear.frame(width: AccountsTreeMetrics.chevron, height: 1)
    }
  }

  private var name: some View {
    HStack(spacing: 6) {
      Text(verbatim: title)
        .appFont(AppFont.callout.weight(Self.isHeading(row.node) ? .semibold : .medium))
        .foregroundStyle(theme.contentPrimary)
        .lineLimit(1)
      if let caption {
        Text(verbatim: caption)
          .appFont(.subheadline)
          .foregroundStyle(theme.contentSecondary)
          .lineLimit(1)
      }
      if let badge {
        HStack(spacing: 3) {
          Image(systemName: badge.symbol)
            .font(.system(size: 8))  // font-fixed: symbol of a 16 pt capsule
          Text(verbatim: badge.text)
            .appFont(.footnote)
        }
        .foregroundStyle(theme.accentContent)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(theme.accentTint, in: Capsule())
        .fixedSize()
      }
    }
  }

  /// A group, «Без группы», the hidden ones and the archive are headings: semibold.
  static func isHeading(_ node: AccountsTree.Node) -> Bool {
    switch node.kind {
    case .group, .noGroup, .hidden, .archive: true
    default: false
    }
  }

  /// The symbol of a row, as drawn: a grid for a group, columns for a bank, a wallet for an
  /// account, a card for a card or a card account.
  static func symbol(of node: AccountsTree.Node) -> String {
    switch node.kind {
    case .group, .noGroup, .hidden: "square.grid.2x2"
    case .archive, .archivedGroup, .archivedBank: "archivebox"
    case .bank: "building.columns"
    case .account(let account):
      account.credit != nil || account.isBorrowed ? "creditcard" : "wallet.bifold"
    case .card: "creditcard"
    }
  }
}
