import SwiftUI
import CoreAudio

/// The System channel strips (Output, Input): vertical volume slider + device picker each.
/// Laid out by `StripGrid` as the first strips of the panel; the Output FX panel is `FXDetail`.
struct SystemAudioSection: View {
    let system: SystemAudio
    let model: MixerModel
    @Binding var fxOpen: Bool
    @Environment(\.stripWidth) private var stripWidth

    var body: some View {
        HStack(alignment: .top, spacing: PanelMetrics.stripSpacing) {
            row(title: L("sys.output"), icon: "hifispeaker.fill",
                symbol: speakerSymbol(system.outputHasVolume ? system.outputVolume : model.softwareVolume,
                                      muted: system.outputHasVolume ? system.outputMuted : model.softwareMuted),
                muted: system.outputHasVolume ? system.outputMuted : model.softwareMuted,
                onSymbol: {
                    if system.outputHasVolume { system.setOutputMuted(!system.outputMuted) }
                    else { model.toggleSoftwareMute() }
                },
                devices: system.visibleOutputDevices, current: system.outputID, onSelect: system.selectOutput,
                value: outputBinding,
                enabled: true, isMaster: true, meter: .output,
                lead: outputConnection)
            row(title: L("sys.input"), icon: "mic.fill",
                symbol: system.inputMuted ? "mic.slash.fill" : "mic.fill",
                muted: system.inputMuted, onSymbol: { system.setInputMuted(!system.inputMuted) },
                devices: system.visibleInputDevices, current: system.inputID, onSelect: system.selectInput,
                value: Binding(get: { system.inputVolume }, set: { system.setInputVolume($0) }),
                enabled: system.inputHasVolume, meter: model.inputMeterLive ? .input : .hatched,
                lead: inputUsage)
        }
    }

    /// Output FX (master chain) panel, shown under the first row while open.
    var fxDetail: some View {
        Collapsible(isOpen: fxOpen) { FXPanelView(row: model.masterRow, model: model) }
    }

    private func row(title: String, icon: String, symbol: String, muted: Bool, onSymbol: (() -> Void)?,
                     devices: [AudioDeviceInfo], current: AudioObjectID, onSelect: @escaping (AudioDeviceInfo) -> Void,
                     value: Binding<Float>, enabled: Bool, isMaster: Bool = false, meter: LeadMeter = .empty,
                     lead: LeadBadge = .none) -> some View {
        ChannelStrip(name: title,
                     icon: AnyView(Image(systemName: icon).font(.system(size: 17)).help(title).accessibilityLabel(title)),
                     corner: AnyView(leadBadge(lead)), meter: AnyView(leadPill(meter)),
                     volume: value, enabled: enabled, noVolumeHelp: L("sys.noVolume"),
                     muted: muted, muteSymbol: symbol, onMute: onSymbol,
                     highlighted: isMaster && fxOpen) {
            HStack(spacing: 3) {
                DevicePicker(system: system, devices: devices, current: current, onSelect: onSelect)
                if isMaster {
                    masterBoostButton
                    masterFXButton
                }
            }
        }
        .frame(width: stripWidth)
    }

    /// Hardware volume when the device has it, otherwise the software master volume.
    private var outputBinding: Binding<Float> {
        if system.outputHasVolume {
            return Binding(get: { system.outputVolume }, set: { system.setOutputVolume($0) })
        }
        return Binding(get: { model.softwareVolume }, set: { model.setSoftwareVolume($0) })
    }

    enum LeadBadge { case none, symbol(String, help: String), dot(Color, help: String), hatchedDot }

    /// Output: connection type of the current device.
    private var outputConnection: LeadBadge {
        guard let device = system.device(uid: system.outputUID) else { return .none }
        let c = device.connection
        return .symbol(c.symbol, help: c.name)
    }

    /// Input: who is using the microphone (filled dot + names), hatched dot when nobody is.
    private var inputUsage: LeadBadge {
        let users = model.inputUserNames
        if users.isEmpty && !model.inputMeterLive { return .hatchedDot }
        return .dot(.orange, help: users.isEmpty ? L("sys.inUse") : L("sys.inUseBy", users.joined(separator: ", ")))
    }

    @ViewBuilder
    private func leadBadge(_ badge: LeadBadge) -> some View {
        Group {
            switch badge {
            case .none:
                Color.clear
            case .symbol(let name, let help):
                Image(systemName: name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(help)
            case .dot(let color, let help):
                Circle().fill(color).frame(width: 8, height: 8).help(help)
            case .hatchedDot:
                Canvas { context, size in
                    let shape = Path(ellipseIn: CGRect(origin: .zero, size: size))
                    context.clip(to: shape)
                    context.fill(shape, with: .color(Color.primary.opacity(0.06)))
                    var x: CGFloat = -size.height
                    while x < size.width {
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: size.height))
                        line.addLine(to: CGPoint(x: x + size.height, y: 0))
                        context.stroke(line, with: .color(Color.primary.opacity(0.35)), lineWidth: 1)
                        x += 3
                    }
                    context.stroke(shape, with: .color(Color.primary.opacity(0.25)), lineWidth: 0.5)
                }
                .frame(width: 8, height: 8)
            }
        }
        .frame(width: PanelMetrics.starWidth, height: 16)
        .accessibilityHidden(true)
    }

    enum LeadMeter { case output, input, hatched, empty }

    @ViewBuilder
    private func leadPill(_ kind: LeadMeter) -> some View {
        switch kind {
        case .output:
            MiniVUMeter(meter: model.outputMeter, active: true, height: PanelMetrics.stripSliderHeight)
        case .input:
            MiniVUMeter(meter: model.inputMeter, active: true, height: PanelMetrics.stripSliderHeight)
        case .hatched:
            // Same two-bar shape as the live meter, each bar hatched (microphone idle).
            Canvas { context, size in
                let gap: CGFloat = 1.5
                let w = (size.width - gap) / 2
                for x in [CGFloat(0), w + gap] {
                    var layer = context
                    let shape = Path(roundedRect: CGRect(x: x, y: 0, width: w, height: size.height), cornerRadius: w / 2)
                    layer.clip(to: shape)
                    layer.fill(shape, with: .color(Color.primary.opacity(0.06)))
                    var lx = x - size.height
                    while lx < x + w {
                        var line = Path()
                        line.move(to: CGPoint(x: lx, y: size.height))
                        line.addLine(to: CGPoint(x: lx + size.height, y: 0))
                        layer.stroke(line, with: .color(Color.primary.opacity(0.25)), lineWidth: 1)
                        lx += 4
                    }
                }
            }
            .frame(width: PanelMetrics.meterWidth, height: PanelMetrics.stripSliderHeight)
            .accessibilityHidden(true)
        case .empty:
            // Two empty bars, same shape as the live meter.
            Canvas { context, size in
                let gap: CGFloat = 1.5
                let w = (size.width - gap) / 2
                for x in [CGFloat(0), w + gap] {
                    let bar = Path(roundedRect: CGRect(x: x, y: 0, width: w, height: size.height), cornerRadius: w / 2)
                    context.fill(bar, with: .color(Color.primary.opacity(0.1)))
                }
            }
            .frame(width: PanelMetrics.meterWidth, height: PanelMetrics.stripSliderHeight)
            .accessibilityHidden(true)
        }
    }

    // MARK: Output FX (master chain)

    private var masterBoostButton: some View {
        let active = model.masterRow.settings.magicBoostActive
        return Button { model.toggleMagicBoost(model.masterRow) } label: {
            CircleButtonLabel(systemImage: "dial.high.fill", active: active)
        }
        .buttonStyle(.plain)
        .help(L("row.boost"))
        .accessibilityLabel(L("row.boost"))
    }

    private var masterFXButton: some View {
        Button { withAnimation(.snappy(duration: 0.22)) { fxOpen.toggle() } } label: {
            CircleButtonLabel(systemImage: "chevron.right")
                .rotationEffect(.degrees(fxOpen ? 90 : 0))
                .overlay(alignment: .topTrailing) {
                    if model.masterRow.settings.anyEffectActive {
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

    private func speakerSymbol(_ v: Float, muted: Bool) -> String {
        if muted || v == 0 { return "speaker.slash.fill" }
        if v < 0.34 { return "speaker.wave.1.fill" }
        if v < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

private struct DevicePicker: View {
    let system: SystemAudio
    let devices: [AudioDeviceInfo]
    let current: AudioObjectID
    let onSelect: (AudioDeviceInfo) -> Void

    private var currentDevice: AudioDeviceInfo? { devices.first { $0.id == current } }

    var body: some View {
        Menu {
            ForEach(devices) { device in
                Button { onSelect(device) } label: {
                    if device.id == current {
                        Label(system.displayName(device), systemImage: "checkmark")
                    } else {
                        Text(system.displayName(device))
                    }
                }
            }
        } label: {
            PillLabel(systemImage: currentDevice.map { system.symbol($0) } ?? "hifispeaker.fill",
                      title: currentDevice.map { system.displayName($0) } ?? L("sys.noDevice"),
                      iconOnly: true)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(currentDevice.map { system.displayName($0) } ?? L("sys.noDevice"))
    }

}

/// Best-effort SF Symbol for an audio device, from its name.
enum DeviceSymbol {
    static func name(for name: String?) -> String {
        let n = (name ?? "").lowercased()
        if n.contains("airpods") { return "airpods" }
        if n.contains("macbook") || n.contains("built-in") || n.contains("imac") { return "laptopcomputer" }
        if n.contains("display") || n.contains("hdmi") || n.contains("monitor") { return "display" }
        if n.contains("headphone") || n.contains("headset") || n.contains("buds") { return "headphones" }
        if n.contains("micro") || n.contains("mic") { return "mic.fill" }
        return "hifispeaker.fill"
    }
}
