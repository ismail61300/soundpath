import AVFoundation
import Foundation

/// Filter types exposed in the UI (subset of `AVAudioUnitEQFilterType`).
enum EQFilterKind: String, Codable, CaseIterable, Identifiable {
    case peak, lowShelf, highShelf, lowPass, highPass

    var id: String { rawValue }

    var avType: AVAudioUnitEQFilterType {
        switch self {
        case .peak: return .parametric
        case .lowShelf: return .lowShelf
        case .highShelf: return .highShelf
        case .lowPass: return .resonantLowPass
        case .highPass: return .resonantHighPass
        }
    }

    var localizationKey: String { "eq.type.\(rawValue)" }
}

/// One parametric band: frequency (Hz), gain (dB) and Q.
struct EQBand: Codable, Equatable, Hashable {
    var kind: EQFilterKind = .peak
    var frequency: Float
    var gain: Float = 0
    var q: Float = 1.41

    /// `AVAudioUnitEQFilterParameters.bandwidth` is in octaves; convert from Q.
    var bandwidthOctaves: Float {
        let qq = max(0.05, Double(q))
        return Float((2 / log(2)) * asinh(1 / (2 * qq)))
    }

    var frequencyLabel: String {
        frequency >= 1000
            ? (frequency.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(frequency / 1000))k" : String(format: "%.1fk", frequency / 1000))
            : "\(Int(frequency.rounded()))"
    }
}

struct EQSettings: Codable, Equatable {
    static let bandCount = 10
    static let standardFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let gainRange: ClosedRange<Float> = -12...12

    var enabled = true
    var presetID: String? = EQPreset.flat.id
    var preamp: Float = 0
    var bands: [EQBand] = EQSettings.standardFrequencies.map { EQBand(frequency: $0) }

    var isNeutral: Bool { preamp == 0 && bands.allSatisfy { $0.kind == .peak && $0.gain == 0 } }

    mutating func apply(_ preset: EQPreset) {
        presetID = preset.id
        preamp = preset.preamp
        bands = preset.bands
    }
}

struct EQPreset: Codable, Equatable, Identifiable, Hashable {
    let id: String
    var name: String
    var preamp: Float
    var bands: [EQBand]
    /// Built-in presets have a localization key instead of a user-visible name.
    var isBuiltIn: Bool

    static func graphic(_ id: String, _ gains: [Float]) -> EQPreset {
        EQPreset(id: id, name: id, preamp: 0,
                 bands: zip(EQSettings.standardFrequencies, gains).map { EQBand(frequency: $0, gain: $1) },
                 isBuiltIn: true)
    }

    static let flat = graphic("flat", Array(repeating: 0, count: 10))

    /// Classic graphic-EQ curves (32 Hz … 16 kHz).
    static let builtIns: [EQPreset] = [
        flat,
        graphic("acoustic", [5, 4.9, 3.9, 1, 2.1, 1.8, 3.5, 4.1, 3.6, 2.1]),
        graphic("bassBoost", [5.5, 4.3, 3.5, 2.5, 1.3, 0, 0, 0, 0, 0]),
        graphic("bassReduce", [-5.5, -4.3, -3.5, -2.5, -1.3, 0, 0, 0, 0, 0]),
        graphic("classical", [4.8, 3.8, 3, 2.5, -1.5, -1.5, 0, 2.3, 3.3, 3.8]),
        graphic("dance", [3.6, 6.7, 5, 0, 2, 3.7, 5.3, 4.6, 3.6, 0]),
        graphic("deep", [5, 3.5, 1.7, 1, 2.9, 2.5, 1.5, -2.2, -3.6, -4.6]),
        graphic("electronic", [4.3, 3.8, 1.2, 0, -2.2, 2.3, 0.9, 1.3, 4.2, 4.9]),
        graphic("hipHop", [5.1, 4.3, 1.5, 3.1, -1.1, -1.1, 1.5, -0.7, 2, 3]),
        graphic("jazz", [4.1, 3, 1.5, 2.3, -1.6, -1.6, 0, 1.5, 3, 3.8]),
        graphic("loudness", [6, 4.2, 0, 0, -2.1, 0, -1.1, -5.6, 5, 1.2]),
        graphic("lounge", [-3.2, -1.6, -0.6, 1.5, 4.1, 2.6, 0, -1.6, 2.1, 0.9]),
        graphic("piano", [3.2, 2, 0, 2.6, 3.2, 1.6, 3.6, 4.6, 3.2, 3.8]),
        graphic("pop", [-1.7, -1.1, 0, 2.2, 4.1, 4.1, 2.2, 0, -1.1, -1.7]),
        graphic("rnb", [2.7, 7, 5.8, 1.4, -2.3, -1.6, 2.4, 2.7, 3, 3.6]),
        graphic("rock", [5, 4, 3.1, 1.6, -0.6, -1.1, 0.6, 2.6, 3.5, 4.4]),
        graphic("smallSpeakers", [5.5, 4.3, 3.6, 2.6, 1.2, 0, -1.2, -2.4, -3.6, -4.5]),
        graphic("spokenWord", [-3.6, -0.6, 0, 0.6, 3.4, 4.6, 4.9, 4.3, 2.6, 0]),
        graphic("trebleBoost", [0, 0, 0, 0, 0, 1.3, 2.5, 3.5, 4.3, 5.5]),
        graphic("trebleReduce", [0, 0, 0, 0, 0, -1.3, -2.5, -3.5, -4.3, -5.5]),
        graphic("vocalBoost", [-1.5, -3, -3, 1.5, 3.7, 3.7, 3, 1.5, 0, -1.5]),
    ]
}

/// Parses AutoEQ "ParametricEQ.txt" exports (also Equalizer APO format):
/// ```
/// Preamp: -6.4 dB
/// Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
/// Filter 2: ON PK Fc 2600 Hz Gain -3.1 dB Q 2.10
/// ```
enum AutoEQParser {
    static func parse(_ text: String, name: String) -> EQPreset? {
        var preamp: Float = 0
        var bands: [EQBand] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = tokens.first?.lowercased() else { continue }
            if first.hasPrefix("preamp") {
                if let v = tokens.dropFirst().compactMap(Float.init).first(where: \.isFinite) { preamp = v }
                continue
            }
            guard first.hasPrefix("filter"), tokens.contains(where: { $0.uppercased() == "ON" }) else { continue }
            func value(after key: String) -> Float? {
                guard let i = tokens.firstIndex(where: { $0.lowercased() == key }), i + 1 < tokens.count else { return nil }
                return Float(tokens[i + 1]).flatMap { $0.isFinite ? $0 : nil } // "nan" / "inf" parse as Floats
            }
            let typeToken = tokens.first(where: { ["PK", "PEQ", "LSC", "LS", "HSC", "HS", "LP", "LPQ", "HP", "HPQ"].contains($0.uppercased()) })?.uppercased()
            let kind: EQFilterKind
            switch typeToken {
            case "LSC", "LS": kind = .lowShelf
            case "HSC", "HS": kind = .highShelf
            case "LP", "LPQ": kind = .lowPass
            case "HP", "HPQ": kind = .highPass
            case "PK", "PEQ": kind = .peak
            default: continue
            }
            guard let fc = value(after: "fc"), fc > 0 else { continue }
            let gain = value(after: "gain") ?? 0
            let q = value(after: "q") ?? (kind == .peak ? 1.41 : 0.71)
            bands.append(EQBand(kind: kind, frequency: max(20, min(20_000, fc)), gain: max(-24, min(24, gain)),
                                q: max(0.1, min(20, q))))
            if bands.count == EQSettings.bandCount { break }
        }
        guard !bands.isEmpty else { return nil }
        // Pad unused bands with neutral peaks at standard frequencies.
        for f in EQSettings.standardFrequencies where bands.count < EQSettings.bandCount {
            bands.append(EQBand(frequency: f))
        }
        return EQPreset(id: "user.\(UUID().uuidString)", name: name, preamp: max(-24, min(24, preamp)),
                        bands: bands, isBuiltIn: false)
    }
}
