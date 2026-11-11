import CoreAudio
import Foundation
import OSLog

private let log = Logger(subsystem: "com.soundpath.SoundPath", category: "ProcessTap")

/// Captures the audio of one or more process objects with a CoreAudio process tap,
/// mutes their original output, and pushes the captured stereo signal into a ring buffer.
///
/// Topology:
/// ```
/// process(es) → CATapDescription(mutedWhenTapped) → private aggregate device
///             (main sub-device = current output, drift-compensated) → IOProc → StereoRingBuffer
/// ```
final class ProcessTap {
    private(set) var processObjects: [AudioObjectID]
    let ring: StereoRingBuffer

    private let tapDescription: CATapDescription
    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var format = AudioStreamBasicDescription()
    private(set) var isRunning = false

    var sampleRate: Double { format.mSampleRate }

    init(processObjects: [AudioObjectID], outputDeviceUID: String, label: String,
         ring: StereoRingBuffer) throws {
        self.processObjects = processObjects
        self.ring = ring

        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.name = "SoundPath – \(label)"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        tapDescription = desc

        do {
            try createTap()
            try createAggregate(outputUID: outputDeviceUID)
            try startIO()
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    // MARK: Setup

    private func createTap() throws {
        var id = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(tapDescription, &id), "AudioHardwareCreateProcessTap")
        tapID = id
        guard let fmt = id.tapFormat else {
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, context: "kAudioTapPropertyFormat")
        }
        guard fmt.mFormatID == kAudioFormatLinearPCM, fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              fmt.mBitsPerChannel == 32 else {
            throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, context: "Tap format (non-float32)")
        }
        format = fmt
    }

    private func createAggregate(outputUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: tapDescription.name,
            kAudioAggregateDeviceUIDKey: "com.soundpath.tap.\(tapDescription.uuid.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            ]],
        ]
        var id = AudioObjectID.unknown
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id),
                  "AudioHardwareCreateAggregateDevice")
        aggregateID = id
    }

    private func startIO() throws {
        // Everything captured by the IOProc block is resolved up front so the realtime
        // closure never retains/releases objects or allocates.
        unowned(unsafe) let ring = self.ring
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(max(format.mChannelsPerFrame, 1))

        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInput, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            let count = list.count
            guard count > 0 else { return }

            // Tap streams come after any input streams of the sub-device, so read from the end.
            if nonInterleaved {
                guard count >= channels else { return }
                let lb = list[count - channels]
                let rb = channels > 1 ? list[count - channels + 1] : lb
                guard let lp = lb.mData?.assumingMemoryBound(to: Float.self),
                      let rp = rb.mData?.assumingMemoryBound(to: Float.self) else { return }
                let frames = Int(lb.mDataByteSize) / MemoryLayout<Float>.size
                ring.write(l: lp, r: rp, stride: 1, frames: frames)
            } else {
                let b = list[count - 1]
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { return }
                let ch = Int(max(b.mNumberChannels, 1))
                let frames = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch)
                ring.write(l: p, r: ch > 1 ? p + 1 : p, stride: ch, frames: frames)
            }
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID

        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        isRunning = true
        log.notice("Tap started: \(self.tapDescription.name, privacy: .private) @ \(self.format.mSampleRate) Hz")
    }

    // MARK: Updates

    /// Updates the set of tapped processes without tearing down the aggregate device.
    func updateProcesses(_ objects: [AudioObjectID]) throws {
        guard objects != processObjects else { return }
        tapDescription.processes = objects
        var addr = AudioObjectPropertyAddress(kAudioTapPropertyDescription)
        var ref: CATapDescription = tapDescription
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        try check(status, "Set kAudioTapPropertyDescription")
        processObjects = objects
    }

    // MARK: Teardown

    func invalidate() {
        if aggregateID.isValid {
            if let ioProcID {
                if isRunning { AudioDeviceStop(aggregateID, ioProcID) }
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
        isRunning = false
    }
}
