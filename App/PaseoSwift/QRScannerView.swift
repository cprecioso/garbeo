#if os(iOS)
import AVFoundation
import PaseoKit
import SwiftUI
import VisionKit

/// Full-screen sheet that scans a Paseo pairing QR code (`paseo daemon pair`, or Desktop's
/// "Pair a device") and returns the link once it parses as a relay offer.
struct QRScannerSheet: View {
    var onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rejected: String?
    @State private var cameraAllowed: Bool?

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && cameraAllowed == nil {
                    ProgressView()
                } else if DataScannerViewController.isSupported && cameraAllowed == true && DataScannerViewController.isAvailable {
                    QRScannerView { payload in
                        if PairingLink.isPairingLink(payload), (try? PairingLink.parse(payload)) != nil {
                            onScan(payload)
                            dismiss()
                        } else {
                            rejected = "That QR code isn't a Paseo pairing code."
                        }
                    }
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Text(rejected ?? "Point the camera at the pairing QR code shown by `paseo daemon pair` or Paseo Desktop.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "Camera scanning unavailable",
                        systemImage: "qrcode.viewfinder",
                        description: Text(DataScannerViewController.isSupported
                            ? "Allow camera access for Paseo in Settings, or paste the pairing link instead."
                            : "This device can't scan QR codes. Paste the pairing link instead."))
                }
            }
            .task {
                guard DataScannerViewController.isSupported else { return }
                cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
            }
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct QRScannerView: UIViewControllerRepresentable {
    var onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: (String) -> Void
        private var lastPayload: String?

        init(onPayload: @escaping (String) -> Void) { self.onPayload = onPayload }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in addedItems {
                guard let payload = barcode.payloadStringValue, payload != lastPayload else { continue }
                lastPayload = payload
                onPayload(payload)
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue { onPayload(payload) }
        }
    }
}
#endif
