import Foundation
import SwiftUI
import Vision
import VisionKit

/// Apple's document camera: edge detection, perspective correction and
/// auto-capture for free. Hands back one page image and nothing else — the
/// picture never leaves this struct.
struct DocumentScanner: UIViewControllerRepresentable {
    var onScan: (UIImage) -> Void
    var onError: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            if scan.pageCount > 0 { parent.onScan(scan.imageOfPage(at: 0)) }
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onError("The camera could not scan the receipt. Import an image or enter it manually.")
            parent.dismiss()
        }
    }
}

/// On-device OCR for one receipt. Produces the plain text the drafter reads;
/// the image is released as soon as this returns.
enum ReceiptText {
    enum Failure: Error { case noImageData, noText }

    static func read(_ image: UIImage) async throws -> String {
        let normalized = UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        guard let cgImage = normalized.cgImage else { throw Failure.noImageData }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let observations = try await request.perform(on: cgImage)
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let blocks = observations.compactMap { observation -> (text: String, rect: CGRect)? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, observation.boundingBox.toImageCoordinates(size, origin: .upperLeft))
        }

        let text = ordered(blocks)
        guard !text.isEmpty else { throw Failure.noText }
        return text
    }

    /// Vision returns blocks in detection order, not reading order. A receipt
    /// only makes sense top to bottom, with the amount beside its label, so
    /// blocks are banded into rows first and read left to right within a row.
    // ponytail: fixed row banding off the mean block height. Good enough for a
    // flat receipt; switch to clustering if skewed photos start splitting rows.
    static func ordered(_ blocks: [(text: String, rect: CGRect)]) -> String {
        guard !blocks.isEmpty else { return "" }
        let meanHeight = max(blocks.reduce(0) { $0 + $1.rect.height } / CGFloat(blocks.count), 1)
        let rows = Dictionary(grouping: blocks) { Int(($0.rect.midY / (meanHeight * 0.7)).rounded(.down)) }
        return rows.keys.sorted()
            .map { key in
                rows[key]!.sorted { $0.rect.minX < $1.rect.minX }
                    .map(\.text)
                    .joined(separator: "  ")
            }
            .joined(separator: "\n")
    }
}
