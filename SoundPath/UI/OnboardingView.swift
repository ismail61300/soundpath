import SwiftUI

/// Colours of the app icon: graphite, coral and cream.
private enum Brand {
    static let graphiteTop = Color(red: 0x2b / 255, green: 0x2e / 255, blue: 0x36 / 255)
    static let graphiteBottom = Color(red: 0x15 / 255, green: 0x17 / 255, blue: 0x1b / 255)
    static let coral = Color(red: 1, green: 0x6b / 255, blue: 0x3d / 255)
    static let cream = Color(red: 0xf4 / 255, green: 0xef / 255, blue: 0xe6 / 255)
}

/// First-launch tour: a few pages that slide in from the trailing edge, with the audio permission
/// requested on the last one. Drawn in the icon's colours.
struct OnboardingView: View {
    static let size = CGSize(width: 720, height: 540)

    let model: MixerModel
    /// Called by "Get started" on the last page.
    let finish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var movingForward = true

    private struct Page { let art: Art; let title: String; let body: String }
    private enum Art { case icon, sliders, route, boost }

    private var infoPages: [Page] {
        [Page(art: .icon, title: L("onb.welcome.title"), body: L("onb.welcome.body")),
         Page(art: .sliders, title: L("onb.volume.title"), body: L("onb.volume.body")),
         Page(art: .route, title: L("onb.route.title"), body: L("onb.route.body")),
         Page(art: .boost, title: L("onb.fx.title"), body: L("onb.fx.body"))]
    }

    private var lastPage: Int { infoPages.count }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    if page < lastPage { infoPage(infoPages[page]) } else { permissionPage }
                }
                .id(page)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { background }
        .ignoresSafeArea() // the background runs under the transparent title bar
        .foregroundStyle(Brand.cream)
        .tint(Brand.coral)
        // The user may allow access in System Settings instead of the prompt: follow it live.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if page == lastPage { model.refreshPermission() }
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Brand.graphiteTop, Brand.graphiteBottom], startPoint: .top, endPoint: .bottom)
            // The icon's faint dot grid.
            Canvas { context, size in
                for x in stride(from: 32.0, to: size.width, by: 48) {
                    for y in stride(from: 32.0, to: size.height, by: 48) {
                        context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)),
                                     with: .color(Brand.cream.opacity(0.06)))
                    }
                }
            }
        }
    }

    // MARK: Pages

    private func infoPage(_ page: Page) -> some View {
        VStack(spacing: 22) {
            art(page.art).frame(height: 200)
            text(title: page.title, body: page.body)
        }
        .padding(.horizontal, 56)
    }

    private var permissionPage: some View {
        VStack(spacing: 22) {
            permissionArt.frame(height: 200)
            text(title: L("onb.perm.title"), body: L("onb.perm.body"))
            permissionStatus
        }
        .padding(.horizontal, 56)
    }

    private func text(title: String, body: String) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.system(size: 32, weight: .semibold)).multilineTextAlignment(.center)
            Text(body)
                .font(.system(size: 17))
                .foregroundStyle(Brand.cream.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
        }
    }

    @ViewBuilder private var permissionStatus: some View {
        switch model.permission {
        case .authorized:
            Label(L("onb.perm.granted"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Brand.coral)
        case .denied:
            VStack(spacing: 10) {
                Text(L("onb.perm.denied")).font(.callout).foregroundStyle(Brand.cream.opacity(0.65))
                Button(L("permission.openSettings")) { AudioCapturePermission.openSystemSettings() }
                    .buttonStyle(PillButtonStyle(filled: false))
            }
        case .unknown:
            Button(L("onb.perm.grant")) { model.requestPermission(includingMicrophone: true) }
                .buttonStyle(PillButtonStyle(filled: true))
        }
    }

    // MARK: Illustrations (icon language: nodes, routes, cream and coral)

    @ViewBuilder private func art(_ art: Art) -> some View {
        switch art {
        case .icon: Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 190, height: 190)
        case .sliders: SlidersArt()
        case .route: RouteArt()
        case .boost: BoostArt()
        }
    }

    private var permissionArt: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Brand.cream.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(Brand.cream.opacity(0.18), lineWidth: 1.5))
                .frame(width: 150, height: 150)
                .overlay(Image(systemName: "lock.shield.fill").font(.system(size: 64)).foregroundStyle(Brand.cream))
            if model.permission == .authorized {
                Circle().fill(Brand.coral).frame(width: 46, height: 46)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Brand.graphiteBottom))
                    .overlay(Circle().strokeBorder(Brand.graphiteBottom, lineWidth: 5))
                    .offset(x: 12, y: 12)
            }
        }
        .frame(width: 170, height: 170)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(L("onb.back")) { go(to: page - 1) }
                .buttonStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Brand.cream.opacity(0.65))
                .opacity(page == 0 ? 0 : 1)
                .disabled(page == 0)
                .frame(width: 140, alignment: .leading)
            Spacer()
            HStack(spacing: 8) {
                ForEach(0...lastPage, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Brand.coral : Brand.cream.opacity(0.22))
                        .frame(width: index == page ? 22 : 8, height: 8)
                }
            }
            .animation(.snappy(duration: 0.3), value: page)
            .accessibilityHidden(true)
            Spacer()
            Button(page == lastPage ? L("onb.done") : L("onb.next")) {
                if page == lastPage { finish() } else { go(to: page + 1) }
            }
            // On the last page the permission button is the main action until access is granted.
            .buttonStyle(PillButtonStyle(filled: page != lastPage || model.permission == .authorized))
            .keyboardShortcut(.defaultAction)
            .frame(width: 140, alignment: .trailing)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 30)
        .padding(.top, 8)
    }

    private func go(to target: Int) {
        guard (0...lastPage).contains(target) else { return }
        movingForward = target > page
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.35)) { page = target }
    }
}

// MARK: - Pieces

/// Coral pill (primary) or cream outline (secondary).
private struct PillButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(filled ? Brand.graphiteBottom : Brand.cream)
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
            .background {
                if filled {
                    Capsule().fill(Brand.coral)
                } else {
                    Capsule().strokeBorder(Brand.cream.opacity(0.4), lineWidth: 1.5)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Four vertical sliders: one per app.
private struct SlidersArt: View {
    private let levels: [CGFloat] = [0.85, 0.55, 0.7, 0.3]
    private let trackHeight: CGFloat = 150

    var body: some View {
        HStack(spacing: 44) {
            ForEach(levels.indices, id: \.self) { index in
                VStack(spacing: 14) {
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Brand.cream.opacity(0.14)).frame(width: 9, height: trackHeight)
                        Capsule().fill(Brand.coral).frame(width: 9, height: trackHeight * levels[index])
                        Circle().fill(Brand.cream).frame(width: 26, height: 26)
                            .offset(y: -(trackHeight * levels[index]) + 13)
                    }
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Brand.cream.opacity(index == 0 ? 0.9 : 0.16))
                        .frame(width: 30, height: 30)
                }
            }
        }
    }
}

/// One source routed to two outputs: the icon's own picture, larger.
private struct RouteArt: View {
    var body: some View {
        ZStack {
            curve(to: CGPoint(x: 330, y: 40), color: Brand.coral)
            curve(to: CGPoint(x: 330, y: 160), color: Brand.cream.opacity(0.45))
            node(at: CGPoint(x: 40, y: 100), radius: 24, fill: Brand.cream, symbol: nil)
            node(at: CGPoint(x: 330, y: 40), radius: 30, fill: Brand.coral, symbol: "hifispeaker.fill")
            node(at: CGPoint(x: 330, y: 160), radius: 30, fill: Brand.cream.opacity(0.9), symbol: "headphones")
        }
        .frame(width: 370, height: 200)
    }

    private func curve(to end: CGPoint, color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 40, y: 100))
            path.addCurve(to: end, control1: CGPoint(x: 200, y: 100), control2: CGPoint(x: 180, y: end.y))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
    }

    private func node(at point: CGPoint, radius: CGFloat, fill: Color, symbol: String?) -> some View {
        ZStack {
            Circle().fill(Brand.graphiteBottom).frame(width: radius * 2 + 12, height: radius * 2 + 12)
            Circle().fill(fill).frame(width: radius * 2, height: radius * 2)
            if let symbol {
                Image(systemName: symbol).font(.system(size: radius * 0.8, weight: .semibold))
                    .foregroundStyle(Brand.graphiteBottom)
            }
        }
        .position(point)
    }
}

/// A waveform that swells in the middle: the signal getting a boost.
private struct BoostArt: View {
    private let heights: [CGFloat] = [28, 44, 66, 96, 140, 96, 66, 44, 28]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(abs(index - heights.count / 2) <= 1 ? Brand.coral : Brand.cream.opacity(0.3))
                    .frame(width: 16, height: heights[index])
            }
        }
    }
}
