#if os(iOS)
  import AppCore
  import SwiftUI
  import VisionKit

  /// The live camera reading QR codes (VisionKit). It stays open and gathers every different
  /// receipt code it sees until «Готово»; the codes then go on as a queue. A code that is no
  /// receipt is not gathered (a loyalty link next to the receipt), except that when nothing else
  /// was seen the first of them is handed over, so the screen can say it is not a receipt.
  struct ReceiptScannerScreen: View {
    let onCodes: ([String]) -> Void
    let onClose: () -> Void

    @Dependency(\.environment) private var environment
    @State private var payloads: [String] = []
    @State private var foreign: String?

    var body: some View {
      ZStack(alignment: .topTrailing) {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
          ReceiptScanner(onCode: gather).ignoresSafeArea()
        } else {
          VStack(spacing: 12) {
            Image(systemName: "camera.badge.ellipsis").appFont(.largeTitle)
              .accessibilityHidden(true)
            Text(verbatim: ReceiptText.t("receipt.camera.unavailable", environment))
              .multilineTextAlignment(.center).padding(.horizontal, 24)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        HStack(spacing: 12) {
          if !payloads.isEmpty {
            Button(
              ReceiptText.format("receipt.scan.done", environment, payloads.count)
            ) {
              onCodes(payloads)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("receipt.scan.done")
          } else if let foreign {
            Button(ReceiptText.t("receipt.scan.notReceipt", environment)) { onCodes([foreign]) }
              .buttonStyle(.bordered)
          }
          Button(ReceiptText.t("receipt.cancel", environment), action: onClose)
            .buttonStyle(.bordered)
        }
        .padding(16)
      }
    }

    private func gather(_ payload: String) {
      if ReceiptLinkParser.read(payload) != nil {
        if !payloads.contains(payload) { payloads.append(payload) }
      } else if foreign == nil {
        foreign = payload
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
      private var delivered: Set<String> = []

      init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

      func dataScanner(
        _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
        allItems: [RecognizedItem]
      ) {
        for item in addedItems {
          if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue,
            delivered.insert(payload).inserted
          {
            onCode(payload)
          }
        }
      }
    }
  }
#endif
