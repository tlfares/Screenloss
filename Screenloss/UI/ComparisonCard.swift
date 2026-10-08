import SwiftUI
import UIKit

/// The biggest selected photo, encoded for real with the chosen settings,
/// against its original. Drag across to compare; pinch to zoom and move
/// with two fingers, and the zoom stays while you drag the divider.
/// Double-tap, or 1:1, to see actual pixels, where differences show first.
struct ComparisonCard: View {
    let item: MediaItem
    let recipe: CompressionRecipe

    @Environment(\.displayScale) private var displayScale
    @State private var source: Data?
    @State private var original: UIImage?
    @State private var preview: Preview?
    @State private var isEncoding = false
    @State private var split: CGFloat = 0.5
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    /// The card's size, for the 1:1 button.
    @State private var viewport: CGSize = .zero

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
                    withAnimation(Motion.smooth) {
                        if isZoomed {
                            zoom = 1
                            pan = .zero
                        } else {
                            zoom(to: actualPixelZoom(in: viewport), around: nil, in: viewport)
                        }
                    }
                } label: {
                    Text(isZoomed ? "Fit" : "1:1")
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: 32)
                        .contentTransition(.identity)
                }
                .buttonStyle(.glass)
                .disabled(original == nil)
                .accessibilityLabel(isZoomed ? "Fit to card" : "Show actual pixels")
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
            zoom = 1
            pan = .zero
            guard let data = await Self.load(item.id) else {
                preview = Preview(image: nil, size: nil, note: String(localized: "The original couldn't be loaded."))
                return
            }
            source = data
            original = await Self.decode(data)
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
        return String(localized: "\(before) → \(ByteFormat.string(size)) · \(percent)% smaller")
    }

    private var isZoomed: Bool { zoom > 1.01 }

    @ViewBuilder
    private var comparison: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color.screenBackground
                if let original {
                    picture(original, in: size)
                        .overlay(alignment: .topLeading) { tag(String(localized: "Original")).padding(10) }
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
            .gesture(dividerGesture(in: size))
            .gesture(pinchGesture(in: size))
            .gesture(twoFingerPan(in: size))
            .gesture(doubleTap(in: size))
            .onAppear { viewport = size }
            .onChange(of: size) { _, new in viewport = new }
        }
    }

    // MARK: Zoom

    /// Where the photo sits at zoom 1: fitted in the card.
    private func fitted(in size: CGSize) -> CGSize {
        guard let original, original.size.width > 0, original.size.height > 0 else { return size }
        let scale = min(size.width / original.size.width, size.height / original.size.height)
        return CGSize(width: original.size.width * scale, height: original.size.height * scale)
    }

    /// The zoom at which one pixel of the photo is one pixel of the screen.
    private func actualPixelZoom(in size: CGSize) -> CGFloat {
        guard let original, size.width > 0 else { return 1 }
        let pixels = original.size.width * original.scale / displayScale
        return max(1, pixels / fitted(in: size).width)
    }

    /// Far enough to see single pixels clearly, four screen pixels each.
    private func maxZoom(in size: CGSize) -> CGFloat {
        max(4, actualPixelZoom(in: size) * 4)
    }

    /// Scales by `factor` keeping the point under `anchor` where it is.
    private func zoom(by factor: CGFloat, around anchor: CGPoint, in size: CGSize) {
        let target = min(maxZoom(in: size), max(1, zoom * factor))
        let applied = target / zoom
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        pan = CGSize(
            width: (anchor.x - center.x) * (1 - applied) + applied * pan.width,
            height: (anchor.y - center.y) * (1 - applied) + applied * pan.height
        )
        zoom = target
        pan = clamped(pan, in: size)
    }

    private func zoom(to target: CGFloat, around anchor: CGPoint?, in size: CGSize) {
        zoom(by: target / zoom, around: anchor ?? CGPoint(x: size.width / 2, y: size.height / 2), in: size)
    }

    /// Keeps the photo covering the card wherever it's larger than it.
    private func clamped(_ offset: CGSize, in size: CGSize) -> CGSize {
        let content = fitted(in: size)
        let limitX = max(0, (content.width * zoom - size.width) / 2)
        let limitY = max(0, (content.height * zoom - size.height) / 2)
        return CGSize(width: min(limitX, max(-limitX, offset.width)), height: min(limitY, max(-limitY, offset.height)))
    }

    private func picture(_ image: UIImage, in size: CGSize) -> some View {
        let content = fitted(in: size)
        return Image(uiImage: image)
            .resizable()
            // Past actual pixels, show them as squares rather than a blur.
            .interpolation(zoom >= actualPixelZoom(in: size) * 1.5 ? .none : .high)
            .frame(width: content.width, height: content.height)
            .scaleEffect(zoom)
            .offset(pan)
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    /// One finger, mostly sideways: moves the divider. Vertical drags are
    /// left to the sheet's scroll.
    private func dividerGesture(in size: CGSize) -> some UIGestureRecognizerRepresentable {
        GestureRecognizer<UIPanGestureRecognizer>(make: {
            let pan = UIPanGestureRecognizer()
            pan.maximumNumberOfTouches = 1
            return pan
        }, shouldBegin: { recognizer in
            let velocity = recognizer.velocity(in: recognizer.view)
            return abs(velocity.x) > abs(velocity.y)
        }) { recognizer, location in
            guard recognizer.state == .began || recognizer.state == .changed, recognizer.numberOfTouches == 1 else { return }
            split = min(0.98, max(0.02, location.x / max(size.width, 1)))
        }
    }

    private func pinchGesture(in size: CGSize) -> some UIGestureRecognizerRepresentable {
        GestureRecognizer(make: UIPinchGestureRecognizer.init) { recognizer, location in
            switch recognizer.state {
            case .began, .changed:
                zoom(by: recognizer.scale, around: location, in: size)
                recognizer.scale = 1
            case .ended, .cancelled:
                if zoom < 1.05 {
                    withAnimation(Motion.smooth) {
                        zoom = 1
                        pan = .zero
                    }
                }
            default: break
            }
        }
    }

    private func twoFingerPan(in size: CGSize) -> some UIGestureRecognizerRepresentable {
        GestureRecognizer<UIPanGestureRecognizer>(make: {
            let pan = UIPanGestureRecognizer()
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            return pan
        }) { recognizer, _ in
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            let delta = recognizer.translation(in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            pan = clamped(CGSize(width: pan.width + delta.x, height: pan.height + delta.y), in: size)
        }
    }

    /// Double-tap: actual pixels around that spot, or back to the whole photo.
    private func doubleTap(in size: CGSize) -> some UIGestureRecognizerRepresentable {
        GestureRecognizer<UITapGestureRecognizer>(make: {
            let tap = UITapGestureRecognizer()
            tap.numberOfTapsRequired = 2
            return tap
        }) { recognizer, location in
            guard recognizer.state == .ended else { return }
            withAnimation(Motion.smooth) {
                if isZoomed {
                    zoom = 1
                    pan = .zero
                } else {
                    zoom(to: max(2, actualPixelZoom(in: size)), around: location, in: size)
                }
            }
        }
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

    /// Decoded here rather than at first draw, which would happen on the
    /// main thread in the middle of an animation.
    @concurrent
    private static func decode(_ data: Data) async -> UIImage? {
        await UIImage(data: data)?.byPreparingForDisplay()
    }

    @concurrent
    private static func load(_ id: String) async -> Data? {
        guard let asset = LibraryWriter.asset(for: id) else { return nil }
        return try? await LibraryWriter.imageData(for: asset)
    }

    @concurrent
    private static func encode(_ data: Data, item: MediaItem, recipe: CompressionRecipe) async -> Preview {
        let url = URL.temporaryDirectory.appending(path: "preview-\(UUID().uuidString).\(recipe.photoFormat.fileExtension.lowercased())")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let size = try ImageTranscoder.transcode(.init(
                data: data, recipe: recipe, isScreenshot: item.isScreenshot,
                creationDate: item.creationDate, expectsLivePhotoIdentifier: item.isLivePhoto
            ), to: url)
            let image = await (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))?.byPreparingForDisplay()
            let kept = Double(size) > Double(data.count) * (1 - recipe.minimumSaving)
            if item.isLivePhoto {
                // The video decides as much as the photo here.
                let note: String? = switch recipe.livePhotoMode {
                case .still: kept ? String(localized: "Photo kept as is, its motion is removed") : nil
                case .keepLive: kept ? String(localized: "Photo kept as is, only its motion is compressed") : nil
                }
                return Preview(image: image, size: kept ? Int64(data.count) : size, note: note)
            }
            return Preview(image: image, size: size, note: kept ? String(localized: "Not enough smaller: this one would be kept as is") : nil)
        } catch let error as TranscodeError where error == .alreadyEfficient {
            if item.isLivePhoto {
                return Preview(image: await decode(data), size: nil, note: recipe.livePhotoMode == .still
                    ? String(localized: "Photo kept as is, its motion is removed")
                    : String(localized: "Photo and motion kept as they are at this level"))
            }
            return Preview(image: await decode(data), size: nil, note: recipe.photoFormat.isLossless
                ? String(localized: "Already HEIF: kept as is in lossless mode")
                : String(localized: "Already HEIF: kept as is at this level"))
        } catch {
            return Preview(image: nil, size: nil, note: error.localizedDescription)
        }
    }
}

/// A UIKit recognizer as a SwiftUI gesture, for what SwiftUI's own can't
/// tell apart: one finger from two, and the pinch's center as it moves.
private struct GestureRecognizer<Recognizer: UIGestureRecognizer>: UIGestureRecognizerRepresentable {
    let make: () -> Recognizer
    var shouldBegin: ((Recognizer) -> Bool)?
    let action: (Recognizer, CGPoint) -> Void

    init(make: @escaping () -> Recognizer, shouldBegin: ((Recognizer) -> Bool)? = nil, action: @escaping (Recognizer, CGPoint) -> Void) {
        self.make = make
        self.shouldBegin = shouldBegin
        self.action = action
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> Recognizer {
        let recognizer = make()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: Recognizer, context: Context) {
        context.coordinator.shouldBegin = shouldBegin.map { check in { check($0 as! Recognizer) } }
    }

    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        // The sheet's scroll stays put while the photo is being handled.
        switch recognizer.state {
        case .began: context.coordinator.holdScroll(of: recognizer.view)
        case .ended, .cancelled, .failed: context.coordinator.releaseScroll()
        default: break
        }
        action(recognizer, context.converter.localLocation)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shouldBegin: ((UIGestureRecognizer) -> Bool)?
        private weak var heldScroll: UIScrollView?

        /// Disabling the scroll's pan cancels what it was doing.
        func holdScroll(of view: UIView?) {
            var ancestor = view
            while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
            guard let scroll = ancestor as? UIScrollView else { return }
            scroll.panGestureRecognizer.isEnabled = false
            heldScroll = scroll
        }

        func releaseScroll() {
            heldScroll?.panGestureRecognizer.isEnabled = true
            heldScroll = nil
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            shouldBegin?(recognizer) ?? true
        }

        /// Pinch and two-finger pan work together; nothing else does.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            Self.isTwoFinger(recognizer) && Self.isTwoFinger(other)
        }

        private static func isTwoFinger(_ recognizer: UIGestureRecognizer) -> Bool {
            recognizer is UIPinchGestureRecognizer || (recognizer as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2
        }
    }
}
