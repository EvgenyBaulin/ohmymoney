import Foundation

/// Settings of the tiles of Overview that live in the database (the table `settings`, carried by
/// the archive with the rest of the books).
public enum OverviewSettings {
  /// The most a purchase may cost to be a «small purchase» (tile 88), in whole rubles; absent or
  /// not a positive number — not set, and the tile has nothing to count.
  public static let smallPurchaseLimitKey = "overview.smallPurchaseLimit"

  /// The limit the stored text says, in rubles; `nil` for none, zero, a negative or a text that
  /// is no whole number.
  public static func smallPurchaseLimit(from stored: String?) -> AmountE4? {
    guard let text = stored?.trimmingCharacters(in: .whitespaces), let whole = Int64(text),
      whole > 0, whole <= maximumSmallPurchaseLimit
    else { return nil }
    return AmountE4(whole: whole)
  }

  /// The text to store for a limit in whole rubles; an empty text for none (the table keeps no
  /// empty value apart from this one, which reads as not set).
  public static func text(forSmallPurchaseLimit whole: Int64?) -> String {
    guard let whole, whole > 0, whole <= maximumSmallPurchaseLimit else { return "" }
    return String(whole)
  }

  /// A small purchase is never more than this: a limit above it is a typing slip.
  public static let maximumSmallPurchaseLimit: Int64 = 1_000_000

  /// What the limit is when the owner switches the tile on without saying: the app proposes it.
  public static let suggestedSmallPurchaseLimit: Int64 = 500
}
