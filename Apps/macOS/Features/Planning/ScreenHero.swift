import AppCore
import SwiftUI

/// The card at the top of Planning, Capital and a trip: a small caption, the one figure big, and
/// a few lines of what it is made of, on the theme's hero gradient (`heroStart` to `heroEnd`,
/// text in `heroContent`). Content, never glass. «Увеличить контраст» switches the whole app to
/// the Contrast theme and adds the separator edge. The meaning is in the words; the colour only
/// marks the card as the one figure of the screen.
struct ScreenHero: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  let caption: String
  let figure: String
  var lines: [String] = []
  var figureIdentifier: String = "screen.hero.figure"

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: caption)
        .appFont(.callout)
        .opacity(0.85)
      Text(verbatim: figure)
        .appFont(.largeTitle.bold().monospacedDigit())
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .accessibilityIdentifier(figureIdentifier)
      ForEach(Array(lines.enumerated()), id: \.offset) { position, line in
        Text(verbatim: line)
          .appFont(position == 0 ? .callout.monospacedDigit() : .caption.monospacedDigit())
          .opacity(0.85)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .foregroundStyle(theme.heroContent)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .background(background, in: .rect(cornerRadius: 16))
    .overlay {
      if contrast == .increased {
        RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("screen.hero")
  }

  private var background: LinearGradient {
    LinearGradient(
      colors: [theme.heroStart, theme.heroEnd], startPoint: .topLeading,
      endPoint: .bottomTrailing)
  }
}

/// The header of a card of these screens: the title on the left, a quiet caption («4 ближайших»,
/// «ожидается 120 000 ₽») on the right.
struct ScreenCardHeader: View {
  let title: String
  var caption: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: title)
        .appFont(.headline)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      if let caption {
        Text(verbatim: caption)
          .appFont(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
  }
}

/// Which of two columns a screen's cards go in on a wide window, and when it is narrow enough
/// for one. The screens of Planning, Capital and a trip share the break.
enum ScreenColumns {
  static let twoFrom: CGFloat = 760

  static func count(forWidth width: CGFloat) -> Int { width >= twoFrom ? 2 : 1 }

  /// Deals `items` into `count` columns by turns, keeping their order inside a column.
  static func deal<Item>(_ items: [Item], into count: Int) -> [[Item]] {
    let count = max(count, 1)
    var columns = Array(repeating: [Item](), count: count)
    for (index, item) in items.enumerated() { columns[index % count].append(item) }
    return columns
  }
}

/// The words of the hero card of Planning: the free sum's caption, its figure, the sentence
/// about the day and the payments, and the terms taken away from the figure on one line.
enum PlanningHero {
  struct Content: Equatable {
    var caption: String
    var figure: String
    var lines: [String]
  }

  /// `nil` while nothing is counted and there is no figure to show.
  @MainActor
  static func make(free: FreeMoney, environment: AppEnvironment) -> Content? {
    guard free.state == .ready, let main = free.main, let summary = PlanningSummary(free) else {
      return nil
    }
    let spendable = free.goalSavings > .zero || free.cushion > .zero
    var lines = [PlanningBlockText.sentence(summary, environment)]
    let terms = free.lines.filter { $0.amount != .zero }.map { line in
      PlanningText.sign(line.sign == .plus) + " "
        + environment.language(line.key, table: "Planning") + " "
        + environment.money.rounded(line.amount)
    }
    if !terms.isEmpty { lines.append(terms.joined(separator: " · ")) }
    return Content(
      caption: PlanningBlockText.t(spendable ? "free.mainSpendable" : "free.main", environment),
      figure: environment.money.rounded(main), lines: lines)
  }
}
