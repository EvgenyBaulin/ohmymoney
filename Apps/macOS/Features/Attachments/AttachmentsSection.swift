import AppCore
import AppDatabase
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
  import PhotosUI
#endif

/// The words of the attachments (the `Attachments` catalog).
@MainActor
enum AttachmentsText {
  static let table = "Attachments"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func kind(_ kind: AttachmentKind, _ environment: AppEnvironment) -> String {
    t("att.kind.\(kind.rawValue)", environment)
  }

  static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

/// A section of files for one thing, with its own model: the card put on the screen of an
/// operation, an asset, a debt or a subscription that is already saved. It shows nothing when the
/// app has no database to keep files for.
struct AttachedFilesCard: View {
  @Dependency(\.environment) private var environment
  let owner: AttachmentOwnerKind
  let id: UUID
  @State private var model: AttachmentsModel

  init(owner: AttachmentOwnerKind, id: UUID) {
    self.owner = owner
    self.id = id
    _model = State(initialValue: AttachmentsModel(owner: owner, ownerId: id))
  }

  var body: some View {
    if environment.attachments != nil {
      AttachmentsSection(model: model)
        .id(id)
    }
  }
}

/// The files of one thing: a list with a thumbnail, the kind, «Хранить всегда» and «В корзину»
/// on each, and the ways to add — the file chooser, a drop onto the section, the pasteboard;
/// on a phone the photo library and the camera. A click opens the file in QuickLook. Content, so
/// no glass.
struct AttachmentsSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Bindable var model: AttachmentsModel

  @State private var choosing = false
  @State private var preview: URL?
  @State private var dropTargeted = false
  #if os(iOS)
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsCamera = false
  #endif

  private var service: AttachmentService? { environment.attachments }
  private func t(_ key: String) -> String { AttachmentsText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(verbatim: t("att.title")).appFont(.headline)
        Spacer(minLength: 8)
        if model.isBusy { ProgressView().controlSize(.small) }
        PasteButton(supportedContentTypes: [.fileURL, .image, .pdf]) { providers in
          Task { await paste(providers) }
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("attachments.paste")
        addMenu
      }
      if model.files.isEmpty && model.pending.isEmpty {
        Text(verbatim: t("att.empty"))
          .appFont(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(model.files) { row($0) }
      ForEach(model.pending) { pendingRow($0) }
      if model.deferred, !model.pending.isEmpty {
        Text(verbatim: t("att.pending.hint"))
          .appFont(.caption).foregroundStyle(.secondary)
      }
      if model.failedCount > 0 {
        Label {
          Text(
            verbatim: environment.format(
              "att.failed", table: AttachmentsText.table, counts: model.failedCount))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .appFont(.caption).foregroundStyle(.red)
        .accessibilityIdentifier("attachments.failed")
      }
    }
    .padding(dropTargeted ? 4 : 0)
    .overlay {
      if dropTargeted {
        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
          .allowsHitTesting(false)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      guard !files.isEmpty else { return false }
      add(files.map(AttachmentSource.init(file:)))
      return true
    } isTargeted: {
      dropTargeted = $0
    }
    .fileImporter(
      isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true
    ) { result in
      if case .success(let urls) = result { add(urls.map(AttachmentSource.init(file:))) }
    }
    .quickLookPreview($preview)
    .task { model.reload(service: service) }
    .accessibilityIdentifier("attachments.section")
    #if os(iOS)
      .photosPicker(
        isPresented: $showsPhotos, selection: $pickedPhotos, matching: .images)
      .onChange(of: pickedPhotos) { _, items in
        guard !items.isEmpty else { return }
        pickedPhotos = []
        Task { await addPhotos(items) }
      }
      .fullScreenCover(isPresented: $showsCamera) {
        AttachmentCamera { data in
          showsCamera = false
          if let data {
            add([AttachmentSource(data: data, fileName: Self.cameraName(environment))])
          }
        }
        .ignoresSafeArea()
      }
    #endif
  }

  // MARK: Adding

  private var addMenu: some View {
    Menu {
      Button {
        choosing = true
      } label: {
        Label(t("att.add.file"), systemImage: "doc.badge.plus")
      }
      #if os(iOS)
        Button {
          showsPhotos = true
        } label: {
          Label(t("att.add.photo"), systemImage: "photo.on.rectangle")
        }
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
          Button {
            showsCamera = true
          } label: {
            Label(t("att.add.camera"), systemImage: "camera")
          }
        }
      #endif
    } label: {
      Label(t("att.add"), systemImage: "paperclip.badge.ellipsis")
        .labelStyle(.titleAndIcon)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityIdentifier("attachments.add")
  }

  private func add(_ sources: [AttachmentSource]) {
    Task { await model.add(sources, service: service, store: store) }
  }

  /// Files and pictures from the pasteboard: a file keeps its own name, a picture without one is
  /// named by the day.
  private func paste(_ providers: [NSItemProvider]) async {
    var sources: [AttachmentSource] = []
    for provider in providers {
      if provider.canLoadObject(ofClass: URL.self),
        let url = try? await Self.loadURL(from: provider), url.isFileURL
      {
        sources.append(AttachmentSource(file: url))
      } else if let type = [UTType.pdf, .image].first(where: {
        provider.hasItemConformingToTypeIdentifier($0.identifier)
      }), let data = try? await Self.loadData(from: provider, type: type) {
        let ext = (type == .pdf ? UTType.pdf : (provider.registeredContentTypes.first ?? .png))
          .preferredFilenameExtension ?? "bin"
        sources.append(
          AttachmentSource(data: data, fileName: Self.pastedName(environment, ext: ext)))
      }
    }
    add(sources)
  }

  private static func loadURL(from provider: NSItemProvider) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadObject(ofClass: URL.self) { url, error in
        if let url { continuation.resume(returning: url) }
        else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
      }
    }
  }

  private static func loadData(from provider: NSItemProvider, type: UTType) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
        if let data { continuation.resume(returning: data) }
        else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
      }
    }
  }

  private static func pastedName(_ environment: AppEnvironment, ext: String) -> String {
    "\(AttachmentsText.t("att.name.pasted", environment)) \(stamp()).\(ext)"
  }

  fileprivate static func cameraName(_ environment: AppEnvironment) -> String {
    "\(AttachmentsText.t("att.name.photo", environment)) \(stamp()).jpg"
  }

  private static func stamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    return formatter.string(from: Date())
  }

  #if os(iOS)
    private func addPhotos(_ items: [PhotosPickerItem]) async {
      var sources: [AttachmentSource] = []
      for item in items {
        // The bytes as the library has them: no resizing, no re-encoding.
        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        sources.append(
          AttachmentSource(
            data: data,
            fileName: "\(t("att.name.photo")) \(Self.stamp()) \(sources.count + 1).\(ext)"))
      }
      add(sources)
    }
  #endif

  // MARK: Rows

  private func row(_ file: AttachedFile) -> some View {
    let availability = service?.availability(of: file) ?? .present
    return HStack(spacing: 10) {
      Button {
        open(file)
      } label: {
        HStack(spacing: 10) {
          AttachmentThumbnail(file: file, service: service)
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: file.fileName).lineLimit(1).truncationMode(.middle)
            Text(verbatim: subtitle(file, availability))
              .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(availability != .present)
      .accessibilityLabel(Text(verbatim: file.fileName))
      .accessibilityHint(Text(verbatim: t("att.open")))
      Button {
        model.setKeepForever(file.id, !file.keepForever, service: service, store: store)
      } label: {
        Image(systemName: file.keepForever ? "pin.fill" : "pin")
      }
      .buttonStyle(.borderless)
      .help(t("att.keep"))
      .accessibilityLabel(Text(verbatim: t("att.keep")))
      .accessibilityValue(Text(verbatim: file.keepForever ? t("att.on") : t("att.off")))
      .accessibilityIdentifier("attachments.keep.\(file.id)")
      Menu {
        Picker(t("att.kind"), selection: kindBinding(file)) {
          ForEach(AttachmentKind.allCases, id: \.self) {
            Text(verbatim: AttachmentsText.kind($0, environment)).tag($0)
          }
        }
        Button(t("att.remove"), role: .destructive) {
          model.trash(file.id, service: service, store: store)
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel(Text(verbatim: t("att.more")))
      .accessibilityIdentifier("attachments.menu.\(file.id)")
    }
    .contextMenu {
      Button(t("att.remove"), role: .destructive) {
        model.trash(file.id, service: service, store: store)
      }
    }
  }

  private func pendingRow(_ source: AttachmentSource) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "paperclip").foregroundStyle(.secondary).frame(width: 44)
      Text(verbatim: source.fileName).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 4)
      Button {
        model.removePending(source.id)
      } label: {
        Image(systemName: "xmark.circle")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text(verbatim: t("att.remove")))
    }
  }

  private func kindBinding(_ file: AttachedFile) -> Binding<AttachmentKind> {
    Binding(
      get: { file.kind },
      set: { model.setKind(file.id, $0, service: service, store: store) })
  }

  private func subtitle(
    _ file: AttachedFile, _ availability: AttachmentRetention.Availability
  ) -> String {
    switch availability {
    case .removedByRule: return t("att.removedByRule")
    case .missing: return t("att.missing")
    case .present:
      return [AttachmentsText.kind(file.kind, environment), AttachmentsText.size(file.byteSize)]
        .joined(separator: " · ")
    }
  }

  private func open(_ file: AttachedFile) {
    guard let service else { return }
    Task {
      let url = await Task.detached { AttachmentsModel.previewURL(for: file, in: service) }.value
      preview = url
    }
  }
}

#if os(iOS)
  /// The system camera, for a photo of a receipt or a warranty card. It hands over the picture at
  /// the best quality the system gives; cancelling hands over nothing.
  struct AttachmentCamera: UIViewControllerRepresentable {
    let finish: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
      let picker = UIImagePickerController()
      picker.sourceType = .camera
      picker.delegate = context.coordinator
      return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
      UINavigationControllerDelegate
    {
      let finish: (Data?) -> Void
      init(finish: @escaping (Data?) -> Void) { self.finish = finish }

      func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
      ) {
        let image = info[.originalImage] as? UIImage
        finish(image?.jpegData(compressionQuality: 1))
      }

      func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
    }
  }
#endif
