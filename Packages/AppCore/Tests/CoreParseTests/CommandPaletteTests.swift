import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// ⌘K: what a typed word finds, in what order, and the five last commands.
@Suite("Палитра команд")
struct CommandPaletteTests {
  static let sber = UUID()
  static let tbank = UUID()
  static let dark = UUID()
  static let latin = UUID()
  static let carLoan = UUID()
  static let goal = UUID()
  static let category = UUID()
  static let person = UUID()

  static let source = PaletteSource(
    accounts: [
      PaletteNamed(id: sber, name: "Сбер"), PaletteNamed(id: tbank, name: "Т-Банк"),
      PaletteNamed(id: dark, name: "Тёмный счёт"), PaletteNamed(id: latin, name: "Sber Cash"),
    ],
    debts: [PaletteNamed(id: carLoan, name: "Автокредит")],
    goals: [PaletteNamed(id: goal, name: "Отпуск")],
    categories: [PaletteNamed(id: category, name: "Такси")],
    people: [PaletteNamed(id: person, name: "Маша")])

  static let entries = PaletteCatalog.entries(for: source)

  private func ids(_ query: String, recents: PaletteRecents = PaletteRecents()) -> [String] {
    CommandPalette.search(query, in: Self.entries, recents: recents).map(\.id)
  }

  @Test("«сбер» находит открыть, сверить и перевод для Сбера — и ничего про Т-Банк")
  func anAccountHasThreeLines() {
    let found = ids("сбер")
    #expect(found.contains("account.open.\(Self.sber.uuidString)"))
    #expect(found.contains("account.reconcile.\(Self.sber.uuidString)"))
    #expect(found.contains("account.transfer.\(Self.sber.uuidString)"))
    #expect(!found.contains { $0.hasSuffix(Self.tbank.uuidString) })
  }

  @Test("Названия строк: «Открыть счёт Сбер», «Сверить Сбер…»")
  func theTitlesAreTheOnesTheOwnerSees() throws {
    let open = try #require(Self.entries.first { $0.id == "account.open.\(Self.sber.uuidString)" })
    #expect(open.searchTitles == ["Открыть счёт Сбер", "Open account Сбер"])
    #expect(open.argument == "Сбер")
    #expect(open.titleKey == "palette.account.open")
    let reconcile = try #require(
      Self.entries.first { $0.id == "account.reconcile.\(Self.sber.uuidString)" })
    #expect(reconcile.searchTitles.first == "Сверить Сбер…")
  }

  @Test("Падеж не мешает: «перевод со сбера»")
  func caseDoesNotMatter() {
    #expect(ids("перевод со сбера").first == "account.transfer.\(Self.sber.uuidString)")
  }

  @Test("Английские слова находят английские названия")
  func englishWords() {
    #expect(ids("reconcile sber").first == "account.reconcile.\(Self.latin.uuidString)")
    #expect(ids("new debt").first == "command.newDebt")
    #expect(ids("Новый долг").first == "command.newDebt")
  }

  @Test("Регистр и ё не важны")
  func caseAndYoDoNotMatter() {
    #expect(ids("ТЕМНЫЙ").contains("account.open.\(Self.dark.uuidString)"))
    #expect(ids("тёмный") == ids("темный"))
  }

  @Test("Начало слова находит слово; порядок слов не обязателен")
  func prefixesAndOrder() {
    #expect(ids("нов дол").first == "command.newDebt")
    #expect(ids("долг новый").contains("command.newDebt"))
    #expect(ids("кален").first == "screen.calendar")
  }

  @Test("Ничего подходящего — пусто")
  func noMatch() {
    #expect(ids("йцукенгшщзх").isEmpty)
  }

  @Test("Команда выше экрана выше вещи, когда слова совпали одинаково")
  func commandsBeforeThings() {
    let found = ids("долг")
    let command = found.firstIndex(of: "command.newDebt")
    let screen = found.firstIndex(of: "screen.debts")
    let thing = found.firstIndex(of: "debt.open.\(Self.carLoan.uuidString)")
    #expect(command != nil && screen != nil && thing != nil)
    if let command, let screen, let thing { #expect(command < screen && command < thing) }
    #expect(ids("автокредит") == ["debt.open.\(Self.carLoan.uuidString)"])
  }

  @Test("Долги, цели, категории и люди открываются; операций среди строк нет")
  func theThingsToOpen() {
    #expect(ids("отпуск") == ["goal.open.\(Self.goal.uuidString)"])
    #expect(ids("маша") == ["person.open.\(Self.person.uuidString)"])
    #expect(ids("категорию такси") == ["category.open.\(Self.category.uuidString)"])
    // Only accounts, debts, goals, categories and people get lines of their own.
    let kinds = Set(Self.entries.map(\.kind))
    #expect(kinds == Set(PaletteKind.allCases))
    #expect(Set(Self.entries.map(\.id)).count == Self.entries.count)
  }

  @Test("Каждая команда — и пункт меню: у неё есть имя")
  func everyCommandIsAMenuItem() {
    let commands = Set(PaletteCatalog.fixedEntries.filter { $0.kind == .command }.map(\.id))
    #expect(!PaletteCatalog.menuCommandIds.isEmpty)
    #expect(Set(PaletteCatalog.menuCommandIds) == commands)
    #expect(PaletteCatalog.fixedEntries.allSatisfy { $0.searchTitles.count == 2 })
  }

  // MARK: Recents

  @Test("Пустой запрос: сначала последние команды, потом остальные команды и экраны")
  func emptyQueryShowsRecents() {
    let recents = PaletteRecents().recording("command.newDebt").recording("screen.capital")
    let found = ids("", recents: recents)
    #expect(found.prefix(2) == ["screen.capital", "command.newDebt"])
    #expect(found.filter { $0 == "command.newDebt" }.count == 1)
    #expect(found.allSatisfy { !$0.hasPrefix("account.") })
  }

  @Test("Последних не больше пяти, новая — первой, повтор не двоится")
  func recentsKeepFive() {
    var recents = PaletteRecents()
    for index in 1...7 { recents = recents.recording("command.\(index)") }
    #expect(recents.ids == ["command.7", "command.6", "command.5", "command.4", "command.3"])
    recents = recents.recording("command.5")
    #expect(recents.ids == ["command.5", "command.7", "command.6", "command.4", "command.3"])
  }

  @Test("Закрытый счёт уходит из последних")
  func recentsForgetWhatIsGone() {
    let gone = "account.open.\(UUID().uuidString)"
    let recents = PaletteRecents(ids: [gone, "command.newDebt"]).keeping(existing: Self.entries)
    #expect(recents.ids == ["command.newDebt"])
    #expect(!ids("", recents: PaletteRecents(ids: [gone])).contains(gone))
  }

  @Test("Недавняя команда при поиске чуть выше такой же")
  func aRecentOneRanksHigher() {
    let plain = ids("нов")
    #expect(plain.first == "command.newOperation")
    let recents = PaletteRecents().recording("command.newGoal")
    #expect(ids("нов", recents: recents).first == "command.newGoal")
  }

  @Test("Последние хранятся строкой JSON и читаются обратно; мусор — пустой список")
  func recentsRoundTrip() {
    let recents = PaletteRecents().recording("a").recording("b")
    #expect(PaletteRecents(json: recents.json) == recents)
    #expect(PaletteRecents(json: "не json") == PaletteRecents())
    #expect(PaletteRecents(json: nil) == PaletteRecents())
    #expect(PaletteRecents.settingsKey == "palette.recent")
  }

  @Test("Готовый индекс даёт то же, что список")
  func anIndexAgreesWithTheList() {
    let index = PaletteIndex(Self.entries)
    let recents = PaletteRecents().recording("screen.capital")
    for query in ["", "сбер", "нов", "долг", "reconcile", "ё", "йцук"] {
      #expect(
        CommandPalette.search(query, in: index, recents: recents)
          == CommandPalette.search(query, in: Self.entries, recents: recents), "«\(query)»")
    }
  }

  @Test("Предел числа строк")
  func theLimit() {
    #expect(CommandPalette.search("о", in: Self.entries, limit: 3).count <= 3)
  }
}
