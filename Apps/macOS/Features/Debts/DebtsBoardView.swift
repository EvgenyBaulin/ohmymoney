import AppCore
import SwiftUI

/// The type of «Долги» at «Обычный», as the design names it in points — the same on the Mac, the
/// iPad and the phone, whose frames share them; each grows with the size of the text chosen in
/// Settings.
enum DebtsType {
  /// The figure of a tile of the summary and of a card: 34 semibold.
  static let figure = AppFont.system(size: 34, weight: .semibold).monospacedDigit()
  /// The word of a tile of the summary: 13.
  static let summaryLabel = AppFont.system(size: 13)
  /// The line under a figure, the words of the ladder and its result: 12.
  static let caption = AppFont.system(size: 12)
  /// The name of a group: 13 semibold.
  static let groupName = AppFont.system(size: 13, weight: .semibold)
  /// The name of a card and the title of the ladder or the phone's summary: 14 semibold.
  static let cardName = AppFont.system(size: 14, weight: .semibold)
  /// «Выплачено 38 %»: 12.5 medium; the figures beside it 12.
  static let progressTitle = AppFont.system(size: 12.5, weight: .medium).monospacedDigit()
  static let progressFigures = AppFont.system(size: 12).monospacedDigit()
  /// A term of a card: the word 11 over the figure 13 medium.
  static let termLabel = AppFont.system(size: 11)
  static let termValue = AppFont.system(size: 13, weight: .medium).monospacedDigit()
  /// A step of the ladder on the Mac: the number 12 semibold, the words 12.
  static let stepNumber = AppFont.system(size: 12, weight: .semibold).monospacedDigit()
  /// A step on the iPad and the phone: the name 13 medium over 11.
  static let stepName = AppFont.system(size: 13, weight: .medium)
  static let stepDetail = AppFont.system(size: 11).monospacedDigit()
  /// A value of the result and a line of the phone's summary: 12 medium, 13 medium.
  static let resultValue = AppFont.system(size: 12, weight: .medium).monospacedDigit()
  static let phoneSummaryValue = AppFont.system(size: 13, weight: .medium).monospacedDigit()
  /// The title of the screen on the phone: 34 bold.
  static let phoneTitle = AppFont.system(size: 34, weight: .bold)
}

/// «Долги» when no debt is open: the title with «Новый долг», the summary, the cards by group
/// and the card of the payoff ladder — on the Mac and the iPad three columns, on the phone one.
/// A card opens its debt or its person in the place of the board; there is no list beside it.
struct DebtsBoardView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces
  let board: DebtsBoard
  let ladder: DebtsLadderCard?
  let cardDebts: [CreditCardDebtLine]
  let withoutRate: Int
  let reviewCount: Int
  let select: (DebtsSelection) -> Void
  let delete: (UUID) -> Void
  let create: () -> Void
  let review: () -> Void
  @State private var width: CGFloat = 0
  /// «Закрытые» is folded until asked: closed debts pile up over the years.
  @State private var showsClosed = false

  /// The phone's one column; a width not measured yet is the wide page.
  private var isPhone: Bool { width > 0 && width < DebtsMetrics.phoneWidth }

  private var side: CGFloat { isPhone ? PhoneMetrics.screenMargin : StyleMetrics.pageSide }
  private var top: CGFloat {
    #if os(iOS)
      16
    #else
      StyleMetrics.pageTop
    #endif
  }

  var body: some View {
    ScrollView {
      Group {
        if isPhone { phone } else { wide }
      }
      .padding(.horizontal, side)
      .padding(.top, top)
      .padding(.bottom, StyleMetrics.pageBottom)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .background(surfaces.background)
    // Whole points, rounded down: the three columns come from this width and the content's width
    // comes from the columns, so a width that came back one float step larger every pass (as the
    // English iPad screen's did) never settled — the layout ran for minutes.
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width.rounded(.down)
    } action: {
      width = $0
    }
    .accessibilityIdentifier("debts.board")
  }

  // MARK: The Mac and the iPad

  private var content: CGFloat { max(width - 2 * side, 0) }
  private var column: CGFloat { DebtsMetrics.column(in: content) }

  private var wide: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScreenTitleRow(title: environment.language("section.debts")) { headerButtons }
      summaryRow
        .padding(.top, DebtsMetrics.headerGap)
      if withoutRate > 0 { withoutRateNote.padding(.top, 8) }
      if !board.groups.isEmpty || ladder != nil {
        HStack(alignment: .top, spacing: DebtsMetrics.columnGap) {
          groups(columns: ladder == nil ? 3 : 2)
            .frame(
              width: ladder == nil ? content : 2 * column + DebtsMetrics.columnGap,
              alignment: .topLeading)
          if let ladder {
            ladderCard(ladder)
              .frame(width: column)
              .frame(maxHeight: .infinity, alignment: .top)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, DebtsMetrics.sectionGap)
      } else {
        Text(verbatim: t("debts.none"))
          .appFont(DebtsType.caption).foregroundStyle(surfaces.secondary)
          .padding(.top, DebtsMetrics.sectionGap)
      }
      if !cardDebts.isEmpty {
        CreditCardDebtCards(lines: cardDebts) { select(.card($0)) }
          .padding(.top, DebtsMetrics.sectionGap)
      }
    }
  }

  @ViewBuilder private var headerButtons: some View {
    if reviewCount > 0 {
      Button(environment.language.format("review.banner", table: "Debts", counts: reviewCount)) {
        review()
      }
      .buttonStyle(.quietAction)
      .accessibilityIdentifier("debts.review.open")
    }
    Button(t("debts.new"), action: create)
      .buttonStyle(.primaryAction)
      .guideTarget(GuideTarget.debtsAdd)
      .accessibilityIdentifier("debts.new")
  }

  private var summaryRow: some View {
    HStack(alignment: .top, spacing: DebtsMetrics.columnGap) {
      summaryTile(
        "iOwe", symbol: "arrow.down.right", ink: theme.accentDefault, tint: theme.accentTint,
        label: t("debts.iOwe"), amount: board.summary.iOwe, line: board.summary.iOweLine(environment))
      summaryTile(
        "monthly", symbol: "calendar", ink: theme.chart2, tint: theme.chart2Tint,
        label: t("debts.monthly"), amount: board.summary.monthly,
        line: board.summary.nextPayment.map {
          environment.format(
            "debts.summary.next", table: "Debts", environment.dates.dayAndMonth($0))
        } ?? " ")
      summaryTile(
        "owedToMe", symbol: "person.2", ink: theme.statusPositive, tint: theme.statusPositiveTint,
        label: t("debts.owedToMe"), amount: board.summary.owedToMe,
        line: environment.language.format(
          "debts.summary.people", table: "Debts", counts: board.summary.peopleCount))
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("debts.summary")
  }

  private func summaryTile(
    _ id: String, symbol: String, ink: Color, tint: Color, label: String, amount: AmountE4,
    line: String
  ) -> some View {
    VStack(alignment: .leading, spacing: DebtsMetrics.summaryLineGap) {
      HStack(spacing: DebtsMetrics.summaryIconGap) {
        KindIcon(
          symbol: symbol, ink: ink, tint: tint, size: DebtsMetrics.summaryIcon,
          glyph: DebtsMetrics.summaryGlyph)
        Text(verbatim: label)
          .appFont(DebtsType.summaryLabel).foregroundStyle(theme.contentSecondary)
      }
      Text(verbatim: environment.money.rounded(amount))
        .appFont(DebtsType.figure).foregroundStyle(theme.contentPrimary)
        .lineLimit(1).minimumScaleFactor(0.5)
      Text(verbatim: line)
        .appFont(DebtsType.caption).foregroundStyle(theme.contentSecondary)
    }
    .padding(DebtsMetrics.summaryPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .debtsCardSurface()
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("debts.summary.\(id)")
  }

  private var withoutRateNote: some View {
    Text(
      verbatim: environment.language.format(
        "debts.withoutRateCount", table: "Debts", counts: withoutRate)
    )
    .appFont(DebtsType.caption).foregroundStyle(theme.contentSecondary)
  }

  private func groups(columns: Int) -> some View {
    VStack(alignment: .leading, spacing: DebtsMetrics.sectionGap) {
      ForEach(board.rows(columns: columns)) { row in
        HStack(alignment: .top, spacing: DebtsMetrics.columnGap) {
          ForEach(row.groups) { group in
            groupView(group, columns: row.groups.count > 1 ? 1 : columns)
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("debts.groups")
  }

  private func groupView(_ group: DebtsBoard.Group, columns: Int) -> some View {
    VStack(alignment: .leading, spacing: DebtsMetrics.groupTitleGap) {
      groupTitle(group)
      if shows(group) { grid(group, columns: columns) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("debts.group.\(group.kind.rawValue)")
  }

  private func shows(_ group: DebtsBoard.Group) -> Bool { group.kind != .closed || showsClosed }

  private func grid(_ group: DebtsBoard.Group, columns: Int) -> some View {
    Grid(
      alignment: .topLeading, horizontalSpacing: DebtsMetrics.columnGap,
      verticalSpacing: DebtsMetrics.columnGap
    ) {
      ForEach(Array(stride(from: 0, to: group.cards.count, by: columns)), id: \.self) { start in
        GridRow {
          ForEach(group.cards[start..<min(start + columns, group.cards.count)]) { card in
            cardView(card).frame(width: column)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func groupTitle(_ group: DebtsBoard.Group) -> some View {
    let title = Text(verbatim: "\(groupName(group.kind)) · \(group.cards.count)")
      .appFont(DebtsType.groupName).foregroundStyle(theme.contentPrimary)
    if group.kind == .closed {
      // The name of «Закрытые» is its own button: it folds and unfolds the closed debts.
      Button {
        withAnimation(.snappy) { showsClosed.toggle() }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "chevron.right")
            .appFont(DebtsType.caption).foregroundStyle(theme.contentSecondary)
            .rotationEffect(.degrees(showsClosed ? 90 : 0))
            .accessibilityHidden(true)
          title
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityValue(Text(verbatim: showsClosed ? "1" : "0"))
      .accessibilityIdentifier("debts.closed.toggle")
    } else {
      title.accessibilityAddTraits(.isHeader)
    }
  }

  private func groupName(_ kind: DebtsBoard.GroupKind) -> String {
    switch kind {
    case .iOwe: t("debts.iOwe")
    case .owedToMe: t("debts.owedToMe")
    case .instalments: t("debts.group.instalments")
    case .closed: t("debts.closed")
    }
  }

  private func cardView(_ card: DebtsBoard.Card) -> some View {
    DebtsBoardCard(card: card, phone: isPhone, open: { select(card.selection) }, delete: delete)
  }

  private func ladderCard(_ ladder: DebtsLadderCard) -> some View {
    DebtsLadderCardView(ladder: ladder, phone: isPhone) { select(.ladder) }
  }

  // MARK: The phone

  private var phone: some View {
    VStack(alignment: .leading, spacing: DebtsMetrics.phoneStackGap) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: environment.language("section.debts"))
          .appFont(DebtsType.phoneTitle)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        Button(action: create) {
          Image(systemName: "plus")
            .font(.system(size: 20, weight: .regular))  // font-fixed: the 24 pt «+» of the bar
            .frame(width: 24, height: 24)
            .foregroundStyle(theme.accentDefault)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: t("debts.new")))
        .guideTarget(GuideTarget.debtsAdd)
        .accessibilityIdentifier("debts.new")
      }
      if reviewCount > 0 {
        Button(environment.language.format("review.banner", table: "Debts", counts: reviewCount)) {
          review()
        }
        .buttonStyle(.quietAction)
        .accessibilityIdentifier("debts.review.open")
      }
      phoneSummary
      if withoutRate > 0 { withoutRateNote }
      if board.groups.isEmpty, ladder == nil {
        Text(verbatim: t("debts.none"))
          .appFont(DebtsType.caption).foregroundStyle(theme.contentSecondary)
      }
      ForEach(board.groups) { group in
        VStack(alignment: .leading, spacing: DebtsMetrics.groupTitleGap) {
          groupTitle(group)
          if shows(group) {
            VStack(spacing: DebtsMetrics.phoneCardStackGap) {
              ForEach(group.cards) { cardView($0) }
            }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("debts.group.\(group.kind.rawValue)")
      }
      if let ladder { ladderCard(ladder) }
      if !cardDebts.isEmpty {
        CreditCardDebtCards(lines: cardDebts) { select(.card($0)) }
      }
    }
  }

  private var phoneSummary: some View {
    VStack(alignment: .leading, spacing: DebtsMetrics.phoneSummaryGap) {
      Text(verbatim: t("debts.summary.title"))
        .appFont(DebtsType.cardName).foregroundStyle(theme.contentPrimary)
      phoneSummaryLine(t("debts.iOwe"), board.summary.iOwe)
      phoneSummaryLine(t("debts.monthly"), board.summary.monthly)
      phoneSummaryLine(t("debts.owedToMe"), board.summary.owedToMe)
    }
    .padding(DebtsMetrics.phoneSummaryPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .debtsCardSurface()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("debts.summary")
  }

  private func phoneSummaryLine(_ label: String, _ amount: AmountE4) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: label)
        .appFont(DebtsType.summaryLabel).foregroundStyle(theme.contentSecondary)
      Spacer(minLength: 8)
      Text(verbatim: environment.money.rounded(amount))
        .appFont(DebtsType.phoneSummaryValue).foregroundStyle(theme.contentPrimary)
    }
    .accessibilityElement(children: .combine)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// The round tinted icon of a kind: the symbol in `ink` on `tint` — the words beside it always
/// say what it means.
private struct KindIcon: View {
  let symbol: String
  let ink: Color
  let tint: Color
  let size: CGFloat
  let glyph: CGFloat

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: glyph * 0.8, weight: .medium))  // font-fixed: the glyph of a fixed circle
      .frame(width: glyph, height: glyph)
      .foregroundStyle(ink)
      .frame(width: size, height: size)
      .background(tint, in: .circle)
      .accessibilityHidden(true)
  }
}

/// A card of the board: the icon of its kind, the name and the label of the kind, the balance,
/// what of it is paid with its bar, and the rate, the payment and the nearest due. A click opens
/// the debt or the person; «Удалить…» of a debt asks first and is not undone.
struct DebtsBoardCard: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let card: DebtsBoard.Card
  let phone: Bool
  let open: () -> Void
  let delete: (UUID) -> Void

  var body: some View {
    Button(action: open) {
      VStack(
        alignment: .leading, spacing: phone ? DebtsMetrics.phoneCardGap : DebtsMetrics.cardGap
      ) {
        HStack(spacing: DebtsMetrics.cardIconGap) {
          KindIcon(
            symbol: card.symbol, ink: theme.accentDefault, tint: theme.accentTint,
            size: DebtsMetrics.cardIcon, glyph: DebtsMetrics.cardGlyph)
          Text(verbatim: name)
            .appFont(DebtsType.cardName).foregroundStyle(theme.contentPrimary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
          if DebtPaymentMark.isShown, let stripe = card.stripe {
            DebtStripeSymbol(mark: stripe, key: stripe.debtKey)
          }
          StatusLabel(tone: .neutral, text: t(card.labelKey))
        }
        Text(verbatim: environment.money.rounded(card.amount, currency: card.currency))
          .appFont(DebtsType.figure).foregroundStyle(theme.contentPrimary)
          .lineLimit(1).minimumScaleFactor(0.5)
        if let percent = card.percent, let paid = card.paid, let total = card.total {
          progress(percent: percent, paid: paid, total: total)
        }
        HStack(alignment: .top, spacing: DebtsMetrics.termsGap) {
          term(t("debts.card.rate"), card.rate.map { "\(environment.money.rate($0)) %" })
          term(
            t("debts.card.payment"),
            card.payment.map { environment.money.rounded($0, currency: card.progressCurrency) })
          term(t("debts.card.nextDue"), card.nextDue.map { environment.dates.dayAndMonth($0) })
        }
      }
      .padding(phone ? DebtsMetrics.phoneCardPadding : DebtsMetrics.cardPadding)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .debtsCardSurface()
      .overlay(alignment: .leading) {
        if DebtPaymentMark.isShown, let stripe = card.stripe {
          DebtStripeEdge(
            mark: stripe, padding: phone ? DebtsMetrics.phoneCardPadding : DebtsMetrics.cardPadding)
        }
      }
      .contentShape(.rect(cornerRadius: ContentCard.cornerRadius))
    }
    .buttonStyle(.plain)
    .contextMenu {
      if let id = card.debtId {
        Button(t("debts.delete"), role: .destructive) { delete(id) }
      }
    }
    .accessibilityIdentifier(Self.identifier(of: card.selection))
  }

  private var name: String { card.name.isEmpty ? t("debts.noPerson") : card.name }

  /// «debts.card.<id>» for a debt, «debts.person.<id>» for a person (`none` for nobody).
  static func identifier(of selection: DebtsSelection) -> String {
    switch selection {
    case .debt(let id): "debts.card.\(id.uuidString)"
    case .person(let id): "debts.person.\(id?.uuidString ?? "none")"
    case .card(let id): "debts.creditCard.\(id.uuidString)"
    case .ladder: "debts.ladder.card"
    }
  }

  private func progress(percent: Int, paid: AmountE4, total: AmountE4) -> some View {
    VStack(alignment: .leading, spacing: DebtsMetrics.progressGap) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: environment.format(card.progressKey, table: "Debts", "\(percent) %"))
          .appFont(DebtsType.progressTitle).foregroundStyle(theme.contentPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(
          verbatim: environment.format(
            "debts.card.ofTotal", table: "Debts",
            environment.money.rounded(paid, currency: card.progressCurrency).withoutUnit(
              of: card.progressCurrency, money: environment.money),
            environment.money.rounded(total, currency: card.progressCurrency))
        )
        .appFont(DebtsType.progressFigures).foregroundStyle(theme.contentSecondary)
        .lineLimit(1)
      }
      PaidTrack(percent: percent, track: theme.fillNeutral, fill: theme.statusPositive)
        .accessibilityLabel(Text(verbatim: t("debts.card.paid")))
        .accessibilityValue(Text(verbatim: "\(percent) %"))
    }
  }

  private func term(_ label: String, _ value: String?) -> some View {
    VStack(alignment: .leading, spacing: DebtsMetrics.termLineGap) {
      Text(verbatim: label)
        .appFont(DebtsType.termLabel).foregroundStyle(theme.contentSecondary)
      Text(verbatim: value ?? "—")
        .appFont(DebtsType.termValue).foregroundStyle(theme.contentPrimary)
    }
    .lineLimit(1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

extension String {
  /// «87 400» out of «87 400 ₽»: the first figure of «87 400 из 230 000 ₽» carries no unit, the
  /// second does. A rounded amount is always its figure, a no-break space and the unit.
  fileprivate func withoutUnit(of currency: CurrencyCode, money: MoneyFormatter) -> String {
    let suffix = "\u{00A0}\(money.unit(for: currency))"
    return hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
  }
}

/// The bar of what is paid: the grey track and the paid part over it, 6 high, rounded 3. The
/// share is said in words beside it; the bar only repeats it.
private struct PaidTrack: View {
  let percent: Int
  let track: Color
  let fill: Color

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: DebtsMetrics.trackRadius)
    shape.fill(track)
      .frame(height: DebtsMetrics.trackHeight)
      .overlay(alignment: .leading) {
        PaidShareLayout(percent: percent) { shape.fill(fill) }
      }
      .clipShape(shape)
  }
}

/// Lays its one child out `percent` of the width it is given, the full height.
private struct PaidShareLayout: Layout {
  let percent: Int

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let width = bounds.width * CGFloat(min(max(percent, 0), 100)) / 100
    for subview in subviews {
      subview.place(
        at: bounds.origin, proposal: ProposedViewSize(width: width, height: bounds.height))
    }
  }
}

/// The card of the payoff ladder: the method in a line, the debts in the order they are paid,
/// when the last one goes and the interest the money above saves, and «Открыть лестницу…». On
/// the phone the whole card opens the ladder and says only the date.
struct DebtsLadderCardView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let ladder: DebtsLadderCard
  let phone: Bool
  let open: () -> Void

  var body: some View {
    Group {
      if phone {
        Button(action: open) { card.contentShape(.rect) }
          .buttonStyle(.plain)
      } else {
        card
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("debts.ladder.card")
  }

  private var card: some View {
    VStack(
      alignment: .leading, spacing: phone ? DebtsMetrics.phoneLadderGap : DebtsMetrics.ladderGap
    ) {
      Text(verbatim: t("ladder.title"))
        .appFont(DebtsType.cardName).foregroundStyle(theme.contentPrimary)
        .accessibilityAddTraits(.isHeader)
      if !phone {
        Text(verbatim: t("ladder.card.\(ladder.method.rawValue)"))
          .appFont(DebtsType.caption).foregroundStyle(theme.contentSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(Array(ladder.steps.enumerated()), id: \.element.id) { index, step in
        stepView(index + 1, step)
      }
      VStack(alignment: .leading, spacing: DebtsMetrics.resultGap) {
        result(t("ladder.free.label"), freeText)
        if !phone, let saved = ladder.interestSaved {
          result(t("ladder.card.saved"), "≈ \(environment.money.rounded(saved))")
        }
      }
      if !phone {
        Spacer(minLength: 0)
        Button(t("ladder.card.open"), action: open)
          .buttonStyle(.rowAction)
          .accessibilityIdentifier("debts.ladder")
      }
    }
    .padding(phone ? DebtsMetrics.phoneLadderPadding : DebtsMetrics.ladderPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .debtsCardSurface()
  }

  private var freeText: String {
    guard let free = ladder.freeFrom else { return t("ladder.card.never") }
    let when = Self.month(free, genitive: false, locale: environment.language.locale)
    guard let without = ladder.freeWithout else { return when }
    return environment.format(
      "ladder.card.instead", table: "Debts", when,
      Self.month(without, genitive: true, locale: environment.language.locale))
  }

  /// «май 2028», and after «вместо» «марта 2030»: the month as a phrase needs it, in the case
  /// the language asks.
  static func month(_ month: MonthKey, genitive: Bool, locale: Locale) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    let names = (genitive ? formatter.monthSymbols : formatter.standaloneMonthSymbols) ?? []
    let name = month.month - 1 < names.count ? names[month.month - 1] : month.iso
    return "\(name) \(month.year)"
  }

  private func stepDetail(_ step: DebtsLadderCard.Step) -> String {
    "\(environment.money.rate(step.ratePercent)) % · \(environment.money.rounded(step.balance))"
  }

  @ViewBuilder
  private func stepView(_ number: Int, _ step: DebtsLadderCard.Step) -> some View {
    #if os(macOS)
      HStack(spacing: 2) {
        Text(verbatim: String(number))
          .appFont(DebtsType.stepNumber).foregroundStyle(theme.contentPrimary)
          .padding(.horizontal, DebtsMetrics.macStepHorizontal)
          .padding(.vertical, DebtsMetrics.macStepVertical)
          .background(theme.surfaceCard, in: .rect(cornerRadius: DebtsMetrics.macStepPlateRadius))
        VStack(spacing: 1) {
          Text(verbatim: step.name)
          Text(verbatim: stepDetail(step))
        }
        .appFont(DebtsType.caption).foregroundStyle(theme.contentSecondary)
        .lineLimit(1)
        .padding(.horizontal, DebtsMetrics.macStepHorizontal)
        .padding(.vertical, DebtsMetrics.macStepVertical)
      }
      .padding(DebtsMetrics.macStepInset)
      .background(theme.surfaceSegmented, in: .rect(cornerRadius: DebtsMetrics.macStepRadius))
      .accessibilityElement(children: .combine)
    #else
      HStack(spacing: DebtsMetrics.stepGap) {
        Text(verbatim: String(number))
          .appFont(DebtsType.stepNumber).foregroundStyle(theme.contentOnAccent)
          .frame(width: DebtsMetrics.stepNumber, height: DebtsMetrics.stepNumber)
          .background(theme.accentDefault, in: .circle)
        VStack(alignment: .leading, spacing: 1) {
          Text(verbatim: step.name)
            .appFont(DebtsType.stepName).foregroundStyle(theme.contentPrimary)
          Text(verbatim: stepDetail(step))
            .appFont(DebtsType.stepDetail).foregroundStyle(theme.contentSecondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, DebtsMetrics.stepHorizontal)
      .padding(.vertical, phone ? DebtsMetrics.stepVertical : 8)
      .background(theme.fillNeutral, in: .rect(cornerRadius: DebtsMetrics.stepRadius))
      .accessibilityElement(children: .combine)
    #endif
  }

  private func result(_ label: String, _ value: String) -> some View {
    // Side by side as the frame draws it; a value too long for that («ноябрь 2028 вместо
    // февраля 2031») goes under its label rather than squeezing it.
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        resultLabel(label).frame(maxWidth: .infinity, alignment: .leading)
        resultValue(value).fixedSize()
      }
      VStack(alignment: .leading, spacing: 2) {
        resultLabel(label)
        resultValue(value).fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func resultLabel(_ label: String) -> some View {
    Text(verbatim: label)
      .appFont(DebtsType.caption).foregroundStyle(theme.contentSecondary)
      .fixedSize()
  }

  private func resultValue(_ value: String) -> some View {
    Text(verbatim: value)
      .appFont(DebtsType.resultValue).foregroundStyle(theme.contentPrimary)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

extension View {
  /// A card of «Долги»: the card's surface, its 1 pt edge, radius 12 on the Mac and 22 on the
  /// iPad and the phone, and the separator under «Увеличить контраст».
  func debtsCardSurface() -> some View { modifier(DebtsCardSurface()) }
}

private struct DebtsCardSurface: ViewModifier {
  @Environment(\.appTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: ContentCard.cornerRadius)
    content
      .background(theme.surfaceCard, in: shape)
      .overlay {
        shape.strokeBorder(theme.borderCard, lineWidth: StyleMetrics.cardBorder)
        if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
      }
  }
}
