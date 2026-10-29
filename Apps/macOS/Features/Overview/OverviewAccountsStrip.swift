import AppCore
import SwiftUI

/// «Счета · Все» and the cards of the accounts side by side, as the phone design draws them
/// under the hero: 230 × 112 cards on the gradients of the theme's chart colours, scrolled
/// across. A tap on a card opens the account, «Все» the list of accounts. Content, never glass;
/// the words carry the meaning, the colour only tells the cards apart.
struct OverviewAccountsStrip: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces

  static let cardSize = CGSize(width: 230, height: 112)

  /// The strip stands on the phone and the tablet; the Mac has the accounts in its sidebar.
  static var shows: Bool {
    #if os(iOS)
      true
    #else
      false
    #endif
  }

  /// The colours of the cards, one after another; the accent first.
  private var tints: [Color] {
    [theme.accentDefault, theme.chart2, theme.chart3, theme.chart6, theme.chart4, theme.chart7]
  }

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  var body: some View {
    let lines = Self.lines(compute.snapshot?.planning.accounts, environment: environment)
    if !lines.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: t("accounts.section.accounts"))
            .appFont(.subheadline.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 8)
          Button {
            NotificationCenter.default.post(name: .openSidebarItem, object: SidebarItem.allAccounts)
          } label: {
            Text(verbatim: environment.language("overview.accounts.all", table: "Overview"))
              .appFont(.footnote.weight(.medium))
              .foregroundStyle(surfaces.accent)
              .frame(minHeight: 44, alignment: .trailing)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("overview.accounts.all")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, -12)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
              card(line, tint: line.accent?.swatch ?? tints[index % tints.count])
            }
          }
          .padding(.vertical, 8)
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("overview.accounts.strip")
      }
    }
  }

  /// What a card says.
  struct Line: Identifiable, Equatable {
    let id: UUID
    let title: String
    let isMain: Bool
    let caption: String
    let figure: String
    /// The colour the owner gave the account; the card is painted in it.
    var accent: AccountAccent? = nil
  }

  /// The live accounts of the summary in the owner's order, one card each.
  @MainActor
  static func lines(_ accounts: AccountsSnapshot?, environment: AppEnvironment) -> [Line] {
    guard let accounts else { return [] }
    let ordered = accounts.ordered(locale: environment.language.locale)
    return ordered.sections.filter(\.inSummary).flatMap(\.accounts).map { line in
      let figure = SidebarFigure.of(
        line, money: environment.money,
        words: { environment.language($0, table: AccountText.table) },
        withoutRate: {
          environment.format("sidebar.withoutRate", table: AccountText.table, $0)
        })
      var card = Line(
        id: line.account.id, title: line.account.name, isMain: line.account.isDefault,
        caption: line.account.isDefault
          ? environment.language("accounts.main", table: AccountText.table) : "",
        figure: figure.main)
      card.accent = line.account.accountAccent
      return card
    }
  }

  private func card(_ line: Line, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text(verbatim: line.title)
          .appFont(.footnote.weight(.semibold))
          .lineLimit(1)
        Spacer(minLength: 4)
        if line.isMain {
          Image(systemName: "star.fill")
            .appFont(.caption)
            .accessibilityHidden(true)
        }
      }
      Spacer(minLength: 4)
      if !line.caption.isEmpty {
        Text(verbatim: line.caption)
          .appFont(.caption)
          .cardInk(.note)
          .lineLimit(1)
      }
      Text(verbatim: line.figure)
        .appFont(.title2.bold().monospacedDigit())
        .minimumScaleFactor(0.6)
        .lineLimit(1)
    }
    // White on the owner's colour (4.5 : 1 or more, and darker still toward the corner);
    // the theme's text colour on the theme's gradients.
    .foregroundStyle(line.accent == nil ? theme.heroContent : .white)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .leading)
    .background(
      LinearGradient(
        colors: [tint, tint.mix(with: .black, by: 0.3)], startPoint: .topLeading,
        endPoint: .bottomTrailing),
      in: .rect(cornerRadius: 22)
    )
    .cardShadow(.soft, radius: 9, y: 8)
    .contentShape(.rect(cornerRadius: 22))
    .onTapGesture {
      NotificationCenter.default.post(name: .openSidebarItem, object: SidebarItem.account(line.id))
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }
}
