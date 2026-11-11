import AudioToolbox
import AVFoundation
import CoreAudio
import OSLog

private let log = Logger(subsystem: "com.soundpath.SoundPath", category: "AppAudioChain")

/// Per-application audio chain inside the shared `AVAudioEngine`:
///
/// ```
/// ProcessTap → StereoRingBuffer → AVAudioSourceNode
///   → AVAudioUnitEQ (10 parametric bands, globalGain = preamp)
///   → DynamicsProcessor (Boost: upward compression + makeup gain)
///   → PeakLimiter (preGain = Volume Overdrive up to +12 dB, prevents clipping)
///   → AVAudioMixerNode (per-app volume / mute) → main mixer
/// ```
///
/// All DSP runs inside Apple's Audio Units; our own realtime code is limited to the
/// ring-buffer read and vDSP metering in the source node.
@MainActor
final class AppAudioChain {
    let id: String
    let label: String
    let ring = StereoRingBuffer()
    let meter = LevelMeter()

    private(set) var sourceNode: AVAudioSourceNode!
    let eq = AVAudioUnitEQ(numberOfBands: EQSettings.bandCount)
    let dynamics = AVAudioUnitEffect(audioComponentDescription: .appleEffect(kAudioUnitSubType_DynamicsProcessor))
    let limiter = AVAudioUnitEffect(audioComponentDescription: .appleEffect(kAudioUnitSubType_PeakLimiter))
    let mixer = AVAudioMixerNode()
    /// Insert point for an optional Audio Unit plug-in (between `pre` and the EQ).
    let pre = AVAudioMixerNode()
    let pluginSlot = PluginSlot()

    private(set) var tap: ProcessTap?
    private(set) var format: AVAudioFormat
    private(set) var settings = AppSettings.default
    /// Idle bypass: true while the app delivers digital silence.
    private(set) var isIdle = false

    var isTapping: Bool { tap?.isRunning == true }

    init(id: String, label: String, sampleRate: Double) {
        self.id = id
        self.label = label
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        sourceNode = makeSourceNode(format: format)
        configureStaticParameters()
        updateBypass()
    }

    /// The realtime render block. Captures only unowned(unsafe) references; no allocation.
    private func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        unowned(unsafe) let ring = self.ring
        unowned(unsafe) let meter = self.meter
        return AVAudioSourceNode(format: format) { isSilence, _, frameCount, ablPointer -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPointer)
            let frames = Int(frameCount)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                isSilence.pointee = true
                return noErr
            }
            let delivered = ring.read(outL: l, outR: r, frames: frames)
            if delivered == 0 {
                isSilence.pointee = true
            } else {
                meter.process(l: l, r: r, frames: frames)
            }
            return noErr
        }
    }

    private func configureStaticParameters() {
        // Limiter: fast attack, short release; PreGain is driven by Volume Overdrive.
        limiter.setParameter(kLimiterParam_AttackTime, 0.002)
        limiter.setParameter(kLimiterParam_DecayTime, 0.05)
        limiter.setParameter(kLimiterParam_PreGain, 0)
        // Dynamics: no downward expansion; quick attack, musical release.
        dynamics.setParameter(kDynamicsProcessorParam_ExpansionRatio, 1)
        dynamics.setParameter(kDynamicsProcessorParam_ExpansionThreshold, -100)
        dynamics.setParameter(kDynamicsProcessorParam_AttackTime, 0.002)
        dynamics.setParameter(kDynamicsProcessorParam_ReleaseTime, 0.12)
    }

    // MARK: Engine wiring

    private var effectNodes: [AVAudioNode] { [eq, dynamics, limiter] }

    /// `output` is the node this chain feeds (the host's master bus).
    func attach(to engine: AVAudioEngine, output: AVAudioNode) {
        let chain: [AVAudioNode] = [sourceNode, pre] + effectNodes + [mixer]
        chain.forEach(engine.attach)
        for (a, b) in zip(chain, chain.dropFirst()) {
            engine.connect(a, to: b, format: format)
        }
        engine.connect(mixer, to: output, format: format)
        pluginSlot.bind(engine: engine, head: pre, tail: eq, format: format)
    }

    func detach(from engine: AVAudioEngine) {
        pluginSlot.unbind()
        let chain: [AVAudioNode] = [sourceNode, pre] + effectNodes + [mixer]
        for node in chain {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
    }

    /// Rebuilds the source node for a new sample rate. Must be detached from the engine.
    func setSampleRate(_ rate: Double) {
        guard rate > 0, rate != format.sampleRate else { return }
        format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        sourceNode = makeSourceNode(format: format)
        apply(settings) // band frequencies are clamped against the new Nyquist
    }

    // MARK: Settings → DSP

    func apply(_ s: AppSettings) {
        settings = s
        mixer.outputVolume = s.muted ? 0 : max(0, min(1, s.volume))

        if let e = s.eq {
            let nyquistSafe = Float(format.sampleRate * 0.45)
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
            dynamics.setParameter(kDynamicsProcessorParam_Threshold, -12 - 28 * k) // −12…−40 dB
            dynamics.setParameter(kDynamicsProcessorParam_HeadRoom, 6 - 3 * k)     // harder knee as strength rises
            dynamics.setParameter(kDynamicsProcessorParam_OverallGain, 3 + 12 * k) // makeup +3…+15 dB
        }

        limiter.setParameter(kLimiterParam_PreGain, s.overdriveActive ? (s.overdrive?.gainDB ?? 0) : 0)
        pluginSlot.apply(s.plugin)
        updateBypass()
    }

    func setIdle(_ idle: Bool) {
        guard idle != isIdle else { return }
        isIdle = idle
        updateBypass()
    }

    /// Effects are bypassed when disabled or while the app is silent (idle bypass).
    private func updateBypass() {
        let s = settings
        setBypass(eq, isIdle || !s.eqActive)
        setBypass(dynamics, isIdle || !s.magicBoostActive)
        // The limiter guards any stage that can add gain.
        setBypass(limiter, isIdle || !s.anyEffectActive)
    }

    private func setBypass(_ unit: AVAudioUnitEffect, _ value: Bool) {
        if unit.bypass != value { unit.bypass = value }
    }

    // MARK: Tap lifecycle

    func startTap(processObjects: [AudioObjectID], outputUID: String) throws {
        if let tap {
            try? tap.updateProcesses(processObjects)
            if tap.processObjects == processObjects { return }
            stopTap() // in-place update failed → recreate
        }
        ring.reset()
        let newTap = try ProcessTap(processObjects: processObjects, outputDeviceUID: outputUID,
                                    label: label, ring: ring)
        if newTap.sampleRate > 0, newTap.sampleRate != format.sampleRate {
            log.notice("Tap rate \(newTap.sampleRate) ≠ chain rate \(self.format.sampleRate)")
        }
        tap = newTap
    }

    func stopTap() {
        tap?.invalidate()
        tap = nil
    }
}

extension AudioComponentDescription {
    static func appleEffect(_ subType: OSType) -> AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subType,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0, componentFlagsMask: 0)
    }
}

extension AVAudioUnit {
    /// Sets a global-scope parameter on the underlying AudioUnit (main thread only).
    func setParameter(_ id: AudioUnitParameterID, _ value: Float) {
        AudioUnitSetParameter(audioUnit, id, kAudioUnitScope_Global, 0, value, 0)
    }
}
