import SwiftUI

/// 10-band parametric EQ panel: preamp + 10 vertical gain sliders. Clicking a frequency label
/// opens a band editor (type, frequency, Q, gain). Used as a popover and as a pinned window.
struct EQPanelView: View {
    let row: AppRow
    let model: MixerModel
    let pinned: Bool
    var onPin: () -> Void = {}

    @Environment(\.unpinEQ) private var unpinEQ
    @State private var editingBand: Int?
    @State private var showSave = false
    @State private var presetName = ""

    private var eq: EQSettings { row.settings.eq ?? EQSettings() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sliders
            footer
        }
        .padding(14)
        .frame(width: 560)
        .alert(L("eq.saveTitle"), isPresented: $showSave) {
            TextField(L("eq.presetName"), text: $presetName)
            Button(L("common.save")) {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                if let current = model.preset(id: eq.presetID), !current.isBuiltIn {
                    model.renamePreset(current, to: name)   // pencil on a saved preset renames it
                } else {
                    model.saveCurrentEQ(of: row, as: name)
                }
            }
            .keyboardShortcut(.defaultAction)
            Button(L("common.cancel"), role: .cancel) {}
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            HeaderIconButton(systemImage: pinned ? "pin.fill" : "pin",
                             help: pinned ? L("header.unpin") : L("header.pin"), isActive: pinned) {
                if pinned { unpinEQ(row.id) } else { onPin() }
            }
            Image(nsImage: row.icon).resizable().frame(width: 18, height: 18)
            Text(L("eq.title")).font(.headline)
            Button {
                let current = model.preset(id: eq.presetID)
                presetName = (current?.isBuiltIn ?? true) ? "" : (current?.name ?? "")
                showSave = true
            } label: {
                Image(systemName: "pencil").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("eq.save"))
            Text(row.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Toggle(isOn: Binding(get: { eq.enabled }, set: { v in mutate { $0.enabled = v } })) { EmptyView() }
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    // MARK: Sliders

    private var sliders: some View {
        HStack(alignment: .top, spacing: 0) {
            bandColumn(title: L("eq.preamp"), value: eq.preamp, editable: false,
                       binding: Binding(get: { eq.preamp }, set: { v in mutate { $0.preamp = v; $0.presetID = nil } }))
                .frame(width: 52)

            scale

            ForEach(0..<EQSettings.bandCount, id: \.self) { i in
                let band = eq.bands[i]
                bandColumn(title: band.frequencyLabel + "Hz", value: band.gain, editable: true, index: i,
                           binding: Binding(get: { eq.bands[i].gain },
                                            set: { v in mutate { $0.bands[i].gain = v; $0.presetID = nil } }))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 210)
        .disabled(!eq.enabled)
        .opacity(eq.enabled ? 1 : 0.5)
    }

    private var scale: some View {
        VStack(alignment: .trailing) {
            ForEach(["+12", "+6", "0", "-6", "-12"], id: \.self) { label in
                Text(label + " dB")
                if label != "-12" { Spacer() }
            }
        }
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.top, 22)
        .padding(.bottom, 26)
        .frame(width: 40)
    }

    private func bandColumn(title: String, value: Float, editable: Bool, index: Int = -1,
                            binding: Binding<Float>) -> some View {
        VStack(spacing: 6) {
            Group {
                if editable {
                    Button(title) { editingBand = index }
                        .buttonStyle(.plain)
                        .popover(isPresented: Binding(get: { editingBand == index },
                                                      set: { if !$0 { editingBand = nil } })) {
                            BandEditor(band: Binding(get: { eq.bands[index] },
                                                     set: { b in mutate { $0.bands[index] = b; $0.presetID = nil } }))
                                .localizedEnvironment()
                        }
                        .help(L("eq.band.freq"))
                } else {
                    Text(title)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(editable && eq.bands[index].kind != .peak ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .frame(height: 14)

            VerticalSlider(value: binding, range: EQSettings.gainRange)

            Text(String(format: "%.1f", value))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(height: 14)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(L("fx.preset")).font(.system(size: 11)).foregroundStyle(.secondary)
            EQPresetPicker(row: row, model: model).frame(width: 190)
            Spacer()
            Menu {
                Button(L("eq.save")) { presetName = ""; showSave = true }
                Button(L("eq.import")) { model.importAutoEQ(applyingTo: row) }
                if let p = model.preset(id: eq.presetID), !p.isBuiltIn {
                    Button(L("eq.delete"), role: .destructive) { model.deletePreset(p) }
                }
                Divider()
                Button(L("eq.reset")) { model.applyPreset(.flat, to: row) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.small)
    }

    private func mutate(_ change: (inout EQSettings) -> Void) {
        model.update(row) {
            var e = $0.eq ?? EQSettings()
            change(&e)
            $0.eq = e
        }
    }
}

/// Edits one parametric band.
private struct BandEditor: View {
    @Binding var band: EQBand

    var body: some View {
        Form {
            Picker(L("eq.band.type"), selection: $band.kind) {
                ForEach(EQFilterKind.allCases) { Text(L($0.localizationKey)).tag($0) }
            }
            LabeledContent(L("eq.band.freq")) {
                HStack {
                    TextField("", value: $band.frequency, format: .number.precision(.fractionLength(0)))
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text("Hz").foregroundStyle(.secondary)
                    Stepper("", value: $band.frequency, in: 20...20000, step: band.frequency < 1000 ? 5 : 100)
                        .labelsHidden()
                }
            }
            LabeledContent(L("eq.band.q")) {
                HStack {
                    Slider(value: $band.q, in: 0.1...10).frame(width: 120)
                    Text(String(format: "%.2f", band.q)).monospacedDigit().frame(width: 36)
                }
            }
            LabeledContent(L("eq.band.gain")) {
                HStack {
                    Slider(value: $band.gain, in: EQSettings.gainRange).frame(width: 120)
                    Text(String(format: "%+.1f dB", band.gain)).monospacedDigit().frame(width: 56)
                }
            }
            .disabled(band.kind == .lowPass || band.kind == .highPass)
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .controlSize(.small)
        .onChange(of: band.frequency) { _, f in
            if f < 20 || f > 20000 { band.frequency = min(20000, max(20, f)) }
        }
    }
}
