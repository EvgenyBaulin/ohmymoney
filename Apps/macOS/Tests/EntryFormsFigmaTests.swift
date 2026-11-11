import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The entry against the design: the line (Mac 88:71025, the capsule 28:4630; phone 191:172834;
/// tablet 199:48115), the ↓ panel (6:86444), the form at the right (6:88341, its column 6:88496)
/// and the sheets of quick entry (6:158853 «Операции из банка», 56:159403 and 56:159670
/// «Черновики»): the numbers of the frames, and the windows themselves measured against them, a
/// picture of each kept with the result. The windows are light, as the frames are.
@MainActor
final class EntryFormsFigmaTests: SectionFigmaHarness {

  // MARK: The numbers of the frames

  /// The capsule: 50 tall on the Mac, 16 × 12 inside, 12 between the sparkles 18, the words,
  /// the quiet symbols and the send arrow 24; the phone's 48, 16 and 8 at its ends; the
  /// tablet's 54, 14 inside, its send circle 32.
  func testTheLineNumbersAreTheFrames() {
    let mac = EntryLineMetrics.of(.mac)
    XCTAssertEqual(mac.height, 50)
    XCTAssertEqual(mac.leading, 16)
    XCTAssertEqual(mac.trailing, 16)
    XCTAssertEqual(mac.vertical, 12)
    XCTAssertEqual(mac.gap, 12)
    XCTAssertEqual(mac.icon, 18)
    XCTAssertEqual(mac.send, 24)
    XCTAssertEqual(mac.height, mac.send + 2 * mac.vertical + 2, "the arrow and the edge")
    let phone = EntryLineMetrics.of(.phone)
    XCTAssertEqual(phone.height, 48)
    XCTAssertEqual(phone.leading, 16)
    XCTAssertEqual(phone.trailing, 8)
    XCTAssertEqual(phone.gap, 10)
    XCTAssertEqual(phone.text, 15)
    XCTAssertEqual(phone.height, phone.send + 2 * phone.vertical)
    let pad = EntryLineMetrics.of(.pad)
    XCTAssertEqual(pad.height, 54)
    XCTAssertEqual(pad.leading, 14)
    XCTAssertEqual(pad.send, 32)
    XCTAssertEqual(pad.text, 16)
    XCTAssertEqual(pad.height, pad.send + 2 * pad.vertical)
  }

  /// The phone's line is the column less 16 at each side (408 of 440); the tablet's 600 wherever
  /// the column holds it; the Mac's is 520 pt.
  func testTheLineIsAsWideAsItsFrameOnEachDevice() {
    XCTAssertEqual(
      EntryBarMetrics.columnWidth(windowWidth: 440, detailWidth: 440, idiom: .phone), 408)
    XCTAssertEqual(
      EntryBarMetrics.columnWidth(windowWidth: 1366, detailWidth: 1116, idiom: .pad), 600)
    XCTAssertEqual(
      EntryBarMetrics.columnWidth(windowWidth: 678, detailWidth: 600, idiom: .pad), 568,
      "a narrow tablet column keeps 16 at each side")
    XCTAssertEqual(
      EntryBarMetrics.columnWidth(windowWidth: 1440, detailWidth: 1208, idiom: .mac),
      520)
  }

  /// The panel 20 inside, 12 between rows, the kinds' track 3 inside with segments 10 × 6 in
  /// 13 pt; the form 16 inside, 10 between rows, its fields 8 apart under labels 4 above, the
  /// kinds of one width in 11 pt, the track 2 inside, «Записать» 16 × 8 rounded 8.
  func testThePanelAndFormNumbersAreTheFrames() {
    XCTAssertEqual(EntryPanelMetrics.padding, 20)
    XCTAssertEqual(EntryPanelMetrics.gap, 12)
    XCTAssertEqual(EntryPanelMetrics.radius, 22)
    XCTAssertEqual(EntryFieldFlowMetrics.cellSpacing, 10)
    XCTAssertEqual(EntryFieldFlowMetrics.rowSpacing, 12)
    XCTAssertEqual(EntryKindTrackMetrics.panel.inset, 3)
    XCTAssertEqual(EntryKindTrackMetrics.panel.trackRadius, 10)
    XCTAssertEqual(EntryKindTrackMetrics.panel.chipRadius, 8)
    XCTAssertEqual(EntryKindTrackMetrics.panel.horizontal, 10)
    XCTAssertEqual(EntryKindTrackMetrics.panel.vertical, 6)
    XCTAssertEqual(EntryKindTrackMetrics.panel.text, 13)
    XCTAssertFalse(EntryKindTrackMetrics.panel.equalWidths)

    XCTAssertEqual(EntryFormDock.width, 360)
    XCTAssertEqual(EntryFormMetrics.inset, 16)
    XCTAssertEqual(EntryFormMetrics.gap, 10)
    XCTAssertEqual(EntryFormMetrics.fieldGap, 8)
    XCTAssertEqual(EntryFormMetrics.labelGap, 4)
    XCTAssertEqual(EntryFieldFlowMetrics.sideCellSpacing, 8)
    XCTAssertEqual(EntryFieldFlowMetrics.sideRowSpacing, 10)
    XCTAssertEqual(
      2 * 160 + EntryFormMetrics.fieldGap, EntryFormDock.width - 2 * EntryFormMetrics.inset,
      "two fields of 160 fill the column")
    XCTAssertEqual(EntryKindTrackMetrics.form.inset, 2)
    XCTAssertEqual(EntryKindTrackMetrics.form.text, 11)
    XCTAssertTrue(EntryKindTrackMetrics.form.equalWidths)
    XCTAssertEqual(EntryFormMetrics.saveHorizontal, 16)
    XCTAssertEqual(EntryFormMetrics.saveVertical, 8)
    XCTAssertEqual(EntryFormMetrics.saveRadius, 8)
  }

  /// The kinds stand in the design's order, every kind of the app among them once.
  func testTheKindsStandInTheDesignsOrder() {
    XCTAssertEqual(
      EntryKindTabs.designOrder.map(EntryKindTabs.identifier(of:)),
      [
        "entry.kind.expense", "entry.kind.income", "entry.kind.transfer", "entry.kind.refund",
        "entry.kind.reimbursement",
      ])
    XCTAssertEqual(Set(EntryKindTabs.designOrder), Set(EntryKindTiles.all))
  }

  /// The sheets: 520 wide, the head 16 × 20, the body 20 with 14 between its parts, the rows in
  /// a card rounded 10 with 12 at its sides and 10 above and below each, the foot 14 × 20.
  func testTheQuickSheetNumbersAreTheFrames() {
    XCTAssertEqual(QuickSheetMetrics.width, 520)
    XCTAssertEqual(QuickSheetMetrics.headHorizontal, 20)
    XCTAssertEqual(QuickSheetMetrics.headVertical, 16)
    XCTAssertEqual(QuickSheetMetrics.body, 20)
    XCTAssertEqual(QuickSheetMetrics.bodyGap, 14)
    XCTAssertEqual(QuickSheetMetrics.listRadius, 10)
    XCTAssertEqual(QuickSheetMetrics.listSide, 12)
    XCTAssertEqual(QuickSheetMetrics.rowVertical, 10)
    XCTAssertEqual(QuickSheetMetrics.footHorizontal, 20)
    XCTAssertEqual(QuickSheetMetrics.footVertical, 14)
  }

  /// The words of the frames: one prompt on every device, «Новая запись» over the form,
  /// «Записать» under it and at the foot of the panel.
  func testTheWordsAreTheFrames() {
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.language("entry.placeholder", table: "Entry"), "Что купили? Например: кафе 450")
    XCTAssertEqual(environment.language("entry.form.title", table: "Entry"), "Новая запись")
    XCTAssertEqual(environment.language("entry.save", table: "Entry"), "Записать")
    XCTAssertEqual(QuickText.t("quick.bills.title", environment), "Операции из банка")
    XCTAssertEqual(QuickText.t("quick.drafts.title", environment), "Черновики")
    XCTAssertEqual(QuickText.t("quick.drafts.empty", environment), "Черновиков нет")
  }

  // MARK: The windows

  /// The line of the Mac's main window at 1440 × 900: a capsule 50 tall, the send arrow 24 with
  /// 16 to the capsule's end, the sparkles at its start 16 in.
  func testTheMacLineIsTheFrame() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    let window = mainWindow(.operations, width: 1440)
    window.appearance = NSAppearance(named: .aqua)
    settle(window)
    try waitUntilStill(["entry.line.capsule", "entry.line.send"], in: window)
    let capsule = try frame(of: "entry.line.capsule", in: window)
    let send = try frame(of: "entry.line.send", in: window)
    XCTAssertEqual(capsule.width, 520, accuracy: 1, "the capsule's width")
    XCTAssertEqual(capsule.height, 50, accuracy: 1, "the capsule's height")
    XCTAssertEqual(send.width, 24, accuracy: 1, "the send arrow")
    XCTAssertEqual(capsule.maxX - send.maxX, 16, accuracy: 1.5, "16 after the arrow")
    XCTAssertEqual(send.midY, capsule.midY, accuracy: 1, "the arrow stands in the middle")
    XCTAssertEqual(capsule.minY, 18, accuracy: 2, "18 over the window's bottom edge")
    try attachPicture(of: window, named: "entry-line-mac-1440")
  }

  func testTheMacPanelAndChipsHaveIndependentCenteredWidths() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    let chipsBefore = environment.entryChipsShown
    defer { environment.entryChipsShown = chipsBefore }
    try XCTUnwrap(environment.references).save(
      Template(text: "Coffee", amountE4: AmountE4(whole: 250), currency: .rub))
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      environment.entryChipsShown = true
      let bar = EntryBar(
        windowWidth: 1440, detailWidth: 1208, style: .line, opensDetails: true
      ) { EmptyView() }
      let window = screenWindow(bar, idiom: .mac, width: 1208, height: 900)
      settle(window)
      let capsule = try frame(of: "entry.line.capsule", in: window)
      let panel = try frame(of: "entry.details.panel", in: window)
      let chips = try frame(of: "entry.templates", in: window)
      XCTAssertEqual(capsule.width, 520, accuracy: 1)
      XCTAssertEqual(panel.width, 720, accuracy: 1)
      XCTAssertEqual(chips.width, 480, accuracy: 1)
      XCTAssertEqual(panel.midX, capsule.midX, accuracy: 1)
      XCTAssertEqual(chips.midX, capsule.midX, accuracy: 1)
      // The two quiet controls remain in place of a microphone; both are real actions.
      XCTAssertNotNil(find("entry.question.toggle", in: window))
      XCTAssertNotNil(find("entry.details.toggle", in: window))
      for identifier in EntryKindTabs.designOrder.map(EntryKindTabs.identifier(of:)) {
        XCTAssertNotNil(find(identifier, in: window), identifier)
      }
    }
  }

  /// The line drawn by the phone's frame (408 × 48 in a column of 440) and by the tablet's
  /// (600 × 54 beside the sidebar of a 1366 window).
  func testThePhoneAndTabletLinesAreTheirFrames() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    for (idiom, width, line) in [(LayoutIdiom.phone, 440.0, 408.0), (.pad, 1116.0, 600.0)] {
      let metrics = EntryLineMetrics.of(idiom)
      let bar = EntryBar(windowWidth: width, detailWidth: width, style: .line) { EmptyView() }
      let window = screenWindow(bar, idiom: idiom, width: width, height: 300)
      window.appearance = NSAppearance(named: .aqua)
      settle(window)
      try waitUntilStill(["entry.line.capsule", "entry.line.send"], in: window)
      let capsule = try frame(of: "entry.line.capsule", in: window)
      let send = try frame(of: "entry.line.send", in: window)
      XCTAssertEqual(capsule.width, line, accuracy: 1.5, "\(idiom): the capsule's width")
      XCTAssertEqual(capsule.height, metrics.height, accuracy: 1.5, "\(idiom): its height")
      XCTAssertEqual(send.width, metrics.send, accuracy: 1, "\(idiom): the send circle")
      XCTAssertEqual(
        capsule.maxX - send.maxX, metrics.trailing, accuracy: 1.5, "\(idiom): after the send")
      try attachPicture(of: window, named: "entry-line-\(idiom.rawValue)")
    }
  }

  /// The form at the right at 1440 × 900: 360 wide at the window's right edge, the kinds' track
  /// 328 across, 16 in; a kind chosen brings «Записать» 328 × 30 across the column.
  func testTheMacFormIsTheFrame() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    environment.entryStyle = .form
    let window = mainWindow(.operations, width: 1440)
    window.appearance = NSAppearance(named: .aqua)
    settle(window)
    try waitUntilStill(["entry.form.title", "entry.kind.track"], in: window)
    let title = try frame(of: "entry.form.title", in: window)
    let track = try frame(of: "entry.kind.track", in: window)
    let width = try XCTUnwrap(window.contentView).bounds.width
    XCTAssertEqual(track.width, EntryFormDock.width - 2 * EntryFormMetrics.inset, accuracy: 1.5)
    XCTAssertEqual(track.maxX, width - EntryFormMetrics.inset, accuracy: 1.5, "16 from the edge")
    XCTAssertEqual(title.minX, track.minX, accuracy: 1.5, "the title stands over the kinds")
    XCTAssertNil(find("entry.form.save", in: window), "no «Записать» before the kind")
    try attachPicture(of: window, named: "entry-form-mac-1440-kinds")

    let expense = try XCTUnwrap(
      WindowAccessibility.element(identified: "entry.kind.expense", in: window))
    WindowAccessibility.press(expense)
    settle(window)
    try waitUntilStill(["entry.form.save"], in: window)
    let save = try frame(of: "entry.form.save", in: window)
    XCTAssertEqual(save.width, track.width, accuracy: 1.5, "«Записать» across the column")
    XCTAssertEqual(save.height, 30, accuracy: 2, "«Записать» 30 tall")
    let segments = try ["entry.kind.expense", "entry.kind.income", "entry.kind.transfer"].map {
      try frame(of: $0, in: window)
    }
    XCTAssertEqual(segments[0].width, segments[1].width, accuracy: 1, "kinds of one width")
    XCTAssertEqual(segments[0].midY, segments[2].midY, accuracy: 1, "kinds in one row")
    XCTAssertLessThan(segments[1].maxX, segments[2].minX, "«Перевод» right after «Доход»")
    try attachPicture(of: window, named: "entry-form-mac-1440-expense")
  }

  /// «Операции из банка» at its 520: the head, the ticks and sums of the rows in their card, the
  /// hint, «Отмена» and «Записать 2».
  func testTheBankSheetIsTheFrame() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let today = environment.today
    let items = [
      BankListItem(
        source: "a",
        message: BankMessage(
          operation: .purchase, money: Money(amount: AmountE4(whole: 450), currency: .rub),
          merchant: "Кафе", day: today)),
      BankListItem(
        source: "b",
        message: BankMessage(
          operation: .purchase, money: Money(amount: AmountE4(whole: 63), currency: .rub),
          merchant: "Метро", day: today)),
    ]
    let candidates = QuickBank.candidates(items, entries: [], calendar: .utc, today: today)
    let sheet = BillListSheet(
      list: QuickEntryModel.BillList(candidates: candidates, skipped: 0), write: { _ in })
    let window = screenWindow(sheet, idiom: .mac, width: QuickSheetMetrics.width, height: 460)
    window.appearance = NSAppearance(named: .aqua)
    settle(window)
    try waitUntilStill(["quick.sheet.title", "quick.bills.write"], in: window)
    let title = try frame(of: "quick.sheet.title", in: window)
    let close = try frame(of: "quick.sheet.close", in: window)
    let write = try frame(of: "quick.bills.write", in: window)
    XCTAssertEqual(title.minX, QuickSheetMetrics.headHorizontal, accuracy: 1.5)
    XCTAssertEqual(
      QuickSheetMetrics.width - close.maxX, QuickSheetMetrics.headHorizontal, accuracy: 2.5)
    XCTAssertEqual(
      QuickSheetMetrics.width - write.maxX, QuickSheetMetrics.footHorizontal, accuracy: 2.5)
    XCTAssertEqual(write.minY, QuickSheetMetrics.footVertical, accuracy: 2.5, "the foot 14 in")
    try attachPicture(of: window, named: "quick-bank-sheet-mac")
  }

  /// «Черновики», empty and with two: the head, «Черновиков нет» or the rows with «Дописать»,
  /// and «Закрыть» at the foot.
  func testTheDraftsSheetIsTheFrame() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let empty = DraftsModel()
    var window = screenWindow(
      DraftsSheet(model: empty, finish: { _ in }), idiom: .mac, width: QuickSheetMetrics.width,
      height: 275)
    window.appearance = NSAppearance(named: .aqua)
    settle(window)
    try waitUntilStill(["quick.sheet.title", "quick.drafts.empty"], in: window)
    let title = try frame(of: "quick.sheet.title", in: window)
    XCTAssertEqual(title.minX, QuickSheetMetrics.headHorizontal, accuracy: 1.5)
    try attachPicture(of: window, named: "quick-drafts-empty-mac")

    let store = MemoryDraftStore()
    let full = DraftsModel()
    full.attach(store)
    full.keep("кофе", now: Date(timeIntervalSince1970: 1_793_000_000))
    full.keep("такси 3", now: Date(timeIntervalSince1970: 1_793_100_000))
    window = screenWindow(
      DraftsSheet(model: full, finish: { _ in }), idiom: .mac, width: QuickSheetMetrics.width,
      height: 380)
    window.appearance = NSAppearance(named: .aqua)
    settle(window)
    try waitUntilStill(["quick.sheet.title", "quick.drafts.finish"], in: window)
    XCTAssertNil(find("quick.drafts.empty", in: window))
    try attachPicture(of: window, named: "quick-drafts-mac")
  }
}

/// Drafts kept in memory, for a sheet drawn in a test.
private final class MemoryDraftStore: DraftStoring {
  private var drafts: [PendingDraft] = []
  func load() -> [PendingDraft] { drafts }
  func save(_ drafts: [PendingDraft]) -> Bool {
    self.drafts = drafts
    return true
  }
}
