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
        case .screenshots: "Screenshots"
        case .screenRecordings: "Screen Recordings"
        case .photos: "Photos"
        case .livePhotos: "Live Photos"
        case .videos: "Videos"
        case .legacyImages: "JPEG & PNG"
        case .largeFiles: "Large Files"
        case .everything: "All Items"
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
        case .screenshots: "Saved as PNG, often several MB each"
        case .screenRecordings: "Long recordings add up fast"
        case .photos: "Camera photos and saved images"
        case .livePhotos: "Keep them Live, or make them still"
        case .videos: "Everything you've filmed or saved"
        case .legacyImages: "Images not yet in HEIF"
        case .largeFiles: "Items over \(ByteFormat.string(MediaCategory.largeFileThreshold))"
        case .everything: "Pick exactly what to compress"
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
        case .largest: "Largest First"
        case .newest: "Newest First"
        case .oldest: "Oldest First"
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
