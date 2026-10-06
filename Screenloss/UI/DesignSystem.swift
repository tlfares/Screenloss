import SwiftUI

nonisolated enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false))
    }
}

/// The accent the app is drawn in. Green by default: it's the color of
/// space coming back.
enum AppTint: String, CaseIterable, Identifiable {
    case mint, blue, indigo, pink, orange, yellow, silver

    static let storageKey = "appTint"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mint: "Mint"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .pink: "Pink"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .silver: "Silver"
        }
    }

    var color: Color {
        switch self {
        case .mint: Color(red: 0.39, green: 0.89, blue: 0.62)
        case .blue: Color(red: 0.30, green: 0.62, blue: 1.0)
        case .indigo: Color(red: 0.55, green: 0.52, blue: 1.0)
        case .pink: Color(red: 1.0, green: 0.42, blue: 0.62)
        case .orange: Color(red: 1.0, green: 0.62, blue: 0.27)
        case .yellow: Color(red: 0.98, green: 0.82, blue: 0.30)
        case .silver: Color(red: 0.80, green: 0.81, blue: 0.84)
        }
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

            if isExpanded {
                content
                    .padding(.top, 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
        .animation(Motion.snappy, value: isExpanded)
    }
}

/// A capsule picker whose highlight slides between options, the same as
/// in XMGo and LRCplayer.
struct GlassSegmentedPicker<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var symbol: ((Option) -> String)?
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(Motion.snappy) { selection = option }
                } label: {
                    VStack(spacing: 4) {
                        if let symbol {
                            Image(systemName: symbol(option)).font(.headline)
                        }
                        Text(title(option))
                            .font(symbol == nil ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: symbol == nil ? 36 : 56)
                    .padding(.horizontal, 4)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(.tint.opacity(0.28))
                                .matchedGeometryEffect(id: "highlight", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .sensoryFeedback(.selection, trigger: selection)
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
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(.white.opacity(0.55))
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
