import SwiftUI

// MARK: - Layout constants shared by headers and rows (keeps columns aligned)

enum PanelMetrics {
    // Channel strips: fixed-width vertical strips wrapped into rows of 3...5 (see StripGrid).
    static let stripWidth: CGFloat = 112
    static let stripSpacing: CGFloat = 8
    static let stripSliderHeight: CGFloat = 120
    /// Width for `columns` strips in the first row; `divider` adds the System | Applications line.
    static func panelWidth(columns: Int, divider: Bool) -> CGFloat {
        CGFloat(columns) * stripWidth + CGFloat(columns - 1) * stripSpacing + 2 * panelPadding
            + (divider ? stripSpacing + 1 : 0)
    }
    static let starWidth: CGFloat = 16
    static let meterWidth: CGFloat = 12
    static let iconSize: CGFloat = 26
    static let rowSpacing: CGFloat = 10
    /// Menu panel header buttons (pin, expand, settings): one shared size.
    static let headerGlyph: CGFloat = 15
    static let headerButtonWidth: CGFloat = 30
    static let headerButtonHeight: CGFloat = 28
    static let panelPadding: CGFloat = 12
    // Concentric corners (Apple style): a container's radius = its content's radius + the padding between them.
    /// Round controls inside a container: circle buttons (30) and pills (30 high).
    static let controlSize: CGFloat = 30
    /// Padding between a strip / FX card / bar and the controls inside it.
    static let containerPadding: CGFloat = 8
    /// Strips, FX cards, the FX bar, the permission banner: 15 + 8 = 23.
    static let stripRadius: CGFloat = controlSize / 2 + containerPadding
    /// The panel around those containers: 23 + 12 = 35.
    static let panelRadius: CGFloat = stripRadius + panelPadding
}

// MARK: - Header button

/// Toolbar-style icon button for the panel header.
struct HeaderIconButton: View {
    let systemImage: String
    let help: String
    var isActive = false
    /// Larger glyph and hit area (menu panel header only).
    var large = false
    /// Glyph size override for the large style (pin / expand / gear differ so they look equally big).
    var glyph: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: large ? (glyph ?? PanelMetrics.headerGlyph) : 13, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: large ? PanelMetrics.headerButtonWidth : 26, height: large ? PanelMetrics.headerButtonHeight : 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Mini vertical stereo VU meter

struct MiniVUMeter: View {
    let meter: MeterState
    var active: Bool
    var height: CGFloat = 28

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 1.5
            let w = (size.width - gap) / 2
            bar(context, x: 0, w: w, h: size.height, level: CGFloat(meter.left), peak: CGFloat(meter.peakLeft))
            bar(context, x: w + gap, w: w, h: size.height, level: CGFloat(meter.right), peak: CGFloat(meter.peakRight))
        }
        .frame(width: PanelMetrics.meterWidth, height: height)
        .opacity(active ? 1 : 0.4)
        .accessibilityHidden(true)
    }

    private static let gradient = Gradient(stops: [
        .init(color: .green, location: 0), .init(color: .green, location: 0.6),
        .init(color: .yellow, location: 0.85), .init(color: .red, location: 1),
    ])

    private func bar(_ ctx: GraphicsContext, x: CGFloat, w: CGFloat, h: CGFloat, level: CGFloat, peak: CGFloat) {
        let track = Path(roundedRect: CGRect(x: x, y: 0, width: w, height: h), cornerRadius: w / 2)
        ctx.fill(track, with: .color(.primary.opacity(0.1)))
        if level > 0 {
            let fillH = max(w, h * level)
            let rect = CGRect(x: x, y: h - fillH, width: w, height: fillH)
            ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2),
                     with: .linearGradient(Self.gradient, startPoint: CGPoint(x: x, y: h), endPoint: CGPoint(x: x, y: 0)))
        }
        if peak > 0.02 {
            let y = max(0, h - h * peak)
            ctx.fill(Path(CGRect(x: x, y: y, width: w, height: 1.5)),
                     with: .color(peak > 0.95 ? .red : .primary.opacity(0.55)))
        }
    }
}

// MARK: - Vertical slider (system look: capsule track, accent fill from zero, white knob)

struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var zero: Float = 0
    /// Value granularity (EQ gains snap to 0.1 dB, volumes use 0.01).
    var step: Float = 0.1
    /// Double-tap jumps to `zero` (right for EQ gain, wrong for a volume: it would mute).
    var resetOnDoubleTap = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false
    private let knob: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height - knob
            let pos = position(for: value, height: h)
            let zeroPos = position(for: zero, height: h)
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 4)
                    .padding(.vertical, knob / 2)
                Capsule()
                    .fill(.tint)
                    .frame(width: 4, height: abs(pos - zeroPos))
                    .offset(y: min(pos, zeroPos) + knob / 2)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                    .frame(width: knob, height: knob)
                    .offset(y: pos)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        value = valueAt(y: g.location.y - knob / 2, height: h)
                    }
                    .onEnded { _ in dragging = false; onEditingChanged(false) }
            )
            .onTapGesture(count: 2) { if resetOnDoubleTap { value = zero } }
        }
        .accessibilityElement()
        .accessibilityValue(String(format: "%.1f", value))
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 48
            value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? step : -step)))
        }
    }

    private func position(for v: Float, height: CGFloat) -> CGFloat {
        let t = CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
        return height * (1 - min(1, max(0, t)))
    }

    private func valueAt(y: CGFloat, height: CGFloat) -> Float {
        let t = Float(1 - min(1, max(0, y / max(1, height))))
        let raw = range.lowerBound + t * (range.upperBound - range.lowerBound)
        return (raw / step).rounded() * step
    }
}

// MARK: - Helpers

extension EQPreset {
    @MainActor var displayName: String { isBuiltIn ? L("preset.\(id)") : name }
}

/// Reads the language inside `body`, so every window re-evaluates it when the language changes. Reading it where the
/// root view is built would freeze the direction for windows that are created once (Settings, Audio Devices).
private struct LocalizedEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.locale, Localizer.shared.locale)
            .environment(\.layoutDirection, Localizer.shared.layoutDirection)
    }
}

extension View {
    /// Applies the current UI language & layout direction (used by every scene root).
    func localizedEnvironment() -> some View { modifier(LocalizedEnvironment()) }
}

// MARK: - Pinned EQ window actions (injected by the app delegate; the popover has no SwiftUI scene)

private struct PinEQKey: EnvironmentKey { static let defaultValue: @MainActor (String) -> Void = { _ in } }
private struct UnpinEQKey: EnvironmentKey { static let defaultValue: @MainActor (String) -> Void = { _ in } }

extension EnvironmentValues {
    var pinEQ: @MainActor (String) -> Void {
        get { self[PinEQKey.self] }
        set { self[PinEQKey.self] = newValue }
    }
    var unpinEQ: @MainActor (String) -> Void {
        get { self[UnpinEQKey.self] }
        set { self[UnpinEQKey.self] = newValue }
    }
}

// MARK: - Circular accessory buttons (boost, FX …)

struct CircleButtonLabel: View {
    let systemImage: String
    var active = false
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: size, height: size)
            .background(Circle().fill(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
    }
}

// MARK: - Capsule pill used for menus (device pickers, Add Favorite)

struct PillLabel: View {
    let systemImage: String?
    let title: String
    var width: CGFloat?
    /// Compact view: show only the icon and the chevron.
    var iconOnly = false

    var body: some View {
        if iconOnly, let systemImage {
            CompactMenuButtonLabel(systemImage: systemImage, title: title)
        } else {
            pill
        }
    }

    private var pill: some View {
        HStack(spacing: iconOnly ? 4 : 8) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 13)).frame(width: 18)
            }
            if !iconOnly {
                Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, iconOnly ? 8 : 12)
        .padding(.vertical, 7) // 30pt high: a capsule of radius controlSize / 2
        .frame(width: width)
        .background(Capsule().fill(.quaternary))
        .contentShape(Capsule())
        .help(iconOnly ? title : "")
    }
}

extension AnyTransition {
    /// Card body expand / collapse: fades while sliding under the header.
    static var cardBody: AnyTransition { .opacity.combined(with: .move(edge: .top)) }
}

// MARK: - Collapsible body (smooth expand / collapse without moving content)

/// Lays its single child out at full natural size but reports only `progress` of its height, so the
/// surrounding layout grows / shrinks smoothly while the content itself never moves or overlaps.
private struct CollapseLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        // An infinite / unspecified proposal must not leak out as an infinite size: AppKit rejects it
        // ("_NSViewValidateGeometry").
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let size = child.sizeThatFits(ProposedViewSize(width: width, height: nil))
        guard size.width.isFinite, size.height.isFinite else { return .zero }
        // Report the proposed width, not the child's: a wide child must not widen (and so shift) its parent stack.
        return CGSize(width: width ?? size.width, height: max(0, size.height * progress))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        guard bounds.width.isFinite else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        guard size.height.isFinite else { return }
        child.place(at: bounds.origin, anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

struct Collapsible<Content: View>: View {
    let isOpen: Bool
    @ViewBuilder var content: Content

    var body: some View {
        CollapseLayout(progress: isOpen ? 1 : 0) { content }
            // No fade: an animated opacity turns the content into an offscreen group in which translucent
            // styles (strokes, materials, hierarchical fills) render as flat white. Clipping alone is enough.
            .clipped()
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)
    }
}

// MARK: - Compact menu button (device picker as a full circular button)

/// Circular menu button: filled circle with a hairline border, hover highlight and a chevron badge.
/// The whole circle is the hit area, not just the glyph.
struct CompactMenuButtonLabel: View {
    let systemImage: String
    let title: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(hovering ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary)))
            .overlay(Circle().strokeBorder(Color.primary.opacity(hovering ? 0.28 : 0.16), lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .heavy))
                    .foregroundStyle(.secondary)
                    .frame(width: 11, height: 11)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
                    .offset(x: 2, y: 2)
            }
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(title)
            .accessibilityLabel(title)
    }
}

// MARK: - Channel strips

private struct StripWidthKey: EnvironmentKey { static let defaultValue = PanelMetrics.stripWidth }

extension EnvironmentValues {
    /// Width of one strip: `PanelMetrics.stripWidth`, or wider when the panel is wider than its strips need (open FX panel).
    var stripWidth: CGFloat {
        get { self[StripWidthKey.self] }
        set { self[StripWidthKey.self] = newValue }
    }
}

/// One vertical channel strip: icon, name, a vertical volume slider beside its live level meter,
/// mute + percent, and a caller-provided control row (device picker, Boost, FX).
struct ChannelStrip<Controls: View>: View {
    let name: String
    let icon: AnyView
    /// Small badge in the top-left corner (favorite star, status dot, connection symbol).
    let corner: AnyView
    let meter: AnyView
    @Binding var volume: Float
    var enabled = true
    var noVolumeHelp = ""
    let muted: Bool
    let muteSymbol: String
    var onMute: (() -> Void)?
    var highlighted = false
    @ViewBuilder var controls: Controls

    var body: some View {
        // 8pt (containerPadding) everywhere inside a strip: edges and gaps. The three 30pt buttons + 2×3pt fill the 96pt inner width.
        VStack(spacing: 8) {
            icon.frame(width: PanelMetrics.iconSize, height: PanelMetrics.iconSize)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                VerticalSlider(value: $volume, range: 0...1, step: 0.01, resetOnDoubleTap: false)
                    .frame(width: 24, height: PanelMetrics.stripSliderHeight)
                    .opacity(enabled ? 1 : 0.4)
                    .disabled(!enabled)
                    .help(enabled ? "" : noVolumeHelp)
                    .accessibilityLabel(name)
                meter.frame(height: PanelMetrics.stripSliderHeight)
            }

            HStack(spacing: 4) {
                Button { onMute?() } label: {
                    Image(systemName: muteSymbol)
                        .font(.system(size: 13))
                        .foregroundStyle(muted ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .frame(width: 20)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(onMute == nil)

                Text(Double(volume).formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(muted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }

            controls
        }
        .padding(PanelMetrics.containerPadding)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: PanelMetrics.stripRadius, style: .continuous)
            .fill(highlighted ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(0.05))))
        .overlay(alignment: .topLeading) { corner.padding(7) }
    }
}

/// Lays out one grid: `leading` (the System strips) and a divider, then the items, wrapped into rows
/// of `columns` fixed-width strips. Details (open FX panels) show full width under their row.
struct StripGrid<Item: Identifiable, Leading: View, LeadingDetail: View, Strip: View, Detail: View>: View {
    let items: [Item]
    let columns: Int
    /// How many strip slots `leading` takes in the first row.
    let leadingCount: Int
    @ViewBuilder var leading: Leading
    @ViewBuilder var leadingDetail: LeadingDetail
    @ViewBuilder var strip: (Item) -> Strip
    @ViewBuilder var detail: (Item) -> Detail
    @Environment(\.stripWidth) private var stripWidth

    private var rows: [[Item]] {
        let first = max(0, columns - leadingCount)
        var result = [Array(items.prefix(first))]
        let rest = Array(items.dropFirst(first))
        result += stride(from: 0, to: rest.count, by: columns).map { Array(rest[$0..<min($0 + columns, rest.count)]) }
        return result
    }

    var body: some View {
        let rows = rows
        VStack(spacing: PanelMetrics.stripSpacing) {
            ForEach(rows.indices, id: \.self) { i in
                if i > 0 { Divider() }
                // Spacing 0: closed details are zero-height; open ones pad themselves.
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: PanelMetrics.stripSpacing) {
                        if i == 0 {
                            leading
                            if !rows[0].isEmpty { Divider().padding(.vertical, 4) }
                        }
                        ForEach(rows[i]) { item in
                            strip(item).frame(width: stripWidth)
                        }
                    }
                    // Not a trailing Spacer: HStack adds its spacing before it, which made the first row 8pt too wide.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if i == 0 { leadingDetail }
                    ForEach(rows[i]) { detail($0) }
                }
            }
        }
    }
}
