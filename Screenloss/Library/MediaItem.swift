import Foundation
import Photos
import UniformTypeIdentifiers

nonisolated enum MediaKind: String, Codable, Sendable {
    case photo, video
}

/// Why an item is left alone. Each of these would lose something the
/// library can't get back from a re-encoded copy.
nonisolated enum Blocker: String, Codable, Sendable {
    case raw, animated, portrait, spatial, slowMotion, cinematic, burst, loopingLivePhoto, readOnly, unknownFormat

    var label: String {
        switch self {
        case .raw: String(localized: "RAW")
        case .animated: String(localized: "Animated")
        case .portrait: String(localized: "Portrait")
        case .spatial: String(localized: "Spatial")
        case .slowMotion: String(localized: "Slo-mo")
        case .cinematic: String(localized: "Cinematic")
        case .burst: String(localized: "Burst")
        case .loopingLivePhoto: String(localized: "Loop or Bounce")
        case .readOnly: String(localized: "Read-only")
        case .unknownFormat: String(localized: "Unsupported")
        }
    }

    var explanation: String {
        switch self {
        case .raw: String(localized: "RAW files keep sensor data that HEIF can't hold.")
        case .animated: String(localized: "Re-encoding would keep only the first frame.")
        case .portrait: String(localized: "Depth data and Portrait edits would be lost.")
        case .spatial: String(localized: "Spatial depth would be lost.")
        case .slowMotion: String(localized: "The slow-motion ramp couldn't be edited anymore.")
        case .cinematic: String(localized: "Cinematic focus data would be lost.")
        case .burst: String(localized: "It would be pulled out of its burst.")
        case .loopingLivePhoto: String(localized: "Its Loop or Bounce effect would be lost.")
        case .readOnly: String(localized: "This item can't be changed from apps.")
        case .unknownFormat: String(localized: "This file format isn't supported.")
        }
    }
}

/// One asset of the library, as much as the app needs to show, sort and
/// estimate it without touching PhotoKit again.
nonisolated struct MediaItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: MediaKind
    let subtypes: UInt
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: Double
    let creationDate: Date?
    /// Every resource of the asset: what deleting it gives back.
    let size: Int64
    /// The type of the file that would be re-encoded.
    let uti: String?
    let filename: String
    let isEdited: Bool
    let blocker: Blocker?

    var mediaSubtypes: PHAssetMediaSubtype { PHAssetMediaSubtype(rawValue: subtypes) }
    var isScreenshot: Bool { mediaSubtypes.contains(.photoScreenshot) }
    var isScreenRecording: Bool { mediaSubtypes.contains(.videoScreenRecording) }
    var isLivePhoto: Bool { mediaSubtypes.contains(.photoLive) }
    var isEligible: Bool { blocker == nil }
    var pixelCount: Int { pixelWidth * pixelHeight }

    var format: MediaFormat { MediaFormat(uti: uti, kind: kind) }
}

nonisolated enum MediaFormat: String, Sendable {
    case png, jpeg, heif, gif, tiff, webp, raw, mov, mp4, otherImage, otherVideo

    init(uti: String?, kind: MediaKind) {
        guard let uti, let type = UTType(uti) else {
            self = kind == .photo ? .otherImage : .otherVideo
            return
        }
        if type.conforms(to: .png) { self = .png }
        else if type.conforms(to: .jpeg) { self = .jpeg }
        else if type.conforms(to: .heic) || type.conforms(to: .heif) { self = .heif }
        else if type.conforms(to: .gif) { self = .gif }
        else if type.conforms(to: .tiff) { self = .tiff }
        else if type.conforms(to: .webP) { self = .webp }
        else if type.conforms(to: .rawImage) { self = .raw }
        else if type.conforms(to: .quickTimeMovie) { self = .mov }
        else if type.conforms(to: .mpeg4Movie) { self = .mp4 }
        else { self = kind == .photo ? .otherImage : .otherVideo }
    }

    var label: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heif: "HEIF"
        case .gif: "GIF"
        case .tiff: "TIFF"
        case .webp: "WebP"
        case .raw: "RAW"
        case .mov: "MOV"
        case .mp4: "MP4"
        case .otherImage: String(localized: "Image")
        case .otherVideo: String(localized: "Video")
        }
    }

    /// Lossless or older formats, where HEIF gives the most back.
    var isLegacyImage: Bool {
        switch self {
        case .png, .jpeg, .tiff, .webp, .otherImage: true
        default: false
        }
    }
}
