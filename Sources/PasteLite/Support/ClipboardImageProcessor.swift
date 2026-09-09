import AppKit
import ImageIO

struct ClipboardThumbnail: Sendable {
    var data: Data
    var pixelWidth: Int
    var pixelHeight: Int
}

enum ClipboardImageProcessor {
    static func imageData(in assets: [ClipboardAsset]) -> Data? {
        for type in [NSPasteboard.PasteboardType.png, .tiff, .legacyTIFF] {
            if let asset = assets.first(where: { $0.pasteboardType == type }) {
                return asset.data
            }
        }
        return nil
    }

    static func title(for assets: [ClipboardAsset]) -> String {
        guard let data = imageData(in: assets),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return "Image"
        }
        return "Image (\(width.intValue)×\(height.intValue))"
    }

    static func thumbnail(from data: Data, maxPixelSize: Int) -> ClipboardThumbnail? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(1, maxPixelSize), 1600)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ClipboardThumbnail(data: output as Data, pixelWidth: image.width, pixelHeight: image.height)
    }
}
