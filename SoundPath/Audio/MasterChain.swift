import AVFoundation
import AudioToolbox

/// Master effect chain that every per-app mixer feeds into:
/// `bus → EQ → DynamicsProcessor (Boost) → PeakLimiter (Overdrive) → main mixer`.
/// This is the "Output" FX of the System card; it affects everything SoundPath routes.
@MainActor
final class MasterChain {
    let bus = AVAudioMixerNode()
    /// Insert point for an optional Audio Unit plug-in (between the bus and the EQ).
    let pluginSlot = PluginSlot()
    let eq = AVAudioUnitEQ(numberOfBands: EQSettings.bandCount)
    let dynamics = AVAudioUnitEffect(audioComponentDescription: .appleEffect(kAudioUnitSubType_DynamicsProcessor))
    let limiter = AVAudioUnitEffect(audioComponentDescription: .appleEffect(kAudioUnitSubType_PeakLimiter))
    /// Last stage; its `pan` implements the per-device balance.
    let trim = AVAudioMixerNode()
    private(set) var settings = AppSettings.default
    private var sampleRate: Double = 48_000
    private var volume: Float = 1

    init() {
        limiter.setParameter(kLimiterParam_AttackTime, 0.002)
        limiter.setParameter(kLimiterParam_DecayTime, 0.05)
        limiter.setParameter(kLimiterParam_PreGain, 0)
        dynamics.setParameter(kDynamicsProcessorParam_ExpansionRatio, 1)
        dynamics.setParameter(kDynamicsProcessorParam_ExpansionThreshold, -100)
        dynamics.setParameter(kDynamicsProcessorParam_AttackTime, 0.002)
        dynamics.setParameter(kDynamicsProcessorParam_ReleaseTime, 0.12)
    }

    private var nodes: [AVAudioNode] { [bus, eq, dynamics, limiter, trim] }

    func attach(to engine: AVAudioEngine, format: AVAudioFormat) {
        sampleRate = format.sampleRate
        nodes.forEach(engine.attach)
        for (a, b) in zip(nodes, nodes.dropFirst()) { engine.connect(a, to: b, format: format) }
        engine.connect(trim, to: engine.mainMixerNode, format: format)
        pluginSlot.bind(engine: engine, head: bus, tail: eq, format: format)
        bus.outputVolume = volume
        apply(settings)
    }

    /// Feeds `meter` with the master output level (non-realtime tap; only installed while a panel is visible).
    func installMeterTap(_ meter: LevelMeter) {
        trim.removeTap(onBus: 0)
        trim.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let left = UnsafePointer<Float>(data[0])
            let right = buffer.format.channelCount > 1 ? UnsafePointer<Float>(data[1]) : left
            meter.process(l: left, r: right, frames: Int(buffer.frameLength))
        }
    }

    func removeMeterTap() { trim.removeTap(onBus: 0) }

    /// Left/right balance, -1…1.
    func setBalance(_ value: Float) { trim.pan = max(-1, min(1, value)) }

    /// Software master volume (used when the output device has no hardware volume).
    func setVolume(_ value: Float) {
        volume = max(0, min(1, value))
        bus.outputVolume = volume
    }

    func detach(from engine: AVAudioEngine) {
        pluginSlot.unbind()
        for node in nodes {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
    }

    func apply(_ s: AppSettings) {
        settings = s
        if let e = s.eq {
            let nyquistSafe = Float(sampleRate * 0.45)
            for (i, band) in e.bands.prefix(eq.bands.count).enumerated() {
                let p = eq.bands[i]
                p.filterType = band.kind.avType
                p.frequency = max(20, min(nyquistSafe, band.frequency))
                p.gain = max(-24, min(24, band.gain))
                p.bandwidth = max(0.05, min(5, band.bandwidthOctaves))
                p.bypass = false
            }
            eq.globalGain = max(-24, min(24, e.preamp))
        }
        if let b = s.magicBoost {
            let k = max(0, min(1, b.strength))
            dynamics.setParameter(kDynamicsProcessorParam_Threshold, -12 - 28 * k)
            dynamics.setParameter(kDynamicsProcessorParam_HeadRoom, 6 - 3 * k)
            dynamics.setParameter(kDynamicsProcessorParam_OverallGain, 3 + 12 * k)
        }
        limiter.setParameter(kLimiterParam_PreGain, s.overdriveActive ? (s.overdrive?.gainDB ?? 0) : 0)
        pluginSlot.apply(s.plugin)
        setBypass(eq, !s.eqActive)
        setBypass(dynamics, !s.magicBoostActive)
        setBypass(limiter, !s.anyEffectActive)
    }

    private func setBypass(_ unit: AVAudioUnitEffect, _ value: Bool) {
        if unit.bypass != value { unit.bypass = value }
    }
}
