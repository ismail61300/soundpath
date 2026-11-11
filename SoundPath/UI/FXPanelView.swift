import SwiftUI

/// The FX area that unfolds under an app row: effect cards + action bar.
struct FXPanelView: View {
    let row: AppRow
    let model: MixerModel
    @Environment(\.pinEQ) private var pinEQ
    @State private var showEQ = false
    private var isMaster: Bool { row.id == MixerModel.masterID }

    // The Output row's FX also covers the current output device (sample rate, balance).
    private var outputUID: String { model.system.outputUID }
    private var deviceSettings: DeviceSettings { model.system.deviceSettings[outputUID] }
    private func updateDevice(_ change: (inout DeviceSettings) -> Void) {
        var s = deviceSettings
        change(&s)
        model.system.deviceSettings[outputUID] = s
    }

    var body: some View {
        // 12pt everywhere (card gaps, above the first card, panel edges) keeps the spacing even.
        VStack(spacing: 12) {
            if isMaster, deviceSettings.balanceCard { balanceCard }
            if let od = row.settings.overdrive { overdriveCard(od) }
            if let eq = row.settings.eq { eqCard(eq) }
            if let mb = row.settings.magicBoost { magicBoostCard(mb) }
            actionBar
        }
        // No side or bottom padding: cards line up with the strips' edges, and the panel's own padding closes the bottom.
        .padding(.top, 12)
    }

    // MARK: Cards

    private func card<Trailing: View>(title: String, isOn: Binding<Bool>, onRemove: @escaping () -> Void,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: isOn) { EmptyView() }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
            Spacer(minLength: 8)
            trailing()
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .help(L("fx.remove"))
            .accessibilityLabel(L("fx.remove"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: PanelMetrics.stripRadius, style: .continuous).fill(.background.opacity(0.55)))
    }

    private func overdriveCard(_ od: OverdriveSettings) -> some View {
        card(title: L("fx.overdrive"),
             isOn: Binding(get: { od.enabled }, set: { v in model.update(row) { $0.overdrive?.enabled = v } }),
             onRemove: { model.update(row) { $0.overdrive = nil } }) {
            Picker("", selection: Binding(get: { od.multiplier },
                                          set: { v in model.update(row) { $0.overdrive?.multiplier = v } })) {
                ForEach(Array(OverdriveSettings.range), id: \.self) { Text("\($0)x").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 190)
            .disabled(!od.enabled)
        }
    }

    private func eqCard(_ eq: EQSettings) -> some View {
        card(title: L("fx.eq"),
             isOn: Binding(get: { eq.enabled }, set: { v in model.update(row) { $0.eq?.enabled = v } }),
             onRemove: { model.update(row) { $0.eq = nil } }) {
            Text(L("fx.preset"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            EQPresetPicker(row: row, model: model)
                .frame(minWidth: 90, maxWidth: 160)
            Button { showEQ.toggle() } label: {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(L("fx.openEQ"))
            .accessibilityLabel(L("fx.openEQ"))
            .popover(isPresented: $showEQ, arrowEdge: .trailing) {
                EQPanelView(row: row, model: model, pinned: false) {
                    showEQ = false
                    pinEQ(row.id)
                }
                .localizedEnvironment()
            }
        }
    }

    private func magicBoostCard(_ mb: MagicBoostSettings) -> some View {
        card(title: L("fx.magicBoost"),
             isOn: Binding(get: { mb.enabled }, set: { v in model.update(row) { $0.magicBoost?.enabled = v } }),
             onRemove: { model.update(row) { $0.magicBoost = nil } }) {
            Slider(value: Binding(get: { Double(mb.strength) },
                                  set: { v in model.update(row) { $0.magicBoost?.strength = Float(v) } }),
                   in: 0...1)
                .controlSize(.small)
                .frame(maxWidth: 150)
                .disabled(!mb.enabled)
        }
    }

    /// Sample-rate picker of the current output device (Output row only), shown between Add Effect and Options.
    @ViewBuilder private var sampleRateMenu: some View {
        if isMaster, let device = model.system.device(uid: outputUID) {
            let current = device.id.nominalSampleRate
            Menu {
                ForEach(model.system.availableSampleRates(of: device.id), id: \.self) { rate in
                    Button { model.system.setSampleRate(rate, of: device.id) } label: {
                        if abs(rate - current) < 1 { Label("\(Int(rate)) Hz", systemImage: "checkmark") }
                        else { Text("\(Int(rate)) Hz") }
                    }
                }
            } label: {
                PillLabel(systemImage: nil, title: "\(Int(current)) Hz").fixedSize()
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
            .fixedSize()
            .help(L("dev.sampleRate"))
        }
    }

    private var balanceCard: some View {
        card(title: L("dev.balance"),
             isOn: Binding(get: { deviceSettings.balanceOn }, set: { v in updateDevice { $0.balanceOn = v } }),
             onRemove: { updateDevice { $0.balanceCard = false; $0.balance = 0 } }) {
            Text("L").font(.system(size: 12)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(deviceSettings.balance) },
                                  set: { v in updateDevice { $0.balance = Float(v) } }), in: -1...1)
                .controlSize(.small)
                .frame(maxWidth: 170)
                .disabled(!deviceSettings.balanceOn)
            Text("R").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button(L("fx.overdrive")) { model.update(row) { $0.overdrive = OverdriveSettings() } }
                    .disabled(row.settings.overdrive != nil)
                Button(L("fx.eq")) {
                    model.update(row) { $0.eq = EQSettings() }
                    showEQ = true
                }
                .disabled(row.settings.eq != nil)
                Button(L("fx.magicBoost")) { model.update(row) { $0.magicBoost = MagicBoostSettings() } }
                    .disabled(row.settings.magicBoost != nil)
                if isMaster {
                    Button(L("dev.balance").replacingOccurrences(of: ":", with: "")) { updateDevice { $0.balanceCard = true } }
                        .disabled(deviceSettings.balanceCard)
                }
            } label: {
                PillLabel(systemImage: nil, title: L("fx.add")).fixedSize()
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
            .fixedSize()

            Spacer(minLength: 0)

            sampleRateMenu
        }
        // A bar like the cards: pills (r 15) + 8pt padding = radius 23, concentric with the panel corner.
        .padding(PanelMetrics.containerPadding)
        .background(RoundedRectangle(cornerRadius: PanelMetrics.stripRadius, style: .continuous).fill(.background.opacity(0.55)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Preset menu shared by the FX card and the EQ panel.
struct EQPresetPicker: View {
    let row: AppRow
    let model: MixerModel

    var body: some View {
        let current = model.preset(id: row.settings.eq?.presetID)
        Menu {
            ForEach(model.presets.filter(\.isBuiltIn)) { preset in
                Button(preset.displayName) { model.applyPreset(preset, to: row) }
            }
            let user = model.presets.filter { !$0.isBuiltIn }
            if !user.isEmpty {
                Divider()
                ForEach(user) { preset in
                    Button(preset.displayName) { model.applyPreset(preset, to: row) }
                }
            }
            Divider()
            Button(L("eq.import")) { model.importAutoEQ(applyingTo: row) }
        } label: {
            PillLabel(systemImage: "waveform.path", title: current?.displayName ?? L("fx.custom"))
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
    }
}
