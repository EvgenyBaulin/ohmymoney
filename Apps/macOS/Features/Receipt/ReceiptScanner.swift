#if os(iOS)
  import SwiftUI
  import VisionKit

  /// The live camera reading QR codes (VisionKit). It hands over the text of the first code it
  /// sees and closes; whether that is a cash receipt is `ReceiptQRParser`'s business.
  struct ReceiptScannerScreen: View {
    let onCode: (String) -> Void
    let onClose: () -> Void

    @Dependency(\.environment) private var environment

    var body: some View {
      ZStack(alignment: .topTrailing) {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
          ReceiptScanner(onCode: onCode).ignoresSafeArea()
        } else {
          VStack(spacing: 12) {
            Image(systemName: "camera.badge.ellipsis").appFont(.largeTitle)
              .accessibilityHidden(true)
            Text(verbatim: ReceiptText.t("receipt.camera.unavailable", environment))
              .multilineTextAlignment(.center).padding(.horizontal, 24)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        Button(ReceiptText.t("receipt.cancel", environment), action: onClose)
          .buttonStyle(.borderedProminent).padding(16)
      }
    }
  }

  struct ReceiptScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
      let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .accurate,
        recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
        isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
      scanner.delegate = context.coordinator
      try? scanner.startScanning()
      return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
      let onCode: (String) -> Void
      private var delivered = false

      init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

      func dataScanner(
        _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
        allItems: [RecognizedItem]
      ) {
        guard !delivered else { return }
        for item in addedItems {
          if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
            delivered = true
            dataScanner.stopScanning()
            onCode(payload)
            return
          }
        }
      }
    }
  }
#endif
