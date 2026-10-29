import AppCore
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
  import PhotosUI
#endif

extension View {
  /// The receipt reader over the main window: «Файл» → «Чек по QR…» or a picture dropped on the
  /// window. Like every question the app raises by itself, never over the cover of the locked app.
  func receiptSheet(_ deps: AppDependencies) -> some View {
    modifier(ReceiptPresenter(deps: deps))
  }
}

struct ReceiptPresenter: ViewModifier {
  let deps: AppDependencies

  /// Pictures a camera or a screenshot gives.
  static func pictures(in urls: [URL]) -> [URL] {
    urls.filter { url in
      UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) ?? false
    }
  }

  func body(content: Content) -> some View {
    let environment = deps.environment
    content.sheet(item: environment.lock.presenting(Bindable(environment).receiptRequest)) {
      request in
      ReceiptSheet(urls: request.urls).appDependencies(deps)
    }
  }
}

/// «Чек по QR»: the sum, the day and the time of a cash receipt, read from the code on a photo or
/// on the camera. The lines of the receipt are not in the code and nothing goes to the network.
struct ReceiptSheet: View {
  let urls: [URL]

  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss

  @State private var model: ReceiptModel?
  @State private var picking = false
  @State private var isDropTarget = false
  @State private var scanning = false
  @State private var continuity = ContinuityCameraHandle()
  #if os(iOS)
    @State private var pickedPhoto: PhotosPickerItem?
  #endif

  private func t(_ key: String) -> String { ReceiptText.t(key, environment) }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let model {
        content(model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .sheetFrame(minWidth: 520, idealWidth: 560, minHeight: 380, idealHeight: 420)
    .task {
      guard model == nil else { return }
      let made = ReceiptModel(
        environment: environment, store: store, dataset: { compute.snapshot?.dataset })
      model = made
      if let url = urls.first { await made.read(fileAt: url) }
    }
    .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { result in
      guard case .success(let chosen) = result, let model else { return }
      Task { await model.read(fileAt: chosen) }
    }
    .dropDestination(for: URL.self) { dropped, _ in
      guard let model, let url = ReceiptPresenter.pictures(in: dropped).first else { return false }
      Task { await model.read(fileAt: url) }
      return true
    } isTargeted: {
      isDropTarget = $0
    }
    .overlay {
      if isDropTarget {
        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
          .padding(6).allowsHitTesting(false)
      }
    }
    #if os(iOS)
      .fullScreenCover(isPresented: $scanning) {
        ReceiptScannerScreen(
          onCode: { payload in
            scanning = false
            model?.read(payload: payload)
          },
          onClose: { scanning = false })
      }
      .onChange(of: pickedPhoto) { _, item in
        guard let item, let model else { return }
        Task {
          if let data = try? await item.loadTransferable(type: Data.self),
            let image = ReceiptQRDetector.image(from: data)
          {
            await model.read(image: image, photo: ReceiptPhoto(data: data, filename: "receipt.jpg"))
          } else {
            model.pictureUnreadable()
          }
          pickedPhoto = nil
        }
      }
    #endif
    .accessibilityIdentifier("receipt.sheet")
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: t("receipt.title")).appFont(.headline)
      Text(verbatim: t("receipt.subtitle")).appFont(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }

  // MARK: Content

  @ViewBuilder
  private func content(_ model: ReceiptModel) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      switch model.stage {
      case .waiting:
        inputs(model)
      case .reading:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(verbatim: t("receipt.reading")).foregroundStyle(.secondary)
        }
      case .noCode:
        notice("receipt.noCode", symbol: "qrcode.viewfinder")
        inputs(model)
      case .notReceipt:
        notice("receipt.notReceipt", symbol: "questionmark.circle")
        inputs(model)
      case .found:
        found(model)
      case .done(let kind):
        done(kind, model)
      case .failed(let failure):
        notice(failureKey(failure), symbol: "exclamationmark.triangle")
        buttons(model)
      }
    }
    .padding(16)
  }

  private func notice(_ key: String, symbol: String) -> some View {
    Label {
      Text(verbatim: t(key)).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: symbol).accessibilityHidden(true)
    }
    .foregroundStyle(.secondary)
  }

  private func failureKey(_ failure: ReceiptModel.FailureKind) -> String {
    switch failure {
    case .notWritten: "receipt.failed.notWritten"
    case .gone: "receipt.failed.gone"
    case .noCategory: "receipt.failed.noCategory"
    }
  }

  // MARK: Ways to bring a picture

  @ViewBuilder
  private func inputs(_ model: ReceiptModel) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        #if os(macOS)
          Button {
            continuity.showMenu(hint: t("receipt.iphone.menuHint"))
          } label: {
            Label(t("receipt.iphone"), systemImage: "iphone.gen3.radiowaves.left.and.right")
          }
          .background(
            ContinuityCameraReceiver(handle: continuity) { image, photo in
              Task { await model.read(image: image, photo: photo) }
            }
          )
          .accessibilityIdentifier("receipt.iphone")
        #else
          Button {
            scanning = true
          } label: {
            Label(t("receipt.scan"), systemImage: "qrcode.viewfinder")
          }
          .accessibilityIdentifier("receipt.scan")
          PhotosPicker(selection: $pickedPhoto, matching: .images) {
            Label(t("receipt.photos"), systemImage: "photo")
          }
        #endif
        Button {
          picking = true
        } label: {
          Label(t("receipt.choose"), systemImage: "photo.on.rectangle")
        }
        .accessibilityIdentifier("receipt.choose")
      }
      #if os(macOS)
        Text(verbatim: t("receipt.iphone.hint")).appFont(.caption).foregroundStyle(.secondary)
        Text(verbatim: t("receipt.drop")).appFont(.caption).foregroundStyle(.secondary)
      #endif
    }
  }

  // MARK: A receipt was read

  @ViewBuilder
  private func found(_ model: ReceiptModel) -> some View {
    Label {
      Text(
        verbatim: ReceiptText.format(
          "receipt.facts", environment, model.receiptSumText, model.receiptDayText,
          model.receiptTimeText)
      )
      .monospacedDigit()
    } icon: {
      Image(systemName: "qrcode").accessibilityHidden(true)
    }
    .appFont(.body)
    if model.receipt?.isRefund == true {
      Text(verbatim: t("receipt.refund")).foregroundStyle(.secondary)
    }
    if model.isSupplementing, let id = model.chosenId {
      Text(verbatim: model.question(for: id)).appFont(.title3)
        .fixedSize(horizontal: false, vertical: true)
      if model.choices.count > 1 {
        Picker(
          t("receipt.choices"),
          selection: Binding(get: { model.chosenId ?? id }, set: { model.chosenId = $0 })
        ) {
          ForEach(model.choices, id: \.id) { choice in
            Text(verbatim: "\(model.title(of: choice.id)) · \(model.dayText(of: choice.id))")
              .tag(choice.id)
          }
        }
        .accessibilityIdentifier("receipt.choices")
      } else {
        Text(verbatim: model.dayText(of: id)).foregroundStyle(.secondary)
      }
    } else {
      Text(verbatim: model.newOperationText).appFont(.title3)
        .fixedSize(horizontal: false, vertical: true)
      Text(verbatim: t(model.canCreate ? "receipt.new.category" : "receipt.new.refundHint"))
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    Spacer(minLength: 0)
    HStack {
      Button(t("receipt.cancel")) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Spacer()
      if model.isSupplementing {
        Button(t("receipt.otherPurchase")) { model.makeNew() }
          .accessibilityIdentifier("receipt.other")
        Button(t(model.canKeepPhoto ? "receipt.addTimePhoto" : "receipt.addTime")) {
          model.confirm()
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("receipt.confirm")
      } else {
        if case .supplement = model.proposal {
          Button(t("receipt.backToFound")) { model.backToFound() }
        }
        Button(t("receipt.anotherReceipt")) { model.reset() }
        Button(t(model.canKeepPhoto ? "receipt.createPhoto" : "receipt.create")) {
          model.confirm()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canCreate)
        .accessibilityIdentifier("receipt.confirm")
      }
    }
  }

  private func done(_ kind: ReceiptModel.DoneKind, _ model: ReceiptModel) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      switch kind {
      case .timeAdded(let time):
        Label(
          ReceiptText.format("receipt.done.time", environment, time),
          systemImage: "checkmark.circle")
      case .created:
        Label(t("receipt.done.created"), systemImage: "checkmark.circle")
      }
      Text(verbatim: t("receipt.done.undo")).foregroundStyle(.secondary)
      Spacer(minLength: 0)
      HStack {
        Spacer()
        Button(t("receipt.anotherReceipt")) { model.reset() }
        Button(t("receipt.done")) { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
  }

  private func buttons(_ model: ReceiptModel) -> some View {
    HStack {
      Spacer()
      Button(t("receipt.anotherReceipt")) { model.reset() }
      Button(t("receipt.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
    }
  }
}
