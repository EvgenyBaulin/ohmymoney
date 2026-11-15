import AppCore
import SwiftUI

/// The colours an account can wear, keyed `01`, `02`, … in `payment_methods.accent`. The keys are
/// stored: the first twelve (the classics) never change and a new colour only takes the next
/// key. A classic is one colour for both schemes, picked at a luminance where it holds at least
/// 3 : 1 against the lightest and the darkest surface of every theme; the colours after them
/// (yellows, reds and blues close to what banks wear, and a few shades) are named as colours,
/// never as brands, and a dot of one is told from its surface by the hairline edge. A colour
/// never carries meaning alone: the name of the account always stands next to it. On a card the
/// colour is the card itself and the words on it take white or black, whichever reads
/// (`cardPaint`).
enum AccountAccent: String, CaseIterable, Sendable {
  case c01 = "01"
  case c02 = "02"
  case c03 = "03"
  case c04 = "04"
  case c05 = "05"
  case c06 = "06"
  case c07 = "07"
  case c08 = "08"
  case c09 = "09"
  case c10 = "10"
  case c11 = "11"
  case c12 = "12"
  case c13 = "13"
  case c14 = "14"
  case c15 = "15"
  case c16 = "16"
  case c17 = "17"
  case c18 = "18"
  case c19 = "19"
  case c20 = "20"
  case c21 = "21"
  case c22 = "22"
  case c23 = "23"
  case c24 = "24"
  case c25 = "25"
  case c26 = "26"

  /// The twelve colours every version has had.
  static let classic: [AccountAccent] = Array(allCases.prefix(12))

  var isClassic: Bool { Self.classic.contains(self) }

  /// The key as stored.
  var key: String { rawValue }

  /// The accent a stored key names; `nil` for no key and for a key this version does not know.
  init?(key: String?) {
    guard let key, let found = Self(rawValue: key) else { return nil }
    self = found
  }

  var color: ThemeColor {
    switch self {
    case .c01: ThemeColor(0xDD34_2EFF)
    case .c02: ThemeColor(0xCA4E_10FF)
    case .c03: ThemeColor(0x9271_18FF)
    case .c04: ThemeColor(0x5D81_15FF)
    case .c05: ThemeColor(0x1688_3CFF)
    case .c06: ThemeColor(0x1684_76FF)
    case .c07: ThemeColor(0x1A7F_A1FF)
    case .c08: ThemeColor(0x2973_DCFF)
    case .c09: ThemeColor(0x6E63_E6FF)
    case .c10: ThemeColor(0xA24A_E2FF)
    case .c11: ThemeColor(0xDA23_8EFF)
    case .c12: ThemeColor(0x7676_76FF)
    case .c13: ThemeColor(0xFFDD_2DFF)
    case .c14: ThemeColor(0xFEE6_00FF)
    case .c15: ThemeColor(0xFFB0_00FF)
    case .c16: ThemeColor(0xE306_11FF)
    case .c17: ThemeColor(0x00A6_50FF)
    case .c18: ThemeColor(0x009F_DFFF)
    case .c19: ThemeColor(0x005B_FFFF)
    case .c20: ThemeColor(0x0A28_96FF)
    case .c21: ThemeColor(0x4A55_68FF)
    case .c22: ThemeColor(0x1A1A_1AFF)
    case .c23: ThemeColor(0x8ADB_B8FF)
    case .c24: ThemeColor(0xFFB3_8AFF)
    case .c25: ThemeColor(0xB9A8_F2FF)
    case .c26: ThemeColor(0xD8C6_A0FF)
    }
  }

  var swatch: Color { Color(color) }

  /// How a card of this colour is painted: the colour, the end its gradient runs to and the ink
  /// of the words on it. White on a darker colour with the end darkened by 30 %, black on a
  /// lighter one with the end lightened by 20 %, so the ink reads at 4.5 : 1 on both ends; a
  /// colour near the middle of the scale takes whichever ink fits it, because the end moves
  /// away from the ink, never toward it.
  var cardPaint: CardPaint {
    let white = ThemeColor(0xFFFF_FFFF)
    let black = ThemeColor(0x0000_00FF)
    if white.contrast(on: color) >= 4.5 {
      return CardPaint(start: color, end: color.mixed(with: black, by: 0.3), ink: white)
    }
    return CardPaint(start: color, end: color.mixed(with: white, by: 0.2), ink: black)
  }

  struct CardPaint: Equatable, Sendable {
    let start: ThemeColor
    let end: ThemeColor
    let ink: ThemeColor
  }

  /// The String Catalog key (table `Accounts`) of the colour's name, for VoiceOver and help.
  var nameKey: String { "account.accent.\(rawValue)" }
}

extension ThemeColor {
  /// This colour moved `fraction` of the way toward `other`, byte by byte.
  func mixed(with other: ThemeColor, by fraction: Double) -> ThemeColor {  // stats-only
    func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
      UInt8((Double(a) + (Double(b) - Double(a)) * fraction).rounded())
    }
    return ThemeColor(
      red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue))
  }
}

extension PaymentMethod {
  /// The colour the account wears; `nil` for none.
  var accountAccent: AccountAccent? { AccountAccent(key: accent) }
}

/// A round mark of an account's colour with a hairline edge. Decoration only: hidden from
/// VoiceOver, the name of the account stands next to it.
struct AccountAccentDot: View {
  let accent: AccountAccent
  var diameter: CGFloat = 8
  @Environment(\.appTheme) private var theme

  var body: some View {
    Circle()
      .fill(Color(WindowTint.markColor(for: accent, colors: theme)))
      .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
      .frame(width: diameter, height: diameter)
      .accessibilityHidden(true)
  }
}
