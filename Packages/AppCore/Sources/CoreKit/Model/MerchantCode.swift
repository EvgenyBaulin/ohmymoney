import Foundation

/// The merchant category code (MCC) a bank gives a shop: four decimal digits, kept as text so
/// that «0742» keeps its zero.
public enum MerchantCode {
  /// Four digits from a text of up to four digits (`"742"` → `"0742"`, `" 5411 "` → `"5411"`);
  /// `nil` for an empty text or anything that is not a code.
  public static func normalized(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 4, trimmed.allSatisfy({ $0.isASCII && $0.isNumber })
    else { return nil }
    return String(repeating: "0", count: 4 - trimmed.count) + trimmed
  }

  /// The code from a number a text format read (`742` → `"0742"`); `nil` outside 0…9999.
  public static func normalized(_ number: Int?) -> String? {
    guard let number, (0...9999).contains(number) else { return nil }
    return normalized(String(number))
  }
}
