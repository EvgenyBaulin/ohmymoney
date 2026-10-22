import AppCore
import SwiftUI

/// The progress bar of a goal as the design draws it: a thick capsule, the accent while the goal
/// is being saved and the positive colour once it is gathered. The words beside it («62 %»,
/// «собрана») carry the meaning; the colour only confirms it.
struct GoalProgressBar: View {
  @Environment(\.themeSurfaces) private var surfaces
  let basisPoints: Int

  static let height: CGFloat = 10

  /// The share of the track the bar fills, kept between none and the whole.
  static func fraction(basisPoints: Int) -> Double {
    Double(min(max(basisPoints, 0), Shares.whole)) / Double(Shares.whole)  // chart-only
  }

  static func isComplete(basisPoints: Int) -> Bool { basisPoints >= Shares.whole }

  var body: some View {
    let complete = Self.isComplete(basisPoints: basisPoints)
    Capsule()
      .fill(.quaternary)
      .overlay(alignment: .leading) {
        GeometryReader { proxy in
          Capsule()
            .fill(complete ? surfaces.positive : surfaces.accent)
            .frame(width: proxy.size.width * Self.fraction(basisPoints: basisPoints))
        }
      }
      .frame(height: Self.height)
      .clipShape(.capsule)
      .accessibilityHidden(true)
  }
}

/// The small rounded tile with a goal's symbol, tinted like its bar: a target while it is saved
/// for, a check once it is gathered.
struct GoalTile: View {
  @Environment(\.themeSurfaces) private var surfaces
  let complete: Bool
  /// What the tile shows while the goal is saved for; the cushion has its own.
  var symbol: String = "target"

  var body: some View {
    let tint = complete ? surfaces.positive : surfaces.accent
    Image(systemName: complete ? "checkmark" : symbol)
      .appFont(.callout.weight(.semibold))
      .foregroundStyle(tint)
      .frame(width: 36, height: 36)
      .background(tint.opacity(0.14), in: .rect(cornerRadius: 10))
      .accessibilityHidden(true)
  }
}
