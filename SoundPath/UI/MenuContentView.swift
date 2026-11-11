import SwiftUI
import AppKit

/// Menu bar panel: header toolbar, a "System" card and an "Applications" card of vertical channel
/// strips wrapped into rows of 3...5 (Settings), per-strip FX disclosure. Uses only system
/// colours/materials, so it follows the user's accent colour, light/dark mode and (on macOS 26) Liquid Glass.
struct MenuContentView: View {
    let model: MixerModel
    @Bindable private var localizer = Localizer.shared
    @Environment(\.openSettingsWindow) private var openSettings
    @Environment(\.openAudioDevicesWindow) private var openDevices
    @AppStorage(PrefKey.stripColumns) private var storedColumns = 4
    /// The one FX panel that is open (accordion): an app's id, or `Self.outputFXID` for the Output strip.
    @State private var openFXID: String?
    private static let outputFXID = "__output__"

    private var maxContentHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 160 }
    /// Narrowest panel the open FX panel fits in: the EQ card (~370pt) and Overdrive card are the widest; cards span the full content width.
    private var fxMinWidth: CGFloat {
        guard let id = openFXID else { return 0 }
        let settings = id == Self.outputFXID ? model.masterRow.settings : model.rows.first { $0.id == id }?.settings
        return settings?.eq != nil ? 396 : settings?.overdrive != nil ? 376 : 316
    }
    private var panelWidth: CGFloat {
        let fit = PanelMetrics.panelWidth(columns: columns, divider: !model.rows.isEmpty)
        return max(fit, fxMinWidth)
    }
    /// Strips share the panel's width equally, so a panel widened for FX has no empty gap beside them.
    private var stripWidth: CGFloat {
        let divider = model.rows.isEmpty ? 0 : PanelMetrics.stripSpacing + 1
        let gaps = CGFloat(columns - 1) * PanelMetrics.stripSpacing
        return ((panelWidth - 2 * PanelMetrics.panelPadding - divider - gaps) / CGFloat(columns)).rounded(.down)
    }
    private var maxColumns: Int { min(5, max(3, storedColumns)) }
    /// The panel grows with the content: 2 System strips alone, then +1 per app until the setting's width, then it wraps down.
    private var columns: Int { min(maxColumns, 2 + model.rows.count) }

    var body: some View {
        VStack(spacing: 12) {
            header

            if model.permission != .authorized {
                PermissionBanner(model: model)
            }

            mixerCard

            if let error = model.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .padding(PanelMetrics.panelPadding)
        .frame(width: panelWidth)
        // Drop an .app on the panel to add it as a favorite (also works for apps that aren't playing).
        .dropDestination(for: URL.self) { urls, _ in
            var added = false
            for url in urls where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                model.addFavorite(bundleID: id, name: name)
                added = true
            }
            return added
        }
    }

    // MARK: Header (title · pin · settings)

    private var header: some View {
        // Glyph-to-glyph gaps are equal (button frames have different internal padding): 10 + 8.5 = 2 + 8.5 + 7.5.
        HStack(spacing: 0) {
            Text("SoundPath")
                .font(.system(size: 17, weight: .semibold))
                .padding(.leading, 12)
            Spacer()
            HeaderIconButton(systemImage: model.panelPinned ? "pin.fill" : "pin",
                             help: model.panelPinned ? L("header.unpinPanel") : L("header.pin"),
                             isActive: model.panelPinned, large: true, glyph: 13) {
                model.panelPinned.toggle()
            }
            Menu {
                if case .available(let version, let url) = UpdateChecker.shared.state {
                    Button(L("set.update.available", version)) { NSWorkspace.shared.open(url) }
                    Divider()
                }
                Button(L("set.openMenu")) { openSettings() }
                    .keyboardShortcut(",")
                Button(L("menu.permissions")) { AudioCapturePermission.openSystemSettings() }
                Divider()
                Button(L("dev.menu")) { openDevices() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Picker(L("menu.language"), selection: $localizer.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang == .system ? L("menu.language.system") : lang.nativeName).tag(lang)
                    }
                }
                Divider()
                Menu(L("menu.help")) {
                    Button(L("menu.github")) { Self.open("https://github.com/ismail61300/soundpath") }
                    Button(L("menu.reportIssue")) { Self.open("https://github.com/ismail61300/soundpath/issues") }
                }
                Button(L("menu.about")) {
                    NSApp.activate()
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                Button(L("menu.quit")) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: PanelMetrics.headerGlyph, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: PanelMetrics.headerButtonWidth, height: PanelMetrics.headerButtonHeight)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .padding(.leading, 2)
            .padding(.trailing, 5)
            .help(L("menu.settings"))
        }
        .padding(.top, 2)
    }

    // MARK: Mixer (System strips | Applications strips, directly on the panel)

    private var mixerCard: some View {
        VStack(spacing: 0) {
            ScrollView {
                let system = SystemAudioSection(system: model.system, model: model, fxOpen: fxBinding(Self.outputFXID))
                StripGrid(items: model.rows, columns: columns, leadingCount: 2) {
                    system
                } leadingDetail: {
                    system.fxDetail
                } strip: { row in
                    AppRowView(row: row, model: model, fxOpen: fxBinding(row.id))
                } detail: { row in
                    Collapsible(isOpen: openFXID == row.id) {
                        FXPanelView(row: row, model: model)
                    }
                }
            }
            // Scrolls only when the content is taller than the screen allows.
            .environment(\.stripWidth, stripWidth)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: maxContentHeight)
            .fixedSize(horizontal: false, vertical: true)

            if model.rows.isEmpty { emptyState }
        }
    }

    private func fxBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { openFXID == id },
                set: { if $0 { openFXID = id } else if openFXID == id { openFXID = nil } })
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.zzz")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(L("empty.title"))
                .font(.system(size: 12, weight: .medium))
            Text(L("empty.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

private struct PermissionBanner: View {
    let model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("permission.title"), systemImage: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
            Text(L(model.permission == .denied ? "permission.denied" : "permission.body"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if model.permission == .denied {
                    Button(L("permission.openSettings")) { AudioCapturePermission.openSystemSettings() }
                } else {
                    Button(L("permission.grant")) { model.requestPermission() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: PanelMetrics.stripRadius, style: .continuous).fill(.tint.opacity(0.12)))
    }
}
