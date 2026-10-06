import Foundation
import Photos
import UniformTypeIdentifiers

/// Walks the library and describes every photo and video. Reading an
/// asset's resources is the slow part, so what it learns is kept on disk
/// and reused while the asset's modification date doesn't change.
nonisolated enum LibraryScanner {
    struct CacheEntry: Codable, Sendable {
        var modified: Date?
        var size: Int64
        var uti: String?
        var filename: String
        var isEdited: Bool
        var hasPairedVideo: Bool
    }

    struct Result: Sendable {
        var items: [MediaItem]
        var cache: [String: CacheEntry]
    }

    static func scan(cache: [String: CacheEntry], progress: @Sendable (_ done: Int, _ total: Int) -> Void) -> Result {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: options)
        let total = assets.count

        var items: [MediaItem] = []
        items.reserveCapacity(total)
        var freshCache: [String: CacheEntry] = [:]
        freshCache.reserveCapacity(total)

        for index in 0..<total {
            autoreleasepool {
                let asset = assets.object(at: index)
                guard asset.mediaType == .image || asset.mediaType == .video else { return }
                let id = asset.localIdentifier
                let entry: CacheEntry
                if let cached = cache[id], cached.modified == asset.modificationDate {
                    entry = cached
                } else {
                    entry = describe(asset)
                }
                freshCache[id] = entry
                items.append(item(for: asset, entry: entry))
            }
            if index % 250 == 0 { progress(index, total) }
        }
        progress(total, total)
        return Result(items: items, cache: freshCache)
    }

    /// Describes assets that just appeared, without walking the whole library.
    static func items(for identifiers: [String]) -> [MediaItem] {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var items: [MediaItem] = []
        assets.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            items.append(item(for: asset, entry: describe(asset)))
        }
        return items
    }

    private static func describe(_ asset: PHAsset) -> CacheEntry {
        let resources = PHAssetResource.assetResources(for: asset)
        var size: Int64 = 0
        var original: PHAssetResource?
        var rendered: PHAssetResource?
        var hasPairedVideo = false
        for resource in resources {
            size += fileSize(of: resource)
            switch resource.type {
            case .photo, .video: if original == nil { original = resource }
            case .fullSizePhoto, .fullSizeVideo: rendered = resource
            case .pairedVideo, .fullSizePairedVideo: hasPairedVideo = true
            default: break
            }
        }
        // An edited asset is re-encoded from what Photos shows, its render.
        let primary = rendered ?? original ?? resources.first
        return CacheEntry(
            modified: asset.modificationDate,
            size: size,
            uti: primary?.uniformTypeIdentifier,
            filename: original?.originalFilename ?? primary?.originalFilename ?? "",
            isEdited: rendered != nil,
            hasPairedVideo: hasPairedVideo
        )
    }

    /// PhotoKit has no public size property; this is the value Photos itself
    /// shows. Checked first so a future rename can't crash the scan.
    static func fileSize(of resource: PHAssetResource) -> Int64 {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return 0 }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    private static func item(for asset: PHAsset, entry: CacheEntry) -> MediaItem {
        let kind: MediaKind = asset.mediaType == .video ? .video : .photo
        return MediaItem(
            id: asset.localIdentifier,
            kind: kind,
            subtypes: effectiveSubtypes(of: asset, entry: entry).rawValue,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            creationDate: asset.creationDate,
            size: entry.size,
            uti: entry.uti,
            filename: entry.filename,
            isEdited: entry.isEdited,
            blocker: blocker(for: asset, kind: kind, entry: entry)
        )
    }

    /// A Live Photo whose motion was turned off in Photos, or that has no
    /// video at all, shows as a still photo: it's treated as one.
    private static func effectiveSubtypes(of asset: PHAsset, entry: CacheEntry) -> PHAssetMediaSubtype {
        var subtypes = asset.mediaSubtypes
        if subtypes.contains(.photoLive), asset.playbackStyle == .image || !entry.hasPairedVideo {
            subtypes.remove(.photoLive)
        }
        return subtypes
    }

    private static func blocker(for asset: PHAsset, kind: MediaKind, entry: CacheEntry) -> Blocker? {
        let subtypes = asset.mediaSubtypes
        if !asset.canPerform(.delete) { return .readOnly }
        if subtypes.contains(.spatialMedia) { return .spatial }
        switch kind {
        case .photo:
            if let uti = entry.uti, let type = UTType(uti), type.conforms(to: .rawImage) { return .raw }
            if entry.uti == nil { return .unknownFormat }
            if subtypes.contains(.photoAnimation) { return .animated }
            if subtypes.contains(.photoDepthEffect) { return .portrait }
            if asset.burstIdentifier != nil { return .burst }
            // Edited Live Photos are fine: Photos renders both the photo and
            // its video. Loop and Bounce turn them into a video effect.
            if subtypes.contains(.photoLive), asset.playbackStyle == .videoLooping { return .loopingLivePhoto }
        case .video:
            if subtypes.contains(.videoHighFrameRate) { return .slowMotion }
            if subtypes.contains(.videoCinematic) { return .cinematic }
        }
        return nil
    }
}

/// Where the scan's results live between launches.
nonisolated enum ScanCacheStore {
    private static var url: URL {
        URL.cachesDirectory.appending(path: "library-scan-v1.plist")
    }

    static func load() -> [String: LibraryScanner.CacheEntry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? PropertyListDecoder().decode([String: LibraryScanner.CacheEntry].self, from: data)) ?? [:]
    }

    static func save(_ cache: [String: LibraryScanner.CacheEntry]) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
