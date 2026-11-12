import AppCore
import XCTest

@testable import OhMyMoney

@MainActor
final class ThingsWishesFeatureTests: XCTestCase {
  func testWishPreviewChoosesALocalPhotoAndIgnoresVideosFilesAndTrash() {
    let id = UUID()
    func file(_ name: String, _ type: String, trashed: Bool = false) -> AttachedFile {
      AttachedFile(
        ownerKind: .wish, ownerId: id, contentHash: String(repeating: "a", count: 64),
        fileName: name, byteSize: 10, mediaType: type,
        trashedAt: trashed ? Date() : nil)
    }
    let video = file("video.mov", "video/quicktime")
    let document = file("file.bin", "application/octet-stream")
    let removed = file("removed.jpg", "image/jpeg", trashed: true)
    let photo = file("photo.png", "image/png")
    XCTAssertEqual(WishPhotoPreview.firstPhoto(in: [video, document, removed, photo]), photo)
    XCTAssertNil(WishPhotoPreview.firstPhoto(in: [video, document, removed]))
    XCTAssertEqual(AttachmentsModel.defaultKind(for: .wish, fileName: "photo.jpg"), .document)
    XCTAssertEqual(AttachmentsModel.defaultKind(for: .ownedItem, fileName: "video.mov"), .document)
  }

  func testFailedDeferredFilesRemainAvailableForRetryAndCanBeDiscarded() async {
    let model = AttachmentsModel(owner: .wish, ownerId: UUID(), deferred: true)
    let store = TransactionsStore()
    await model.add(
      [AttachmentSource(data: Data("synthetic".utf8), fileName: "photo.jpg")],
      service: nil, store: store)
    let failed = await model.commitPending(service: nil, store: store, retryFailures: true)
    XCTAssertEqual(failed, 1)
    XCTAssertEqual(model.pending.count, 1)
    model.discardPending()
    XCTAssertTrue(model.pending.isEmpty)
  }

  func testNewWordsReadInBothLanguages() {
    let environment = AppEnvironment()
    let keys = [
      "purchases.link.take", "purchases.link.success", "purchases.link.failure.address",
      "purchases.link.failure.response", "purchases.link.failure.markup",
      "purchases.link.failure.network",
      "purchases.link.image", "purchases.files.failed", "purchases.valuation.update",
      "purchases.valuation.amount", "purchases.valuation.day", "purchases.valuation.history",
      "purchases.valuation.empty", "purchases.thing.files",
    ]
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for key in keys {
        let text = PurchasesText.t(key, environment)
        XCTAssertFalse(text.isEmpty)
        XCTAssertNotEqual(text, key)
      }
      XCTAssertNotEqual(AttachmentsText.t("att.add.media", environment), "att.add.media")
    }
  }
}
