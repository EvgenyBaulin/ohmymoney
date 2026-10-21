import XCTest

@testable import OhMyMoney

final class BackupNameTests: XCTestCase {
  private let moscow = TimeZone(identifier: "Europe/Moscow")!

  private func moment(_ h: Int, _ m: Int, day: Int = 6) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = moscow
    return calendar.date(
      from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
  }

  private func russian(_ word: BackupName.Word) -> String {
    switch word {
    case .reason(.change): "после правки"
    case .reason(.daily): "ежедневная"
    case .reason(.beforeMigration(let to)): "перед обновлением" + (to.map { " до \($0)" } ?? "")
    case .reason(.beforeRestore): "перед восстановлением"
    case .reason(.beforeImport): "перед импортом"
    case .reason(.beforeRepair): "перед исправлением"
    case .damaged: "повреждена"
    }
  }

  private func english(_ word: BackupName.Word) -> String {
    switch word {
    case .reason(.change): "after a change"
    case .reason(.daily): "daily"
    case .reason(.beforeMigration(let to)): "before the update" + (to.map { " to \($0)" } ?? "")
    case .reason(.beforeRestore): "before restoring"
    case .reason(.beforeImport): "before import"
    case .reason(.beforeRepair): "before repair"
    case .damaged: "damaged"
    }
  }

  private var wordings: [(BackupName.Word, String)] {
    let words: [BackupName.Word] = [
      .reason(.change), .reason(.daily), .reason(.beforeMigration(to: nil)),
      .reason(.beforeRestore), .reason(.beforeImport), .reason(.beforeRepair), .damaged,
    ]
    return words.flatMap { [($0, russian($0)), ($0, english($0))] }
  }

  func testTheNameIsDateAndTimeFirstWithoutAColon() {
    let name = BackupName(moment: moment(23, 32), appVersion: "1.12.0", reason: .change)
    let text = name.fileName(in: moscow, words: russian)
    XCTAssertEqual(text, "2026-10-06 23.32 · 1.12.0 · после правки.sqlite")
    XCTAssertFalse(text.contains(":") || text.contains("/"))
  }

  func testTheNamesSortByNameAsTheyDoByTime() {
    let names = [moment(9, 5), moment(23, 32), moment(10, 0, day: 7), moment(0, 1)]
      .map {
        BackupName(moment: $0, appVersion: "1.12.0", reason: .change)
          .fileName(in: moscow, words: russian)
      }
    let byTime = [moment(0, 1), moment(9, 5), moment(23, 32), moment(10, 0, day: 7)]
      .map {
        BackupName(moment: $0, appVersion: "1.12.0", reason: .change)
          .fileName(in: moscow, words: russian)
      }
    XCTAssertEqual(names.sorted(), byTime)
  }

  func testEveryReasonReadsBackInBothLanguagesFromOneParse() {
    let reasons: [BackupName.Reason] = [
      .change, .daily, .beforeMigration(to: "10"), .beforeMigration(to: nil), .beforeRestore,
      .beforeImport,
    ]
    for reason in reasons {
      for words in [russian, english] {
        let made = BackupName(moment: moment(8, 30), appVersion: "1.12.0", reason: reason)
        let text = made.fileName(in: moscow, words: words)
        let read = BackupName.parse(text, in: moscow, wordings: wordings)
        XCTAssertEqual(read, made, text)
      }
    }
  }

  func testADamagedCopyAndASecondOfTheSameMinuteKeepTheirMarks() {
    let made = BackupName(
      moment: moment(8, 30), appVersion: "1.12.0", reason: .beforeRestore, damaged: true,
      duplicate: 3)
    let text = made.fileName(in: moscow, words: english)
    XCTAssertEqual(text, "2026-10-06 08.30 · 1.12.0 · before restoring (damaged) (3).sqlite")
    XCTAssertEqual(BackupName.parse(text, in: moscow, wordings: wordings), made)
  }

  func testAnOldNameAndAMadeUpDateAreNotOfThisKind() {
    XCTAssertNil(
      BackupName.parse(
        "finance-2026-10-06T233200+0300.sqlite", in: moscow, wordings: wordings))
    XCTAssertNil(
      BackupName.parse(
        "2026-13-40 08.30 · 1.12.0 · после правки.sqlite", in: moscow, wordings: wordings))
    XCTAssertNil(
      BackupName.parse("2026-10-06 08.30 · 1.12.0 · что-то.sqlite", in: moscow, wordings: wordings))
  }

  func testThePathCharactersAFileSystemRefusesAreLeftOut() {
    let made = BackupName(moment: moment(8, 30), appVersion: "1.12/0", reason: .change)
    let text = made.fileName(in: moscow) { _ in "a:b/c" }
    XCTAssertFalse(text.dropLast(7).contains(":") || text.contains("/"))
  }
}
