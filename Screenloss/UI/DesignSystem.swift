import SwiftUI

nonisolated enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false))
    }
}

/// The accent the app is drawn in. Green by default: it's the color of
/// space coming back.
enum AppTint: String, CaseIterable, Identifiable {
    case mint, blue, indigo, yellow

    static let storageKey = "appTint"

    /// The stored tint, or mint when it's gone (one removed in an update).
    static func stored(_ rawValue: String) -> AppTint { AppTint(rawValue: rawValue) ?? .mint }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mint: "Mint"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .yellow: "Yellow"
        }
    }

    private var shades: (bright: (Double, Double, Double), deep: (Double, Double, Double)) {
        switch self {
        case .mint: ((0.39, 0.89, 0.62), (0.0, 0.62, 0.40))
        case .blue: ((0.30, 0.62, 1.0), (0.0, 0.46, 0.96))
        case .indigo: ((0.55, 0.52, 1.0), (0.40, 0.34, 0.92))
        case .yellow: ((0.98, 0.82, 0.30), (0.78, 0.56, 0.0))
        }
    }

    /// Deeper in light mode: the bright shades read poorly on white.
    var color: Color {
        let shades = shades
        return Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .light ? shades.deep : shades.bright
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// The swatch in Settings: always the bright shade, in both modes.
    var swatchColor: Color {
        let c = shades.bright
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    /// The home screen icon drawn in this tint. Mint is the primary icon.
    var iconName: String? {
        self == .mint ? nil : "AppIcon-\(title)"
    }

    /// iOS confirms each change with its own alert, so it's only asked
    /// when the icon actually differs.
    func applyIcon() {
        let application = UIApplication.shared
        guard application.supportsAlternateIcons, application.alternateIconName != iconName else { return }
        application.setAlternateIconName(iconName)
    }
}

/// Light, dark, or as the system is, the same as in LRCplayer.
enum AppAppearance: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    static let storageKey = "appAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .system: "circle.lefthalf.filled"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: .unspecified
        }
    }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .dark
    }

    /// Set on the windows rather than through SwiftUI's
    /// `preferredColorScheme`, which doesn't go back to the system's style
    /// once it has forced one. Windows opened later get it as they appear;
    /// the root view applies it at launch and whenever the setting changes.
    @MainActor static func startApplying() {
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: nil) { note in
            let window = note.object as? UIWindow
            MainActor.assumeIsolated {
                window?.overrideUserInterfaceStyle = current.style
            }
        }
    }

    /// `animated`: cross-fades to the new style (a style change otherwise
    /// swaps every color in one frame).
    @MainActor static func apply(animated: Bool) {
        let style = current.style
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.overrideUserInterfaceStyle != style {
                guard animated else {
                    window.overrideUserInterfaceStyle = style
                    continue
                }
                // A still of the screen as it is, faded out over the new style.
                // (A view transition's "before" image kept the Liquid Glass
                // live: it switched to the new style in the first frame.)
                let still = window.screen.snapshotView(afterScreenUpdates: false)
                still.frame = window.bounds
                still.isUserInteractionEnabled = false
                window.addSubview(still)
                window.overrideUserInterfaceStyle = style
                UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                    still.alpha = 0
                } completion: { _ in
                    still.removeFromSuperview()
                }
            }
        }
    }
}

extension Color {
    /// Behind every screen: black in dark mode, the grouped gray in light
    /// mode, so the glass cards stand out in both.
    static let screenBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light ? .systemGroupedBackground : .black
    })
}

enum Motion {
    static let snappy = Animation.interactiveSpring(response: 0.34, dampingFraction: 0.84)
    static let smooth = Animation.spring(response: 0.42, dampingFraction: 0.9)
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

struct CollapsibleGlassCard<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: systemImage).font(.headline).foregroundStyle(.tint)
                        .frame(width: 24)
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)

            // Kept alive while folded: built only when opening, a card of
            // menus (Compression) stuttered as it unfolded.
            content
                .padding(.top, 18)
                // Laid out once at its own height, then revealed: given the
                // growing height frame by frame, text rewrapped as the card
                // opened and every row was laid out again on each frame.
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: isExpanded ? nil : 0, alignment: .top)
                // Clipped only while folded: open, controls drawn a little
                // past their frame (a toggle's glass knob) stay whole.
                .clipShape(Rectangle().inset(by: isExpanded ? -24 : 0))
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
        .animation(Motion.snappy, value: isExpanded)
    }
}

/// A capsule picker whose selection slides between options and can be
/// dragged, the same as in LRCplayer.
struct GlassSegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let symbol: ((Value) -> String)?
    let label: String
    let commitsWhenSettled: Bool

    /// What the capsule shows, ahead of `selection` until it settles.
    @State private var shown: Value?
    /// The slide whose end hands its option over (a newer one replaces it).
    @State private var pendingSlide: UUID?
    /// The capsule's leading edge while it follows the finger.
    @State private var dragX: CGFloat?
    @State private var width: CGFloat = 0
    /// The selection held under the finger: it lifts, like iOS's glass
    /// selections do.
    @State private var isHolding = false
    @GestureState private var isTouching = false

    private static var inset: CGFloat { 4 }
    private static var settle: Animation { .spring(response: 0.32, dampingFraction: 0.86) }

    init(_ label: String, options: [Value], selection: Binding<Value>, title: @escaping (Value) -> String, symbol: ((Value) -> String)? = nil, commitsWhenSettled: Bool = false) {
        self.label = label
        self.options = options
        _selection = selection
        self.title = title
        self.symbol = symbol
        self.commitsWhenSettled = commitsWhenSettled
    }

    private var current: Value { shown ?? selection }
    private var segment: CGFloat { options.isEmpty ? 0 : (width - Self.inset * 2) / CGFloat(options.count) }

    private func index(of value: Value) -> Int { options.firstIndex(of: value) ?? 0 }

    private func nearestIndex(toLeadingEdge x: CGFloat) -> Int {
        guard segment > 0 else { return 0 }
        return min(max(Int((x / segment).rounded()), 0), options.count - 1)
    }

    var body: some View {
        let highlighted = dragX.map { nearestIndex(toLeadingEdge: $0) } ?? index(of: current)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.tint.opacity(isHolding ? 0.22 : 0.30))
                .glassEffect(.regular.interactive(), in: .capsule)
                .frame(width: max(segment, 0))
                .scaleEffect(isHolding ? 1.1 : 1)
                .offset(x: dragX ?? CGFloat(index(of: current)) * segment)
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element) { offset, option in
                    VStack(spacing: 5) {
                        if let symbol {
                            Image(systemName: symbol(option)).font(.headline)
                        }
                        Text(title(option))
                            .font(symbol == nil ? .subheadline.weight(.semibold) : .caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(offset == highlighted ? .primary : .secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(offset == highlighted ? .isSelected : [])
                    .accessibilityAction { select(option) }
                }
            }
        }
        .frame(height: symbol == nil ? 40 : 58)
        .padding(Self.inset)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Capsule())
        .gesture(drag)
        // Not interactive: the whole capsule bouncing under the finger
        // fought the selection's slide (only the selection moves, as in
        // iOS's segmented controls).
        .glassEffect(.regular, in: .capsule)
        .onChange(of: isTouching) { _, touching in
            // Also on a cancelled touch, which skips `onEnded`.
            if !touching {
                if isHolding { withAnimation(Self.settle) { isHolding = false } }
                if dragX != nil { withAnimation(Self.settle) { dragX = nil } }
            }
        }
        .onChange(of: selection) { _, _ in
            if pendingSlide == nil { shown = nil }
        }
        .sensoryFeedback(.selection, trigger: highlighted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, state, _ in state = true }
            .onChanged { value in
                let startsOnSelection = Int((value.startLocation.x - Self.inset) / max(segment, 1)) == index(of: current)
                if startsOnSelection, !isHolding {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHolding = true }
                }
                // A drag starts on the selection, like iOS's; elsewhere the
                // touch is a tap on the option it lifts on.
                let startIndex = Int((value.startLocation.x - Self.inset) / max(segment, 1))
                guard abs(value.translation.width) > 6, startIndex == index(of: current) || dragX != nil else { return }
                let start = CGFloat(index(of: current)) * segment
                let x = min(max(start + value.translation.width, 0), segment * CGFloat(options.count - 1))
                if dragX == nil {
                    withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.9)) { dragX = x }
                } else {
                    dragX = x
                }
            }
            .onEnded { value in
                let target: Int
                if let dragX {
                    target = nearestIndex(toLeadingEdge: dragX)
                } else {
                    target = min(max(Int((value.location.x - Self.inset) / max(segment, 1)), 0), options.count - 1)
                }
                select(options[target])
            }
    }

    private func select(_ option: Value) {
        guard commitsWhenSettled else {
            pendingSlide = nil
            withAnimation(Self.settle) {
                shown = nil
                dragX = nil
                isHolding = false
            }
            if option != selection { selection = option }
            return
        }
        let slide = UUID()
        pendingSlide = option == selection ? nil : slide
        withAnimation(Self.settle, completionCriteria: .logicallyComplete) {
            shown = option == selection ? nil : option
            dragX = nil
            isHolding = false
        } completion: {
            guard pendingSlide == slide else { return }
            pendingSlide = nil
            // `shown` stays until `selection` actually changes: the owner
            // may apply it a moment later.
            selection = option
        }
    }
}

/// A big number with a caption under it.
struct Figure: View {
    let value: String
    let label: String
    var tinted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Library size now against after compressing, as one bar.
struct SavingsBar: View {
    let total: Int64
    let saving: Int64

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(saving) / Double(total)))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: max(0, width * (1 - fraction)))
                Capsule()
                    .fill(.tint)
                    .frame(width: width * fraction)
                    .offset(x: width * (1 - fraction))
            }
        }
        .frame(height: 10)
        .animation(Motion.smooth, value: fraction)
        .accessibilityElement()
        .accessibilityLabel("About \(Int((fraction * 100).rounded())) percent can be freed")
    }
}
