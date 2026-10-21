import Foundation

/// The words VoiceOver says for the «…» button of a row in a Settings list: «Действия с
/// «Сбер»» / «Actions for «Sber»» — the row it acts on named, as in every list of Settings
/// (reference books, categories, accounts, groups, cards, templates).
@MainActor
enum SettingsRowMenu {
  static func label(_ name: String, _ environment: AppEnvironment) -> String {
    environment.format("references.rowMenu", table: "Settings", name)
  }
}
