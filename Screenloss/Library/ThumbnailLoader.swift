import Photos
import SwiftUI
import UIKit

/// Thumbnails for the grids, from a caching manager shared by every cell.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let manager = PHCachingImageManager()
    private let assets = NSCache<NSString, PHAsset>()

    private init() {
        assets.countLimit = 2000
    }

    func asset(for id: String) -> PHAsset? {
        if let cached = assets.object(forKey: id as NSString) { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        assets.setObject(asset, forKey: id as NSString)
        return asset
    }

    /// A quick, blurry image first, then the sharp one.
    func images(for id: String, pointSize: CGSize, scale: CGFloat, contentMode: PHImageContentMode = .aspectFill) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            guard let asset = asset(for: id) else {
                continuation.finish()
                return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let target = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
            let request = manager.requestImage(for: asset, targetSize: target, contentMode: contentMode, options: options) { image, info in
                if let image { continuation.yield(image) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { continuation.finish() }
            }
            let manager = manager
            continuation.onTermination = { _ in
                manager.cancelImageRequest(request)
            }
        }
    }
}

/// A square of the library, filled as soon as its image arrives.
struct AssetThumbnail: View {
    let id: String
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.secondarySystemFill)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
            .task(id: id) {
                image = nil
                let size = proxy.size
                guard size.width > 0, size.height > 0 else { return }
                let mode: PHImageContentMode = contentMode == .fill ? .aspectFill : .aspectFit
                for await next in ThumbnailLoader.shared.images(for: id, pointSize: size, scale: displayScale, contentMode: mode) {
                    // Decoded off the main thread, so scrolling doesn't pay
                    // for it when the image first shows.
                    image = await next.byPreparingForDisplay() ?? next
                }
            }
        }
    }
}
