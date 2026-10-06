import AVFoundation
import Foundation
import Photos

/// Everything that reads from or writes to the photo library while
/// compressing.
nonisolated enum LibraryWriter {
    /// A finished copy, ready to take its original's place.
    struct Replacement: Sendable {
        let originalID: String
        let kind: MediaKind
        let fileURL: URL
        let pairedVideoURL: URL?
        let filename: String
    }

    // MARK: Reading

    static func asset(for id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// The image as Photos shows it: the original, or its render if edited.
    static func imageData(for asset: PHAsset) async throws -> Data {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data {
                    continuation.resume(returning: data)
                } else if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: TranscodeError.cancelled)
                } else {
                    continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? TranscodeError.unreadable)
                }
            }
        }
    }

    static func videoAsset(for asset: PHAsset) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SendableBox<AVAsset>, Error>) in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: SendableBox(avAsset))
                } else if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: TranscodeError.cancelled)
                } else {
                    continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? TranscodeError.unreadable)
                }
            }
        }
        return box.value
    }

    /// A Live Photo's video as Photos plays it: its render when the photo
    /// was adjusted (by an edit, or by the camera itself, like a
    /// Photographic Style), so it matches the photo it's saved with.
    static func writePairedVideo(of asset: PHAsset, to url: URL) async throws {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePairedVideo })
                ?? resources.first(where: { $0.type == .pairedVideo })
        else { throw TranscodeError.unreadable }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
    }

    // MARK: Writing

    /// Adds the copies to the library in one change, each with its
    /// original's date, location, favorite and hidden state, and in the
    /// same spot of the same albums. Returns the new identifiers by original.
    static func save(_ replacements: [Replacement]) async throws -> [String: String] {
        let created = SendableBox([String: String]())
        try await PHPhotoLibrary.shared().performChanges {
            let ids = replacements.map(\.originalID)
            let originals = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var byID: [String: PHAsset] = [:]
            originals.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }

            var placeholders: [String: PHObjectPlaceholder] = [:]
            for replacement in replacements {
                guard let original = byID[replacement.originalID] else { continue }
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = replacement.filename
                options.shouldMoveFile = true
                request.addResource(with: replacement.kind == .video ? .video : .photo, fileURL: replacement.fileURL, options: options)
                if let paired = replacement.pairedVideoURL {
                    let videoOptions = PHAssetResourceCreationOptions()
                    videoOptions.shouldMoveFile = true
                    request.addResource(with: .pairedVideo, fileURL: paired, options: videoOptions)
                }
                request.creationDate = original.creationDate
                request.location = original.location
                request.isFavorite = original.isFavorite
                request.isHidden = original.isHidden
                if let placeholder = request.placeholderForCreatedAsset {
                    placeholders[replacement.originalID] = placeholder
                    created.value[replacement.originalID] = placeholder.localIdentifier
                }
            }
            placeInAlbums(originals: byID, placeholders: placeholders)
        }
        return created.value
    }

    /// Puts each copy right before its original in every album that holds
    /// it, so once the original goes the album looks the same.
    private static func placeInAlbums(originals: [String: PHAsset], placeholders: [String: PHObjectPlaceholder]) {
        var perAlbum: [String: (album: PHAssetCollection, entries: [(index: Int, placeholder: PHObjectPlaceholder)])] = [:]
        var contents: [String: PHFetchResult<PHAsset>] = [:]
        for (id, placeholder) in placeholders {
            guard let original = originals[id] else { continue }
            let albums = PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil)
            albums.enumerateObjects { album, _, _ in
                guard album.assetCollectionSubtype == .albumRegular, album.canPerform(.addContent) else { return }
                let key = album.localIdentifier
                let assets = contents[key] ?? PHAsset.fetchAssets(in: album, options: nil)
                contents[key] = assets
                let index = assets.index(of: original)
                guard index != NSNotFound else { return }
                perAlbum[key, default: (album, [])].entries.append((index, placeholder))
            }
        }
        for (key, value) in perAlbum {
            guard let assets = contents[key],
                  let change = PHAssetCollectionChangeRequest(for: value.album, assets: assets)
            else { continue }
            // Indexes in the final order: each earlier insertion shifts the
            // ones after it by one.
            let sorted = value.entries.sorted { $0.index < $1.index }
            let indexes = IndexSet(sorted.enumerated().map { $0.element.index + $0.offset })
            change.insertAssets(sorted.map(\.placeholder) as NSArray, at: indexes)
        }
    }

    /// Moves originals to Recently Deleted. iOS asks the user first.
    static func deleteAssets(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            guard assets.count > 0 else { return }
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    /// Which of these assets are still in the library.
    static func existing(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var found = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            found.insert(asset.localIdentifier)
        }
        return found
    }
}

/// Carries a value PhotoKit or AVFoundation hands over on one thread to the
/// task that uses it next. Only one side touches it at a time.
nonisolated final class SendableBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
