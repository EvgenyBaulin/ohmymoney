import AppCore
import Foundation

/// The words of the receipt by QR (the `Receipt` catalog).
@MainActor
enum ReceiptText {
  static let table = "Receipt"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  ) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }
}
