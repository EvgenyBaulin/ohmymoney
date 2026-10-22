import AppCore
import SwiftUI

/// «Как это будет»: the tinted block under a step or a sheet that says, in a few short lines,
/// what saving it will do. Content, not glass: the theme's accent tint with the accent content
/// colour for the title.
struct DebtInfoBlock: View {
  @Environment(\.appTheme) private var theme
  let title: String
  let lines: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: title)
        .appFont(.subheadline.weight(.semibold))
        .foregroundStyle(Color(theme.palette.accentContent))
        .accessibilityAddTraits(.isHeader)
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(verbatim: "•")
          Text(verbatim: line).fixedSize(horizontal: false, vertical: true)
        }
        .appFont(.callout)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color(theme.palette.accentTint), in: .rect(cornerRadius: 12))
    .accessibilityElement(children: .combine)
  }
}

/// The dots under the title of the wizard: the steps done and the one on screen are filled, the
/// ones ahead are hollow, so progress never rests on colour alone (the step is also said in
/// words beside the title).
struct DebtStepDots: View {
  @Environment(\.themeSurfaces) private var surfaces
  let current: Int
  let count: Int

  var body: some View {
    HStack(spacing: 6) {
      ForEach(0..<count, id: \.self) { index in
        Circle()
          .fill(index <= current ? surfaces.accent : surfaces.cardBorder)
          .frame(width: 8, height: 8)
          .overlay {
            if index > current {
              Circle().strokeBorder(surfaces.secondary.opacity(0.5), lineWidth: 1)
            }
          }
      }
    }
    .accessibilityHidden(true)
  }
}

/// One choice of a step as a card with a round mark: the chosen card is tinted and edged in the
/// accent, the mark is filled — a shape, not only a colour.
struct DebtOptionCard: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces
  let title: String
  var subtitle: String?
  var symbol: String?
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? surfaces.accent : surfaces.secondary)
          .imageScale(.large)
        if let symbol {
          Image(systemName: symbol).foregroundStyle(surfaces.secondary).frame(width: 22)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: title).appFont(.callout.weight(.semibold))
          if let subtitle {
            Text(verbatim: subtitle).appFont(.caption).foregroundStyle(surfaces.secondary)
          }
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(
        selected ? Color(theme.palette.accentTint) : surfaces.card, in: .rect(cornerRadius: 12)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(
            selected ? surfaces.accent : surfaces.cardBorder, lineWidth: selected ? 1.5 : 0.5)
      }
      .contentShape(.rect(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// «Части» of an instalment plan: one tile per part, the paid ones ticked and tinted with the
/// word «оплачена», the others with their number and «ждёт» — the state is in the words and the
/// tick, the green only confirms it.
struct InstalmentPartsCard: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  let parts: Int
  let paid: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: t("parts.title")).appFont(.headline).accessibilityAddTraits(.isHeader)
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8
      ) {
        ForEach(1...max(parts, 1), id: \.self) { number in
          tile(number)
        }
      }
    }
    .contentCard()
    .accessibilityIdentifier("debts.parts")
  }

  private func tile(_ number: Int) -> some View {
    let done = number <= paid
    return VStack(spacing: 2) {
      if done {
        Image(systemName: "checkmark").foregroundStyle(surfaces.positive)
      } else {
        Text(verbatim: String(number)).appFont(.headline).monospacedDigit()
      }
      Text(verbatim: t(done ? "parts.paid" : "parts.waits"))
        .appFont(.caption2).foregroundStyle(surfaces.secondary).lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, minHeight: 46)
    .padding(.vertical, 4)
    .background(done ? surfaces.positive.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(done ? surfaces.positive : surfaces.cardBorder, lineWidth: done ? 1 : 0.5)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      Text(verbatim: "\(number) · \(t(done ? "parts.paid" : "parts.waits"))"))
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
