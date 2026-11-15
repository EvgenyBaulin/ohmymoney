import AppCore
import CoreGraphics
import Foundation
import Observation

/// A picture of the receipt that may be kept with the operation.
struct ReceiptPhoto: Equatable {
  var data: Data
  var filename: String
}

/// One thing a receipt is read from: a file, the bytes of a picture, or the text of a QR code.
enum ReceiptInput: Equatable {
  case file(URL)
  case data(Data, filename: String)
  case payload(String)
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
    /// A guest bill: not a receipt, the payment (a receipt or a slip) comes after it.
    case bill
    case found
    /// The same receipt is already on this operation: nothing is written, it is shown.
    case alreadyRecorded(UUID)
    /// A link that names a receipt by its numbers only: no sum, so nothing to write, and the
    /// receipt is not on any operation.
    case linkOnly
    /// The last receipt of a queue has ended: the count of how they went.
    case queueDone(ReceiptQueueTally)
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
  /// What the paper was when the receipt came from printed text, `nil` for a QR code. Printed
  /// text can be misread, so the screen asks to check it before anything is written.
  private(set) var printedKind: PaperKind?
  /// The shop read from the header of a foreign receipt, only when the recognition was sure.
  private(set) var printedMerchant: String?
  /// The paper printed fiscal numbers that did not pass the checks: the receipt has no key.
  private(set) var numbersRejected = false
  /// The operation the time goes to: the nearest by default, another of the offered ones by choice.
  var chosenId: UUID?
  /// «Это другая покупка»: a new operation although something fits.
  private(set) var wantsNew = false
  /// The receipt shared by hand between categories, for a new operation (the QR carries only
  /// the total). Empty: the whole receipt goes to «Не помню», as before.
  private(set) var splitLines: [ReceiptSplit.Line] = []

  /// Several receipts taken one after another, `nil` for a single one.
  private(set) var queue: ReceiptQueue?
  private var pending: [ReceiptInput] = []
  /// The receipt of the queue that waits for the owner's word.
  private(set) var awaitingOwner = false

  /// Whether a queue is still going: more receipts to read, or one waiting for the owner.
  var isQueueRunning: Bool { queue.map { !$0.isFinished } ?? false }

  private let environment: AppEnvironment
  private let store: TransactionsStore
  private let dataset: @MainActor () -> Dataset?

  init(
    environment: AppEnvironment, store: TransactionsStore,
    dataset: @escaping @MainActor () -> Dataset?
  ) {
    self.environment = environment
    self.store = store
    self.dataset = dataset
  }

  // MARK: Input

  /// A picture: found off the main thread (Vision is slow on a large photo).
  func read(image: CGImage, photo: ReceiptPhoto?) async {
    self.photo = photo
    stage = .reading
    let reading = await Task.detached(priority: .userInitiated) {
      ReceiptQRDetector.reading(of: image)
    }.value
    switch reading {
    case .receipt(let receipt): accept(receipt, photo: photo)
    case .keyOnly, .notReceipt, .noCode:
      stage = .reading
      let lines = await Task.detached(priority: .userInitiated) {
        ReceiptTextReader.lines(in: image)
      }.value
      read(
        printed: PrintedReceiptReader.read(recognized: lines), photo: photo,
        otherwise: Self.fallback(for: reading), key: Self.key(of: reading))
    }
  }

  private static func fallback(for reading: ReceiptQRDetector.Reading) -> Stage {
    reading == .noCode ? .noCode : .notReceipt
  }

  private static func key(of reading: ReceiptQRDetector.Reading) -> ReceiptNumbers? {
    if case .keyOnly(let numbers) = reading { return numbers }
    return nil
  }

  func read(fileAt url: URL) async {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url) else {
      stage = .noCode
      return
    }
    await read(data: data, filename: url.lastPathComponent)
  }

  /// A file as it came — a photo in its full size, a screenshot, the PDF of an electronic
  /// receipt (every page) — read off the main thread.
  func read(data: Data, filename: String) async {
    photo = ReceiptPhoto(data: data, filename: filename)
    stage = .reading
    let reading = await Task.detached(priority: .userInitiated) {
      ReceiptQRDetector.reading(ofFile: data)
    }.value
    switch reading {
    case .receipt(let receipt):
      accept(receipt, photo: ReceiptPhoto(data: data, filename: filename))
    case .keyOnly, .notReceipt, .noCode:
      let lines = await Task.detached(priority: .userInitiated) {
        ReceiptTextReader.lines(inFile: data)
      }.value
      read(
        printed: PrintedReceiptReader.read(recognized: lines),
        photo: ReceiptPhoto(data: data, filename: filename), otherwise: Self.fallback(for: reading),
        key: Self.key(of: reading))
    }
  }

  /// The recognised lines of a picture whose QR code gave no receipt: a receipt, a slip or any
  /// paper with a total and a moment becomes a proposal to check; a guest bill is told to wait
  /// for the payment; anything else leaves `otherwise`.
  func read(printedLines lines: [String], photo: ReceiptPhoto? = nil, otherwise: Stage = .noCode) {
    read(printed: PrintedReceiptReader.read(lines: lines), photo: photo, otherwise: otherwise)
  }

  /// Lines with the recognition's confidence: a confidently read foreign receipt also offers
  /// the shop's name.
  func read(
    recognized lines: [RecognizedLine], photo: ReceiptPhoto? = nil, otherwise: Stage = .noCode
  ) {
    read(printed: PrintedReceiptReader.read(recognized: lines), photo: photo, otherwise: otherwise)
  }

  private func read(
    printed reading: PrintedReading, photo: ReceiptPhoto?, otherwise: Stage,
    key: ReceiptNumbers? = nil
  ) {
    switch reading {
    case .receipt(let printed):
      accept(printed.receipt, photo: photo, printed: printed)
    case .bill:
      stage = .bill
    case .nothing:
      if let key {
        acceptKey(key, photo: photo)
      } else {
        stage = otherwise
      }
    }
  }

  /// The text of a QR code a camera has already read.
  func read(payload: String, photo: ReceiptPhoto? = nil) {
    switch ReceiptLinkParser.read(payload) {
    case .receipt(let receipt): accept(receipt, photo: photo)
    case .keyOnly(let numbers): acceptKey(numbers, photo: photo)
    case nil: stage = .notReceipt
    }
  }

  /// A receipt known by its numbers only: if an operation holds it, say so; otherwise there is
  /// nothing to write (the page behind the link is never opened).
  private func acceptKey(_ numbers: ReceiptNumbers, photo: ReceiptPhoto?) {
    self.photo = photo
    receipt = nil
    proposal = nil
    if let holder = ReceiptMatch.recorded(numbers: numbers, among: candidates(holding: numbers)) {
      chosenId = nil
      stage = .alreadyRecorded(holder.id)
    } else {
      stage = .linkOnly
    }
  }

  /// A file that is not a picture, or one that cannot be opened.
  func pictureUnreadable() { stage = .noCode }

  func reset() {
    stage = .waiting
    receipt = nil
    proposal = nil
    photo = nil
    printedKind = nil
    printedMerchant = nil
    numbersRejected = false
    chosenId = nil
    wantsNew = false
    splitLines = []
    queue = nil
    pending = []
    awaitingOwner = false
  }

  private func accept(_ receipt: ReceiptQR, photo: ReceiptPhoto?, printed: PrintedReceipt? = nil) {
    self.receipt = receipt
    self.photo = photo
    printedKind = printed?.kind
    printedMerchant = printed?.merchant
    numbersRejected = printed?.numbersRejected ?? false
    wantsNew = false
    splitLines = []
    let proposed = ReceiptMatch.propose(
      receipt, among: candidates(for: receipt), calendar: environment.calendar)
    proposal = proposed
    switch proposed {
    case .alreadyRecorded(let holder):
      chosenId = nil
      stage = .alreadyRecorded(holder.id)
    case .supplement(let found, _, _):
      chosenId = found.id
      stage = .found
    case .new:
      chosenId = nil
      stage = .found
    }
  }

  /// The operations of the books, and those that already hold this receipt read from the
  /// database: the lists may be a moment behind a write, and a second scan right after the first
  /// must still find it.
  private func candidates(for receipt: ReceiptQR) -> [ReceiptCandidate] {
    candidates(holding: receipt.numbers)
  }

  private func candidates(holding numbers: ReceiptNumbers?) -> [ReceiptCandidate] {
    var list = (dataset()?.entries ?? [])
      .filter { !$0.transaction.isDeleted }
      .map { Self.candidate($0.transaction) }
    if let numbers,
      let holders = try? environment.transactions?.operations(holdingReceipt: numbers)
    {
      // The database is the fresher: an operation the lists still show without the numbers is
      // replaced by its stored self.
      let held = Set(holders.map(\.id))
      list = list.filter { !held.contains($0.id) } + holders.map(Self.candidate)
    }
    return list
  }

  private static func candidate(_ transaction: CoreKit.Transaction) -> ReceiptCandidate {
    ReceiptCandidate(
      id: transaction.id, kind: transaction.kind, occurredAt: transaction.occurredAt,
      timeZoneId: transaction.timeZoneId, currency: transaction.currency,
      amountE4: transaction.amountE4, receipt: transaction.receipt)
  }

  /// The operation as the lists have it, else as the database has it.
  private func entry(of id: UUID) -> TransactionEntry? {
    if let entry = dataset()?.entries.first(where: { $0.id == id }) { return entry }
    return (try? environment.transactions?.entry(id: id)) ?? nil
  }

  // MARK: What the screen shows

  /// The operations the time can go to, the nearest first (empty when a new one is made).
  var choices: [ReceiptCandidate] {
    guard !wantsNew, case .supplement(let first, _, let others) = proposal else { return [] }
    return [first] + others
  }

  /// Operations that nearly fit (a rounding, a tip) when none fits exactly: offered, never chosen
  /// for the owner.
  var similar: [ReceiptCandidate] {
    guard case .new(let draft) = proposal, !wantsNew else { return [] }
    return draft.similar
  }

  /// The same near operations with what makes each close, for the screen to say.
  var nearby: [ReceiptNearMatch] {
    guard case .new(let draft) = proposal, !wantsNew else { return [] }
    return draft.nearby
  }

  /// «Сумма на 0,50 ₽ меньше (округление) · в тот же день» for a near operation.
  func reason(for match: ReceiptNearMatch) -> String {
    let amount = environment.money.exact(
      AmountE4(raw: abs(match.sumDifferenceE4)), currency: match.candidate.currency)
    let sum: String
    if match.isRounding {
      sum = ReceiptText.format(
        match.sumDifferenceE4 < 0 ? "receipt.near.sum.roundedDown" : "receipt.near.sum.roundedUp",
        environment, amount)
    } else {
      sum = ReceiptText.format(
        match.sumDifferenceE4 < 0 ? "receipt.near.sum.less" : "receipt.near.sum.more",
        environment, amount)
    }
    let dayKey =
      match.dayOffset < 0
      ? "receipt.near.day.before"
      : match.dayOffset > 0 ? "receipt.near.day.after" : "receipt.near.day.same"
    let day = ReceiptText.t(dayKey, environment)
    return ReceiptText.format("receipt.near.reason", environment, sum, day)
  }

  /// Smaller operations already written for the day of the receipt: a purchase paid in two
  /// ways was entered as two, and a new one for the whole receipt would count it twice.
  var sameDay: [ReceiptCandidate] {
    guard case .new(let draft) = proposal, !wantsNew else { return [] }
    return draft.sameDay
  }

  /// The few of them that add up to the receipt exactly: very likely what the receipt is for.
  var splitParts: [ReceiptCandidate] {
    guard case .new(let draft) = proposal, !wantsNew else { return [] }
    return draft.splitParts
  }

  /// «600 + 400» for the operations that add up to the receipt.
  var splitSumText: String {
    splitParts.map { environment.money.exact($0.amountE4, currency: $0.currency) }
      .joined(separator: " + ")
  }

  /// The owner picked a similar operation: the time goes to it like to an exact match.
  func useSimilar(_ id: UUID) {
    guard let receipt, let found = (similar + sameDay).first(where: { $0.id == id }) else {
      return
    }
    let zone = CalendarContext(timeZone: environment.calendar.zone(recordedIn: found.timeZoneId))
    proposal = .supplement(found, moment: receipt.moment(in: zone), others: [])
    wantsNew = false
    chosenId = id
  }

  var isSupplementing: Bool { !wantsNew && !choices.isEmpty }

  /// A refund the books have no refund for is not made out of thin air: a refund is always of a
  /// purchase, and is recorded on it. Lines of a split above the receipt block the write too.
  var canCreate: Bool {
    guard let draft = newDraft, draft.kind != .refund else { return false }
    return !splitRemainder.isNegative
  }

  // MARK: Splitting by categories

  /// The categories a line may take: live expense categories, the system ones left out (what the
  /// lines leave goes to «Не помню» by itself).
  var splitCategories: [CoreKit.Category] {
    (dataset()?.categories ?? []).filter {
      $0.kind == .expense && !$0.archived && $0.systemRole == nil
    }
  }

  /// The receipt as a split: its total and the lines so far.
  private var split: ReceiptSplit {
    ReceiptSplit(total: receipt?.amountE4 ?? .zero, lines: splitLines)
  }

  /// What the lines leave of the receipt; below zero when they exceed it.
  var splitRemainder: AmountE4 { split.remainder }

  /// A line of `amount` in `category`; a zero or negative sum is no line.
  func addSplitLine(category: UUID, amount: AmountE4) {
    guard amount > .zero else { return }
    splitLines.append(ReceiptSplit.Line(categoryId: category, amountE4: amount))
  }

  func removeSplitLine(at index: Int) {
    guard splitLines.indices.contains(index) else { return }
    splitLines.remove(at: index)
  }

  func clearSplit() { splitLines = [] }

  var newDraft: ReceiptDraft? {
    if case .new(let draft) = proposal { return draft }
    guard let receipt else { return nil }
    return ReceiptMatch.draft(for: receipt, calendar: environment.calendar)
  }

  /// The words that name an operation: its comment, else its category, else «операция».
  func title(of id: UUID) -> String {
    guard let entry = entry(of: id) else {
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
    guard let transaction = entry(of: id)?.transaction else {
      return ""
    }
    return environment.dates.longDay(
      environment.calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId))
  }

  var receiptSumText: String {
    receipt.map { environment.money.exact($0.amountE4, currency: $0.currency) } ?? ""
  }

  /// The key of the catalog for the line that asks to check what was read from printed text;
  /// `nil` for a QR code, which is exact.
  var checkNoteKey: String? {
    switch printedKind {
    case nil: nil
    case .fiscal: numbersRejected ? "receipt.check.numbers" : "receipt.check.printed"
    case .slip: "receipt.check.slip"
    case .bill, .other: "receipt.check.other"
    }
  }

  /// «ФН 9960440300000000 · ФД 12345 · ФП 2345678901» of a receipt read from print, to be
  /// compared with the paper; empty when there are no numbers.
  var numbersText: String {
    guard let numbers = receipt?.numbers else { return "" }
    return ReceiptText.format(
      "receipt.numbers", environment, numbers.fiscalDrive, numbers.documentNumber,
      numbers.fiscalSign ?? "—")
  }

  /// «Магазин: Cafe Aroma» when the shop was read, else empty.
  var merchantText: String {
    printedMerchant.map { ReceiptText.format("receipt.new.merchant", environment, $0) } ?? ""
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

  /// «Этот чек уже записан: «Кофе», 15 января 2026 г.»
  func alreadyRecordedText(_ id: UUID) -> String {
    ReceiptText.format("receipt.already", environment, title(of: id), dayText(of: id))
  }

  // MARK: Several receipts

  /// Takes the inputs one after another. One input is read as a single receipt. Several make a
  /// queue: what has one obvious answer is written by itself (`ReceiptQueuePolicy`), a receipt
  /// that needs a decision waits for it, and at the end the count says how they went.
  func start(_ inputs: [ReceiptInput]) async {
    reset()
    guard inputs.count > 1 else {
      if let only = inputs.first { await load(only) }
      return
    }
    queue = ReceiptQueue(total: inputs.count)
    pending = inputs
    await runQueue()
  }

  private func load(_ input: ReceiptInput) async {
    switch input {
    case .file(let url): await read(fileAt: url)
    case .data(let data, let filename): await read(data: data, filename: filename)
    case .payload(let text): read(payload: text)
    }
  }

  private func runQueue() async {
    while !pending.isEmpty {
      await load(pending.removeFirst())
      switch stage {
      case .alreadyRecorded:
        queue?.settle(.repeated)
      case .found:
        guard let proposal else {
          queue?.settle(.unread)
          continue
        }
        switch ReceiptQueuePolicy.action(for: proposal, printed: printedKind != nil) {
        case .repeated:
          queue?.settle(.repeated)
        case .supplement(let id):
          chosenId = id
          queue?.settle(confirm() ? .recorded : .left)
        case .create:
          queue?.settle(confirm() ? .recorded : .left)
        case .ask:
          awaitingOwner = true
          return
        }
      default:
        // No code, not a receipt, a guest bill, a link with no sum: nothing was read.
        queue?.settle(.unread)
      }
    }
    if let queue, queue.isFinished { stage = .queueDone(queue.tally) }
  }

  /// The button of the receipt on screen. In a queue the next receipt follows by itself.
  func confirmAndContinue() async {
    guard isQueueRunning, awaitingOwner else {
      confirm()
      return
    }
    let written = confirm()
    // A split above the receipt keeps it open: the owner takes a line off and writes again.
    if !written, stage == .found { return }
    queue?.settle(written ? .recorded : .left)
    awaitingOwner = false
    await runQueue()
  }

  /// «Пропустить»: the receipt that waits is passed by, the queue goes on.
  func skipCurrent() async {
    guard isQueueRunning, awaitingOwner else { return }
    queue?.settle(.left)
    awaitingOwner = false
    await runQueue()
  }

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
    // The numbers of the receipt go with its time: the same receipt read again finds this one.
    entry.transaction.receipt = receipt.numbers
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
    // Lines above the receipt are said by the sheet, not failed: the receipt stays open so that
    // the owner can take a line off and write again.
    if splitRemainder.isNegative { return false }
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
    // The lines of a split become the parts; what they leave goes to «Не помню».
    var amounts = [(category: category.id, source: CategorySource.system, amount: draft.amountE4)]
    if !splitLines.isEmpty {
      guard case .success(let lines) = split.parts(remainderCategory: category.id) else {
        stage = .failed(.notWritten)
        return false
      }
      amounts = lines.map {
        ($0.categoryId, $0.categoryId == category.id ? .system : .manual, $0.amountE4)
      }
    }
    let id = UUID()
    let now = environment.now()
    let transaction = Transaction(
      id: id, kind: draft.kind, occurredAt: draft.moment, currency: draft.currency,
      amountE4: draft.amountE4, note: printedMerchant, createdAt: now, updatedAt: now,
      timeZoneId: TravelDay.recordedId(in: environment.calendar.timeZone),
      receipt: receipt.numbers)
    let entry = TransactionEntry(
      transaction: transaction,
      parts: amounts.map {
        TransactionPart(
          transactionId: id, categoryId: $0.category, categorySource: $0.source,
          amountE4: $0.amount)
      })
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
