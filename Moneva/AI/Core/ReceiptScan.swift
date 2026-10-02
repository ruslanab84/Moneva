import Foundation
import SwiftUI
import Vision
import VisionKit

/// Apple's document camera: edge detection, perspective correction and
/// auto-capture. Hands the first page to the local receipt review.
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

/// OCR geometry and confidence stay available until the review is dismissed.
struct ReceiptTextRow {
    var text: String
    var confidence: Float
}

enum ReceiptText {
    enum Failure: Error { case noImageData, noText }

    static func read(_ image: UIImage) async throws -> [ReceiptTextRow] {
        let normalized = UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        guard let cgImage = normalized.cgImage else { throw Failure.noImageData }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: cgImage)
        try Task.checkCancellation()
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let blocks = observations.compactMap { observation -> Block? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Block(text: candidate.string, rect: observation.boundingBox.toImageCoordinates(size, origin: .upperLeft), confidence: candidate.confidence)
        }
        let rows = rows(blocks)
        guard !rows.isEmpty else { throw Failure.noText }
        return rows
    }

    struct Block {
        var text: String
        var rect: CGRect
        var confidence: Float = 1
    }

    /// Pair labels and prices using actual vertical overlap rather than fixed page bands.
    static func rows(_ blocks: [Block]) -> [ReceiptTextRow] {
        var groups: [[Block]] = []
        for block in blocks.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let last = groups.last, let anchor = last.first,
               abs(anchor.rect.midY - block.rect.midY) <= max(1, min(anchor.rect.height, block.rect.height) * 0.5) {
                groups[groups.count - 1].append(block)
            } else { groups.append([block]) }
        }
        return groups.map { group in
            ReceiptTextRow(text: group.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: "  "),
                confidence: group.map(\.confidence).min() ?? 0)
        }
    }

    static func ordered(_ blocks: [(text: String, rect: CGRect)]) -> String {
        rows(blocks.map { Block(text: $0.text, rect: $0.rect) }).map(\.text).joined(separator: "\n")
    }

    static func amount(_ printed: String) -> Decimal? {
        let unsigned = printed.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "−", with: "")
        if unsigned.range(of: #"^[0-9]{1,3}([,. \u00a0\u202f])[0-9]{3}(?:\1[0-9]{3})*[.,][0-9]{2}$"#, options: .regularExpression) != nil,
           let separator = unsigned.lastIndex(where: { $0 == "." || $0 == "," }),
           let grouping = unsigned.first(where: { !$0.isNumber }), grouping != unsigned[separator] {
            let integer = unsigned[..<separator].filter(\.isNumber)
            return Money.parse(integer + "." + unsigned[unsigned.index(after: separator)...])
        }
        return Money.parse(unsigned)
    }

    /// Conservative numeric candidates. Unrecognized layouts stay visible in raw OCR for manual entry.
    // ponytail: rightmost printed amount supports simple receipt rows; add merchant-specific layouts only from verified fixtures.
    static func items(from rows: [ReceiptTextRow]) -> [ReceiptItem] {
        let price = try! NSRegularExpression(pattern: #"(?:^|\s)[$€£₼]?\s*([-−]?(?:[0-9]{1,3}(?:[,. \u00a0\u202f][0-9]{3})+[.,][0-9]{2}|[0-9]+(?:[.,][0-9]{1,3})?)-?)(?:\s*(?:[A-Z]{1,3}|[$€£₼]))?\s*$"#)
        let summaries = #"^(sub\s*total|total|grand total|amount due|balance due|cash|change|visa|mastercard|card payment|payment|tendered)\b"#
        return rows.compactMap { row in
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = price.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let amount = amount(String(text[range])) else { return nil }
            let name = String(text[..<range.lowerBound]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "$€£₼")))
            guard !name.isEmpty else { return nil }
            let folded = CategoryLibrary.fold(name)
            let excluded = folded.range(of: summaries, options: .regularExpression) != nil
            let discount = text[range].contains("-") || text[range].contains("−") || folded.contains("discount") || folded.contains("coupon")
            let tax = folded.range(of: #"\b(tax|vat|gst)\b"#, options: .regularExpression) != nil
            return ReceiptItem(name: name, kind: discount ? .discount : tax ? .tax : .item, amount: amount,
                alreadyIncluded: excluded, uncertainty: excluded ? "Printed summary or payment; excluded from the split. Verify this." : "Verify the printed line total and choose a category.",
                sourceText: text, ocrConfidence: row.confidence)
        }
    }
}
