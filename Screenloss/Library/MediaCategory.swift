import Foundation

/// The groups the library is browsed by. They overlap on purpose: a
/// 300 MB screen recording is both a screen recording and a large file.
enum MediaCategory: String, CaseIterable, Identifiable, Hashable {
    case screenshots
    case screenRecordings
    case photos
    case livePhotos
    case videos
    case legacyImages
    case largeFiles
    case everything

    var id: String { rawValue }

    /// The tiles on the home screen; `everything` is the manual selection.
    static let tiles: [MediaCategory] = [.screenshots, .screenRecordings, .photos, .livePhotos, .videos, .legacyImages, .largeFiles, .everything]

    var title: String {
        switch self {
        case .screenshots: String(localized: "Screenshots")
        case .screenRecordings: String(localized: "Screen Recordings")
        case .photos: String(localized: "Photos")
        case .livePhotos: String(localized: "Live Photos")
        case .videos: String(localized: "Videos")
        case .legacyImages: String(localized: "JPEG & PNG")
        case .largeFiles: String(localized: "Large Files")
        case .everything: String(localized: "All Items")
        }
    }

    var symbol: String {
        switch self {
        case .screenshots: "camera.viewfinder"
        case .screenRecordings: "record.circle"
        case .photos: "photo"
        case .livePhotos: "livephoto"
        case .videos: "video"
        case .legacyImages: "doc.richtext"
        case .largeFiles: "externaldrive"
        case .everything: "square.grid.3x3"
        }
    }

    var subtitle: String {
        switch self {
        case .screenshots: String(localized: "Saved as PNG, often several MB each")
        case .screenRecordings: String(localized: "Long recordings add up fast")
        case .photos: String(localized: "Camera photos and saved images")
        case .livePhotos: String(localized: "Keep them Live, or make them still")
        case .videos: String(localized: "Everything you've filmed or saved")
        case .legacyImages: String(localized: "Images not yet in HEIF")
        case .largeFiles: String(localized: "Items over \(ByteFormat.string(MediaCategory.largeFileThreshold))")
        case .everything: String(localized: "Pick exactly what to compress")
        }
    }

    static let largeFileThreshold: Int64 = 25_000_000

    func contains(_ item: MediaItem) -> Bool {
        switch self {
        case .screenshots: item.isScreenshot
        case .screenRecordings: item.isScreenRecording
        case .photos: item.kind == .photo && !item.isScreenshot
        case .livePhotos: item.isLivePhoto
        case .videos: item.kind == .video && !item.isScreenRecording
        case .legacyImages: item.kind == .photo && !item.isScreenshot && item.format.isLegacyImage
        case .largeFiles: item.size >= MediaCategory.largeFileThreshold
        case .everything: true
        }
    }

    /// Big first: that's where the space is.
    var defaultSort: BrowserSort {
        switch self {
        case .everything: .newest
        default: .largest
        }
    }
}

enum BrowserSort: String, CaseIterable, Identifiable {
    case largest, newest, oldest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .largest: String(localized: "Largest First")
        case .newest: String(localized: "Newest First")
        case .oldest: String(localized: "Oldest First")
        }
    }

    var symbol: String {
        switch self {
        case .largest: "arrow.down.circle"
        case .newest: "calendar"
        case .oldest: "clock.arrow.circlepath"
        }
    }

    func sorted(_ items: [MediaItem]) -> [MediaItem] {
        switch self {
        case .largest: items.sorted { $0.size > $1.size }
        case .newest: items.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .oldest: items.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        }
    }
}
