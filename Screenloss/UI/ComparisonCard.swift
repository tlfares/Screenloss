import SwiftUI
import UIKit

/// The biggest selected photo, encoded for real with the chosen settings,
/// against its original. Drag the handle to compare; switch to 1:1 to see
/// actual pixels, where differences would show first.
struct ComparisonCard: View {
    let item: MediaItem
    let recipe: CompressionRecipe

    @Environment(\.displayScale) private var displayScale
    @State private var source: Data?
    @State private var original: UIImage?
    @State private var preview: Preview?
    @State private var isEncoding = false
    @State private var split: CGFloat = 0.5
    @State private var actualPixels = false

    private struct Preview {
        let image: UIImage?
        let size: Int64?
        let note: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preview").font(.headline)
                    Text(caption)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button {
                    withAnimation(Motion.smooth) { actualPixels.toggle() }
                } label: {
                    Text(actualPixels ? "Fit" : "1:1")
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: 32)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(actualPixels ? "Fit to card" : "Show actual pixels")
            }

            comparison
                .frame(height: 380)
                .clipShape(.rect(cornerRadius: 18))
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .task(id: item.id) {
            source = nil
            original = nil
            preview = nil
            guard let data = await Self.load(item.id) else {
                preview = Preview(image: nil, size: nil, note: "The original couldn't be loaded.")
                return
            }
            source = data
            original = UIImage(data: data)
        }
        .task(id: PreviewKey(id: item.id, recipe: recipe, loaded: source != nil)) {
            guard let source else { return }
            // Settings are often flicked through: wait for them to settle.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isEncoding = true
            let result = await Self.encode(source, item: item, recipe: recipe)
            guard !Task.isCancelled else { return }
            isEncoding = false
            withAnimation(Motion.smooth) { preview = result }
        }
    }

    private var caption: String {
        let before = ByteFormat.string(Int64(source?.count ?? Int(item.size)))
        if let note = preview?.note { return note }
        guard let size = preview?.size else { return "\(before) → …" }
        let percent = source.map { Int((1 - Double(size) / Double($0.count)) * 100) } ?? 0
        return "\(before) → \(ByteFormat.string(size)) · \(percent)% smaller"
    }

    @ViewBuilder
    private var comparison: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color.black
                if let original {
                    picture(original, in: size)
                        .overlay(alignment: .topLeading) { tag("Original").padding(10) }
                }
                if let image = preview?.image {
                    picture(image, in: size)
                        .overlay(alignment: .topTrailing) { tag(recipe.photoFormat.title).padding(10) }
                        .mask(alignment: .leading) {
                            Rectangle().padding(.leading, size.width * split)
                        }
                    handle(height: size.height)
                        .position(x: size.width * split, y: size.height / 2)
                }
                if original == nil || isEncoding && preview == nil {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        split = min(0.98, max(0.02, value.location.x / max(size.width, 1)))
                    }
            )
        }
    }

    private func picture(_ image: UIImage, in size: CGSize) -> some View {
        Group {
            if actualPixels {
                // One image pixel per screen pixel, centered.
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: image.size.width * image.scale / displayScale,
                           height: image.size.height * image.scale / displayScale)
                    .frame(width: size.width, height: size.height)
            } else {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            }
        }
        .clipped()
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
    }

    private func handle(height: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.9)).frame(width: 2, height: height)
            Image(systemName: "arrow.left.and.right")
                .font(.caption.weight(.bold))
                .frame(width: 34, height: 34)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityHidden(true)
    }

    // MARK: Work

    private struct PreviewKey: Hashable {
        let id: String
        let recipe: CompressionRecipe
        let loaded: Bool
    }

    @concurrent
    private static func load(_ id: String) async -> Data? {
        guard let asset = LibraryWriter.asset(for: id) else { return nil }
        return try? await LibraryWriter.imageData(for: asset)
    }

    @concurrent
    private static func encode(_ data: Data, item: MediaItem, recipe: CompressionRecipe) async -> Preview {
        let url = URL.temporaryDirectory.appending(path: "preview-\(UUID().uuidString).\(recipe.photoFormat == .heif ? "heic" : "jpg")")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let size = try ImageTranscoder.transcode(.init(
                data: data, recipe: recipe, isScreenshot: item.isScreenshot,
                creationDate: item.creationDate, expectsLivePhotoIdentifier: item.isLivePhoto
            ), to: url)
            let image = (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
            let kept = Double(size) > Double(data.count) * (1 - recipe.minimumSaving)
            if item.isLivePhoto {
                // The video decides as much as the photo here.
                let note: String? = switch recipe.livePhotoMode {
                case .still: kept ? "Photo kept as is, its motion is removed" : nil
                case .keepLive: kept ? "Photo kept as is, only its motion is compressed" : nil
                }
                return Preview(image: image, size: kept ? Int64(data.count) : size, note: note)
            }
            return Preview(image: image, size: size, note: kept ? "Not enough smaller: this one would be kept as is" : nil)
        } catch let error as TranscodeError where error == .alreadyEfficient {
            if item.isLivePhoto {
                return Preview(image: UIImage(data: data), size: nil, note: recipe.livePhotoMode == .still
                    ? "Photo kept as is, its motion is removed"
                    : "Photo and motion kept as they are at this level")
            }
            return Preview(image: UIImage(data: data), size: nil, note: "Already HEIF: kept as is at this level")
        } catch {
            return Preview(image: nil, size: nil, note: error.localizedDescription)
        }
    }
}
