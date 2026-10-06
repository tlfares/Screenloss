import Foundation

/// Rough output sizes, from how each format typically behaves. Good enough
/// to rank and total; the preview encodes a real sample when it matters.
nonisolated enum SavingsEstimator {
    /// `madeAt`: the level, if this item is a copy the app already made.
    static func estimatedSize(of item: MediaItem, recipe: CompressionRecipe, madeAt: QualityLevel? = nil) -> Int64 {
        guard item.isEligible, item.size > 0 else { return item.size }
        if let madeAt {
            let level = item.kind == .photo ? recipe.photoQuality : recipe.videoQuality
            let resized = item.kind == .photo ? recipe.photoLimit != .original : recipe.videoLimit != .original
            let dropsMotion = item.isLivePhoto && recipe.livePhotoMode == .still
            if level.strength <= madeAt.strength, !resized, !dropsMotion { return item.size }
        }
        let estimate: Double = switch item.kind {
        case .photo: photoEstimate(item, recipe: recipe)
        case .video: videoEstimate(item, recipe: recipe)
        }
        // Anything that wouldn't clear the threshold is kept as it is.
        let kept = Double(item.size) * (1 - recipe.minimumSaving)
        return estimate >= kept ? item.size : Int64(estimate)
    }

    static func estimatedSaving(of item: MediaItem, recipe: CompressionRecipe, madeAt: QualityLevel? = nil) -> Int64 {
        max(0, item.size - estimatedSize(of: item, recipe: recipe, madeAt: madeAt))
    }

    private static func photoEstimate(_ item: MediaItem, recipe: CompressionRecipe) -> Double {
        // Share of the source size each level lands on, per source format.
        let ratios: [QualityLevel: Double] = switch item.format {
        case .png, .tiff: item.isScreenshot
            ? [.convert: 0.16, .high: 0.10, .balanced: 0.075, .compact: 0.055]
            : [.convert: 0.22, .high: 0.14, .balanced: 0.10, .compact: 0.07]
        case .jpeg, .webp, .otherImage: [.convert: 0.62, .high: 0.48, .balanced: 0.36, .compact: 0.25]
        case .heif: [.convert: 1.0, .high: 0.78, .balanced: 0.55, .compact: 0.38]
        default: [.convert: 1, .high: 1, .balanced: 1, .compact: 1]
        }
        var ratio = ratios[recipe.photoQuality] ?? 1
        if recipe.photoFormat == .jpeg { ratio *= 1.8 }
        if let limit = recipe.photoLimit.maxPixels {
            let longSide = Double(max(item.pixelWidth, item.pixelHeight))
            if longSide > Double(limit) { ratio *= pow(Double(limit) / longSide, 2) }
        }
        // A Live Photo is about 60% photo and 40% video. Its video is
        // already HEVC, so it shrinks less than the photo, or goes entirely.
        if item.isLivePhoto {
            let photo = 0.6 * min(1, ratio)
            switch recipe.livePhotoMode {
            case .still:
                return Double(item.size) * photo
            case .keepLive:
                let video: Double = switch recipe.photoQuality {
                case .convert: 1
                case .high: 0.75
                case .balanced: 0.55
                case .compact: 0.4
                }
                return Double(item.size) * (photo + 0.4 * video)
            }
        }
        return Double(item.size) * min(1, ratio)
    }

    private static func videoEstimate(_ item: MediaItem, recipe: CompressionRecipe) -> Double {
        guard item.duration > 0 else { return Double(item.size) }
        // The camera has filmed in HEVC since iPhone 7: converting alone
        // gives nothing back. The real codec is only read when encoding.
        if recipe.videoQuality == .convert, recipe.videoLimit == .original, item.format == .mov, !item.isScreenRecording {
            return Double(item.size)
        }
        let source = Double(item.size) * 8 / item.duration
        let plan = VideoPlan.dimensions(width: item.pixelWidth, height: item.pixelHeight, limit: recipe.videoLimit)
        // Screen recordings run at 60 fps, the camera mostly at 30.
        let fps: Double = item.isScreenRecording ? 60 : 30
        let target = VideoPlan.bitrate(
            sourceBitrate: source,
            width: plan.width,
            height: plan.height,
            fps: fps,
            quality: recipe.videoQuality,
            downscaled: plan.width < item.pixelWidth
        )
        // Audio and container overhead.
        return min(Double(item.size), (target + 160_000) * item.duration / 8)
    }
}

/// Size and bit rate decisions shared by the estimator and the encoder, so
/// both agree on what a level means.
nonisolated enum VideoPlan {
    static func dimensions(width: Int, height: Int, limit: VideoSizeLimit) -> (width: Int, height: Int) {
        guard let cap = limit.maxShortSide, min(width, height) > cap else {
            return (even(width), even(height))
        }
        let scale = Double(cap) / Double(min(width, height))
        return (even(Int((Double(width) * scale).rounded())), even(Int((Double(height) * scale).rounded())))
    }

    static func bitrate(sourceBitrate: Double, width: Int, height: Int, fps: Double, quality: QualityLevel, downscaled: Bool) -> Double {
        // Higher frame rates need fewer bits per frame: consecutive frames
        // look more alike.
        let effectiveFPS = 30 * pow(max(fps, 1) / 30, 0.6)
        let byPixels = Double(width * height) * effectiveFPS * quality.videoBitsPerPixel
        guard sourceBitrate > 0 else { return byPixels }
        // A downscaled video's source bit rate says little about what the
        // smaller picture needs.
        let bySource = sourceBitrate * quality.videoBitrateRatio * (downscaled ? 0.6 : 1)
        return max(400_000, min(byPixels, bySource))
    }

    private static func even(_ value: Int) -> Int { max(2, value - value % 2) }
}
