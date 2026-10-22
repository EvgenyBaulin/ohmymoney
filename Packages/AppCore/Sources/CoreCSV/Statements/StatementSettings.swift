import Foundation

/// Keys of the `settings` table that the loading of statements reads.
public enum StatementSettings {
  /// The id of the category «Не разобрано», where an operation the owner put off ("decide
  /// later") is filed. It is an ordinary category the app creates on first need and finds by
  /// this key; it is not a system category, which the schema could only widen by rebuilding the
  /// table of categories.
  public static let unsortedCategoryKey = "import.unsortedCategory"
}
