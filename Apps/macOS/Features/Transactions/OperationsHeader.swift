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

/// The month of «Операции»: the capsule ‹ Ноябрь 2026 › at the right of the chips steps the
/// period of the filters a calendar month at a time. It sets the same period the filters edit —
/// nothing of its own — so the sheet of filters and «Сбросить» agree with it.
///
/// The table still opens on the whole history (the search looks through all of it): ‹ from
/// there shows the current month, ‹ again the one before; › goes a month forward, and from the
/// current month back to the whole history. The current and the previous month are the
/// filters' own «Этот месяц» and «Прошлый»; an earlier one is a custom range of its days.
enum OperationsMonth {
  /// The calendar month the filters show, or `nil` when they show something else.
  static func shown(in filters: TransactionFilters, today: DateOnly) -> MonthKey? {
    switch filters.period {
    case .thisMonth: return today.monthKey
    case .lastMonth: return today.monthKey.previous
    case .custom:
      let start = min(filters.customStart, filters.customEnd)
      let end = max(filters.customStart, filters.customEnd)
      let month = start.monthKey
      guard start == month.firstDay, end == lastDay(of: month) else { return nil }
      return month
    case .thisYear, .allTime: return nil
    }
  }

  static func lastDay(of month: MonthKey) -> DateOnly {
    month.next.firstDay.adding(days: -1)
  }

  /// Shows `month`.
  static func show(_ month: MonthKey, in filters: inout TransactionFilters, today: DateOnly) {
    if month == today.monthKey {
      filters.period = .thisMonth
    } else if month == today.monthKey.previous {
      filters.period = .lastMonth
    } else {
      filters.customStart = month.firstDay
      filters.customEnd = lastDay(of: month)
      filters.period = .custom
    }
  }

  /// ‹: the month before the one shown; from anything that is not a month, the current one.
  static func back(_ filters: inout TransactionFilters, today: DateOnly) {
    let month = shown(in: filters, today: today).map(\.previous) ?? today.monthKey
    show(month, in: &filters, today: today)
  }

  /// ›: the month after the one shown; from the current month (or a later one), the whole
  /// history. With no month shown there is nowhere forward to go.
  static func canGoForward(_ filters: TransactionFilters, today: DateOnly) -> Bool {
    shown(in: filters, today: today) != nil
  }

  static func forward(_ filters: inout TransactionFilters, today: DateOnly) {
    guard let month = shown(in: filters, today: today) else { return }
    if month >= today.monthKey {
      filters.period = .allTime
    } else {
      show(month.next, in: &filters, today: today)
    }
  }

  /// What the capsule says: the month — «Ноябрь 2026» —, or the period the filters show.
  @MainActor
  static func title(
    _ filters: TransactionFilters, today: DateOnly, environment: AppEnvironment
  ) -> String {
    if let month = shown(in: filters, today: today) {
      return environment.dates.monthTitle(month)
    }
    switch filters.period {
    case .custom:
      return environment.dates.span(
        DayRange(
          min(filters.customStart, filters.customEnd), max(filters.customStart, filters.customEnd))
      )
    default:
      return environment.language(filters.period.titleKey, table: "Transactions")
    }
  }

  /// How many filters narrow the table beyond what the chips and the month show — the type and
  /// the period —: the chip «Фильтры · N» stands in the row only while there are some.
  static func otherFilters(_ filters: TransactionFilters) -> Int {
    filters.activeCount - (filters.period == .allTime ? 0 : 1) - (filters.kind == nil ? 0 : 1)
  }
}

/// A row of capsule chips; the chosen one stands on the accent tint in the accent's content
/// colour, the others on the neutral fill (the tablet: the card colour with the hairline), and
/// the chosen one says «selected» to VoiceOver — not the colour alone.
struct QuickFilterChips: View {
  let chips: [OperationsQuickFilter]
  let isActive: (OperationsQuickFilter) -> Bool
  let title: (OperationsQuickFilter) -> String
  let choose: (OperationsQuickFilter) -> Void

  var body: some View {
    HStack(spacing: OperationsMetrics.chipGap) {
      ForEach(chips) { chip in
        OperationsChip(title: title(chip), selected: isActive(chip)) { choose(chip) }
          .accessibilityIdentifier("operations.chip.\(chip.rawValue)")
      }
    }
  }
}

/// One chip of «Операции» (Mac 5:35451, tablet 5:76360).
struct OperationsChip: View {
  @Environment(\.appTheme) private var theme
  let title: String
  let selected: Bool
  let action: () -> Void

  /// The fill of a chip: the accent tint when chosen; otherwise the neutral fill on the Mac and
  /// the card colour on a tablet or a phone.
  static func fill(selected: Bool, in theme: AppThemeColors) -> Color {
    if selected { return theme.accentTint }
    #if os(iOS)
      return theme.surfaceCard
    #else
      return theme.fillNeutral
    #endif
  }

  static func ink(selected: Bool, in theme: AppThemeColors) -> Color {
    selected ? theme.accentContent : theme.contentPrimary
  }

  var body: some View {
    Button(action: action) {
      Text(verbatim: title)
        .appFont(Self.font)
        .foregroundStyle(Self.ink(selected: selected, in: theme))
        .lineLimit(1)
        .padding(.horizontal, Self.horizontal)
        .padding(.vertical, Self.vertical)
        .background(Self.fill(selected: selected, in: theme), in: .capsule)
        .overlay {
          #if os(iOS)
            if !selected {
              Capsule().strokeBorder(theme.borderHairline, lineWidth: StyleMetrics.cardBorder)
            }
          #endif
        }
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  static var font: AppFont {
    #if os(iOS)
      OperationsType.padChip
    #else
      OperationsType.chip
    #endif
  }
  static var horizontal: CGFloat {
    #if os(iOS)
      OperationsMetrics.padChipHorizontal
    #else
      OperationsMetrics.chipHorizontal
    #endif
  }
  static var vertical: CGFloat {
    #if os(iOS)
      OperationsMetrics.padChipVertical
    #else
      OperationsMetrics.chipVertical
    #endif
  }
}

/// ‹ Ноябрь 2026 ›: a capsule on the card colour with the hairline, the chevrons either side of
/// the month (Mac 5:35460, tablet 5:76369, phone 5:7985).
struct OperationsMonthCapsule: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.layoutIdiom) private var idiom
  let title: String
  let canGoForward: Bool
  let backTitle: String
  let forwardTitle: String
  let back: () -> Void
  let forward: () -> Void

  var body: some View {
    HStack(spacing: OperationsMetrics.monthGap) {
      chevron("chevron.left", label: backTitle, action: back)
        .accessibilityIdentifier("operations.month.back")
      Text(verbatim: title)
        .appFont(Self.font)
        .foregroundStyle(theme.contentPrimary)
        .lineLimit(1)
        .monospacedDigit()
        .accessibilityIdentifier("operations.month")
      chevron("chevron.right", label: forwardTitle, action: forward)
        .disabled(!canGoForward)
        .opacity(canGoForward ? 1 : 0.35)
        .accessibilityIdentifier("operations.month.forward")
    }
    .padding(.horizontal, Self.horizontal(LayoutIdiom.resolved(idiom)))
    .padding(.vertical, Self.vertical)
    .background(theme.surfaceCard, in: .capsule)
    .overlay { Capsule().strokeBorder(theme.borderHairline, lineWidth: StyleMetrics.cardBorder) }
    .fixedSize()
  }

  private func chevron(_ symbol: String, label: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: Self.chevron * 0.75, weight: .semibold))  // font-fixed: a fixed glyph
        .foregroundStyle(theme.contentSecondary)
        .frame(width: Self.chevron, height: Self.chevron)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(Text(verbatim: label))
  }

  static var font: AppFont {
    #if os(iOS)
      OperationsType.touchMonth
    #else
      OperationsType.month
    #endif
  }
  static var chevron: CGFloat {
    #if os(iOS)
      OperationsMetrics.padMonthChevron
    #else
      OperationsMetrics.monthChevron
    #endif
  }
  static func horizontal(_ idiom: LayoutIdiom) -> CGFloat {
    switch idiom {
    case .mac: OperationsMetrics.monthHorizontal
    case .phone: OperationsMetrics.phoneMonthHorizontal
    case .pad: OperationsMetrics.padMonthHorizontal
    }
  }
  static var vertical: CGFloat {
    #if os(iOS)
      OperationsMetrics.padMonthVertical
    #else
      OperationsMetrics.monthVertical
    #endif
  }
}

/// The search box of «Операции» (Mac 5:35441, tablet 5:76351): the card colour with the hairline,
/// radius 10, 34 tall, the magnifier before the words. The field inside is a plain `TextField`.
struct OperationsSearchBox<Field: View>: View {
  @Environment(\.appTheme) private var theme
  @ViewBuilder let field: Field

  var body: some View {
    HStack(spacing: OperationsMetrics.searchIconGap) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: Self.icon * 0.85, weight: .medium))  // font-fixed: a fixed glyph
        .frame(width: Self.icon, height: Self.icon)
        .foregroundStyle(theme.contentSecondary)
        .accessibilityHidden(true)
      field
        .textFieldStyle(.plain)
        .appFont(Self.font)
    }
    .padding(.horizontal, Self.horizontal)
    .frame(height: OperationsMetrics.controlHeight)
    .background(theme.surfaceCard, in: .rect(cornerRadius: OperationsMetrics.controlRadius))
    .overlay {
      RoundedRectangle(cornerRadius: OperationsMetrics.controlRadius)
        .strokeBorder(theme.borderHairline, lineWidth: StyleMetrics.cardBorder)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("operations.searchBox")
  }

  static var icon: CGFloat {
    #if os(iOS)
      OperationsMetrics.padSearchIcon
    #else
      OperationsMetrics.searchIcon
    #endif
  }
  static var horizontal: CGFloat {
    #if os(iOS)
      OperationsMetrics.padSearchHorizontal
    #else
      OperationsMetrics.searchHorizontal
    #endif
  }
  static var font: AppFont {
    #if os(iOS)
      OperationsType.padSearch
    #else
      OperationsType.search
    #endif
  }
}
