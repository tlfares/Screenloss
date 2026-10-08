import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum TranscodeError: LocalizedError, Equatable {
    case unreadable
    case encoderUnavailable
    case encodingFailed
    case verificationFailed
    case alreadyEfficient
    case noGain
    case cancelled
    case livePhotoMismatch
    case notLossless
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "The original couldn't be read.")
        case .encoderUnavailable: String(localized: "This device can't encode that format.")
        case .encodingFailed: String(localized: "Encoding failed.")
        case .verificationFailed: String(localized: "The new file didn't match the original, so it was discarded.")
        case .alreadyEfficient: String(localized: "Already in an efficient format.")
        case .noGain: String(localized: "A smaller file wasn't possible at this quality.")
        case .cancelled: String(localized: "Cancelled.")
        case .livePhotoMismatch: String(localized: "Its photo and motion couldn't be matched, so it was left as is.")
        case .notLossless: "It can't be stored in JPEG XL without loss."
        case .writerFailed(let reason): reason
        }
    }

    /// Outcomes that leave the original untouched on purpose.
    var isSkip: Bool { self == .alreadyEfficient || self == .noGain || self == .notLossless }
}

/// Re-encodes a still image with ImageIO. The image is copied from its
/// source rather than decoded and redrawn, so orientation, color profile,
/// EXIF/GPS/TIFF/IPTC/XMP and the HDR gain map all come along.
nonisolated enum ImageTranscoder {
    struct Request: Sendable {
        var data: Data
        var recipe: CompressionRecipe
        var isScreenshot: Bool
        var creationDate: Date?
        /// Set for Live Photos: the identifier pairing the still with its video.
        var expectsLivePhotoIdentifier: Bool
    }

    /// Apple's maker note key holding a Live Photo's content identifier.
    private static let livePhotoIdentifierKey = "17"

    /// The identifier pairing a Live Photo's still with its video.
    static func livePhotoIdentifier(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return (properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?[livePhotoIdentifierKey] as? String
    }

    static func transcode(_ request: Request, to url: URL) throws -> Int64 {
        if request.recipe.photoFormat == .jxl {
            // Live Photos stay HEIF: their pairing lives in Apple's maker
            // note, which a JPEG XL copy isn't known to carry.
            if request.expectsLivePhotoIdentifier { throw TranscodeError.alreadyEfficient }
            return try JXLTranscoder.transcode(request, to: url)
        }
        guard let source = CGImageSourceCreateWithData(request.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source)
        else { throw TranscodeError.unreadable }

        let recipe = request.recipe
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { throw TranscodeError.unreadable }

        let limit = recipe.photoLimit.maxPixels.flatMap { max(width, height) > $0 ? $0 : nil }
        let targetType: UTType = recipe.photoFormat == .heif ? .heic : .jpeg
        let sourceIsHEIF = UTType(sourceType as String).map { $0.conforms(to: .heif) || $0.conforms(to: .heic) } ?? false

        // Same quality, same format: re-encoding would only grow the file.
        if recipe.photoQuality == .convert, limit == nil, targetType == .heic, sourceIsHEIF {
            throw TranscodeError.alreadyEfficient
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, targetType.identifier as CFString, 1, nil) else {
            throw TranscodeError.encoderUnavailable
        }

        var options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: recipe.photoQuality.imageQuality,
            kCGImageDestinationPreserveGainMap: true,
        ]
        if let limit { options[kCGImageDestinationImageMaxPixelSize] = limit }
        if targetType == .jpeg { options[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1) }

        // Dictionaries passed here replace the source's, so they're copied
        // whole and amended rather than written from scratch.
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var exifChanged = false
        if request.isScreenshot, exif[kCGImagePropertyExifUserComment] as? String != "Screenshot" {
            // How Photos recognizes a screenshot: keeps it in that album.
            exif[kCGImagePropertyExifUserComment] = "Screenshot"
            exifChanged = true
        }
        if exif[kCGImagePropertyExifDateTimeOriginal] == nil, let date = request.creationDate {
            // PNG screenshots carry no capture date; the copy keeps it
            // inside the file too, for wherever it's exported to.
            exif[kCGImagePropertyExifDateTimeOriginal] = ExifDate.string(from: date)
            exif[kCGImagePropertyExifOffsetTimeOriginal] = ExifDate.offset(for: date)
            exifChanged = true
        }
        if exifChanged { options[kCGImagePropertyExifDictionary] = exif }
        if let makerApple = properties[kCGImagePropertyMakerAppleDictionary] {
            options[kCGImagePropertyMakerAppleDictionary] = makerApple
        }

        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw TranscodeError.encodingFailed
        }

        try verify(url: url, source: properties, expectsLivePhotoIdentifier: request.expectsLivePhotoIdentifier, resized: limit != nil)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size > 0 else { throw TranscodeError.encodingFailed }
        return size
    }

    /// Reads the new file back before anything is saved: an original is
    /// only ever replaced by a copy that's known to be whole.
    private static func verify(url: URL, source: [CFString: Any], expectsLivePhotoIdentifier: Bool, resized: Bool) throws {
        guard let output = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(output) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0,
              CGImageSourceCreateThumbnailAtIndex(output, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
              ] as CFDictionary) != nil
        else { throw TranscodeError.verificationFailed }

        if !resized {
            let sourceWidth = source[kCGImagePropertyPixelWidth] as? Int
            let sourceHeight = source[kCGImagePropertyPixelHeight] as? Int
            guard sourceWidth == width, sourceHeight == height else { throw TranscodeError.verificationFailed }
            if (source[kCGImagePropertyOrientation] as? Int ?? 1) != (properties[kCGImagePropertyOrientation] as? Int ?? 1) {
                throw TranscodeError.verificationFailed
            }
        }
        if expectsLivePhotoIdentifier {
            let original = (source[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?[livePhotoIdentifierKey] as? String
            let copied = (properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?[livePhotoIdentifierKey] as? String
            guard let original, original == copied else { throw TranscodeError.verificationFailed }
        }
    }
}

nonisolated enum ExifDate {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func offset(for date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }
}
