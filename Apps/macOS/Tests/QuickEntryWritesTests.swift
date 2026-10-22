import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Quick entry against a real database: the drafts kept in the settings, several operations
/// written as one step of ⌘Z, the correction of the last operation, the move to another day and
/// the digits kept on a card.
@MainActor
final class QuickEntryWritesTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-quick-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning, spending: environment.spendingRules)
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: Helpers

  private func write(
    _ whole: Int64, _ note: String, hoursAgo: Double = 1
  ) throws
    -> TransactionEntry
  {
    var draft = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-hoursAgo * 3_600), amount: AmountE4(whole: whole),
      note: note)
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    XCTAssertTrue(store.save(entry))
    return entry
  }

  private func stored(_ id: UUID) throws -> TransactionEntry {
    try XCTUnwrap(try XCTUnwrap(environment.transactions).entries(ids: [id]).first)
  }

  private func liveCount() throws -> Int {
    try XCTUnwrap(environment.transactions).recentEntries(limit: 10_000).filter {
      !$0.transaction.isDeleted
    }.count
  }

  private func correction(_ line: String) throws -> AmountCorrection {
    try XCTUnwrap(
      CorrectionLine.read(
        line, parser: InputLineParser(vocabulary: .empty, calendar: environment.calendar),
        today: environment.today))
  }

  private func draft(_ whole: Int64, _ note: String, daysAgo: Int = 0) -> TransactionDraft {
    var draft = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400),
      amount: AmountE4(whole: whole), note: note)
    draft.normalizeSinglePart()
    return draft
  }

  // MARK: Drafts

  func testADraftIsKeptInTheSettingsAndIsNoOperation() throws {
    let drafts = DraftsModel()
    drafts.attach(SettingsDraftStore(settings: environment.settings))
    XCTAssertTrue(drafts.keep("кофе с Машей, сумму узнать"))
    XCTAssertFalse(drafts.keep("   "), "an empty text keeps nothing")
    XCTAssertEqual(drafts.waiting.map(\.text), ["кофе с Машей, сумму узнать"])
    XCTAssertEqual(try liveCount(), 0, "a draft enters no figure")
    // Read again from the database.
    let again = DraftsModel()
    again.attach(SettingsDraftStore(settings: environment.settings))
    XCTAssertEqual(again.waiting.count, 1)
    XCTAssertEqual(again.waiting.first?.text, "кофе с Машей, сумму узнать")
  }

  func testADraftFinishedInTheLineIsResolvedAndADeletedOneIsGone() throws {
    let drafts = DraftsModel()
    drafts.attach(SettingsDraftStore(settings: environment.settings))
    drafts.keep("такси")
    drafts.keep("аптека")
    let first = try XCTUnwrap(drafts.waiting.first)
    drafts.finishing = first.id
    drafts.lineWritten()
    XCTAssertEqual(drafts.waiting.map(\.text), ["аптека"])
    XCTAssertNil(drafts.finishing)
    drafts.resolve(try XCTUnwrap(drafts.waiting.first).id)
    XCTAssertTrue(drafts.waiting.isEmpty)
  }

  func testTheEveningReminderCountsTheDraftsFrom21() throws {
    let drafts = DraftsModel()
    drafts.attach(SettingsDraftStore(settings: environment.settings))
    drafts.keep("такси")
    drafts.keep("аптека")
    let calendar = CalendarContext.system
    let day = calendar.day(of: Date())
    XCTAssertNil(
      DraftReminder.line(
        drafts: drafts.drafts, now: calendar.moment(day, hour: 20, minute: 59), calendar: calendar))
    XCTAssertEqual(
      DraftReminder.line(
        drafts: drafts.drafts, now: calendar.moment(day, hour: 21, minute: 0), calendar: calendar)?
        .count, 2)
  }

  func testTheStoredFormOfDraftsReadsBack() {
    let one = PendingDraft(text: "хлеб", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let text = SettingsDraftStore.encode([one].compactMap { $0 })
    XCTAssertEqual(
      SettingsDraftStore.decode(Data((text ?? "").utf8)).map(\.text), ["хлеб"])
    XCTAssertEqual(SettingsDraftStore.decode(Data("not json".utf8)), [])
  }

  // MARK: Several operations, one step

  func testSeveralOperationsAreWrittenAsOneStepOfUndo() throws {
    let model = QuickEntryModel()
    let drafts = [
      draft(250, "Кофе", daysAgo: 1), draft(62, "Метро", daysAgo: 1), draft(450, "Обед"),
    ]
    let result = model.write(drafts, environment: environment, store: store)
    XCTAssertEqual(result.written, 3)
    XCTAssertEqual(result.left, 0)
    XCTAssertEqual(try liveCount(), 3)
    store.undo()
    XCTAssertEqual(try liveCount(), 0, "one ⌘Z takes all three back")
  }

  func testNothingToWriteWritesNothing() throws {
    let result = QuickEntryModel().write([], environment: environment, store: store)
    XCTAssertEqual(result.written, 0)
    XCTAssertEqual(try liveCount(), 0)
  }

  func testRepeatingYesterdayOffersWhatWasTypedByHandAndWritesTheTickedOnes() throws {
    let yesterday = environment.calendar.adding(days: -1, to: environment.today)
    var first = draft(250, "Кофе")
    first.occurredAt = environment.calendar.moment(yesterday, hour: 9, minute: 15)
    var second = draft(62, "Метро")
    second.occurredAt = environment.calendar.moment(yesterday, hour: 9, minute: 40)
    for item in [first, second] { XCTAssertTrue(store.save(try item.materialize())) }
    let entries = try XCTUnwrap(environment.transactions).recentEntries(limit: 10_000)
    let proposals = RepeatDay.proposals(
      from: entries, on: yesterday, to: environment.today, calendar: environment.calendar)
    XCTAssertEqual(proposals.count, 2)
    var chosen = proposals
    chosen[1].isSelected = false
    let result = QuickEntryModel().write(
      chosen.filter(\.isSelected).map(\.draft), environment: environment, store: store)
    XCTAssertEqual(result.written, 1)
    XCTAssertEqual(try liveCount(), 3)
    // The new one is on today, at the time of the old one.
    let all = try XCTUnwrap(environment.transactions).recentEntries(limit: 10_000)
    let todays = all.filter {
      environment.calendar.day(of: $0.transaction.occurredAt) == environment.today
    }
    XCTAssertEqual(todays.count, 1)
    XCTAssertEqual(todays.first?.transaction.note, "Кофе")
    XCTAssertEqual(
      environment.calendar.timeOfDay(todays[0].transaction.occurredAt).hour, 9)
  }

  // MARK: The correction

  func testTheCorrectionIsOneStepAndUndoBringsBackTheOldAmount() throws {
    _ = try write(100, "Хлеб", hoursAgo: 5)
    let last = try write(250, "Кофе", hoursAgo: 0.1)
    let model = QuickEntryModel()
    let dataset = Dataset(
      entries: try XCTUnwrap(environment.transactions).recentEntries(limit: 10_000))
    guard
      case .offer(let offer) = QuickCorrection.outcome(
        for: try correction("ой 350"), in: dataset,
        now: Date())
    else { return XCTFail("no offer") }
    XCTAssertEqual(offer.before.id, last.id)
    model.correction = offer
    XCTAssertTrue(model.applyCorrection(environment: environment, store: store))
    XCTAssertNil(model.correction)
    XCTAssertEqual(try stored(last.id).transaction.amountE4, AmountE4(whole: 350))
    XCTAssertEqual(try stored(last.id).parts.map(\.amountE4), [AmountE4(whole: 350)])
    store.undo()
    XCTAssertEqual(try stored(last.id).transaction.amountE4, AmountE4(whole: 250))
  }

  // MARK: Moving to another day

  func testAnOperationMovedToAnotherDayKeepsItsTimeAndUndoesInOneStep() async throws {
    let entry = try write(500, "Ужин", hoursAgo: 30)
    let before = environment.calendar.day(of: entry.transaction.occurredAt)
    let target = environment.calendar.adding(days: -2, to: environment.today)
    XCTAssertNotEqual(before, target)
    let mover = MoveToDayModel()
    let compute = ComputeStore(calendar: environment.calendar)
    mover.request(
      try stored(entry.id), to: target, environment: environment, store: store, compute: compute)
    XCTAssertNil(mover.aheadAsk)
    XCTAssertFalse(mover.failed, mover.message ?? "")
    let moved = try stored(entry.id)
    XCTAssertEqual(environment.calendar.day(of: moved.transaction.occurredAt), target)
    XCTAssertEqual(
      environment.calendar.timeOfDay(moved.transaction.occurredAt),
      environment.calendar.timeOfDay(entry.transaction.occurredAt))
    XCTAssertNotNil(mover.message)
    store.undo()
    XCTAssertEqual(
      environment.calendar.day(of: try stored(entry.id).transaction.occurredAt), before)
  }

  func testMovingToTheSameDayIsRefusedAndADayAheadAsks() throws {
    let entry = try write(500, "Ужин", hoursAgo: 1)
    let mover = MoveToDayModel()
    let compute = ComputeStore(calendar: environment.calendar)
    mover.request(
      try stored(entry.id), to: environment.calendar.day(of: entry.transaction.occurredAt),
      environment: environment, store: store, compute: compute)
    XCTAssertTrue(mover.failed)
    let ahead = environment.calendar.adding(days: 3, to: environment.today)
    mover.request(
      try stored(entry.id), to: ahead, environment: environment, store: store, compute: compute)
    let ask = try XCTUnwrap(mover.aheadAsk)
    XCTAssertEqual(ask.day, ahead)
    XCTAssertEqual(
      environment.calendar.day(of: try stored(entry.id).transaction.occurredAt),
      environment.calendar.day(of: entry.transaction.occurredAt), "nothing moved before the word")
    mover.confirmAhead(
      ask, entry: try stored(entry.id), environment: environment, store: store, compute: compute)
    XCTAssertEqual(
      environment.calendar.day(of: try stored(entry.id).transaction.occurredAt), ahead)
  }

  func testTheDragCarriesTheIdOfTheOperationAndNothingElse() {
    let id = UUID()
    XCTAssertEqual(OperationDrag.id(in: OperationDrag.payload(of: id)), id)
    XCTAssertNil(OperationDrag.id(in: id.uuidString))
    XCTAssertNil(OperationDrag.id(in: "hello"))
  }

  // MARK: The note of a day

  func testTheNoteOfADayIsKeptAndEmptyTextDeletesIt() async throws {
    let day = environment.today
    XCTAssertTrue(store.setDayNote("день рождения мамы", on: day))
    let repository = try XCTUnwrap(environment.spendingRules)
    XCTAssertEqual(try repository.note(on: day)?.text, "день рождения мамы")
    XCTAssertTrue(store.setDayNote("", on: day))
    XCTAssertNil(try repository.note(on: day))
  }

  // MARK: The digits of a card

  func testTheDigitsOfACardAreKeptOnlyAsFourDigits() {
    var draft = CardDraft(nil)
    draft.name = "Платинум"
    draft.last4 = "•••• 3230"
    XCTAssertTrue(draft.last4IsValid)
    XCTAssertEqual(draft.keptLast4, "3230")
    draft.last4 = "12"
    XCTAssertFalse(draft.last4IsValid)
    draft.last4 = ""
    XCTAssertTrue(draft.last4IsValid)
    XCTAssertNil(draft.keptLast4)
    draft.last4 = "3230"
    draft.details = "  Иван Иванов, до 05/28  "
    let card = draft.card(previous: nil, accountId: UUID())
    XCTAssertEqual(card.last4, "3230")
    XCTAssertEqual(card.details, "Иван Иванов, до 05/28")
    XCTAssertEqual(CardDraft(card).last4, "3230")
  }
}
