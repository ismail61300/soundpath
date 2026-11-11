import Accelerate
import Darwin
import Synchronization

/// Realtime-safe level meter. The audio thread publishes peak/RMS as atomic bit patterns;
/// the UI polls them at a low frame rate. Also tracks the last time real signal was seen
/// (used for idle bypass).
final class LevelMeter: @unchecked Sendable {
    private let peakL = Atomic<UInt32>(0)
    private let peakR = Atomic<UInt32>(0)
    private let rmsL = Atomic<UInt32>(0)
    private let rmsR = Atomic<UInt32>(0)
    private let lastSignalHostTime = Atomic<UInt64>(0)

    /// Anything below this (≈ -100 dBFS) counts as digital silence.
    static let silenceThreshold: Float = 1e-5

    // MARK: Audio thread

    @inline(__always)
    func process(l: UnsafePointer<Float>, r: UnsafePointer<Float>, frames: Int) {
        process(l: l, strideL: 1, r: r, strideR: 1, frames: frames)
    }

    /// Strided variant for interleaved device buffers.
    @inline(__always)
    func process(l: UnsafePointer<Float>, strideL: Int, r: UnsafePointer<Float>, strideR: Int, frames: Int) {
        guard frames > 0 else { return }
        let n = vDSP_Length(frames)
        var pl: Float = 0, pr: Float = 0, ql: Float = 0, qr: Float = 0
        vDSP_maxmgv(l, vDSP_Stride(strideL), &pl, n)
        vDSP_maxmgv(r, vDSP_Stride(strideR), &pr, n)
        vDSP_rmsqv(l, vDSP_Stride(strideL), &ql, n)
        vDSP_rmsqv(r, vDSP_Stride(strideR), &qr, n)
        // Hold the max until the UI consumes it.
        if pl > Float(bitPattern: peakL.load(ordering: .relaxed)) { peakL.store(pl.bitPattern, ordering: .relaxed) }
        if pr > Float(bitPattern: peakR.load(ordering: .relaxed)) { peakR.store(pr.bitPattern, ordering: .relaxed) }
        if ql > Float(bitPattern: rmsL.load(ordering: .relaxed)) { rmsL.store(ql.bitPattern, ordering: .relaxed) }
        if qr > Float(bitPattern: rmsR.load(ordering: .relaxed)) { rmsR.store(qr.bitPattern, ordering: .relaxed) }
        if pl > Self.silenceThreshold || pr > Self.silenceThreshold {
            lastSignalHostTime.store(mach_absolute_time(), ordering: .relaxed)
        }
    }

    /// Marks signal without measuring (used by the tap side to keep idle detection honest).
    @inline(__always)
    func markSignal() {
        lastSignalHostTime.store(mach_absolute_time(), ordering: .relaxed)
    }

    // MARK: UI thread

    struct Reading: Equatable {
        var peakL: Float = 0, peakR: Float = 0, rmsL: Float = 0, rmsR: Float = 0
        static let zero = Reading()
    }

    /// Returns the values accumulated since the last call and resets them.
    func consume() -> Reading {
        Reading(peakL: Float(bitPattern: peakL.exchange(0, ordering: .relaxed)),
                peakR: Float(bitPattern: peakR.exchange(0, ordering: .relaxed)),
                rmsL: Float(bitPattern: rmsL.exchange(0, ordering: .relaxed)),
                rmsR: Float(bitPattern: rmsR.exchange(0, ordering: .relaxed)))
    }

    /// Seconds since a non-silent buffer was last observed (`.infinity` if never).
    func secondsSinceSignal() -> Double {
        let last = lastSignalHostTime.load(ordering: .relaxed)
        guard last > 0 else { return .infinity }
        return HostClock.seconds(from: last, to: mach_absolute_time())
    }
}

enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        guard end > start else { return 0 }
        let nanos = Double(end - start) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000_000
    }
}
