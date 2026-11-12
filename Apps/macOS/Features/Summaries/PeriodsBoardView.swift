import AppCore
import SwiftUI

/// «По периодам»: the switch Неделя | Месяц | Год and the board of the chosen period, as the
/// frames draw it. The Mac and a tablet show it under the tabs of Reports, two columns of cards;
/// a phone shows it on its page «Итоги», the cards one under another. Under the board: the
/// question of a finished week and the badges of the period.
struct PeriodsBoardView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.layoutIdiom) private var chosenIdiom
  @Environment(\.appTheme) private var theme
  let store: PeriodsBoardStore
  @State private var width: CGFloat = 0
  @State private var route = SummariesRoute.shared

  private var idiom: LayoutIdiom { LayoutIdiom.resolved(chosenIdiom) }
  private var metrics: PeriodsBoardMetrics { .of(idiom) }
  private func t(_ key: String) -> String { environment.language(key, table: "Summaries") }

  var body: some View {
    VStack(alignment: .leading, spacing: idiom == .phone ? metrics.cardGap : 14) {
      segments
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .task {
      await store.model.load()
    }
    .onChange(of: route.requests, initial: true) { _, _ in
      if let asked = route.take() { store.show(asked) }
    }
    .task(id: LoadKey(id: store.selected, kind: store.kind, generation: compute.generation)) {
      await store.reload(compute.snapshot, environment: environment)
    }
    .onChange(of: environment.amounts.isHidingNow) { _, _ in
      store.refreshShare(compute.snapshot, environment: environment)
    }
    .onChange(of: store.kind) { _, new in
      if store.selected?.kind != new { store.selected = store.archive(compute.snapshot).first }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("summaries.board")
  }

  private struct LoadKey: Hashable {
    var id: SummaryID?
    var kind: SummaryKind
    var generation: Int
  }

  // MARK: The switch

  private var kinds: [(value: SummaryKind, title: String)] {
    SummaryKind.allCases.map { ($0, t("summaries.kind.\($0.rawValue)")) }
  }

  @ViewBuilder private var segments: some View {
    @Bindable var store = store
    if idiom == .phone {
      PhoneCapsuleSegments(
        options: kinds, selection: $store.kind, identifier: { "summaries.kind.\($0.rawValue)" })
    } else {
      SectionSegments(
        options: kinds, selection: $store.kind, chipsOnTouch: false,
        identifier: { "summaries.kind.\($0.rawValue)" })
    }
  }

  // MARK: The board

  @ViewBuilder private var content: some View {
    let archive = store.archive(compute.snapshot)
    if archive.isEmpty || (!store.calculating && store.board?.hasData != true) {
      empty(archive.isEmpty ? "summaries.board.empty.text" : "summaries.noData")
    } else if let board = store.board, let snapshot = compute.snapshot {
      let text = PeriodsBoardText(
        environment: environment, names: SummaryNames(dataset: snapshot.dataset))
      PeriodsBoardCards(
        board: board, text: text, metrics: metrics, idiom: idiom,
        twoColumns: PeriodsBoardMetrics.fitsTwoColumns(idiom, width: width), width: width)
      if case .week(let cards) = store.content, cards.week.end < snapshot.today {
        question(cards)
      }
      if let range = store.selected?.range { HabitBadgesSection(range: range, snapshot: snapshot) }
    } else {
      Text(verbatim: t("summaries.calculating"))
        .appFont(.callout)
        .foregroundStyle(theme.contentSecondary)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }
  }

  /// A finished week asks how it went, one tap; an answer already given is marked and can be
  /// changed.
  private func question(_ cards: WeekCards) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: t("summaries.question.title"))
        .appFont(.headline)
      WeekMoodRow(language: environment.language, chosen: cards.mood?.mood) { mood in
        Task { await store.model.answer(week: cards.week, mood: mood, at: environment.now()) }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentCard()
  }

  /// No finished period yet, or none with operations (62:37169): a symbol, the title, the reason.
  private func empty(_ reason: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "chart.bar.xaxis")
        .appFont(AppFont.system(size: 22))
        .foregroundStyle(theme.contentSecondary)
        .accessibilityHidden(true)
      Text(verbatim: t("summaries.board.empty.title"))
        .appFont(PeriodsBoardType.emptyTitle)
        .foregroundStyle(theme.contentPrimary)
      Text(verbatim: t(reason))
        .appFont(PeriodsBoardType.emptyText)
        .foregroundStyle(theme.contentSecondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, minHeight: PeriodsBoardMetrics.emptyHeight)
    .boardCard(metrics)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("summaries.empty")
  }
}

/// The cards of one period: two columns on the Mac and a tablet — the coloured card and the ring,
/// then the columns beside the grades and the main categories — one column on a phone or in a
/// narrow window.
struct PeriodsBoardCards: View {
  let board: PeriodBoard
  let text: PeriodsBoardText
  let metrics: PeriodsBoardMetrics
  let idiom: LayoutIdiom
  let twoColumns: Bool
  let width: CGFloat

  var body: some View {
    if twoColumns {
      let left = PeriodsBoardMetrics.leftColumn(idiom, width: width)
      VStack(alignment: .leading, spacing: metrics.cardGap) {
        HStack(alignment: .top, spacing: metrics.cardGap) {
          hero.frame(width: left).frame(maxHeight: .infinity)
          donut.frame(maxHeight: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .top, spacing: metrics.cardGap) {
          columns
            .frame(width: left)
            .frame(minHeight: PeriodsBoardMetrics.columnsCardHeight, maxHeight: .infinity)
          VStack(spacing: metrics.cardGap) {
            grades.fixedSize(horizontal: false, vertical: true)
            top
          }
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    } else {
      VStack(alignment: .leading, spacing: metrics.cardGap) {
        hero
        donut
        top
        columns
        grades
      }
    }
  }

  private var hero: some View {
    PeriodsHeroCard(board: board, text: text, metrics: metrics)
  }

  private var donut: some View {
    PeriodsDonutCard(board: board, text: text, metrics: metrics)
  }

  private var columns: some View {
    PeriodsColumnsCard(board: board, text: text, metrics: metrics)
  }

  private var grades: some View {
    PeriodsGradesCard(board: board, text: text, metrics: metrics)
  }

  private var top: some View {
    PeriodsTopCard(board: board, text: text, metrics: metrics)
  }
}

// MARK: - The cards

/// «Неделя в цифрах»: the theme's gradient, the spending of the period, how it stands to the one
/// before, the bar of what was kept, and the income, the savings and the dearest day.
struct PeriodsHeroCard: View {
  @Environment(\.appTheme) private var theme
  let board: PeriodBoard
  let text: PeriodsBoardText
  let metrics: PeriodsBoardMetrics

  var body: some View {
    GradientCard(padding: metrics.heroPadding, cornerRadius: metrics.heroRadius) {
      VStack(alignment: .leading, spacing: metrics.heroGap) {
        Text(verbatim: text.title(board.id))
          .appFont(PeriodsBoardType.heroTitle)
          .accessibilityAddTraits(.isHeader)
        Text(verbatim: text.spentCaption(board.id.kind))
          .appFont(PeriodsBoardType.heroLine)
        Text(verbatim: text.rubles(board.spent))
          .appFont(PeriodsBoardType.heroFigure)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
          .accessibilityIdentifier("summaries.hero.figure")
        HStack(spacing: 4) {
          if let symbol = text.changeSymbol(board) {
            Image(systemName: symbol)
              .appFont(AppFont.system(size: 10, weight: .bold))
              .accessibilityHidden(true)
          }
          Text(verbatim: text.change(board))
            .appFont(PeriodsBoardType.heroLine)
        }
        .accessibilityElement(children: .combine)
        bar
        HStack(alignment: .top, spacing: metrics.heroFigureGap) {
          figure(text.t("summaries.board.income"), text.rubles(board.income))
          figure(text.t("summaries.board.saved"), text.saved(board))
          figure(text.highlightLabel(board), text.highlight(board))
        }
      }
      // Beside the ring the card is as tall as it.
      .frame(maxHeight: .infinity, alignment: .topLeading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("summaries.hero")
  }

  /// The share of the income kept: white on the theme's track.
  private var bar: some View {
    Capsule()
      .fill(theme.heroTrack)
      .frame(height: PeriodsBoardMetrics.heroBar)
      .overlay(alignment: .leading) {
        GeometryReader { proxy in
          RoundedRectangle(cornerRadius: PeriodsBoardMetrics.heroBar / 2)
            .fill(theme.heroProgress)
            .frame(width: Self.fill(board.keptFillBP, of: proxy.size.width))
        }
      }
      .accessibilityHidden(true)
  }

  /// The width of `basisPoints` of `width`: points on screen, never money.
  static func fill(_ basisPoints: Int, of width: CGFloat) -> CGFloat {
    width * CGFloat(basisPoints) / CGFloat(Shares.whole)
  }

  private func figure(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: label).appFont(PeriodsBoardType.heroLabel)
      Text(verbatim: value)
        .appFont(PeriodsBoardType.heroValue(metrics))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

/// «Куда ушли деньги»: the ring of the four categories and the rest, the spending of the period in
/// its hole, every part named with its percent beside it.
struct PeriodsDonutCard: View {
  @Environment(\.appTheme) private var theme
  let board: PeriodBoard
  let text: PeriodsBoardText
  let metrics: PeriodsBoardMetrics

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: text.t("summaries.card.categories"))
        .appFont(PeriodsBoardType.cardTitle)
        .foregroundStyle(theme.contentPrimary)
        .accessibilityAddTraits(.isHeader)
      HStack(spacing: PeriodsBoardMetrics.donutToLegend) {
        ShareDonutChart(
          slices: board.slices.enumerated().map { index, slice in
            ShareDonutSlice(
              id: slice.categoryId?.uuidString ?? "rest", name: text.category(slice.categoryId),
              basisPoints: slice.shareBP,
              tint: PeriodsBoardTint.slice(index, isRest: slice.categoryId == nil, theme))
          },
          figure: text.rubles(board.spent),
          caption: text.t("summaries.board.donut.\(board.id.kind.rawValue)"),
          side: PeriodsBoardMetrics.donut, figureType: PeriodsBoardType.donutFigure,
          captionType: PeriodsBoardType.donutCaption)
        VStack(alignment: .leading, spacing: PeriodsBoardMetrics.legendGap) {
          ForEach(Array(board.slices.enumerated()), id: \.offset) { index, slice in
            HStack(spacing: PeriodsBoardMetrics.legendGap) {
              Circle()
                .fill(PeriodsBoardTint.slice(index, isRest: slice.categoryId == nil, theme))
                .frame(width: PeriodsBoardMetrics.legendDot, height: PeriodsBoardMetrics.legendDot)
                .accessibilityHidden(true)
              Text(verbatim: text.category(slice.categoryId))
                .appFont(PeriodsBoardType.legendName)
                .lineLimit(1)
                // 90 as the frames draw it; a narrow phone takes from the name, never the percent.
                .frame(
                  minWidth: 0, idealWidth: PeriodsBoardMetrics.legendName,
                  maxWidth: PeriodsBoardMetrics.legendName, alignment: .leading)
              Text(verbatim: text.percent(slice.shareBP))
                .appFont(PeriodsBoardType.figure)
                .fixedSize()
            }
            .foregroundStyle(theme.contentPrimary)
            .accessibilityElement(children: .combine)
          }
        }
        Spacer(minLength: 0)
      }
    }
    .boardCard(metrics)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("summaries.donut")
  }
}

/// «Расходы по неделям»: six columns of the spending against the same spans a year before.
struct PeriodsColumnsCard: View {
  @Environment(\.appTheme) private var theme
  let board: PeriodBoard
  let text: PeriodsBoardText
  let metrics: PeriodsBoardMetrics

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: text.columnsTitle(board.id.kind))
        .appFont(PeriodsBoardType.cardTitle)
        .foregroundStyle(theme.contentPrimary)
        .accessibilityAddTraits(.isHeader)
      PeriodColumnsChart(
        columns: board.columns.map { column in
          PeriodColumn(
            id: column.range.start.iso, axisLabel: text.axis(column),
            spokenLabel: text.spoken(column), value: column.spent.wholeRubles,
            previous: column.previous.wholeRubles, valueText: text.rubles(column.spent),
            previousText: text.rubles(column.previous))
        },
        plotHeight: metrics.plotHeight, axisType: AppFont.system(size: metrics.axisSize)
      )
      .frame(maxWidth: metrics.plotWidth ?? .infinity, alignment: .leading)
      PeriodColumnsLegend(
        current: text.t("summaries.board.legend.current"),
        previous: text.t("summaries.board.legend.previous"),
        type: AppFont.system(size: metrics.axisSize))
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .boardCard(metrics)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("summaries.columns")
  }
}

/// «Хорошие, обычные и плохие траты»: a row for each with its symbol, its word, a bar as long as
/// its money against the largest, and the money with its share.
struct PeriodsGradesCard: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces
  let board: PeriodBoard
  let text: PeriodsBoardText
  let metrics: PeriodsBoardMetrics

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: text.t("summaries.board.grades"))
        .appFont(PeriodsBoardType.cardTitle)
        .foregroundStyle(theme.contentPrimary)
        .accessibilityAddTraits(.isHeader)
      let largest = board.grades.map(\.amount.raw).max() ?? 0
      ForEach(board.grades, id: \.quality) { grade in
        HStack(spacing: PeriodsBoardMetrics.gradeGap) {
          Image(systemName: Palette.qualitySymbol(grade.quality))
            .appFont(AppFont.system(size: 15))
            .foregroundStyle(ink(grade.quality))
            .frame(width: PeriodsBoardMetrics.gradeSymbol, height: PeriodsBoardMetrics.gradeSymbol)
            .accessibilityHidden(true)
          Text(verbatim: text.gradeName(grade.quality))
            .appFont(PeriodsBoardType.legendName)
            .foregroundStyle(theme.contentPrimary)
            .lineLimit(1)
            .frame(width: PeriodsBoardMetrics.gradeWord, alignment: .leading)
          // The track of the frame, shorter only when a narrow phone needs room for the figures.
          Capsule()
            .fill(theme.fillNeutral)
            .frame(maxWidth: metrics.gradeTrack)
            .frame(height: PeriodsBoardMetrics.gradeHeight)
            .overlay(alignment: .leading) {
              GeometryReader { proxy in
                Capsule()
                  .fill(ink(grade.quality))
                  .frame(
                    width: Self.fill(grade.amount.raw, largest: largest, track: proxy.size.width))
              }
            }
            .accessibilityHidden(true)
          Text(verbatim: text.grade(grade))
            .appFont(PeriodsBoardType.figure)
            .foregroundStyle(theme.contentPrimary)
            .lineLimit(1)
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("summaries.grade.\(grade.quality.rawValue)")
      }
    }
    .boardCard(metrics)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("summaries.grades")
  }

  /// Good in the theme's green, usual in its grey, poor in orange — never alone: the symbol and
  /// the word stand beside it.
  private func ink(_ quality: Quality) -> Color {
    quality == .bad ? Palette.quality(.bad) : surfaces.quality(quality)
  }

  /// The bar of `amount` on a track of `track`, the largest grade filling it; points on screen,
  /// never money.
  static func fill(_ amount: Int64, largest: Int64, track: CGFloat) -> CGFloat {
    guard largest > 0, amount > 0 else { return 0 }
    return track * CGFloat(amount) / CGFloat(largest)
  }
}

/// «Главные категории»: the four, two to a row, each with its chip and its money.
struct PeriodsTopCard: View {
  @Environment(\.appTheme) private var theme
  let board: PeriodBoard
  let text: PeriodsBoardText
  let metrics: PeriodsBoardMetrics

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.topGap) {
      Text(verbatim: text.t("summaries.board.top"))
        .appFont(PeriodsBoardType.topTitle)
        .foregroundStyle(theme.contentPrimary)
        .accessibilityAddTraits(.isHeader)
      let items = Array(board.topCategories.enumerated())
      ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
        HStack(alignment: .top, spacing: PeriodsBoardMetrics.topColumnsGap) {
          row(items[start].offset, items[start].element)
          if start + 1 < items.count {
            row(items[start + 1].offset, items[start + 1].element)
          } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
          }
        }
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .boardCard(metrics, padding: metrics.topPadding)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("summaries.top")
  }

  private func row(_ index: Int, _ category: SummaryCategory) -> some View {
    let name = text.category(category.categoryId)
    return HStack(spacing: PeriodsBoardMetrics.chipGap) {
      Text(verbatim: String(name.prefix(1)).uppercased())
        .appFont(PeriodsBoardType.chipLetter)
        .foregroundStyle(theme.contentOnAccent)
        .padding(.horizontal, PeriodsBoardMetrics.chipPadding)
        .frame(minWidth: 12, minHeight: PeriodsBoardMetrics.chipHeight)
        .background(
          PeriodsBoardTint.slice(index, isRest: false, theme),
          in: .rect(cornerRadius: PeriodsBoardMetrics.chipRadius)
        )
        .accessibilityHidden(true)
      Text(verbatim: name)
        .appFont(PeriodsBoardType.chipName)
        .lineLimit(1)
      Spacer(minLength: 4)
      Text(verbatim: text.rubles(category.amount))
        .appFont(PeriodsBoardType.figure)
    }
    .foregroundStyle(theme.contentPrimary)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Pieces

/// The period of the summary on screen, at the right of the header: «13–19 окт.», «Октябрь 2026»,
/// «2026»; it opens the finished periods of the kind to choose from, the latest first.
struct SummaryPeriodMenu: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let store: PeriodsBoardStore

  var body: some View {
    let archive = store.archive(compute.snapshot)
    Menu {
      ForEach(archive) { id in
        Button(PeriodsBoardStore.label(of: id, environment)) { store.selected = id }
      }
    } label: {
      Text(
        verbatim: store.selected.map { PeriodsBoardStore.label(of: $0, environment) }
          ?? environment.language("summaries.title", table: "Summaries")
      )
      .monospacedDigit()
    }
    .menuStyle(.button)
    .buttonStyle(.quietAction)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(archive.isEmpty)
    .accessibilityIdentifier("summaries.period")
  }
}

extension View {
  /// A white card of the board: the theme's card, its 1-pt edge, 16 inside (or `padding`),
  /// radius 12 on the Mac and 22 on touch.
  func boardCard(_ metrics: PeriodsBoardMetrics, padding: CGFloat? = nil) -> some View {
    modifier(BoardCard(radius: metrics.cardRadius, padding: padding ?? metrics.cardPadding))
  }
}

private struct BoardCard: ViewModifier {
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.colorSchemeContrast) private var contrast
  let radius: CGFloat
  let padding: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius)
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(padding)
      .background(surfaces.card, in: shape)
      .overlay {
        shape.strokeBorder(surfaces.cardBorder, lineWidth: 1)
        if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
      }
  }
}

/// The phone's switch: a capsule 34 tall over the width, the chosen segment white with its word,
/// the others on the track — the chosen one told by its fill, never the colour alone.
struct PhoneCapsuleSegments<Value: Hashable>: View {
  @Environment(\.appTheme) private var theme
  let options: [(value: Value, title: String)]
  @Binding var selection: Value
  var identifier: (Value) -> String = { _ in "" }

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options.indices, id: \.self) { index in
        let option = options[index]
        let selected = option.value == selection
        Button {
          selection = option.value
        } label: {
          Text(verbatim: option.title)
            .appFont(PeriodsBoardType.segmentPhone)
            .foregroundStyle(theme.contentPrimary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? theme.surfaceCard : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier(option.value))
      }
    }
    .padding(3)
    .frame(height: PeriodsBoardMetrics.phoneSegmentHeight)
    .background(theme.surfaceSegmented, in: Capsule())
  }
}
