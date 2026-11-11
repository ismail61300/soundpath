import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer stereo ring buffer.
///
/// - Producer: the CoreAudio tap IOProc (realtime thread).
/// - Consumer: the `AVAudioSourceNode` render block (realtime thread).
///
/// All memory is allocated up front in `init`. `write` and `read` never allocate,
/// lock, or touch Swift reference-counted objects (apart from `self`, which callers
/// capture as `unowned(unsafe)`).
final class StereoRingBuffer: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>

    /// Monotonic frame counters. Only the producer stores `written`, only the consumer stores `consumed`.
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)

    /// Consumer-only state (touched solely on the render thread).
    private var primed = false
    /// Frames buffered before playback starts / resumes after an underrun (adjustable at runtime).
    private let targetAtomic: Atomic<Int>
    /// When more than this is buffered (e.g. after a hiccup), skip ahead to keep latency low.
    private let maxAtomic: Atomic<Int>

    init(capacityFrames: Int = 16_384, targetFrames: Int = 1_024, maxFrames: Int = 4_096) {
        var cap = 1
        while cap < capacityFrames { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        targetAtomic = Atomic(targetFrames)
        maxAtomic = Atomic(min(maxFrames, cap))
        left = .allocate(capacity: cap)
        right = .allocate(capacity: cap)
        left.initialize(repeating: 0, count: cap)
        right.initialize(repeating: 0, count: cap)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Changes the prefill target / skip-ahead limit (called from the main thread).
    func setLatency(target: Int, max maxFrames: Int) {
        targetAtomic.store(target, ordering: .relaxed)
        maxAtomic.store(min(maxFrames, capacity), ordering: .relaxed)
    }

    // MARK: Producer (realtime)

    /// Writes `frames` samples. `l`/`r` may point to the same buffer (mono) and use any stride (interleaved).
    @inline(__always)
    func write(l: UnsafePointer<Float>, r: UnsafePointer<Float>, stride: Int, frames: Int) {
        let w = written.load(ordering: .relaxed)
        let c = consumed.load(ordering: .acquiring)
        let free = capacity - (w - c)
        let n = min(frames, free) // drop overflow instead of overwriting unread data
        guard n > 0 else { return }
        var src = 0
        for i in 0..<n {
            let idx = (w + i) & mask
            left[idx] = l[src]
            right[idx] = r[src]
            src += stride
        }
        written.store(w + n, ordering: .releasing)
    }

    // MARK: Consumer (realtime)

    /// Fills `frames` samples into `outL`/`outR`. Missing data is zero-filled.
    /// Returns the number of real (non-padding) frames delivered.
    @inline(__always)
    @discardableResult
    func read(outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let w = written.load(ordering: .acquiring)
        var c = consumed.load(ordering: .relaxed)
        var available = w - c
        let targetFrames = targetAtomic.load(ordering: .relaxed)
        let maxFrames = maxAtomic.load(ordering: .relaxed)

        if !primed {
            guard available >= targetFrames else {
                outL.update(repeating: 0, count: frames)
                outR.update(repeating: 0, count: frames)
                return 0
            }
            primed = true
        }

        if available > maxFrames + frames {
            // Latency crept up – jump forward so we stay close to the target.
            c = w - targetFrames
            available = targetFrames
        }

        let n = min(available, frames)
        for i in 0..<n {
            let idx = (c + i) & mask
            outL[i] = left[idx]
            outR[i] = right[idx]
        }
        if n < frames {
            (outL + n).update(repeating: 0, count: frames - n)
            (outR + n).update(repeating: 0, count: frames - n)
            primed = false // underrun: rebuffer before resuming
        }
        consumed.store(c + n, ordering: .releasing)
        return n
    }

    /// Discards buffered audio. Only call while neither side is running.
    func reset() {
        consumed.store(written.load(ordering: .acquiring), ordering: .releasing)
        primed = false
    }
}
