import Photos
import SwiftUI
import UIKit

/// The browser's grid, as a collection view rather than a SwiftUI grid:
/// cells are reused instead of rebuilt, thumbnails are cached ahead of the
/// scroll like in Photos, and a selection change touches only the cells on
/// screen.
struct AssetGrid<Header: View>: UIViewRepresentable {
    let items: [MediaItem]
    /// The bars' heights: the grid runs under them, its content starts below.
    let insets: EdgeInsets
    let selection: Set<String>
    let pendingIDs: Set<String>
    let tint: UIColor
    let isSelectable: (MediaItem) -> Bool
    let onTap: (MediaItem) -> Void
    let onSelectionChange: (Set<String>) -> Void
    @ViewBuilder let header: () -> Header

    static var columns: Int { 4 }
    static var spacing: CGFloat { 2 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        let view = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
        view.backgroundColor = .clear
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = true
        view.contentInsetAdjustmentBehavior = .never
        // The Review button floats on the grid: no frosted band behind it,
        // which showed up as a gray zone whenever the button was pressed.
        view.bottomEdgeEffect.isHidden = true
        view.delegate = coordinator
        view.prefetchDataSource = coordinator
        coordinator.attach(to: view)
        coordinator.parent = self
        coordinator.apply(self, to: view)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(self, to: view)
    }

    private static func layout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = CGFloat(columns)
            let side = floor((width - spacing * (columns - 1)) / columns * environment.traitCollection.displayScale) / environment.traitCollection.displayScale
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(side)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)),
                repeatingSubitem: item,
                count: Self.columns
            )
            group.interItemSpacing = .flexible(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = .init(top: 0, leading: 0, bottom: 24, trailing: 0)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(110)),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, UIGestureRecognizerDelegate {
        var parent: AssetGrid?
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
        private var itemsByID: [String: MediaItem] = [:]
        private var order: [String] = []
        private var assets: [String: PHAsset] = [:]
        private var selection = Set<String>()
        private var pendingIDs = Set<String>()
        private var tint: UIColor = .tintColor
        private let images = PHCachingImageManager()
        private let haptics = UISelectionFeedbackGenerator()
        private var drag: (anchor: Int, selecting: Bool, base: Set<String>)?
        private var dragStart: CGPoint = .zero
        private var hasClaimedScrollView = false

        func attach(to view: UICollectionView) {
            collectionView = view
            let cells = UICollectionView.CellRegistration<AssetGridCell, String> { [unowned self] cell, _, id in
                configure(cell, id: id)
            }
            let headers = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { [unowned self] cell, _, _ in
                configureHeader(cell)
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: view) { view, indexPath, id in
                view.dequeueConfiguredReusableCell(using: cells, for: indexPath, item: id)
            }
            dataSource.supplementaryViewProvider = { view, _, indexPath in
                view.dequeueConfiguredReusableSupplementary(using: headers, for: indexPath)
            }

            let pan = UIPanGestureRecognizer(target: self, action: #selector(dragSelect(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            view.addGestureRecognizer(pan)
        }

        /// Brings the view up to date with what SwiftUI passed, touching
        /// only what changed.
        func apply(_ grid: AssetGrid, to view: UICollectionView) {
            let inset = UIEdgeInsets(top: grid.insets.top, left: 0, bottom: grid.insets.bottom, right: 0)
            if view.contentInset != inset {
                let atTop = view.contentOffset.y <= -view.contentInset.top + 1
                view.contentInset = inset
                view.verticalScrollIndicatorInsets = inset
                if atTop { view.contentOffset.y = -inset.top }
            }
            let ids = grid.items.map(\.id)
            let itemsChanged = ids != order
            let dataChanged = !itemsChanged && grid.items.contains { itemsByID[$0.id] != $0 }
            let stateChanged = grid.selection != selection || grid.pendingIDs != pendingIDs || grid.tint != tint

            itemsByID = Dictionary(grid.items.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            selection = grid.selection
            pendingIDs = grid.pendingIDs
            tint = grid.tint

            if itemsChanged {
                let missing = ids.filter { assets[$0] == nil }
                if !missing.isEmpty {
                    PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil).enumerateObjects { asset, _, _ in
                        self.assets[asset.localIdentifier] = asset
                    }
                }
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(ids)
                let animated = !order.isEmpty
                order = ids
                dataSource.apply(snapshot, animatingDifferences: animated)
            } else if dataChanged {
                var snapshot = dataSource.snapshot()
                snapshot.reconfigureItems(ids)
                dataSource.apply(snapshot, animatingDifferences: false)
            }
            if itemsChanged || stateChanged {
                refreshVisibleCells(in: view)
            }
            refreshHeader(in: view)
            claimScrollViewIfNeeded(view)
        }

        // MARK: Cells

        private func configure(_ cell: AssetGridCell, id: String) {
            guard let item = itemsByID[id] else { return }
            cell.show(item, isSelected: selection.contains(id), isPending: pendingIDs.contains(id), tint: tint)
            loadThumbnail(for: cell, id: id)
        }

        private func refreshVisibleCells(in view: UICollectionView) {
            for indexPath in view.indexPathsForVisibleItems {
                guard let id = dataSource.itemIdentifier(for: indexPath),
                      let item = itemsByID[id],
                      let cell = view.cellForItem(at: indexPath) as? AssetGridCell
                else { continue }
                cell.show(item, isSelected: selection.contains(id), isPending: pendingIDs.contains(id), tint: tint)
            }
        }

        private func configureHeader(_ cell: UICollectionViewCell) {
            guard let parent else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                parent.header()
                    .tint(Color(uiColor: parent.tint))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
            .margins(.all, 0)
        }

        private func refreshHeader(in view: UICollectionView) {
            let indexPath = IndexPath(item: 0, section: 0)
            guard let header = view.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath) as? UICollectionViewCell else { return }
            configureHeader(header)
        }

        /// The bar above follows this scroll view (its edge effect, and the
        /// title's background), as it would a SwiftUI one.
        private func claimScrollViewIfNeeded(_ view: UICollectionView) {
            guard !hasClaimedScrollView, view.window != nil else {
                if !hasClaimedScrollView {
                    DispatchQueue.main.async { [weak self, weak view] in
                        guard let self, let view, view.window != nil else { return }
                        self.claimScrollViewIfNeeded(view)
                    }
                }
                return
            }
            var responder: UIResponder? = view.next
            while let current = responder {
                if let controller = current as? UIViewController {
                    controller.setContentScrollView(view, for: .top)
                    hasClaimedScrollView = true
                    return
                }
                responder = current.next
            }
        }

        // MARK: Thumbnails

        private func targetSize(in view: UICollectionView?) -> CGSize {
            let width = view?.bounds.width ?? 400
            let side = (width - AssetGrid.spacing * CGFloat(AssetGrid.columns - 1)) / CGFloat(AssetGrid.columns)
            let scale = view?.traitCollection.displayScale ?? 3
            return CGSize(width: side * scale, height: side * scale)
        }

        private static var options: PHImageRequestOptions {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            return options
        }

        private func loadThumbnail(for cell: AssetGridCell, id: String) {
            cell.cancelRequest(using: images)
            guard let asset = assets[id] else { return }
            let request = images.requestImage(for: asset, targetSize: targetSize(in: collectionView), contentMode: .aspectFill, options: Self.options) { [weak cell] image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard let image else { return }
                if degraded {
                    onMain { cell?.setImage(image, for: id) }
                } else {
                    // Decoded off the main thread before it's shown.
                    image.prepareForDisplay { prepared in
                        onMain { cell?.setImage(prepared ?? image, for: id) }
                    }
                }
            }
            cell.requestID = request
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let assets = indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }.compactMap { self.assets[$0] }
            images.startCachingImages(for: assets, targetSize: targetSize(in: collectionView), contentMode: .aspectFill, options: Self.options)
        }

        func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            let assets = indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }.compactMap { self.assets[$0] }
            images.stopCachingImages(for: assets, targetSize: targetSize(in: collectionView), contentMode: .aspectFill, options: Self.options)
        }

        // MARK: Taps and menus

        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            if let id = dataSource.itemIdentifier(for: indexPath), let item = itemsByID[id] {
                parent?.onTap(item)
            }
            return false
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
            guard let indexPath = indexPaths.first,
                  let id = dataSource.itemIdentifier(for: indexPath),
                  let item = itemsByID[id]
            else { return nil }
            let asset = assets[id]
            return UIContextMenuConfiguration(identifier: id as NSString) {
                asset.map { AssetPreviewController(asset: $0, item: item) }
            } actionProvider: { [weak self] _ in
                let info = "\(item.format.label) · \(ByteFormat.string(item.size)) · \(item.pixelWidth)×\(item.pixelHeight)"
                let action: UIAction
                if let blocker = item.blocker {
                    action = UIAction(title: blocker.label, subtitle: blocker.explanation, image: UIImage(systemName: "nosign"), attributes: .disabled) { _ in }
                } else {
                    let selected = self?.selection.contains(id) ?? false
                    action = UIAction(title: selected ? "Deselect" : "Select", image: UIImage(systemName: selected ? "circle" : "checkmark.circle")) { [weak self] _ in
                        guard let self, let item = self.itemsByID[id] else { return }
                        self.parent?.onTap(item)
                    }
                }
                return UIMenu(title: info, children: [action])
            }
        }

        // MARK: Drag to select

        /// Only a sideways swipe starts it: vertical swipes scroll as usual.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, pan.view === collectionView else { return true }
            // The screen edge stays the way back.
            if let window = pan.view?.window, pan.location(in: window).x < 24 { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }

        /// iOS 26 goes back on a sideways swipe from anywhere; on the grid,
        /// that swipe selects instead, as in Photos. The edge swipe isn't
        /// affected, and neither is scrolling.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            var responder: UIResponder? = recognizer.view
            while let current = responder {
                if let navigation = current as? UINavigationController {
                    return other === navigation.interactiveContentPopGestureRecognizer
                }
                responder = current.next
            }
            return false
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func dragSelect(_ pan: UIPanGestureRecognizer) {
            guard let view = collectionView else { return }
            let location = pan.location(in: view)
            switch pan.state {
            case .began:
                let translation = pan.translation(in: view)
                dragStart = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
                guard let anchor = index(at: dragStart, in: view) else { return }
                view.isScrollEnabled = false
                haptics.prepare()
                drag = (anchor, !selection.contains(order[anchor]), selection)
                extendDrag(to: location, in: view)
            case .changed:
                extendDrag(to: location, in: view)
            default:
                drag = nil
                view.isScrollEnabled = true
            }
        }

        private func extendDrag(to location: CGPoint, in view: UICollectionView) {
            guard let drag, let parent, let current = index(at: location, in: view) else { return }
            var next = drag.base
            for id in order[min(drag.anchor, current)...max(drag.anchor, current)] {
                guard let item = itemsByID[id], parent.isSelectable(item) else { continue }
                if drag.selecting { next.insert(id) } else { next.remove(id) }
            }
            guard next != selection else { return }
            if next.count != selection.count { haptics.selectionChanged() }
            selection = next
            refreshVisibleCells(in: view)
            parent.onSelectionChange(next)
        }

        /// The item under a point, or the nearest one in the gaps between.
        private func index(at point: CGPoint, in view: UICollectionView) -> Int? {
            guard !order.isEmpty,
                  let first = view.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame
            else { return nil }
            let stride = first.width + AssetGrid.spacing
            guard point.y >= first.minY else { return nil }
            let column = min(AssetGrid.columns - 1, max(0, Int(point.x / stride)))
            let row = Int((point.y - first.minY) / stride)
            let index = row * AssetGrid.columns + column
            return index < order.count ? index : nil
        }
    }
}

/// Photos calls back on the main thread for these requests; image
/// preparation, on any thread.
private nonisolated func onMain(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { work() }
    } else {
        DispatchQueue.main.async { work() }
    }
}

// MARK: - Cell

/// A thumbnail with its size, format and selection drawn in plain layers:
/// no SwiftUI view per cell, no offscreen passes.
final class AssetGridCell: UICollectionViewCell {
    var requestID: PHImageRequestID?
    private var representedID: String?

    private let imageView = UIImageView()
    private let shade = CAGradientLayer()
    private let sizeLabel = UILabel()
    private let formatLabel = UILabel()
    private let formatBackground = UIView()
    private let badge = UIImageView()
    private let badgeBackground = UIView()
    private let border = CALayer()
    private var badgeInset: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemFill
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)

        shade.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.6).cgColor]
        shade.startPoint = CGPoint(x: 0.5, y: 0.5)
        shade.endPoint = CGPoint(x: 0.5, y: 1)
        contentView.layer.addSublayer(shade)

        sizeLabel.textColor = .white
        contentView.addSubview(sizeLabel)

        formatBackground.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        formatBackground.layer.cornerRadius = 4
        contentView.addSubview(formatBackground)
        formatLabel.font = .systemFont(ofSize: 9, weight: .bold)
        formatLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        contentView.addSubview(formatLabel)

        contentView.addSubview(badgeBackground)
        contentView.addSubview(badge)

        border.borderWidth = 2.5
        contentView.layer.addSublayer(border)

        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: MediaItem, isSelected: Bool, isPending: Bool, tint: UIColor) {
        if representedID != item.id {
            representedID = item.id
            imageView.image = nil
        }
        let resolvedTint = tint.resolvedColor(with: traitCollection)

        let text = NSMutableAttributedString()
        let font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let symbol = item.isLivePhoto ? "livephoto" : item.kind == .video ? "video.fill" : nil
        if let symbol, let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font)) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: image.withTintColor(.white, renderingMode: .alwaysOriginal))))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: ByteFormat.string(item.size)))
        text.addAttributes([.font: font, .foregroundColor: UIColor.white], range: NSRange(location: 0, length: text.length))
        sizeLabel.attributedText = text
        formatLabel.text = item.format.label

        if !item.isEligible {
            badge.image = UIImage(systemName: "nosign", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            badgeBackground.isHidden = true
        } else if isPending {
            badge.image = UIImage(systemName: "checkmark.seal.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.black, resolvedTint])))
            badgeBackground.isHidden = true
        } else if isSelected {
            badge.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.black, resolvedTint])))
            badgeBackground.isHidden = false
            badgeBackground.backgroundColor = .white
            badgeInset = -1.5
        } else {
            badge.image = UIImage(systemName: "circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            badgeBackground.isHidden = false
            badgeBackground.backgroundColor = UIColor.black.withAlphaComponent(0.25)
            badgeInset = 1
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.borderColor = resolvedTint.cgColor
        border.isHidden = !isSelected
        CATransaction.commit()
        contentView.alpha = item.isEligible ? 1 : 0.45

        accessibilityLabel = "\(item.kind == .video ? "Video" : "Photo"), \(item.format.label), \(ByteFormat.string(item.size))"
        accessibilityValue = isSelected ? "Selected" : nil
        accessibilityTraits = isSelected ? [.button, .selected] : .button
        setNeedsLayout()
    }

    func setImage(_ image: UIImage, for id: String) {
        guard representedID == id else { return }
        imageView.image = image
    }

    func cancelRequest(using manager: PHImageManager) {
        if let requestID { manager.cancelImageRequest(requestID) }
        requestID = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        imageView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = bounds
        border.frame = bounds
        CATransaction.commit()

        let size = sizeLabel.sizeThatFits(bounds.size)
        sizeLabel.frame = CGRect(x: 5, y: bounds.maxY - size.height - 5, width: min(size.width, bounds.width - 10), height: size.height)

        let format = formatLabel.sizeThatFits(bounds.size)
        formatBackground.frame = CGRect(x: 4, y: 4, width: format.width + 8, height: format.height + 4)
        formatLabel.frame = formatBackground.frame.insetBy(dx: 4, dy: 2)

        let badgeSize = badge.image?.size ?? .zero
        badge.frame = CGRect(x: bounds.maxX - badgeSize.width - 5, y: 5, width: badgeSize.width, height: badgeSize.height)
        let circle = min(badge.frame.width, badge.frame.height)
        let circleFrame = CGRect(x: badge.frame.midX - circle / 2, y: badge.frame.midY - circle / 2, width: circle, height: circle)
            .insetBy(dx: badgeInset, dy: badgeInset)
        badgeBackground.frame = circleFrame
        badgeBackground.layer.cornerRadius = circleFrame.width / 2
    }
}

// MARK: - Preview

/// The context menu's preview: the whole picture, at its own shape.
private final class AssetPreviewController: UIViewController {
    private let asset: PHAsset
    private let imageView = UIImageView()

    init(asset: PHAsset, item: MediaItem) {
        self.asset = asset
        super.init(nibName: nil, bundle: nil)
        let aspect = item.pixelWidth > 0 ? min(1.8, max(0.5, CGFloat(item.pixelHeight) / CGFloat(item.pixelWidth))) : 1
        preferredContentSize = CGSize(width: 320, height: 320 * aspect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        imageView.contentMode = .scaleAspectFit
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(imageView)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        let scale = traitCollection.displayScale
        let target = CGSize(width: preferredContentSize.width * scale, height: preferredContentSize.height * scale)
        PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { [weak self] image, _ in
            guard let image else { return }
            DispatchQueue.main.async { self?.imageView.image = image }
        }
    }
}
