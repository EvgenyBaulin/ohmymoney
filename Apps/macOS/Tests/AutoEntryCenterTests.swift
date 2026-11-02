import AppCore
import AppDatabase
import UserNotifications
import XCTest

@testable import OhMyMoney

/// A text of a bank passed on by «Быстрые команды»: offered as a draft by default, written at
/// once through the steps of the entry line when the owner chose so, never written twice, never
/// kept whole, and never named in a notification when its account is hidden.
@MainActor
final class AutoEntryCenterTests: XCTestCase {
  private var book: MacCommandsBook!
  private var center: AutoEntryCenter!
  private var suite: String!

  private let push = "Покупка, карта *7788. 450 ₽. KOFEMANIYA. Доступно 12 300 ₽. Код 9911"

  override func setUp() async throws {
    book = try await MacCommandsBook()
    suite = "autoentry-tests-\(UUID().uuidString)"
    center = AutoEntryCenter()
    center.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let cards = CardActions(environment: book.environment, store: book.store)
    XCTAssertEqual(
      cards.save(
        PaymentCard(accountId: book.sber.id, name: "Платинум", last4: "7788"), previous: nil),
      .done)
    XCTAssertEqual(
      cards.save(
        PaymentCard(accountId: book.secret.id, name: "Тень", last4: "5150"), previous: nil),
      .done)
    book.environment.refreshVocabulary()
    try await book.reload()
  }

  override func tearDown() async throws {
    UserDefaults.standard.removePersistentDomain(forName: suite)
    UserDefaults.standard.removeObject(forKey: AutoEntryLearning.pendingKey)
    UserDefaults.standard.removeObject(forKey: AutoEntryLearning.fingerprintsKey)
    await book?.close()
    book = nil
    center = nil
  }

  private var drafts: [PendingDraft] {
    SettingsDraftStore(settings: book.environment.settings).load()
  }

  func testATextTypedByHandIsNotABanksText() async throws {
    let result = await center.receive("кофе 250", commands: book.commands)
    guard case .refused = result.outcome else { return XCTFail("\(result.outcome)") }
    XCTAssertNil(result.action)
    XCTAssertTrue(drafts.isEmpty)
  }

  /// By default the operation is offered: a draft of «Запишу потом» with the line, a
  /// notification with «Записать» and «Изменить» — and the text itself nowhere.
  func testAnOperationIsOfferedByDefault() async throws {
    XCTAssertEqual(center.mode(), .propose)
    let before = try book.entries().count
    let result = await center.receive(push, commands: book.commands)
    XCTAssertEqual(result.action, .propose)
    let draft = try XCTUnwrap(drafts.first)
    XCTAssertEqual(result.draftId, draft.id)
    XCTAssertTrue(draft.text.contains("450"), draft.text)
    XCTAssertTrue(draft.text.contains("Kofemaniya"), draft.text)
    for text in [draft.text, result.title ?? "", result.body ?? "", result.outcome.text] {
      XCTAssertFalse(text.contains("Код"), "the text of the bank is kept nowhere: \(text)")
      XCTAssertFalse(text.contains("9911"), text)
    }
    XCTAssertNotNil(result.title, "a notification asks «записать?»")
    XCTAssertEqual(try book.entries().count, before, "nothing is written before «Записать»")
  }

  /// «Записать» of the notification writes the draft through the steps of the line.
  func testRecordFromTheNotificationNeedsWhatTheLineNeeds() async throws {
    let result = await center.receive(push, commands: book.commands)
    let id = try XCTUnwrap(result.draftId)
    // No category is known for the shop: the line would ask, so the draft stays.
    let written = await center.recordDraft(id, commands: book.commands)
    XCTAssertFalse(written)
    XCTAssertEqual(drafts.map(\.id), [id])
  }

  /// «Записать» of the notification, when the line knows the category of the shop: written
  /// once, and the draft goes.
  func testRecordFromTheNotificationWritesTheDraft() async throws {
    try await book.history("Kofemaniya", 300, on: book.sber, category: book.cafe.id)
    let result = await center.receive(push, commands: book.commands)
    XCTAssertEqual(result.action, .propose)
    let id = try XCTUnwrap(result.draftId)
    let before = try book.entries().count
    let written = await center.recordDraft(id, commands: book.commands)
    XCTAssertTrue(written)
    XCTAssertEqual(try book.entries().count, before + 1)
    XCTAssertTrue(drafts.isEmpty)
  }

  /// A draft finished the next day lands on the day the bank wrote about.
  func testADraftKeepsTheDayOfTheMessage() async throws {
    try await book.history("Kofemaniya", 300, on: book.sber, category: book.cafe.id)
    let environment = book.environment
    let snapshot = try XCTUnwrap(book.compute.wholeSnapshot)
    let reading = try XCTUnwrap(
      AutoEntryReading(push, environment: environment, snapshot: snapshot))
    let yesterday = environment.today.adding(days: -1)
    let moment = environment.calendar.startOfDay(yesterday).addingTimeInterval(9 * 3600)
    let id = try XCTUnwrap(reading.keepDraft(environment: environment, now: moment))
    let draft = try XCTUnwrap(drafts.first { $0.id == id })
    let token = String(format: " %02d.%02d", yesterday.day, yesterday.month)
    XCTAssertTrue(draft.text.hasSuffix(token), draft.text)
    let written = await center.recordDraft(id, commands: book.commands)
    XCTAssertTrue(written)
    let entry = try XCTUnwrap(
      try book.entries().first { $0.transaction.amountE4 == AmountE4(whole: 450) })
    XCTAssertEqual(environment.calendar.day(of: entry.transaction.occurredAt), yesterday)
  }

  /// Drafts waiting: «2 операции ждут разбора — дописать?» at 21:00; none waiting, or the
  /// evening reminders off: taken back and not shown.
  func testWaitingDraftsAreRemindedAtNine() async throws {
    let posting = DraftsPosting()
    let notifications = MacNotifications(posting: posting)
    notifications.defaults = center.defaults
    let calendar = book.environment.calendar
    let today = book.environment.today
    let morning = calendar.moment(today, hour: 9, minute: 0)
    let drafts = ["кофе", "такси"].compactMap { PendingDraft(text: $0, createdAt: morning) }
    await notifications.scheduleDrafts(drafts, now: morning, calendar: calendar)
    let request = try XCTUnwrap(posting.posted.first)
    XCTAssertEqual(request.identifier, MacNotifications.draftsReminderId)
    XCTAssertTrue(request.content.body.contains("2"), request.content.body)
    let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
    XCTAssertEqual(trigger.timeInterval, 12 * 3600, accuracy: 1)
    XCTAssertEqual(request.content.userInfo[MacNotifications.openDraftsKey] as? String, "1")

    posting.posted = []
    await notifications.scheduleDrafts([], now: morning, calendar: calendar)
    XCTAssertTrue(posting.posted.isEmpty)
    XCTAssertEqual(posting.removed.last, MacNotifications.draftsReminderId)

    center.defaults.set(false, forKey: MacNotifications.key(for: .evening))
    await notifications.scheduleDrafts(drafts, now: morning, calendar: calendar)
    XCTAssertTrue(posting.posted.isEmpty, "the evening reminders are off")
  }

  /// The notification of an offer carries «Записать» and «Изменить», which opens the app.
  func testTheOfferHasRecordAndEdit() {
    let category = MacNotifications.autoEntryCategory()
    XCTAssertEqual(category.identifier, MacNotifications.autoEntryCategoryId)
    XCTAssertEqual(
      category.actions.map(\.identifier),
      [MacNotifications.autoEntryRecordAction, MacNotifications.autoEntryEditAction])
    XCTAssertTrue(category.actions[1].options.contains(.foreground))
  }

  /// Written at once when the owner chose so and the line knows everything.
  func testImmediateWritesThroughTheEntryLine() async throws {
    center.defaults.set(AutoEntryMode.immediate.rawValue, forKey: AutoEntryCenter.modeKey)
    try await book.history("Kofemaniya", 300, on: book.sber, category: book.cafe.id)
    let before = try book.entries().count
    let result = await center.receive(push, commands: book.commands)
    XCTAssertEqual(result.action, .write, "\(result.outcome)")
    XCTAssertEqual(try book.entries().count, before + 1)
    XCTAssertTrue(drafts.isEmpty)
    let written = try XCTUnwrap(
      try book.entries().first { $0.transaction.amountE4 == AmountE4(whole: 450) })
    XCTAssertEqual(written.transaction.paymentMethodId, book.sber.id, "the card's account")
  }

  /// A write the line would stop for — no category for the shop — is offered instead.
  func testImmediateWithoutACategoryIsOffered() async throws {
    center.defaults.set(AutoEntryMode.immediate.rawValue, forKey: AutoEntryCenter.modeKey)
    let before = try book.entries().count
    let result = await center.receive(push, commands: book.commands)
    XCTAssertEqual(result.action, .propose)
    XCTAssertEqual(try book.entries().count, before)
    XCTAssertEqual(drafts.count, 1)
  }

  /// The SMS and the push of one purchase, a minute apart: the second is not offered again.
  func testTheSameOperationIsNotRepeated() async throws {
    _ = await center.receive(push, commands: book.commands)
    let sms = "MIR-7788 07:55 Покупка 450р KOFEMANIYA Баланс: 12300р"
    let second = await center.receive(sms, commands: book.commands)
    XCTAssertEqual(second.action, .skipDuplicate)
    XCTAssertEqual(drafts.count, 1)
  }

  /// The push of an operation already offered, after a restart: still one draft.
  func testAnOfferedOperationIsNotOfferedAgainAfterARestart() async throws {
    _ = await center.receive(push, commands: book.commands)
    let restarted = AutoEntryCenter()
    restarted.defaults = center.defaults
    let sms = "MIR-7788 07:55 Покупка 450р KOFEMANIYA Баланс: 12300р"
    let again = await restarted.receive(sms, commands: book.commands)
    XCTAssertEqual(again.action, .skipDuplicate)
    XCTAssertEqual(drafts.count, 1)
    // Thrown away, the draft no longer stops the same operation from being offered.
    let store = SettingsDraftStore(settings: book.environment.settings)
    XCTAssertTrue(store.save([]))
    let fresh = AutoEntryCenter()
    fresh.defaults = center.defaults
    let third = await fresh.receive(push, commands: book.commands)
    XCTAssertEqual(third.action, .propose)
  }

  /// An operation the owner typed by hand today is not offered again.
  func testAnOperationTypedByHandIsNotRepeated() async throws {
    try await book.history("обед", 250, on: book.sber, category: book.cafe.id)
    _ = await book.commands.add(line: "обед 450")
    try await book.reload()
    let result = await center.receive(push, commands: book.commands)
    XCTAssertEqual(result.action, .skipDuplicate)
    XCTAssertTrue(drafts.isEmpty)
  }

  /// A card of a hidden account: always offered, the draft does not name the card, and by
  /// default no notification says anything about it.
  func testAHiddenAccountIsNotNamed() async throws {
    UserDefaults.standard.removeObject(forKey: MacNotifications.privacyKey)
    center.defaults.set(AutoEntryMode.immediate.rawValue, forKey: AutoEntryCenter.modeKey)
    let text = "Карта *5150: Покупка 640.00 RUR, PEREKRESTOK. Доступно 9860.00 RUR"
    let result = await center.receive(text, commands: book.commands)
    XCTAssertEqual(result.action, .propose)
    XCTAssertNil(result.title, "nothing is said about a hidden account by default")
    let draft = try XCTUnwrap(drafts.first)
    XCTAssertFalse(draft.text.contains("Тень"), draft.text)
    XCTAssertFalse(result.outcome.text.contains("640"), result.outcome.text)
  }

  /// «Скрыть суммы»: the notification names the shop without the amount.
  func testHiddenAmountsLeaveTheAmountOut() async throws {
    book.environment.amounts.hidesAmounts = true
    defer { book.environment.amounts.hidesAmounts = false }
    let result = await center.receive(push, commands: book.commands)
    let title = try XCTUnwrap(result.title)
    XCTAssertTrue(title.contains("Kofemaniya"), title)
    XCTAssertFalse(title.contains("450"), title)
  }

  /// A shop written under a place of the owner's list is offered under that place next time.
  func testAPlaceTheOwnerChoseIsLearned() async throws {
    let references = try XCTUnwrap(book.environment.references)
    let place = Place(name: "Кофемания")
    try references.save(place)
    book.environment.refreshVocabulary()
    XCTAssertTrue(
      AutoEntryLearning.written(
        merchant: "KOFEMANIYA", placeId: place.id, environment: book.environment))
    XCTAssertEqual(
      AutoEntryLearning.names(book.environment).name(for: "KOFEMANIYA"), "Кофемания")
    let result = await center.receive(push, commands: book.commands)
    let draft = try XCTUnwrap(drafts.first { $0.id == result.draftId })
    XCTAssertTrue(draft.text.hasPrefix("Кофемания 450 "), draft.text)
  }

  /// «Только просмотр»: nothing is written or kept.
  func testLockedOrReadOnlyIsRefused() async throws {
    book.environment.shield.adopt(readOnly: true)
    defer { book.environment.shield.adopt(readOnly: false) }
    let result = await center.receive(push, commands: book.commands)
    guard case .refused = result.outcome else { return XCTFail("\(result.outcome)") }
    XCTAssertTrue(drafts.isEmpty)
  }
}

@MainActor
private final class DraftsPosting: NotificationPosting {
  var posted: [UNNotificationRequest] = []
  var removed: [String] = []
  func permission() async -> NotificationPlan.Permission { .allowed }
  func requestPermission() async -> Bool { true }
  func pendingIds() async -> [String] { [] }
  func removePending(_ ids: [String]) { removed += ids }
  func post(_ request: UNNotificationRequest) { posted.append(request) }
}
