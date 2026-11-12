import AppCore
import SwiftUI

/// The four groups of the sections of Analytics, as the design names them: «Траты», «Доход»,
/// «Прогноз», «Привычки». The group is read from the section on screen, so the stored section
/// alone says where the window is.
enum AnalyticsGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
  case spending
  case income
  case forecast
  case habits

  var id: String { rawValue }
  var titleKey: String { "analytics.group.\(rawValue)" }

  /// The sections of the group, in the order of their chips.
  var sections: [AnalyticsSection] {
    switch self {
    case .spending: [.overview, .quality, .others, .forWhom, .places, .events, .paymentMethods]
    case .income: [.incomeSavings]
    case .forecast: [.forecast, .anomalies, .comparison]
    case .habits: [.days, .habits, .leaks]
    }
  }

  /// The group a section belongs to; «Качество модели» lives in Settings and belongs to none.
  static func of(_ section: AnalyticsSection) -> AnalyticsGroup {
    allCases.first { $0.sections.contains(section) } ?? .spending
  }
}

/// The choice of the period at the right of the header: «Неделя», «Месяц», «Квартал», «Год» —
/// the current one of each — and «Свои даты», any month, year or twelve months.
enum AnalyticsPeriodChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
  case week
  case month
  case quarter
  case year
  case custom

  var id: String { rawValue }
  var titleKey: String { "analytics.period.choice.\(rawValue)" }

  /// The kind of the current period the choice gives; «Свои даты» has none of its own.
  var kind: AnalyticsPeriod.Kind? {
    switch self {
    case .week: .week
    case .month: .month
    case .quarter: .quarter
    case .year: .year
    case .custom: nil
    }
  }

  /// The choice a period is shown under: the current week, month, quarter or year under its own
  /// name, everything else — another month, a past year, twelve months — under «Свои даты».
  init(_ period: AnalyticsPeriod, today: DateOnly) {
    guard period.isCurrent(today: today) else {
      self = .custom
      return
    }
    switch period.kind {
    case .week: self = .week
    case .month: self = .month
    case .quarter: self = .quarter
    case .year: self = .year
    case .twelveMonths: self = .custom
    }
  }
}

/// The numbers of the header of Analytics as the design draws it: the Mac's master (5:36907),
/// the tablet's (5:77469) and the phone's (5:6837).
struct AnalyticsMetrics: Equatable, Sendable {
  /// The margins of the page.
  var side: CGFloat
  var top: CGFloat
  /// Between the title and the period under it; between the header and the tabs, and the tabs
  /// and the cards.
  var subtitleGap: CGFloat
  var stackGap: CGFloat
  /// The groups: a track of `groupTrack`, a group `groupHorizontal × groupVertical`, both
  /// rounded `groupRadius`, `groupGap` apart. A phone stretches them over the page.
  var groupTrack: CGFloat
  var groupHorizontal: CGFloat
  var groupVertical: CGFloat
  var groupGap: CGFloat
  var groupRadius: CGFloat
  var groupsFillWidth: Bool
  /// The divider between the groups and the chips: 1 × 18. A phone puts the chips on a line of
  /// their own instead.
  var dividerHeight: CGFloat
  var chipsOnOwnLine: Bool
  /// A chip of a section: `chipHorizontal × chipVertical` in a capsule, `chipGap` apart.
  var chipHorizontal: CGFloat
  var chipVertical: CGFloat
  var chipGap: CGFloat
  /// The chosen chip is filled with the accent on a phone; on the tint elsewhere.
  var chosenChipFilled: Bool
  /// The title stands in the page; a phone has it in its navigation bar.
  var showsTitle: Bool
  /// The period's choice at the right of the header; a phone opens its sheet from the line
  /// under the title.
  var showsPeriodChoice: Bool

  /// The Mac: the page 28 × 22; 14 from the title to the period under it, 16 to the tabs and
  /// 16 to the cards; the groups 14 × 6 in a track of 2, rounded 8, 2 apart; the divider 1 × 18,
  /// 6 from its neighbours; a chip 6 × 5, 6 apart.
  static let mac = AnalyticsMetrics(
    side: StyleMetrics.pageSide, top: StyleMetrics.pageTop, subtitleGap: 14, stackGap: 16,
    groupTrack: 2, groupHorizontal: 14, groupVertical: 6, groupGap: 2, groupRadius: 8,
    groupsFillWidth: false, dividerHeight: 18, chipsOnOwnLine: false,
    chipHorizontal: 6, chipVertical: 5, chipGap: 6, chosenChipFilled: false,
    showsTitle: true, showsPeriodChoice: true)

  /// The tablet: as the Mac, the page 32 at the sides and 16 above.
  static let pad = AnalyticsMetrics(
    side: 32, top: 16, subtitleGap: 14, stackGap: 16,
    groupTrack: 2, groupHorizontal: 14, groupVertical: 6, groupGap: 2, groupRadius: 8,
    groupsFillWidth: false, dividerHeight: 18, chipsOnOwnLine: false,
    chipHorizontal: 6, chipVertical: 5, chipGap: 6, chosenChipFilled: false,
    showsTitle: true, showsPeriodChoice: true)

  /// The phone: the page 16 at the sides; the groups over the width, 28 tall in a track of 2;
  /// the chips on their own line, 10 × 5, 6 apart, the chosen one on the accent; 14 between the
  /// parts.
  static let phone = AnalyticsMetrics(
    side: PhoneMetrics.screenMargin, top: 8, subtitleGap: 4, stackGap: 14,
    groupTrack: 2, groupHorizontal: 10, groupVertical: 6, groupGap: 2, groupRadius: 8,
    groupsFillWidth: true, dividerHeight: 18, chipsOnOwnLine: true,
    chipHorizontal: 10, chipVertical: 5, chipGap: 6, chosenChipFilled: true,
    showsTitle: false, showsPeriodChoice: false)

  static func of(_ idiom: LayoutIdiom) -> AnalyticsMetrics {
    switch idiom {
    case .mac: .mac
    case .pad: .pad
    case .phone: .phone
    }
  }
}

/// The type of the header: a group 13, 12 on a phone; a chip 11.5, 12 on a phone; the period
/// under the title 14 medium, 12 on a phone.
enum AnalyticsType {
  static func group(_ idiom: LayoutIdiom) -> AppFont {
    idiom == .phone ? AppFont.system(size: 12) : .body
  }

  static func chip(_ idiom: LayoutIdiom) -> AppFont {
    idiom == .phone ? AppFont.system(size: 12) : AppFont.system(size: 11.5)
  }

  static func subtitle(_ idiom: LayoutIdiom) -> AppFont {
    idiom == .phone ? AppFont.system(size: 12) : AppFont.system(size: 14, weight: .medium)
  }
}

/// The groups in a grey track with the chosen one white, a hairline, and the chips of the
/// sections of the chosen group.
struct AnalyticsTabsRow: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let section: AnalyticsSection
  let metrics: AnalyticsMetrics
  let idiom: LayoutIdiom
  let choose: (AnalyticsSection) -> Void

  private var group: AnalyticsGroup { .of(section) }

  var body: some View {
    Group {
      if metrics.chipsOnOwnLine {
        VStack(alignment: .leading, spacing: metrics.stackGap) {
          groups
          chips
        }
      } else {
        FlowRow(spacing: metrics.chipGap, lineSpacing: metrics.chipGap) {
          groups
          Rectangle()
            .fill(theme.fillStrong)
            .frame(width: 1, height: metrics.dividerHeight)
            .accessibilityHidden(true)
          ForEach(group.sections) { item in chip(item) }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("analytics.sections")
  }

  private var groups: some View {
    HStack(spacing: metrics.groupGap) {
      ForEach(AnalyticsGroup.allCases) { item in
        let selected = item == group
        Button {
          // A group opens on its first section.
          if !selected, let first = item.sections.first { choose(first) }
        } label: {
          Text(verbatim: AnalyticsText.t(item.titleKey, environment))
            .appFont(AnalyticsType.group(idiom).weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? theme.contentPrimary : theme.contentSecondary)
            .lineLimit(1)
            .padding(.horizontal, metrics.groupHorizontal)
            .padding(.vertical, metrics.groupVertical)
            .frame(maxWidth: metrics.groupsFillWidth ? .infinity : nil)
            .background(
              selected ? theme.surfaceCard : .clear, in: .rect(cornerRadius: metrics.groupRadius)
            )
            .contentShape(.rect(cornerRadius: metrics.groupRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("analytics.group.\(item.rawValue)")
      }
    }
    .padding(metrics.groupTrack)
    .background(theme.surfaceSegmented, in: .rect(cornerRadius: metrics.groupRadius))
    .fixedSize(horizontal: !metrics.groupsFillWidth, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("analytics.groups")
  }

  private var chips: some View {
    FlowRow(spacing: metrics.chipGap, lineSpacing: metrics.chipGap) {
      ForEach(group.sections) { item in chip(item) }
    }
  }

  /// A section: the chosen one on the accent's tint and in the accent, semibold — on a phone on
  /// the accent in the colour on it —, the others grey; the weight says it as well as the colour.
  private func chip(_ item: AnalyticsSection) -> some View {
    let selected = item == section
    return Button {
      choose(item)
    } label: {
      Text(verbatim: AnalyticsText.t(item.titleKey, environment))
        .appFont(AnalyticsType.chip(idiom).weight(selected ? .semibold : .regular))
        .foregroundStyle(chipInk(selected))
        .lineLimit(1)
        .padding(.horizontal, metrics.chipHorizontal)
        .padding(.vertical, metrics.chipVertical)
        .background(chipFill(selected), in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("analytics.chip.\(item.rawValue)")
  }

  private func chipInk(_ selected: Bool) -> Color {
    guard selected else { return theme.contentSecondary }
    return metrics.chosenChipFilled ? theme.contentOnAccent : theme.accentDefault
  }

  private func chipFill(_ selected: Bool) -> Color {
    guard selected else { return theme.fillNeutral }
    return metrics.chosenChipFilled ? theme.accentDefault : theme.accentTint
  }
}

/// The choice of the period at the right of the header: a grey track, the chosen one white.
struct AnalyticsPeriodRow: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let chosen: AnalyticsPeriodChoice
  let enabled: Bool
  let choose: (AnalyticsPeriodChoice) -> Void

  var body: some View {
    HStack(spacing: 2) {
      ForEach(AnalyticsPeriodChoice.allCases) { item in
        let selected = item == chosen
        Button {
          choose(item)
        } label: {
          Text(verbatim: AnalyticsText.t(item.titleKey, environment))
            .appFont(AppFont.body.weight(selected ? .semibold : .regular))
            // A section that keeps its own period greys the choice out: nothing is chosen.
            .foregroundStyle(selected && enabled ? theme.contentPrimary : theme.contentSecondary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(selected ? theme.surfaceCard : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("analytics.period.\(item.rawValue)")
      }
    }
    .padding(3)
    .background(theme.surfaceSegmented, in: .rect(cornerRadius: 10))
    .fixedSize()
    .disabled(!enabled)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("analytics.period")
  }
}

/// «Свои даты» on the Mac and «Выбрать период» on a phone: «Закрыть» and «Текущий» at the top,
/// a month, a year or twelve months, and the months or the years to pick from.
struct AnalyticsPeriodSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let period: AnalyticsPeriod
  let today: DateOnly
  let choose: (AnalyticsPeriod) -> Void

  private var kind: AnalyticsPeriod.Kind {
    switch period.kind {
    case .year: .year
    case .twelveMonths: .twelveMonths
    case .week, .month, .quarter: .month
    }
  }

  var body: some View {
    VStack(spacing: 14) {
      HStack {
        Button(environment.language("action.close")) { dismiss() }
          .buttonStyle(.plain)
          .foregroundStyle(theme.accentContent)
        Spacer()
        Text(verbatim: AnalyticsText.t("analytics.period.sheet", environment))
          .appFont(.headline)
        Spacer()
        Button(AnalyticsText.t("analytics.period.current", environment)) {
          choose(.current(.month, today: today))
          dismiss()
        }
        .buttonStyle(.plain)
        .appFont(.body.weight(.semibold))
        .foregroundStyle(theme.accentContent)
        .accessibilityIdentifier("analytics.period.sheet.current")
      }
      Picker(
        selection: Binding(
          get: { kind },
          set: { choose(AnalyticsPeriod(kind: $0, month: period.month).clamped(to: today)) })
      ) {
        ForEach([AnalyticsPeriod.Kind.month, .year, .twelveMonths], id: \.self) { kind in
          Text(verbatim: AnalyticsText.t(kind.titleKey, environment)).tag(kind)
        }
      } label: {
        Text(verbatim: AnalyticsText.t("analytics.period.kind", environment))
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      PeriodChooser(period: AnalyticsPeriod(kind: kind, month: period.month), today: today) {
        chosen in
        choose(chosen)
        dismiss()
      }
      // The periods of the saved filters.
      SavedPeriodsMenu { chosen in
        choose(chosen)
        dismiss()
      }
      .fixedSize()
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(minWidth: 320, minHeight: 300)
    .themedWindowBackground()
    .accessibilityIdentifier("analytics.period.sheet")
  }
}
