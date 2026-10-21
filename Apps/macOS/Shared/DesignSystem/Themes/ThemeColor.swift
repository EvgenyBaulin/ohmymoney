import Foundation

/// One colour of a theme, as plain bytes: no UI framework, so the data of the themes can be read
/// (and tested) anywhere. `0xRRGGBBAA` is the order the themes JSON writes it in.
public struct ThemeColor: Equatable, Hashable, Sendable {
  public let red: UInt8
  public let green: UInt8
  public let blue: UInt8
  public let alpha: UInt8

  public init(_ rgba: UInt32) {
    red = UInt8((rgba >> 24) & 0xFF)
    green = UInt8((rgba >> 16) & 0xFF)
    blue = UInt8((rgba >> 8) & 0xFF)
    alpha = UInt8(rgba & 0xFF)
  }

  public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// Reads `#RRGGBB` or `#RRGGBBAA`; anything else is `nil`.
  public init?(hex: String) {
    guard hex.hasPrefix("#"), hex.count == 7 || hex.count == 9 else { return nil }
    let digits = hex.dropFirst()
    guard digits.allSatisfy(\.isHexDigit), var value = UInt32(digits, radix: 16) else {
      return nil
    }
    if digits.count == 6 { value = (value << 8) | 0xFF }
    self.init(value)
  }

  /// WCAG relative luminance of the colour itself, alpha ignored.
  var relativeLuminance: Double {  // stats-only
    func linear(_ byte: UInt8) -> Double {
      let value = Double(byte) / 255
      return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// This colour laid over an opaque `background`.
  public func composited(over background: ThemeColor) -> ThemeColor {
    guard alpha < 255 else { return self }
    let a = Double(alpha) / 255
    func mix(_ top: UInt8, _ bottom: UInt8) -> UInt8 {
      UInt8((Double(top) * a + Double(bottom) * (1 - a)).rounded())
    }
    return ThemeColor(
      red: mix(red, background.red), green: mix(green, background.green),
      blue: mix(blue, background.blue))
  }

  /// WCAG contrast ratio (1...21) of this colour on `background`; a translucent colour is
  /// first laid over the background.
  func contrast(on background: ThemeColor) -> Double {  // stats-only
    let top = composited(over: background).relativeLuminance
    let bottom = background.relativeLuminance
    return (max(top, bottom) + 0.05) / (min(top, bottom) + 0.05)
  }
}
