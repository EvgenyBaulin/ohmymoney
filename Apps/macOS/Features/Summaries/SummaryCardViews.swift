import AppCore
import SwiftUI

/// One card of a summary: its title and its lines. Content, so a plain card — no glass.
struct SummaryCardView: View {
  let title: String
  let lines: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: title)
        .appFont(.headline)
        .accessibilityAddTraits(.isHeader)
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        Text(verbatim: line)
          .appFont(.body)
          .monospacedDigit()
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentCard()
    .accessibilityElement(children: .combine)
  }
}

/// The cards of a summary in a ribbon.
struct SummaryRibbon: View {
  let cards: [SummaryCard]
  let text: SummaryText

  var body: some View {
    VStack(spacing: 12) {
      ForEach(cards) { card in
        SummaryCardView(title: text.title(card), lines: text.lines(card))
      }
    }
  }
}

/// The five faces of «Как прошла неделя?»: one tap. The chosen one is marked by its shape (a
/// ring and a filled symbol) as well as by colour.
struct WeekMoodRow: View {
  static let faces = ["😞", "🙁", "😐", "🙂", "😄"]

  let language: AppLanguage
  let chosen: Int?
  let onPick: (Int) -> Void

  var body: some View {
    HStack(spacing: 10) {
      ForEach(1...5, id: \.self) { mood in
        Button {
          onPick(mood)
        } label: {
          VStack(spacing: 2) {
            Text(verbatim: Self.faces[mood - 1])
              .appFont(.title)
            Text(verbatim: language("summaries.mood.\(mood)", table: "Summaries"))
              .appFont(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .minimumScaleFactor(0.7)
          }
          .frame(maxWidth: .infinity, minHeight: 48)
          .padding(.vertical, 4)
          .background {
            if chosen == mood {
              RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language("summaries.mood.\(mood)", table: "Summaries"))
        .accessibilityAddTraits(chosen == mood ? .isSelected : [])
        .accessibilityIdentifier("summaries.mood.\(mood)")
      }
    }
  }
}
