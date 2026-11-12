import XCTest

@testable import OhMyMoney

@MainActor
final class NamesakeLocalizationTests: XCTestCase {
  func testEveryNamesakeChoiceAndArchiveActionHasBothTranslations() {
    let language = AppLanguage()
    let previous = language.choice
    defer { language.choice = previous }
    let keys = [
      "expected.archiveAction", "namesake.live", "namesake.archived", "namesake.canSave",
      "namesake.noHistory", "namesake.renameNew", "namesake.renameExisting",
      "namesake.renameArchived", "namesake.rename", "namesake.suggested", "namesake.restore",
      "namesake.hidePair", "namesake.financial.unique", "namesake.financial.alias",
      "namesake.financial.notSaved", "namesake.financial.renameNewAlias",
      "namesake.financial.renameArchivedAlias", "namesake.financial.restoreCardAccount",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(language(key, table: "Planning"), key)
      }
    }
    language.choice = .russian
    XCTAssertEqual(language("expected.archiveAction", table: "Planning"), "В архив")
    XCTAssertEqual(
      language(
        "namesake.hidePair", "namesake.financial.unique", "namesake.financial.alias",
        "namesake.financial.notSaved", "namesake.financial.renameNewAlias",
        "namesake.financial.renameArchivedAlias", "namesake.financial.restoreCardAccount",
        table: "Planning"),
      "Скрыть предупреждение для этой пары")
    language.choice = .english
    XCTAssertEqual(language("expected.archiveAction", table: "Planning"), "Archive")
  }
}
