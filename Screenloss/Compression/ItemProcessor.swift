import AVFoundation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Turns one library item into a smaller file on disk, off the main actor.
/// Nothing in the library changes here; saving is the job's call.
nonisolated enum ItemProcessor {
    enum Outcome: Sendable {
        case ready(LibraryWriter.Replacement, outputSize: Int64)
        case skipped(String)
        case failed(String)
        case cancelled
    }

    @concurrent
    static func process(
        _ item: MediaItem,
        recipe: CompressionRecipe,
        workDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Outcome {
        var created: [URL] = []
        do {
            if let blocker = item.blocker { return .skipped(blocker.explanation) }
            guard let asset = LibraryWriter.asset(for: item.id) else { return .failed(String(localized: "It's no longer in the library.")) }
            try Task.checkCancellation()
            let base = baseName(of: item)

            switch item.kind {
            case .photo:
                let data = try await LibraryWriter.imageData(for: asset)
                try Task.checkCancellation()
                let keepsLive = item.isLivePhoto && recipe.livePhotoMode == .keepLive
                if keepsLive, ImageTranscoder.livePhotoIdentifier(of: data) == nil {
                    throw TranscodeError.livePhotoMismatch
                }
                let ext = recipe.photoFormat.fileExtension
                let url = workDirectory.appending(path: "\(UUID().uuidString).\(ext)")
                created.append(url)
                var still: (url: URL, ext: String, size: Int64)
                do {
                    let size = try ImageTranscoder.transcode(.init(
                        data: data,
                        recipe: recipe,
                        isScreenshot: item.isScreenshot,
                        creationDate: asset.creationDate,
                        expectsLivePhotoIdentifier: keepsLive
                    ), to: url)
                    still = (url, ext, size)
                } catch TranscodeError.alreadyEfficient where item.isLivePhoto {
                    still = try reuse(data, in: workDirectory, created: &created)
                }
                // A Live Photo whose photo barely shrinks keeps its photo
                // byte for byte: only its video is compressed, or dropped.
                if item.isLivePhoto, Double(still.size) > Double(data.count) * (1 - recipe.minimumSaving), still.url == url {
                    try? FileManager.default.removeItem(at: url)
                    still = try reuse(data, in: workDirectory, created: &created)
                }

                var pairedURL: URL?
                var pairedSize: Int64 = 0
                if keepsLive {
                    let paired = try await livePhotoVideo(
                        of: asset, pairedWith: ImageTranscoder.livePhotoIdentifier(of: data),
                        recipe: recipe, workDirectory: workDirectory, progress: progress
                    )
                    created.append(paired.url)
                    pairedURL = paired.url
                    pairedSize = paired.size
                }

                // A Live Photo is judged as a whole: dropping or shrinking its
                // video counts as much as the photo.
                let before = item.isLivePhoto ? item.size : Int64(data.count)
                if Double(still.size + pairedSize) > Double(before) * (1 - recipe.minimumSaving) {
                    throw TranscodeError.noGain
                }
                progress(1)
                return .ready(.init(
                    originalID: item.id, kind: .photo, fileURL: still.url,
                    pairedVideoURL: pairedURL, filename: "\(base).\(still.ext)"
                ), outputSize: still.size + pairedSize)

            case .video:
                let source = try await LibraryWriter.videoAsset(for: asset)
                try Task.checkCancellation()
                let url = workDirectory.appending(path: "\(UUID().uuidString).MOV")
                created.append(url)
                let transcoder = VideoTranscoder(asset: source, outputURL: url, request: .init(
                    recipe: recipe, originalSize: item.size, isScreenRecording: item.isScreenRecording
                ))
                let size = try await withTaskCancellationHandler {
                    try await transcoder.transcode(progress: progress)
                } onCancel: {
                    transcoder.cancel()
                }
                if Double(size) > Double(item.size) * (1 - recipe.minimumSaving) {
                    throw TranscodeError.noGain
                }
                return .ready(.init(
                    originalID: item.id, kind: .video, fileURL: url,
                    pairedVideoURL: nil, filename: "\(base).MOV"
                ), outputSize: size)
            }
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            if error is CancellationError || (error as? TranscodeError) == .cancelled { return .cancelled }
            if let error = error as? TranscodeError, error.isSkip { return .skipped(error.localizedDescription) }
            return .failed(error.localizedDescription)
        }
    }

    /// A Live Photo's video, re-encoded at the photo's level when that
    /// keeps it paired, otherwise copied as it is. The copy is only used if
    /// it carries the same content identifier as the photo.
    private static func livePhotoVideo(
        of asset: PHAsset,
        pairedWith photoIdentifier: String?,
        recipe: CompressionRecipe,
        workDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (url: URL, size: Int64) {
        let original = workDirectory.appending(path: "\(UUID().uuidString).MOV")
        try await LibraryWriter.writePairedVideo(of: asset, to: original)
        // Saved together, a photo and video that don't share an identifier
        // would come out as a plain photo: the motion would be lost.
        guard let photoIdentifier, await contentIdentifier(of: original) == photoIdentifier else {
            try? FileManager.default.removeItem(at: original)
            throw TranscodeError.livePhotoMismatch
        }
        let originalSize = fileSize(original)
        // Lossless means the motion is left alone too.
        guard recipe.photoQuality != .convert, !recipe.photoFormat.isLossless else { return (original, originalSize) }

        var videoRecipe = recipe
        videoRecipe.videoQuality = recipe.photoQuality
        videoRecipe.videoLimit = .original
        let compressed = workDirectory.appending(path: "\(UUID().uuidString).MOV")
        let transcoder = VideoTranscoder(asset: AVURLAsset(url: original), outputURL: compressed, request: .init(
            recipe: videoRecipe, originalSize: originalSize, isScreenRecording: false, keepsTimedMetadata: true
        ))
        do {
            let size = try await withTaskCancellationHandler {
                try await transcoder.transcode { progress($0 * 0.9) }
            } onCancel: {
                transcoder.cancel()
            }
            let originalID = await contentIdentifier(of: original)
            guard size < originalSize, originalID != nil, await contentIdentifier(of: compressed) == originalID else {
                throw TranscodeError.verificationFailed
            }
            try? FileManager.default.removeItem(at: original)
            return (compressed, size)
        } catch TranscodeError.cancelled {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: compressed)
            throw TranscodeError.cancelled
        } catch {
            // Already as small as it gets, or not provably paired: the
            // original video is the safe choice.
            try? FileManager.default.removeItem(at: compressed)
            return (original, originalSize)
        }
    }

    /// The original image written back unchanged, under its own extension.
    private static func reuse(_ data: Data, in directory: URL, created: inout [URL]) throws -> (url: URL, ext: String, size: Int64) {
        let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType).flatMap { UTType($0 as String) }
        let ext = (type?.preferredFilenameExtension ?? "heic").uppercased()
        let url = directory.appending(path: "\(UUID().uuidString).\(ext)")
        created.append(url)
        try data.write(to: url)
        return (url, ext, Int64(data.count))
    }

    private static func contentIdentifier(of url: URL) async -> String? {
        guard let items = try? await AVURLAsset(url: url).load(.metadata) else { return nil }
        let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataContentIdentifier)
        return try? await matches.first?.load(.stringValue)
    }

    private static func baseName(of item: MediaItem) -> String {
        let name = (item.filename as NSString).deletingPathExtension
        return name.isEmpty ? "IMG_\(item.id.prefix(8))" : name
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
