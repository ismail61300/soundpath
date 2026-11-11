import AVFoundation
import CoreAudio

/// Live level of one input device (for the Audio Devices window). Reads the device directly with an
/// IOProc, so it needs microphone permission. Realtime-safe: the IOProc only runs vDSP into atomics.
@MainActor
final class InputLevelProbe {
    private let meter = LevelMeter()
    private(set) var device: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    /// `left` / `right` are 1-based channel numbers.
    func start(device: AudioObjectID, left: Int, right: Int) {
        stop()
        guard device.isValid else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.begin(device: device, left: left, right: right) } }
        }
    }

    private func begin(device: AudioObjectID, left: Int, right: Int) {
        guard !isRunning else { return }
        let meter = self.meter
        let l = max(0, left - 1), r = max(0, right - 1)
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, inInput, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            guard list.count > 0 else { return }
            // Find the buffer(s) holding channels l and r (channels are numbered across all buffers).
            var base = 0
            var lp: UnsafePointer<Float>?, rp: UnsafePointer<Float>?
            var ls = 1, rs = 1, frames = 0
            for buffer in list {
                let ch = Int(buffer.mNumberChannels)
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), ch > 0 else { base += ch; continue }
                let n = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * ch)
                if l >= base, l < base + ch { lp = UnsafePointer(data + (l - base)); ls = ch; frames = n }
                if r >= base, r < base + ch { rp = UnsafePointer(data + (r - base)); rs = ch; frames = max(frames, n) }
                base += ch
            }
            guard let lp else { return }
            meter.process(l: lp, strideL: ls, r: rp ?? lp, strideR: rp == nil ? ls : rs, frames: frames)
        }
        guard status == noErr, let proc else { return }
        guard AudioDeviceStart(device, proc) == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            return
        }
        self.device = device
        procID = proc
        isRunning = true
    }

    func stop() {
        if isRunning, let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        procID = nil
        isRunning = false
        device = .unknown
    }

    /// Raw peak/RMS since the last call (linear amplitude).
    func consumeReading() -> LevelMeter.Reading { meter.consume() }

    /// Peak since the last call, 0…1 on a −60…0 dBFS scale.
    func consumeLevel() -> (left: Float, right: Float) {
        let reading = meter.consume()
        return (Self.normalize(reading.peakL), Self.normalize(reading.peakR))
    }

    private static func normalize(_ amplitude: Float) -> Float {
        guard amplitude > 0.001 else { return 0 }
        return max(0, min(1, (20 * log10(amplitude) + 60) / 60))
    }
}
