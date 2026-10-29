import AppCore
import SwiftUI

/// The twelve colours an account can wear, keyed `01`…`12` in `payment_methods.accent`. Each is
/// one colour for both schemes, picked at a luminance where it holds at least 3 : 1 against the
/// lightest and the darkest surface of every theme, so a dot or a stripe of it reads on a light
/// card, a dark one and in «Увеличить контраст». It never carries meaning alone: the name of the
/// account always stands next to it. On the gradient cards of the phone the colour is the card
/// itself and the words on it are white (4.5 : 1 and more).
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
    }
  }

  var swatch: Color { Color(color) }

  /// The String Catalog key (table `Accounts`) of the colour's name, for VoiceOver and help.
  var nameKey: String { "account.accent.\(rawValue)" }
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

  var body: some View {
    Circle()
      .fill(accent.swatch)
      .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
      .frame(width: diameter, height: diameter)
      .accessibilityHidden(true)
  }
}
