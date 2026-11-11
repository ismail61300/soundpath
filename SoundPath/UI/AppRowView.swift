import SwiftUI

/// One application channel strip: favorite star, icon, vertical volume slider with live meter, mute,
/// and a control row with the redirect picker, Boost and the FX disclosure.
struct AppRowView: View {
    let row: AppRow
    let model: MixerModel
    @Binding var fxOpen: Bool

    var body: some View {
        ChannelStrip(name: row.name, icon: AnyView(appIcon), corner: AnyView(starButton),
                     meter: AnyView(MiniVUMeter(meter: row.meter, active: row.isTapped,
                                                height: PanelMetrics.stripSliderHeight)),
                     volume: volumeBinding, muted: row.settings.muted, muteSymbol: muteSymbol,
                     onMute: { model.toggleMute(row) }, highlighted: fxOpen) {
            HStack(spacing: 3) {
                redirectPicker
                boostButton
                fxButton
            }
        }
        .contentShape(Rectangle())
        .contextMenu { contextMenu }
    }

    private var starButton: some View {
        Button { model.toggleFavorite(row) } label: {
            Image(systemName: row.isFavorite ? "star.fill" : "star")
                .font(.system(size: 12))
                .foregroundStyle(row.isFavorite ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .help(row.isFavorite ? L("row.unfavorite") : L("row.favorite"))
    }

    private var appIcon: some View {
        Image(nsImage: row.icon)
            .resizable()
            .interpolation(.high)
            .saturation(row.isRunning ? 1 : 0)
            .opacity(row.isRunning ? 1 : 0.6)
            .help([row.name, subtitle].compactMap { $0 }.joined(separator: " — "))
            .accessibilityLabel(row.name)
    }

    private var subtitle: String? {
        if !row.isRunning { return L("row.notRunning") }
        return nil
    }

    // MARK: Volume

    private var muteSymbol: String {
        let v = row.settings.volume
        if row.settings.muted || v == 0 { return "speaker.slash.fill" }
        if v < 0.34 { return "speaker.wave.1.fill" }
        if v < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var volumeBinding: Binding<Float> {
        Binding(get: { row.settings.volume }, set: { model.setVolume($0, for: row) })
    }

    // MARK: Redirect audio to

    private var redirectPicker: some View {
        let devices = model.system.visibleOutputDevices
        let selected = devices.first { $0.uid == row.settings.outputDeviceUID }
        return Menu {
            Button { model.setOutputDevice(nil, for: row) } label: {
                if row.settings.outputDeviceUID == nil {
                    Label(L("redirect.none"), systemImage: "checkmark")
                } else {
                    Text(L("redirect.none"))
                }
            }
            Divider()
            ForEach(devices) { device in
                Button { model.setOutputDevice(device.uid, for: row) } label: {
                    if device.uid == row.settings.outputDeviceUID {
                        Label(model.system.displayName(device), systemImage: "checkmark")
                    } else {
                        Text(model.system.displayName(device))
                    }
                }
            }
        } label: {
            PillLabel(systemImage: selected.map { model.system.symbol($0) } ?? "arrow.up",
                      title: selected.map { model.system.displayName($0) }
                          ?? (row.settings.outputDeviceUID == nil ? L("redirect.none") : L("sys.noDevice")),
                      iconOnly: true)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help(L("col.redirect"))
        .accessibilityLabel(L("col.redirect"))
        .accessibilityValue(selected.map { model.system.displayName($0) } ?? L("redirect.none"))
    }

    // MARK: Boost & FX

    private var boostButton: some View {
        let active = row.settings.magicBoostActive
        return Button { model.toggleMagicBoost(row) } label: {
            CircleButtonLabel(systemImage: "dial.high.fill", active: active)
        }
        .buttonStyle(.plain)
        .help(L("row.boost"))
        .accessibilityLabel(L("row.boost"))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var fxButton: some View {
        Button { withAnimation(.snappy(duration: 0.22)) { fxOpen.toggle() } } label: {
            CircleButtonLabel(systemImage: "chevron.right")
                .rotationEffect(.degrees(fxOpen ? 90 : 0))
                .overlay(alignment: .topTrailing) {
                    if row.settings.anyEffectActive {
                        Text(L("col.fx"))
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.tint))
                            .offset(x: 9, y: -6)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(L("row.fx"))
        .accessibilityLabel(L("row.fx"))
    }

    @ViewBuilder private var contextMenu: some View {
        Button(row.isFavorite ? L("row.unfavorite") : L("row.favorite")) { model.toggleFavorite(row) }
        Button(row.settings.muted ? L("row.unmute") : L("row.mute")) { model.toggleMute(row) }
        Divider()
        Button(L("options.resetEffects")) { model.resetEffects(row) }
            .disabled(!row.settings.hasEffects)
        Button(L("options.resetAll")) { model.resetAll(row) }
    }
}
