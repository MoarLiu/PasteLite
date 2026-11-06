import Foundation
import Vision
import ImageIO

private final class RecognitionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let request: VNRecognizeTextRequest
    init(_ request: VNRecognizeTextRequest) { self.request = request }
    func cancel() { lock.lock(); defer { lock.unlock() }; request.cancel() }
}

actor OCRService {
    static let shared = OCRService()

    func recognize(_ data: Data) async throws -> String {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw LibraryError.invalid("This image cannot be read.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LibraryError.invalid("This image cannot be read.")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
        let cancellation = RecognitionCancellation(request)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image).perform([request])
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard text.utf8.count <= LibraryValidation.snippetByteLimit else {
            throw LibraryError.invalid("Recognized text exceeds 1 MiB.")
        }
        return text
    }
}

extension ClipboardItem {
    var ocrKey: String { "\(origin.rawValue):\(id.uuidString):\(contentHash)" }
}
