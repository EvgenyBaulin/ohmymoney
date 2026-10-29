import AppCore
import CoreGraphics
import Foundation
import Observation

/// A picture of the receipt that may be kept with the operation.
struct ReceiptPhoto: Equatable {
  var data: Data
  var filename: String
}

/// The state of «Чек по QR»: a picture or a scanned text in, one proposal out, one write on
/// the button. The matching is in `CoreParse` (`ReceiptMatch`); this class reads the books,
/// writes through the same store as the entry line (so ⌘Z takes it back in one step) and
/// holds what the screen shows. Nothing is sent anywhere.
@MainActor
@Observable
final class ReceiptModel {
  enum Stage: Equatable {
    /// Nothing yet: the screen offers the ways to bring a picture.
    case waiting
    case reading
    /// The picture has no QR code at all.
    case noCode
    /// A QR code, but not a cash receipt.
    case notReceipt
    case found
    case done(DoneKind)
    case failed(FailureKind)
  }

  enum DoneKind: Equatable {
    case timeAdded(String)
    case created
  }

  enum FailureKind: Equatable {
    case notWritten
    /// The operation to supplement was deleted meanwhile.
    case gone
    /// The books have no «Не помню» category to put a new operation under.
    case noCategory
  }

  private(set) var stage: Stage = .waiting
  private(set) var receipt: ReceiptQR?
  private(set) var proposal: ReceiptProposal?
  private(set) var photo: ReceiptPhoto?
  /// The operation the time goes to: the nearest by default, another of the offered ones by choice.
  var chosenId: UUID?
  /// «Это другая покупка»: a new operation although something fits.
  private(set) var wantsNew = false

  private let environment: AppEnvironment
  private let store: TransactionsStore
  private let dataset: @MainActor () -> Dataset?

  init(
    environment: AppEnvironment, store: TransactionsStore, dataset: @escaping @MainActor () -> Dataset?
  ) {
    self.environment = environment
    self.store = store
    self.dataset = dataset
  }

  // MARK: Input

  /// A picture: found off the main thread (Vision is slow on a large photo).
  func read(image: CGImage, photo: ReceiptPhoto?) async {
    stage = .reading
    let reading = await Task.detached(priority: .userInitiated) {
      ReceiptQRDetector.reading(of: image)
    }.value
    switch reading {
    case .receipt(let receipt): accept(receipt, photo: photo)
    case .notReceipt: stage = .notReceipt
    case .noCode: stage = .noCode
    }
  }

  func read(fileAt url: URL) async {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url), let image = ReceiptQRDetector.image(from: data)
    else {
      stage = .noCode
      return
    }
    await read(image: image, photo: ReceiptPhoto(data: data, filename: url.lastPathComponent))
  }

  /// The text of a QR code a camera has already read.
  func read(payload: String, photo: ReceiptPhoto? = nil) {
    guard let receipt = ReceiptQRParser.parse(payload) else {
      stage = .notReceipt
      return
    }
    accept(receipt, photo: photo)
  }

  /// A file that is not a picture, or one that cannot be opened.
  func pictureUnreadable() { stage = .noCode }

  func reset() {
    stage = .waiting
    receipt = nil
    proposal = nil
    photo = nil
    chosenId = nil
    wantsNew = false
  }

  private func accept(_ receipt: ReceiptQR, photo: ReceiptPhoto?) {
    self.receipt = receipt
    self.photo = photo
    wantsNew = false
    let proposed = ReceiptMatch.propose(
      receipt, among: candidates(), calendar: environment.calendar)
    proposal = proposed
    if case .supplement(let found, _, _) = proposed { chosenId = found.id } else { chosenId = nil }
    stage = .found
  }

  private func candidates() -> [ReceiptCandidate] {
    (dataset()?.entries ?? [])
      .filter { !$0.transaction.isDeleted }
      .map {
        ReceiptCandidate(
          id: $0.id, kind: $0.transaction.kind, occurredAt: $0.transaction.occurredAt,
          timeZoneId: $0.transaction.timeZoneId, currency: $0.transaction.currency,
          amountE4: $0.transaction.amountE4)
      }
  }

  // MARK: What the screen shows

  /// The operations the time can go to, the nearest first (empty when a new one is made).
  var choices: [ReceiptCandidate] {
    guard !wantsNew, case .supplement(let first, _, let others) = proposal else { return [] }
    return [first] + others
  }

  var isSupplementing: Bool { !wantsNew && !choices.isEmpty }

  /// A refund the books have no refund for is not made out of thin air: a refund is always of a
  /// purchase, and is recorded on it.
  var canCreate: Bool { newDraft.map { $0.kind != .refund } ?? false }

  var newDraft: ReceiptDraft? {
    if case .new(let draft) = proposal { return draft }
    guard let receipt else { return nil }
    return ReceiptMatch.draft(for: receipt, calendar: environment.calendar)
  }

  /// The words that name an operation: its comment, else its category, else «операция».
  func title(of id: UUID) -> String {
    guard let entry = dataset()?.entries.first(where: { $0.id == id }) else {
      return ReceiptText.t("receipt.operation.generic", environment)
    }
    if let note = entry.transaction.note?.trimmingCharacters(in: .whitespaces), !note.isEmpty {
      return note
    }
    let categories = dataset()?.categories ?? []
    if let categoryId = entry.parts.first?.categoryId,
      let category = categories.first(where: { $0.id == categoryId })
    {
      return category.name
    }
    return ReceiptText.t("receipt.operation.generic", environment)
  }

  func dayText(of id: UUID) -> String {
    guard let transaction = dataset()?.entries.first(where: { $0.id == id })?.transaction else {
      return ""
    }
    return environment.dates.longDay(
      environment.calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId))
  }

  var receiptSumText: String {
    receipt.map { environment.money.exact($0.amountE4) } ?? ""
  }

  var receiptDayText: String { receipt.map { environment.dates.longDay($0.day) } ?? "" }

  var receiptTimeText: String {
    guard let receipt else { return "" }
    return String(format: "%02d:%02d", receipt.time.hour, receipt.time.minute)
  }

  /// «Нашли «Кофе» — добавить время 18:32 и фото?» or the same without the photo.
  func question(for id: UUID) -> String {
    ReceiptText.format(
      canKeepPhoto ? "receipt.supplement.question.photo" : "receipt.supplement.question",
      environment, title(of: id), receiptTimeText)
  }

  /// «Новая операция: 1 250,50 ₽, 29 октября 2026 г. в 18:32».
  var newOperationText: String {
    ReceiptText.format(
      "receipt.new.summary", environment, receiptSumText, receiptDayText, receiptTimeText)
  }

  var canKeepPhoto: Bool { photo != nil && environment.receiptPhotosCanBeKept }

  // MARK: Choices and the write

  func makeNew() {
    wantsNew = true
    chosenId = nil
  }

  func backToFound() {
    guard case .supplement(let first, _, _) = proposal else { return }
    wantsNew = false
    chosenId = first.id
  }

  /// The button: adds the time to the chosen operation, or writes the new one. Whether it landed.
  @discardableResult
  func confirm() -> Bool {
    guard stage == .found, let receipt else { return false }
    if isSupplementing, let chosenId { return supplement(chosenId, receipt: receipt) }
    return create(receipt)
  }

  private func supplement(_ id: UUID, receipt: ReceiptQR) -> Bool {
    // Read from the database, not from the lists: the lists may be a moment behind a write.
    guard var entry = (try? environment.transactions?.entry(id: id)) ?? nil else {
      stage = .failed(.gone)
      return false
    }
    // The shop's clock is read in the zone the operation was recorded in.
    let zone = CalendarContext(
      timeZone: environment.calendar.zone(recordedIn: entry.transaction.timeZoneId))
    let moment = receipt.moment(in: zone)
    entry.transaction.occurredAt = moment
    entry.transaction.updatedAt = environment.now()
    switch store.saveEdit(entry, calendar: environment.calendar) {
    case .saved:
      keepPhoto(for: id)
      stage = .done(.timeAdded(receiptTimeText))
      return true
    case .gone:
      stage = .failed(.gone)
      return false
    default:
      stage = .failed(.notWritten)
      return false
    }
  }

  private func create(_ receipt: ReceiptQR) -> Bool {
    guard canCreate, let draft = newDraft else {
      stage = .failed(.notWritten)
      return false
    }
    guard
      let category = (dataset()?.categories ?? []).first(where: {
        $0.systemRole == .unknown && $0.kind == .expense && !$0.archived
      })
    else {
      stage = .failed(.noCategory)
      return false
    }
    let id = UUID()
    let now = environment.now()
    let transaction = Transaction(
      id: id, kind: draft.kind, occurredAt: draft.moment, currency: draft.currency,
      amountE4: draft.amountE4, createdAt: now, updatedAt: now,
      timeZoneId: TravelDay.recordedId(in: environment.calendar.timeZone))
    let entry = TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: id, categoryId: category.id, categorySource: .system,
          amountE4: draft.amountE4)
      ])
    guard store.save(entry) else {
      stage = .failed(.notWritten)
      return false
    }
    keepPhoto(for: id)
    stage = .done(.created)
    return true
  }

  /// The photo goes with the operation when the app keeps attachments. The operation is already
  /// written and the photo is an extra: a photo that does not land does not undo the time.
  private func keepPhoto(for id: UUID) {
    guard let photo, environment.receiptPhotosCanBeKept else { return }
    _ = environment.keepReceiptPhoto(photo, for: id)
  }
}
