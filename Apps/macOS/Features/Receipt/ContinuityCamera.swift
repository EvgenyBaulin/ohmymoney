#if os(macOS)
  import AppKit
  import SwiftUI

  /// A responder that takes the picture Continuity Camera brings: «Снять фото» or «Отсканировать
  /// документы» of a nearby iPhone or iPad. AppKit puts the item into a menu popped up over this
  /// view when the responder says it can receive images, and calls `readSelection(from:)` with
  /// the picture on the pasteboard.
  final class ContinuityCameraView: NSView, @preconcurrency NSServicesMenuRequestor {
    var onImage: ((CGImage, ReceiptPhoto?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func validRequestor(
      forSendType sendType: NSPasteboard.PasteboardType?,
      returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
      if let returnType, NSImage.imageTypes.contains(returnType.rawValue) { return self }
      return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
      guard pasteboard.canReadItem(withDataConformingToTypes: NSImage.imageTypes),
        let image = NSImage(pasteboard: pasteboard),
        let picture = ContinuityPictures.cgImage(of: image)
      else { return false }
      onImage?(picture, ContinuityPictures.photo(of: picture))
      return true
    }
  }

  /// From a picture of the pasteboard to pixels Vision reads and a JPEG the app may keep.
  enum ContinuityPictures {
    /// The long side, in pixels, a picture is drawn at: a PDF scan has no pixels of its own, and
    /// the modules of a QR code on a receipt are small.
    static let longSide: CGFloat = 2400

    static func cgImage(of image: NSImage) -> CGImage? {
      var proposed = CGRect(origin: .zero, size: image.size)
      if let direct = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
        max(direct.width, direct.height) >= Int(longSide / 2)
      {
        return direct
      }
      guard image.size.width > 0, image.size.height > 0 else { return nil }
      let scale = longSide / max(image.size.width, image.size.height)
      let width = Int((image.size.width * scale).rounded())
      let height = Int((image.size.height * scale).rounded())
      guard
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      let graphics = NSGraphicsContext(cgContext: context, flipped: false)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = graphics
      image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
      NSGraphicsContext.restoreGraphicsState()
      return context.makeImage()
    }

    static func photo(of image: CGImage) -> ReceiptPhoto? {
      let representation = NSBitmapImageRep(cgImage: image)
      guard
        let data = representation.representation(
          using: .jpeg, properties: [.compressionFactor: 0.85])
      else { return nil }
      return ReceiptPhoto(data: data, filename: "receipt.jpg")
    }
  }

  /// Opens the menu with the Continuity Camera items over the view it is wired to.
  @MainActor
  final class ContinuityCameraHandle {
    fileprivate weak var view: ContinuityCameraView?

    /// Pops up the menu. AppKit adds «Снять фото» and «Отсканировать документы» for every iPhone
    /// or iPad nearby; with none nearby the menu holds `hint` alone, and nothing breaks.
    func showMenu(hint: String) {
      guard let view, let window = view.window, let event = NSApp.currentEvent else { return }
      window.makeFirstResponder(view)
      let menu = NSMenu()
      let title = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
      title.isEnabled = false
      menu.addItem(title)
      NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
  }

  struct ContinuityCameraReceiver: NSViewRepresentable {
    let handle: ContinuityCameraHandle
    let onImage: (CGImage, ReceiptPhoto?) -> Void

    func makeNSView(context: Context) -> ContinuityCameraView {
      let view = ContinuityCameraView()
      view.onImage = onImage
      handle.view = view
      return view
    }

    func updateNSView(_ view: ContinuityCameraView, context: Context) {
      view.onImage = onImage
      handle.view = view
    }
  }
#else
  /// On the phone the camera reads the code itself; this keeps the sheet one piece of code.
  @MainActor
  final class ContinuityCameraHandle {}
#endif
