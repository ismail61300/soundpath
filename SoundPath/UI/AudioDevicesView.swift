import SwiftUI
import Combine
import CoreAudio
import AVFoundation

private let deviceIcons = ["speaker.wave.2.fill", "hifispeaker.fill", "laptopcomputer", "headphones", "airpods",
                           "display", "mic.fill", "music.mic", "pianokeys", "cable.connector", "tv", "waveform"]

/// "Audio Devices" window in the standard macOS layout: a source-list sidebar and a grouped-form
/// detail pane with a segmented control in the toolbar.
struct AudioDevicesView: View {
    let system: SystemAudio
    @State private var selection: String?

    private var selected: AudioDeviceInfo? {
        system.device(uid: selection ?? "") ?? system.allDevices.first
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            if let device = selected {
                DeviceDetail(system: system, device: device)
                    .id(device.uid)
            } else {
                ContentUnavailableView(L("dev.none"), systemImage: "speaker.slash")
            }
        }
        .frame(minWidth: 780, idealWidth: 780, minHeight: 520, idealHeight: 520)
        .appTheme()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { selected?.uid }, set: { selection = $0 })) {
            group(L("dev.inputDevices"), devices: system.allDevices.filter { $0.isInput && !$0.isOutput })
            group(L("dev.outputDevices"), devices: system.allDevices.filter { $0.isOutput && !$0.isInput })
            group(L("dev.ioDevices"), devices: system.allDevices.filter { $0.isInput && $0.isOutput })
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func group(_ title: String, devices: [AudioDeviceInfo]) -> some View {
        if !devices.isEmpty {
            Section(title) {
                ForEach(devices) { device in
                    let hidden = system.settings(for: device).hidden
                    HStack {
                        Label(system.displayName(device), systemImage: system.symbol(device))
                            .lineLimit(1)
                            .opacity(hidden ? 0.5 : 1)
                        Spacer(minLength: 4)
                        Button {
                            var s = system.deviceSettings[device.uid]
                            s.hidden.toggle()
                            system.deviceSettings[device.uid] = s
                        } label: {
                            Image(systemName: hidden ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(hidden ? L("dev.show") : L("dev.hide"))
                    }
                    .tag(device.uid)
                }
            }
        }
    }
}

// MARK: - Detail

private struct DeviceDetail: View {
    let system: SystemAudio
    let device: AudioDeviceInfo
    private var settings: Binding<DeviceSettings> {
        Binding(get: { system.deviceSettings[device.uid] }, set: { system.deviceSettings[device.uid] = $0 })
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: system.symbol(device))
                        .font(.system(size: 22))
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    Text(system.displayName(device))
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                }
                TextField(L("dev.nickname"), text: settings.nickname)
                Picker(L("dev.icon"), selection: Binding(get: { settings.wrappedValue.icon ?? "" },
                                                         set: { settings.wrappedValue.icon = $0.isEmpty ? nil : $0 })) {
                    Text(L("dev.icon.auto")).tag("")
                    Divider()
                    ForEach(deviceIcons, id: \.self) { icon in
                        Label(icon, systemImage: icon).tag(icon)
                    }
                }
            }

            if device.isInput { InputTab(system: system, device: device, settings: settings) }
            if device.isOutput { OutputTab(system: system, device: device, settings: settings) }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared pieces

/// Slider row: leading glyph button, slider and a trailing value, inside a labeled form row.
private struct ChannelPair: View {
    let channels: Int
    @Binding var left: Int
    @Binding var right: Int

    /// A stored channel number can exceed what the device has (e.g. right = 2 on a mono microphone);
    /// show it clamped so the Picker's selection always has a matching tag.
    private func clamped(_ value: Binding<Int>) -> Binding<Int> {
        let count = max(1, channels)
        return Binding(get: { min(max(1, value.wrappedValue), count) },
                       set: { value.wrappedValue = $0 })
    }

    var body: some View {
        Picker(L("dev.leftChannel"), selection: clamped($left)) {
            ForEach(1...max(1, channels), id: \.self) { Text("\($0)").tag($0) }
        }
        Picker(L("dev.rightChannel"), selection: clamped($right)) {
            ForEach(1...max(1, channels), id: \.self) { Text("\($0)").tag($0) }
        }
    }
}

private struct SampleRatePicker: View {
    let system: SystemAudio
    let device: AudioDeviceInfo
    @State private var rate: Double

    init(system: SystemAudio, device: AudioDeviceInfo) {
        self.system = system
        self.device = device
        // Start on the device's real rate so the Picker never has a selection without a matching tag.
        _rate = State(initialValue: device.id.nominalSampleRate)
    }

    var body: some View {
        let rates = system.availableSampleRates(of: device.id)
        Picker(L("dev.sampleRate"), selection: $rate) {
            // Current rate not in the supported list (or unknown): keep a tag for it.
            if !rates.contains(rate) {
                Text(rate > 0 ? "\(Int(rate)) Hz" : "—").tag(rate)
            }
            ForEach(rates, id: \.self) { Text("\(Int($0)) Hz").tag($0) }
        }
        .onChange(of: rate) { _, new in
            if new > 0, abs(new - device.id.nominalSampleRate) > 1 { system.setSampleRate(new, of: device.id) }
        }
        .onAppear { rate = device.id.nominalSampleRate }
    }
}

private func percent(_ v: Float) -> String { Double(v).formatted(.percent.precision(.fractionLength(0))) }

/// Volume row: mute glyph, slider, percentage.
private struct VolumeRow: View {
    let title: String
    let symbol: String
    let mutedSymbol: String
    @Binding var muted: Bool
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let enabled: Bool
    var onMute: () -> Void = {}

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Button {
                    muted.toggle()
                    onMute()
                } label: {
                    Image(systemName: muted ? mutedSymbol : symbol)
                        .foregroundStyle(muted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                Slider(value: value, in: range)
                    .frame(minWidth: 120, maxWidth: 240)
                    .disabled(!enabled)
                Text(percent(Float(value.wrappedValue)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Input

private struct InputTab: View {
    let system: SystemAudio
    let device: AudioDeviceInfo
    @Binding var settings: DeviceSettings
    @State private var volume: Float = 0
    @State private var muted = false
    @State private var level: (left: Float, right: Float) = (0, 0)
    @State private var probe = InputLevelProbe()
    @State private var micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio)
    private let tick = Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()
    private let authTick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    /// Explains why the microphone is in use (the macOS mic indicator lights up while the level is shown).
    private var micStatus: some View {
        let denied = micAuthorized == .denied || micAuthorized == .restricted
        let listening = probe.isRunning && !denied
        return Label {
            Text(denied ? L("dev.level.denied") : (listening ? L("dev.level.live") : L("dev.level.idle")))
        } icon: {
            Image(systemName: denied ? "mic.slash.fill" : "circle.fill")
                .foregroundStyle(denied ? Color.orange : (listening ? Color.green : Color.secondary))
        }
    }

    var body: some View {
        Group {
            Section(L("dev.tab.input")) {
                VolumeRow(title: L("dev.inputVolume"), symbol: "mic.fill", mutedSymbol: "mic.slash.fill",
                          muted: $muted,
                          value: Binding(get: { Double(volume) }, set: {
                              volume = Float($0)
                              system.write(volume: volume, device: device.id, scope: kAudioObjectPropertyScopeInput)
                          }),
                          range: 0...1,
                          enabled: system.readVolume(device.id, scope: kAudioObjectPropertyScopeInput) != nil,
                          onMute: { system.write(mute: muted, device: device.id, scope: kAudioObjectPropertyScopeInput) })
                LabeledContent(L("dev.level")) {
                    LevelBars(left: level.left, right: level.right)
                        .frame(maxWidth: 300)
                }
            }
            Section {
                ChannelPair(channels: device.inChannels, left: $settings.inLeft, right: $settings.inRight)
                SampleRatePicker(system: system, device: device)
            } footer: {
                micStatus
            }
        }
        .onAppear {
            volume = system.readVolume(device.id, scope: kAudioObjectPropertyScopeInput) ?? 0
            muted = system.readMute(device.id, scope: kAudioObjectPropertyScopeInput)
            probe.start(device: device.id, left: settings.inLeft, right: settings.inRight)
        }
        .onDisappear { probe.stop() }
        .onChange(of: settings.inLeft) { _, _ in probe.start(device: device.id, left: settings.inLeft, right: settings.inRight) }
        .onChange(of: settings.inRight) { _, _ in probe.start(device: device.id, left: settings.inLeft, right: settings.inRight) }
        .onReceive(authTick) { _ in
            micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        .onReceive(tick) { _ in
            let new = probe.consumeLevel()
            level = (max(new.left, level.left * 0.8), max(new.right, level.right * 0.8))
        }
    }
}

private struct LevelBars: View {
    let left: Float
    let right: Float
    var body: some View {
        let level = max(left, right)
        let count = 30
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Float(i) / Float(count) < level ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(minWidth: 2, maxWidth: 6, minHeight: 16, maxHeight: 16)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Output

private struct OutputTab: View {
    let system: SystemAudio
    let device: AudioDeviceInfo
    @Binding var settings: DeviceSettings
    @State private var volume: Float = 0
    @State private var muted = false

    var body: some View {
        Group {
            Section(L("dev.tab.output")) {
                VolumeRow(title: L("dev.outputVolume"), symbol: "speaker.wave.3.fill", mutedSymbol: "speaker.slash.fill",
                          muted: $muted,
                          value: Binding(get: { Double(volume) }, set: {
                              volume = min(Float($0), settings.maxVolume)
                              system.write(volume: volume, device: device.id, scope: kAudioObjectPropertyScopeOutput)
                          }),
                          range: 0...1,
                          enabled: system.readVolume(device.id, scope: kAudioObjectPropertyScopeOutput) != nil,
                          onMute: { system.write(mute: muted, device: device.id, scope: kAudioObjectPropertyScopeOutput) })
                VolumeRow(title: L("dev.maxVolume"), symbol: "ear.badge.waveform", mutedSymbol: "ear.badge.waveform",
                          muted: .constant(false),
                          value: Binding(get: { Double(settings.maxVolume) }, set: {
                              settings.maxVolume = Float($0)
                              if volume > settings.maxVolume {
                                  volume = settings.maxVolume
                                  system.write(volume: volume, device: device.id, scope: kAudioObjectPropertyScopeOutput)
                              }
                          }),
                          range: 0.1...1,
                          enabled: true)
                LabeledContent(L("dev.balance")) {
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { Double(settings.balance) }, set: {
                            settings.balance = Float($0)
                            if abs(settings.balance) > 0.02 { settings.balanceCard = true }
                        }), in: -1...1)
                        .frame(minWidth: 120, maxWidth: 240)
                        Text(balanceText)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
            Section {
                ChannelPair(channels: device.outChannels, left: $settings.outLeft, right: $settings.outRight)
                SampleRatePicker(system: system, device: device)
            }
        }
        .onAppear {
            volume = system.readVolume(device.id, scope: kAudioObjectPropertyScopeOutput) ?? 0
            muted = system.readMute(device.id, scope: kAudioObjectPropertyScopeOutput)
        }
    }

    private var balanceText: String {
        let b = settings.balance
        if abs(b) < 0.02 { return L("dev.centered") }
        return "\(b < 0 ? "L" : "R") \(Int(abs(b) * 100))%"
    }
}
