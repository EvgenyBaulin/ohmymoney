import AppCore
import AppDatabase
import UserNotifications
import XCTest

@testable import OhMyMoney

/// The words of a notification follow the owner's choice — by default no amount while hidden —
/// and Spotlight's index gets only what may be indexed, through a stand-in for the system's.
@MainActor
final class MacNotificationsTests: XCTestCase {
  private var book: MacCommandsBook!

  override func setUp() async throws {
    book = try await MacCommandsBook()
  }

  override func tearDown() async throws {
    book?.environment.amounts.hidesAmounts = false
    await book?.close()
    book = nil
  }

  /// A payment of 650 ₽ due tomorrow; `account` pays it.
  private func payment(on account: PaymentMethod) async throws -> (ScheduledPayment, DateOnly) {
    let due = book.environment.today.adding(days: 1)
    let payment = ScheduledPayment(
      name: "Интернет", amountE4: AmountE4(whole: 650), categoryId: book.cafe.id,
      paymentMethodId: account.id, day: due.day, nextDate: due)
    _ = try XCTUnwrap(book.environment.planning).apply(
      PlanningChange(upsert: PlanningRows(scheduled: [payment])))
    try await book.reload()
    return (payment, due)
  }

  private func words(_ privacy: NotificationPlan.Privacy) throws -> NotificationWords {
    NotificationWords(
      environment: book.environment, snapshot: try XCTUnwrap(book.compute.wholeSnapshot),
      privacy: privacy)
  }

  private func notice(
    _ payment: ScheduledPayment, _ due: DateOnly, anonymous: Bool = false
  )
    -> NotificationPlan.Notice
  {
    NotificationPlan.Notice(
      id: "pay:\(payment.id.uuidString.lowercased()):\(due.iso)",
      subject: .paymentTomorrow(paymentId: payment.id, due: due), day: due.adding(days: -1),
      anonymous: anonymous)
  }

  func testAPaymentSaysItsNameAndAmountWhileAmountsAreShown() async throws {
    let (payment, due) = try await payment(on: book.sber)
    let content = try XCTUnwrap(try words(.quiet).content(of: notice(payment, due)))
    XCTAssertTrue(content.title.contains("Интернет"), content.title)
    XCTAssertTrue(content.body.contains("650"), content.body)
    XCTAssertEqual(content.categoryIdentifier, MacNotifications.paymentCategory)
  }

  /// The default: no amount while the amounts are hidden.
  func testHiddenAmountsAreNotSaidByDefault() async throws {
    let (payment, due) = try await payment(on: book.sber)
    book.environment.amounts.hidesAmounts = true
    let quiet = try XCTUnwrap(try words(.quiet).content(of: notice(payment, due)))
    XCTAssertFalse(quiet.body.contains("650"), quiet.body)
    let anonymous = try XCTUnwrap(try words(.anonymous).content(of: notice(payment, due)))
    XCTAssertFalse(anonymous.body.contains("650"), anonymous.body)
    // «Всегда с суммой»: the amount in full, not the mask of the screen.
    let always = try XCTUnwrap(try words(.always).content(of: notice(payment, due)))
    XCTAssertTrue(always.body.contains("650"), always.body)
  }

  /// A payment of a hidden account, announced anonymously: neither its name nor its amount.
  func testAnAnonymousPaymentHasNoNameAndNoAmount() async throws {
    let (payment, due) = try await payment(on: book.secret)
    let content = try XCTUnwrap(
      try words(.anonymous).content(of: notice(payment, due, anonymous: true)))
    XCTAssertFalse(content.title.contains("Интернет"), content.title)
    XCTAssertFalse(content.body.contains("650"), content.body)
    XCTAssertFalse(content.title.isEmpty)
  }

  /// The setting is read from this Mac's defaults, `quiet` until chosen.
  func testThePrivacyChoiceIsKeptOnThisMac() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "MacNotificationsTests-\(UUID())"))
    let notifications = MacNotifications(posting: CountingPosting())
    notifications.defaults = defaults
    XCTAssertEqual(notifications.privacy(), .quiet)
    defaults.set("anonymous", forKey: MacNotifications.privacyKey)
    XCTAssertEqual(notifications.privacy(), .anonymous)
    defaults.set("nonsense", forKey: MacNotifications.privacyKey)
    XCTAssertEqual(notifications.privacy(), .quiet)
  }

  /// The whole way from the data to the center: a payment of a hidden account is not posted by
  /// default, and is posted without its name when the owner chose «anonymous»; posted once.
  func testPostingFollowsThePrivacyChoice() async throws {
    let (open, _) = try await payment(on: book.sber)
    let (hidden, _) = try await payment(on: book.secret)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "MacNotificationsPost-\(UUID())"))
    defaults.set(false, forKey: MacNotifications.key(for: .limits))
    defaults.set(false, forKey: MacNotifications.key(for: .summaries))
    let posting = CountingPosting()
    let notifications = MacNotifications(posting: posting)
    notifications.defaults = defaults

    await notifications.refresh(book.dependencies)
    let openId = open.id.uuidString.lowercased()
    XCTAssertEqual(posting.posted.filter { $0.identifier.contains(openId) }.count, 1)
    XCTAssertFalse(
      posting.posted.contains { $0.identifier.contains(hidden.id.uuidString.lowercased()) },
      "a hidden account's payment was announced")
    // Posted once: the next change of the data says nothing new.
    await notifications.refresh(book.dependencies)
    XCTAssertEqual(posting.posted.count, 1)

    defaults.set("anonymous", forKey: MacNotifications.privacyKey)
    await notifications.refresh(book.dependencies)
    let anonymous = try XCTUnwrap(
      posting.posted.first { $0.identifier.contains(hidden.id.uuidString.lowercased()) })
    XCTAssertFalse(anonymous.content.title.contains("Интернет"), anonymous.content.title)
    XCTAssertFalse(anonymous.content.body.contains("650"), anonymous.content.body)
  }

  /// Spotlight: off — the index is emptied; on — description and place only, never a hidden
  /// account's operation.
  func testSpotlightGetsOnlyWhatMayBeIndexed() async throws {
    try await book.history("обед", 300, on: book.sber)
    try await book.history("подарок", 5_000, on: book.secret)
    let index = RecordingIndex()
    let indexer = SpotlightIndexer(index: index)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "SpotlightIndexerTests-\(UUID())"))
    indexer.defaults = defaults

    await indexer.refresh(book.dependencies)
    let off = await index.calls
    XCTAssertEqual(off, [.removeAll])

    defaults.set(true, forKey: SpotlightIndexer.enabledKey)
    await indexer.refresh(book.dependencies)
    let on = await index.calls
    XCTAssertEqual(on.last, .replace(["обед"]))

    // Nothing changed: nothing is written again.
    await indexer.refresh(book.dependencies)
    let again = await index.calls
    XCTAssertEqual(again.count, on.count)

    await indexer.turnOff()
    let afterOff = await index.calls
    XCTAssertEqual(afterOff.last, .removeAll)
    XCTAssertFalse(defaults.bool(forKey: SpotlightIndexer.enabledKey))
  }
}

/// What the app asked of the index, in order.
private actor RecordingIndex: SpotlightIndexing {
  enum Call: Equatable {
    case replace([String])
    case removeAll
  }

  private(set) var calls: [Call] = []

  func replace(with items: [SpotlightPlan.Item]) async {
    calls.append(.replace(items.map(\.title)))
  }
  func removeAll() async { calls.append(.removeAll) }
}

@MainActor
private final class CountingPosting: NotificationPosting {
  var posted: [UNNotificationRequest] = []
  func permission() async -> NotificationPlan.Permission { .allowed }
  func requestPermission() async -> Bool { true }
  func pendingIds() async -> [String] { [] }
  func removePending(_ ids: [String]) {}
  func post(_ request: UNNotificationRequest) { posted.append(request) }
}
