import AppCore
import SwiftUI

/// One accent colour for the app; everything else is semantic.
/// Quality is never shown by colour alone — always with a label or a symbol.
///
/// The accent itself is not here any more: since the owner chooses it, it has to come from the
/// environment. A shape takes `.tint`, which follows the `.tint(_:)` set in `appDependencies(_:)`;
/// a chart takes `\.appAccent`, because `Color.accentColor` does not.
public enum Palette {
  public static func quality(_ quality: Quality) -> Color {
    switch quality {
    case .good: .green
    case .neutral: .secondary
    case .bad: .orange
    }
  }

  public static func qualitySymbol(_ quality: Quality) -> String {
    switch quality {
    case .good: "arrow.up.forward.circle"
    case .neutral: "circle"
    case .bad: "exclamationmark.triangle"
    }
  }

  public static func qualityKey(_ quality: Quality) -> String {
    switch quality {
    case .good: "quality.good"
    case .neutral: "quality.neutral"
    case .bad: "quality.bad"
    }
  }

  /// A part paid for somebody else, by what became of the money. The symbol always comes
  /// with its words (`reimbursementKey`): the status is never told by colour or shape alone.
  public static func reimbursementSymbol(_ status: ReimbursementStatus) -> String {
    switch status {
    case .expected: "person.crop.circle.badge.clock"
    case .returned: "person.crop.circle.badge.checkmark"
    case .writtenOff: "person.crop.circle.badge.xmark"
    }
  }

  public static func reimbursementKey(_ status: ReimbursementStatus) -> String {
    switch status {
    case .expected: "reimbursementStatus.expected"
    case .returned: "reimbursementStatus.returned"
    case .writtenOff: "reimbursementStatus.writtenOff"
    }
  }

  /// The arrow of a change against the period before; the number beside it carries the
  /// sign. Secondary, never «good» green or «bad» red: more spending is not always worse.
  public static func changeSymbol(_ direction: ChangeDirection) -> String {
    switch direction {
    case .up: "arrow.up.right"
    case .down: "arrow.down.right"
    case .flat: "equal"
    }
  }

  public static func kindSymbol(_ kind: TransactionKind) -> String {
    switch kind {
    case .expense: "arrow.down.circle"
    case .income: "arrow.up.circle"
    case .refund: "arrow.uturn.left.circle"
    case .reimbursement: "person.crop.circle.badge.checkmark"
    }
  }
}

/// A label that shows quality with text and a symbol, never with colour alone.
public struct QualityTag: View {
  private let quality: Quality
  private let title: String
  private let font: AppFont
  @Environment(\.themeSurfaces) private var surfaces

  /// `font` is the caption of a row by default; a card sets it to its own lines.
  public init(quality: Quality, title: String, font: AppFont = .caption) {
    self.quality = quality
    self.title = title
    self.font = font
  }

  public var body: some View {
    Label {
      Text(verbatim: title)
    } icon: {
      Image(systemName: Palette.qualitySymbol(quality))
    }
    .foregroundStyle(surfaces.quality(quality))
    .labelStyle(.titleAndIcon)
    .appFont(font)
  }
}
