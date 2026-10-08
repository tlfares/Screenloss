import Foundation
import Observation

/// How hard to squeeze. "Convert" keeps the quality the file already has
/// and only moves it to HEIF/HEVC; the others trade detail for space.
nonisolated enum QualityLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case convert, high, balanced, compact

    var id: String { rawValue }

    /// How hard each level squeezes, gentlest first.
    var strength: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var title: String {
        switch self {
        case .convert: String(localized: "Convert")
        case .high: String(localized: "High")
        case .balanced: String(localized: "Balanced")
        case .compact: String(localized: "Compact")
        }
    }

    var symbol: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .high: "sparkles"
        case .balanced: "circle.lefthalf.filled"
        case .compact: "arrow.down.right.and.arrow.up.left"
        }
    }

    var photoDescription: String {
        switch self {
        case .convert: String(localized: "Same quality in HEIF. Best for screenshots you zoom into.")
        case .high: String(localized: "Indistinguishable from the original on iPhone.")
        case .balanced: String(localized: "Smaller files, fine detail softens on close zoom.")
        case .compact: String(localized: "Smallest files, for things you only glance at.")
        }
    }

    var videoDescription: String {
        switch self {
        case .convert: String(localized: "Same quality in HEVC, roughly half the size of H.264.")
        case .high: String(localized: "Indistinguishable from the original on iPhone.")
        case .balanced: String(localized: "Noticeably smaller, still sharp on a phone.")
        case .compact: String(localized: "Smallest files, softer on a big screen.")
        }
    }

    /// `kCGImageDestinationLossyCompressionQuality`.
    var imageQuality: Double {
        switch self {
        case .convert: 0.93
        case .high: 0.85
        case .balanced: 0.72
        case .compact: 0.55
        }
    }

    /// Bits per pixel per frame for HEVC, at 30 fps. Apple's camera records
    /// 4K HEVC at roughly 0.1.
    var videoBitsPerPixel: Double {
        switch self {
        case .convert: 0.10
        case .high: 0.065
        case .balanced: 0.042
        case .compact: 0.026
        }
    }

    /// The share of the source bit rate kept at most. HEVC needs about half
    /// of H.264's for the same picture.
    var videoBitrateRatio: Double {
        switch self {
        case .convert: 0.62
        case .high: 0.45
        case .balanced: 0.3
        case .compact: 0.2
        }
    }
}

nonisolated enum PhotoFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case heif, jpeg
    /// Lossless: the quality level doesn't apply.
    case jxl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heif: "HEIF"
        case .jpeg: "JPEG"
        case .jxl: "JPEG XL"
        }
    }

    var fileExtension: String {
        switch self {
        case .heif: "HEIC"
        case .jpeg: "JPG"
        case .jxl: "JXL"
        }
    }

    var isLossless: Bool { self == .jxl }

    var note: String {
        switch self {
        case .heif: String(localized: "HEIF always loses a little, even on Convert. That's Apple's encoder: it has no lossless mode. The difference is invisible on a phone.")
        case .jpeg: String(localized: "JPEG loses a little too, and makes bigger files than HEIF. It opens everywhere.")
        case .jxl: String(localized: "Lossless: every pixel is kept. Files are bigger than HEIF. iPhone, iPad and Mac open them. Windows, Android and many websites may not. Photos doesn't list them under Screenshots. HEIF photos and Live Photos stay as they are.")
        }
    }
}

/// The longest side a photo is allowed to keep.
nonisolated enum PhotoSizeLimit: Int, CaseIterable, Identifiable, Codable, Sendable {
    case original = 0
    case px4032 = 4032
    case px3024 = 3024
    case px2048 = 2048

    var id: Int { rawValue }
    var title: String { self == .original ? String(localized: "Original") : "\(rawValue) px" }
    var maxPixels: Int? { self == .original ? nil : rawValue }
}

/// The shortest side a video is allowed to keep.
nonisolated enum VideoSizeLimit: Int, CaseIterable, Identifiable, Codable, Sendable {
    case original = 0
    case uhd = 2160
    case fullHD = 1080
    case hd = 720

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .original: String(localized: "Original")
        case .uhd: "4K"
        case .fullHD: "1080p"
        case .hd: "720p"
        }
    }

    var maxShortSide: Int? { self == .original ? nil : rawValue }
}

/// What happens to a Live Photo's motion.
nonisolated enum LivePhotoMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Still and video are both compressed, and stay paired.
    case keepLive
    /// The video is dropped: a classic photo, about half the size before
    /// any compression.
    case still

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepLive: String(localized: "Keep Live")
        case .still: String(localized: "Make Still")
        }
    }

    var symbol: String {
        switch self {
        case .keepLive: "livephoto"
        case .still: "photo"
        }
    }

    var description: String {
        switch self {
        case .keepLive: String(localized: "Photo and motion are both compressed. They still play when you press and hold.")
        case .still: String(localized: "Only the photo is kept, as a classic photo. Removing the motion alone saves about half.")
        }
    }
}

/// A snapshot handed to the encoders, so a run isn't affected by settings
/// changed while it's going.
nonisolated struct CompressionRecipe: Sendable, Hashable {
    var photoQuality: QualityLevel
    var photoFormat: PhotoFormat
    var photoLimit: PhotoSizeLimit
    var videoQuality: QualityLevel
    var videoLimit: VideoSizeLimit
    var livePhotoMode: LivePhotoMode
    /// A copy that isn't at least this much smaller is thrown away.
    var minimumSaving: Double
}

@MainActor
@Observable
final class CompressionSettings {
    static let shared = CompressionSettings()

    var photoQuality: QualityLevel { didSet { store(photoQuality.rawValue, "photoQuality") } }
    var photoFormat: PhotoFormat { didSet { store(photoFormat.rawValue, "photoFormat") } }
    var photoLimit: PhotoSizeLimit { didSet { store(photoLimit.rawValue, "photoLimit") } }
    var videoQuality: QualityLevel { didSet { store(videoQuality.rawValue, "videoQuality") } }
    var videoLimit: VideoSizeLimit { didSet { store(videoLimit.rawValue, "videoLimit") } }
    var livePhotoMode: LivePhotoMode { didSet { store(livePhotoMode.rawValue, "livePhotoMode") } }
    var minimumSaving: Double { didSet { store(minimumSaving, "minimumSaving") } }
    var removeOriginals: Bool { didSet { store(removeOriginals, "removeOriginals") } }
    /// Copies this app made start unselected when a category is opened.
    var skipsCompressed: Bool { didSet { store(skipsCompressed, "skipsCompressed") } }

    private init() {
        let defaults = UserDefaults.standard
        photoQuality = defaults.string(forKey: "photoQuality").flatMap(QualityLevel.init) ?? .high
        photoFormat = defaults.string(forKey: "photoFormat").flatMap(PhotoFormat.init) ?? .heif
        photoLimit = PhotoSizeLimit(rawValue: defaults.integer(forKey: "photoLimit")) ?? .original
        videoQuality = defaults.string(forKey: "videoQuality").flatMap(QualityLevel.init) ?? .high
        videoLimit = VideoSizeLimit(rawValue: defaults.integer(forKey: "videoLimit")) ?? .original
        livePhotoMode = defaults.string(forKey: "livePhotoMode").flatMap(LivePhotoMode.init) ?? .keepLive
        minimumSaving = defaults.object(forKey: "minimumSaving") as? Double ?? 0.1
        removeOriginals = defaults.object(forKey: "removeOriginals") as? Bool ?? true
        skipsCompressed = defaults.object(forKey: "skipsCompressed") as? Bool ?? true
    }

    var recipe: CompressionRecipe {
        CompressionRecipe(
            photoQuality: photoQuality,
            photoFormat: photoFormat,
            photoLimit: photoLimit,
            videoQuality: videoQuality,
            videoLimit: videoLimit,
            livePhotoMode: livePhotoMode,
            minimumSaving: minimumSaving
        )
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
